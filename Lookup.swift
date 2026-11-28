import AppKit
import Carbon
import NaturalLanguage

let backendPath = Bundle.main.resourceURL!.appendingPathComponent("runtime/backend.py").path

final class ReadingTextView: NSTextView {
    var passageSelection: ((NSRange) -> Void)?
    // Track the gesture before following a word link. A drag must never also look up its first word.
    override func mouseDown(with event: NSEvent) {
        guard let passageSelection, let window, let layout = layoutManager, let container = textContainer else {
            super.mouseDown(with: event)
            return
        }
        let down = convert(event.locationInWindow, from: nil)
        let anchor = characterIndexForInsertion(at: down)
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if hypot(point.x - down.x, point.y - down.y) >= 3 { dragged = true }
            if dragged {
                _ = autoscroll(with: next)
                let end = characterIndexForInsertion(at: convert(next.locationInWindow, from: nil))
                setSelectedRange(NSRange(location: min(anchor, end), length: abs(end - anchor)))
            }
            if next.type == .leftMouseUp {
                if dragged {
                    if selectedRange().length > 0 { passageSelection(selectedRange()) }
                } else if layout.numberOfGlyphs > 0 {
                    let origin = textContainerOrigin
                    let p = NSPoint(x: down.x - origin.x, y: down.y - origin.y)
                    let glyph = layout.glyphIndex(for: p, in: container)
                    guard glyph < layout.numberOfGlyphs else { break }
                    let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                    if box.contains(p) {
                        passageSelection(NSRange(location: layout.characterIndexForGlyph(at: glyph), length: 1))
                    }
                }
                break
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PassageBox: NSBox {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    func updateColors() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        fillColor = dark ? .black.withAlphaComponent(0.18) : .white.withAlphaComponent(0.24)
        borderColor = dark ? .white.withAlphaComponent(0.14) : .black.withAlphaComponent(0.08)
    }
}

final class LookupPanel: NSPanel {
    var onDismiss: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onDismiss?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

final class LookupProvider: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate, NSToolbarDelegate {
    var panel: NSPanel?
    var input: NSSearchField!
    var headword: NSTextField!
    var bodyStack: NSStackView!
    var contextCard: NSBox!
    var meaningScroll: NSScrollView!
    var meaningHeight: NSLayoutConstraint!
    var contextHeight: NSLayoutConstraint!
    var statusIcon: NSImageView!
    var markedWords: [NSRange] = []
    var selectedParts: [Int] = []
    var meaning: NSTextView!
    var status: NSTextField!
    var info: NSTextField!
    var statusItem: NSStatusItem?
    var hotKey: EventHotKeyRef?
    var returnApplication: NSRunningApplication?
    var shortcutAvailable = false
    var contextView: NSTextView!
    var contextScroll: NSScrollView!
    var copiedContext = ""
    var lookupSource = ""
    var tokenRanges: [NSRange] = []
    var worker: Process?
    var workerInput: FileHandle?
    var currentRequest = ""
    var pending: [String: [String: Any]] = [:]
    var alternate: NSButton!
    var scanID = ""
    var phraseRow: NSStackView!
    var online: NSButton!
    struct PhraseChoice {
        let range: NSRange
        let parts: [Int]?
        let lemma: String
    }
    var phraseRanges: [PhraseChoice] = []
    private let pipeQueue = DispatchQueue(label: "lookup.requests")
    var selectedSurface = ""
    var selectedHint = ""

    private let bodyInset: CGFloat = 24
    private let bodyTop: CGFloat = 12
    private let footerHeight: CGFloat = 48
    private let contextInset: CGFloat = 16
    private let passageFont: NSFont = {
        let font = NSFont.systemFont(ofSize: 18)
        return NSFont(descriptor: font.fontDescriptor.withDesign(.serif) ?? font.fontDescriptor, size: 18) ?? font
    }()

    func startWorker() {
        let process = pythonProcess(resources: Bundle.main.resourceURL!)
        var arguments = ["-B", backendPath, "--serve"]
        if let testRoot = ProcessInfo.processInfo.environment["IELTS_LOOKUP_TEST_ROOT"] {
            arguments += ["--root", testRoot]
        }
        process.arguments = arguments
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            worker = process
            workerInput = stdinPipe.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var buffer = Data()
                while true {
                    let chunk = stdoutPipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = buffer[..<newline]
                        buffer.removeSubrange(...newline)
                        if let result = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                            DispatchQueue.main.async { self?.receive(result) }
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard let self, self.worker === process else { return }
                    if !self.pending.isEmpty {
                        self.setStatus("部分词条尚未确认保存，请重新查词", symbol: "exclamationmark.circle")
                    }
                }
            }
        } catch { setStatus("查词服务未启动：" + error.localizedDescription, symbol: "exclamationmark.circle") }
    }

    func receive(_ result: [String: Any]) {
        guard let id = result["id"] as? String else { return }
        let event = result["event"] as? String ?? ""
        if event == "phrases" {
            if id == scanID { receivePhrases(result) }
            return
        }
        if event == "saved" || result["error"] != nil { pending.removeValue(forKey: id) }
        guard id == currentRequest else { return }
        if let error = result["error"] as? String {
            setStatus("未完成：" + error, symbol: "exclamationmark.circle")
            if event == "result" { setMeaning(error); fitPanel() }
            return
        }
        if event == "result" {
            let lemma = result["lemma"] as? String ?? selectedSurface
            let phonetic = result["phonetic"] as? String ?? ""
            headword.stringValue = lemma
            let form = selectedSurface.lowercased() == lemma.lowercased() ? "" : "来自 " + selectedSurface
            info.stringValue = [phonetic.isEmpty ? "音标待补" : "/" + phonetic + "/", form]
                .filter { !$0.isEmpty }.joined(separator: "    ·    ")
            info.isHidden = phonetic.isEmpty && selectedSurface.contains(" ")
            let translation = result["translation"] as? String ?? ""
            let missingPhrase = translation.isEmpty && selectedSurface.contains(" ")
            online.isHidden = !missingPhrase
            setMeaning(missingPhrase ? "本地未收录这个短语" : (translation.isEmpty ? "词库暂无中文释义" : translation))
            alternate.isHidden = result["has_inflection"] as? Bool != true
            alternate.title = lemma == selectedSurface.lowercased() ? "查看原形" : "查 " + selectedSurface
            setStatus("正在收录", symbol: "clock")
            fitPanel()
        } else if event == "saved" {
            if result["superseded_by_delete"] as? Bool == true {
                setStatus("已从生词本删除", symbol: "trash")
            } else if result["document_updated"] as? Bool == true {
                setStatus(copiedContext.isEmpty ? "已收录" : "已收录词条和原文", symbol: "checkmark.circle")
            } else {
                setStatus("词条已保存，文稿更新失败", symbol: "exclamationmark.circle")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        pipeQueue.sync { try? workerInput?.close() }
        guard let process = worker, process.isRunning else { return .terminateNow }
        DispatchQueue.global().async {
            process.waitUntilExit()
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.servicesProvider = self
        NSUpdateDynamicServices()
        setupClipboardShortcut()
        startWorker()
    }

    func setupClipboardShortcut() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let provider = Unmanaged<LookupProvider>.fromOpaque(context).takeUnretainedValue()
            provider.clipboardLookup()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(optionKey),
                                        EventHotKeyID(signature: 0x49454C54, id: 1),
                                        GetApplicationEventTarget(), 0, &hotKey)
        shortcutAvailable = result == noErr
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "词"
        statusItem?.button?.toolTip = "复制英文后按 ⌥D，中文释义和收录自动完成"
        let menu = NSMenu()
        let lookupItem = NSMenuItem(title: "查复制的单词（⌥D）", action: #selector(clipboardLookup), keyEquivalent: "d")
        lookupItem.keyEquivalentModifierMask = .option
        lookupItem.target = self
        menu.addItem(lookupItem)
        let documentItem = NSMenuItem(title: "打开阅读生词本", action: #selector(openBook), keyEquivalent: "")
        documentItem.target = self
        menu.addItem(documentItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出查词", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc func clipboardLookup() {
        guard let term = NSPasteboard.general.string(forType: .string), !term.isEmpty else {
            showPanel(term: "", source: "复制后查词", performLookup: false)
            setStatus("剪贴板里没有可查的文字", symbol: "clipboard")
            return
        }
        let source = NSWorkspace.shared.frontmostApplication?.localizedName ?? "复制后查词"
        showPanel(term: term, source: source + " · 复制后查词", performLookup: true)
    }

    @objc func quit() { NSApplication.shared.terminate(nil) }

    @objc func lookup(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let term = pasteboard.string(forType: .string) else {
            error.pointee = "没有收到选中的英文。" as NSString
            return
        }
        let source = NSWorkspace.shared.frontmostApplication?.localizedName ?? "选词查词"
        showPanel(term: term, source: source, performLookup: true)
    }

    private let searchID = NSToolbarItem.Identifier("LookupSearch")
    private let pasteID = NSToolbarItem.Identifier("LookupClipboard")
    private let bookID = NSToolbarItem.Identifier("LookupDocument")
    private var searchItem: NSSearchToolbarItem!

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, searchID, pasteID, bookID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == searchID {
            searchItem = NSSearchToolbarItem(itemIdentifier: id)
            input = searchItem.searchField
            input.placeholderString = "输入单词或原文"
            input.setAccessibilityLabel("输入单词或原文，回车查词")
            input.sendsWholeSearchString = true
            input.target = self
            input.action = #selector(manualLookup)
            searchItem.preferredWidthForSearchField = 168
            searchItem.toolTip = "手动查词"
            return searchItem
        }
        guard id == pasteID || id == bookID else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        let paste = id == pasteID
        item.label = paste ? "查剪贴板" : "生词本"
        item.isBordered = true
        item.toolTip = paste ? "查剪贴板中的英文（⌥D）" : "打开生词本"
        item.image = NSImage(systemSymbolName: paste ? "clipboard" : "book", accessibilityDescription: item.label)
        item.target = self
        item.action = paste ? #selector(clipboardLookup) : #selector(openBook)
        return item
    }

    private func readingView(in scroll: NSScrollView, label: String) -> NSTextView {
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let text = ReadingTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.textContainerInset = .zero
        text.setAccessibilityLabel(label)
        scroll.documentView = text
        return text
    }

    func makePanel() {
        let window = LookupPanel(contentRect: NSRect(x: 0, y: 0, width: 502, height: 216),
                                 styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel = window
        window.title = "查词"
        window.toolbarStyle = .unifiedCompact
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let toolbar = NSToolbar(identifier: "LookupTools")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window.toolbar = toolbar
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onDismiss = { [weak self] in self?.closePanel() }
        window.delegate = self
        let surface = NSVisualEffectView()
        surface.material = .sidebar
        surface.blendingMode = .behindWindow
        surface.state = .active
        window.contentView = surface
        let contentTop = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? surface.safeAreaLayoutGuide.topAnchor

        bodyStack = NSStackView()
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 7
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(bodyStack)

        let passageBox = PassageBox()
        contextCard = passageBox
        contextCard.boxType = .custom
        contextCard.titlePosition = .noTitle
        contextCard.contentViewMargins = .zero
        contextCard.borderWidth = 1
        contextCard.cornerRadius = 15
        passageBox.updateColors()
        let card = contextCard.contentView!
        let caption = NSTextField(labelWithString: "阅读原文")
        caption.font = .systemFont(ofSize: 13, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(caption)
        contextScroll = NSScrollView()
        contextView = readingView(in: contextScroll, label: "原文，点按单词查义")
        contextView.delegate = self
        (contextView as? ReadingTextView)?.passageSelection = { [weak self] range in self?.selectPassage(range) }
        contextView.textColor = .labelColor
        contextView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        contextScroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contextScroll)
        contextHeight = contextCard.heightAnchor.constraint(equalToConstant: 75)
        NSLayoutConstraint.activate([
            caption.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: contextInset),
            caption.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            contextScroll.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            contextScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -contextInset),
            contextScroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 6),
            contextScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            contextHeight
        ])

        headword = NSTextField(labelWithString: "")
        let titleFont = NSFont.systemFont(ofSize: 38, weight: .medium)
        let descriptor = titleFont.fontDescriptor.withDesign(.serif) ?? titleFont.fontDescriptor
        headword.font = NSFont(descriptor: descriptor, size: 38) ?? titleFont
        headword.isSelectable = true
        headword.lineBreakMode = .byTruncatingTail
        info = NSTextField(labelWithString: "")
        info.font = .systemFont(ofSize: 14)
        info.textColor = .secondaryLabelColor
        info.isSelectable = true
        meaningScroll = NSScrollView()
        meaning = readingView(in: meaningScroll, label: "中文释义")
        meaningHeight = meaningScroll.heightAnchor.constraint(equalToConstant: 28)
        meaningHeight.priority = .defaultHigh
        meaningHeight.isActive = true

        alternate = NSButton(title: "", target: self, action: #selector(toggleLemma))
        alternate.bezelStyle = .glass
        alternate.borderShape = .capsule
        alternate.controlSize = .small
        alternate.font = .systemFont(ofSize: 12)
        alternate.toolTip = "切换所查拼写和词典原形"
        phraseRow = NSStackView()
        phraseRow.orientation = .horizontal
        phraseRow.spacing = 6
        phraseRow.alignment = .centerY
        phraseRow.distribution = .gravityAreas
        online = NSButton(title: "联网查短语 ↗", target: self, action: #selector(searchOnline))
        online.bezelStyle = .glass
        online.controlSize = .small
        online.toolTip = "在浏览器中用有道查询所选短语"
        for view in [contextCard!, phraseRow!, headword!, info!, meaningScroll!, alternate!, online!] as [NSView] {
            bodyStack.addArrangedSubview(view)
            if view !== alternate && view !== online { view.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true }
        }
        bodyStack.setCustomSpacing(6, after: contextCard)
        bodyStack.setCustomSpacing(2, after: headword)
        bodyStack.setCustomSpacing(14, after: info)

        statusIcon = NSImageView()
        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.setAccessibilityElement(false)
        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let footer = NSStackView(views: [statusIcon, status])
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(footer)
        let close = NSButton(title: "Esc 收起", target: self, action: #selector(closePanel))
        close.controlSize = .small
        close.bezelStyle = .glass
        close.borderShape = .capsule
        close.keyEquivalent = "\u{1b}"
        close.keyEquivalentModifierMask = []
        close.font = .systemFont(ofSize: 12)
        close.toolTip = "收起浮窗，返回阅读"
        close.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(close)
        NSLayoutConstraint.activate([
            bodyStack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: bodyInset),
            bodyStack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -bodyInset),
            bodyStack.topAnchor.constraint(equalTo: contentTop, constant: bodyTop),
            bodyStack.bottomAnchor.constraint(lessThanOrEqualTo: surface.bottomAnchor, constant: -footerHeight),
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14),
            footer.leadingAnchor.constraint(equalTo: bodyStack.leadingAnchor),
            footer.centerYAnchor.constraint(equalTo: surface.bottomAnchor, constant: -footerHeight / 2),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -10),
            close.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -bodyInset),
            close.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        for view in bodyStack.arrangedSubviews { view.isHidden = true }
    }

    private func setStatus(_ message: String, symbol: String) {
        guard let status else { return }
        status.stringValue = message
        status.toolTip = message
        statusIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func setMeaning(_ text: String) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 4
        let styled = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: 17)
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { styled.append(NSAttributedString(string: "\n")) }
            let row = NSMutableAttributedString(string: line, attributes: [
                .font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style
            ])
            if let prefix = Self.partOfSpeech.firstMatch(in: line, range: NSRange(location: 0, length: row.length)) {
                let indent = style.mutableCopy() as! NSMutableParagraphStyle
                indent.headIndent = 42
                indent.tabStops = [NSTextTab(textAlignment: .left, location: 42)]
                row.replaceCharacters(in: NSRange(location: NSMaxRange(prefix.range), length: 1), with: "\t")
                row.addAttribute(.paragraphStyle, value: indent, range: NSRange(location: 0, length: row.length))
                row.addAttributes([.foregroundColor: NSColor.labelColor,
                                   .font: NSFont.systemFont(ofSize: 14, weight: .medium)], range: prefix.range)
            }
            styled.append(row)
        }
        meaning.textStorage?.setAttributedString(styled)
        meaningScroll.isHidden = text.isEmpty
        meaning.scrollToBeginningOfDocument(nil)
    }

    private static let partOfSpeech = try! NSRegularExpression(pattern: #"(?m)^(?:[a-z]{1,7}\.)+(?=\s)"#)
    private static let tokenPattern = try! NSRegularExpression(pattern: "[A-Za-z]+(?:['’‐‑-][A-Za-z]+)*")

    private func readingHeight(_ view: NSTextView, width: CGFloat, limit: CGFloat) -> CGFloat {
        let text = view.attributedString()
        guard text.length > 0 else { return 0 }
        let sample = text.attributedSubstring(from: NSRange(location: 0, length: min(text.length, 2048)))
        let rect = sample.boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(limit, ceil(rect.height) + 4)
    }

    private func fitPanel(keepingWindowHeight: Bool = false) {
        guard let panel, let surface = panel.contentView else { return }
        let bodyWidth = surface.bounds.width - 2 * bodyInset
        let available = keepingWindowHeight ? panel.contentLayoutRect.height : 0
        if !contextCard.isHidden {
            let cap = max(116, available - (meaningScroll.isHidden ? 110 : 250))
            contextHeight.constant = 49 + readingHeight(contextView, width: bodyWidth - 2 * contextInset - 2, limit: cap)
        }
        if !meaningScroll.isHidden {
            meaningHeight.constant = readingHeight(meaning, width: bodyWidth, limit: max(220, available - 150))
        }
        let visible = bodyStack.arrangedSubviews.filter { !$0.isHidden }
        var bodyHeight: CGFloat = 0
        for (index, view) in visible.enumerated() {
            if view === contextCard { bodyHeight += contextHeight.constant }
            else if view === phraseRow { bodyHeight += max(24, view.fittingSize.height) }
            else if view === meaningScroll { bodyHeight += meaningHeight.constant }
            else { bodyHeight += view.intrinsicContentSize.height }
            if index + 1 < visible.count {
                let gap = bodyStack.customSpacing(after: view)
                bodyHeight += gap == NSStackView.useDefaultSpacing ? bodyStack.spacing : gap
            }
        }
        let chrome = panel.frame.height - panel.contentLayoutRect.height
        let height = ceil(chrome + bodyTop + bodyHeight + footerHeight)
        let top = panel.frame.maxY
        var frame = panel.frame
        let scrollAllowance = meaningScroll.isHidden ? 0 : max(0, meaningHeight.constant - 50)
        panel.minSize = NSSize(width: 410, height: height - scrollAllowance)
        frame.size.height = keepingWindowHeight ? max(panel.minSize.height, frame.height) : height
        frame.origin.y = top - frame.height
        if let screen = panel.screen {
            frame.origin.y = max(screen.visibleFrame.minY, frame.origin.y)
            frame = panel.constrainFrameRect(frame, to: screen)
        }
        if panel.frame != frame { panel.setFrame(frame, display: panel.isVisible) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        fitPanel(keepingWindowHeight: true)
    }

    func showPanel(term: String, source: String, performLookup: Bool) {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            returnApplication = frontmost
        }
        let firstOpen = panel == nil
        if firstOpen { makePanel() }
        if performLookup { presentSelection(term, source: source) }
        else {
            resetSelection(source: source)
            setMeaning("复制英文后按 ⌥D，或点放大镜手动查词。")
            setStatus(shortcutAvailable ? "等待查词" : "⌥D 已被占用，可使用工具栏的剪贴板",
                      symbol: shortcutAvailable ? "magnifyingglass" : "exclamationmark.circle")
            fitPanel()
        }
        if firstOpen { panel?.center() }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(panel?.contentView)
    }

    @objc func manualLookup() {
        let term = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        presentSelection(term, source: "手动查词")
        panel?.makeFirstResponder(panel?.contentView)
    }

    private func resetSelection(source: String) {
        currentRequest = ""
        scanID = ""
        phraseRanges = []
        copiedContext = ""
        lookupSource = source
        markedWords = []
        selectedParts = []
        input?.stringValue = ""
        for view in bodyStack.arrangedSubviews { view.isHidden = true }
    }

    func presentSelection(_ selection: String, source: String) {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        resetSelection(source: source)
        let range = NSRange(location: 0, length: (text as NSString).length)
        tokenRanges = Self.tokenPattern.matches(in: text, range: range).map(\.range)
        guard !tokenRanges.isEmpty else {
            setMeaning("请复制一个英文单词，或一段含有英文的原文。")
            setStatus("未找到英文", symbol: "magnifyingglass")
            fitPanel()
            return
        }
        let punctuation = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        if tokenRanges.count == 1,
           Self.tokenPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
               .unicodeScalars.allSatisfy(punctuation.contains) {
            perform(term: (text as NSString).substring(with: tokenRanges[0]), source: source)
        } else {
            copiedContext = text
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: passageFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: style
            ])
            for (index, range) in tokenRanges.enumerated() {
                attributed.addAttribute(.link, value: URL(string: "lookup://word/\(index)")!, range: range)
            }
            contextView.textStorage?.setAttributedString(attributed)
            contextView.setSelectedRange(NSRange(location: 0, length: 0))
            contextView.scrollToBeginningOfDocument(nil)
            contextCard.isHidden = false
            setStatus("点单词，或拖选几个词查短语", symbol: "hand.point.up.left")
            fitPanel()
            scanID = UUID().uuidString
            send(["action": "scan", "id": scanID, "text": text])
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, let index = Int(url.lastPathComponent), tokenRanges.indices.contains(index) else { return true }
        selectPassage(tokenRanges[index])
        return true
    }

    private func receivePhrases(_ result: [String: Any]) {
        guard let choices = result["choices"] as? [[String: Any]] else { return }
        phraseRanges = choices.compactMap { item in
            guard let first = item["first"] as? Int, let last = item["last"] as? Int,
                  tokenRanges.indices.contains(first), tokenRanges.indices.contains(last), first <= last else { return nil }
            return PhraseChoice(range: NSUnionRange(tokenRanges[first], tokenRanges[last]),
                                parts: item["parts"] as? [Int], lemma: item["lemma"] as? String ?? "")
        }
        guard !phraseRanges.isEmpty else { return }
        let source = copiedContext as NSString
        if result["exact"] as? Bool == true, currentRequest.isEmpty {
            let term = source.substring(with: phraseRanges[0].range)
            copiedContext = ""
            contextCard.isHidden = true
            perform(term: term, source: lookupSource)
            fitPanel()
            return
        }
        for view in phraseRow.views(in: .leading) { phraseRow.removeView(view) }
        let label = NSTextField(labelWithString: "短语")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        phraseRow.addView(label, in: .leading)
        let names = phraseRanges.map { $0.parts == nil ? source.substring(with: $0.range).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") : $0.lemma }
        let font = NSFont.systemFont(ofSize: 12)
        var remaining = max(1, bodyStack.bounds.width - 110)
        var shown = 0
        for (i, name) in names.enumerated() {
            let width = ceil((name as NSString).size(withAttributes: [.font: font]).width) + 32
            if i > 0 && width > remaining { break }
            let button = NSButton(title: name, target: self, action: #selector(choosePhrase(_:)))
            button.tag = i
            button.bezelStyle = .glass
            button.borderShape = .capsule
            button.controlSize = .small
            button.font = font
            button.cell?.lineBreakMode = .byTruncatingTail
            button.toolTip = name
            phraseRow.addView(button, in: .leading)
            button.widthAnchor.constraint(lessThanOrEqualToConstant: remaining).isActive = true
            remaining -= width
            shown += 1
        }
        if shown < names.count {
            let more = NSPopUpButton(frame: .zero, pullsDown: true)
            more.controlSize = .small
            more.bezelStyle = .glass
            more.addItem(withTitle: "+\(names.count - shown)")
            for i in shown..<names.count {
                let item = NSMenuItem(title: names[i], action: #selector(choosePhrase(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                more.menu?.addItem(item)
            }
            phraseRow.addView(more, in: .leading)
        }
        phraseRow.isHidden = false
        fitPanel()
    }

    @objc private func choosePhrase(_ sender: AnyObject) {
        let index = (sender as? NSControl)?.tag ?? (sender as? NSMenuItem)?.tag ?? -1
        if phraseRanges.indices.contains(index) {
            let choice = phraseRanges[index]
            selectPassage(choice.range, parts: choice.parts)
        }
    }

    @objc private func searchOnline() {
        var url = URLComponents(string: "https://www.youdao.com/result")!
        url.queryItems = [URLQueryItem(name: "word", value: selectedSurface), URLQueryItem(name: "lang", value: "en")]
        if let target = url.url { NSWorkspace.shared.open(target) }
    }

    private func selectPassage(_ selection: NSRange, parts: [Int]? = nil) {
        let indices = parts ?? tokenRanges.indices.filter { NSIntersectionRange(tokenRanges[$0], selection).length > 0 }
        guard indices.allSatisfy(tokenRanges.indices.contains) else { return }
        let tokens = indices.map { tokenRanges[$0] }
        guard let first = tokens.first, let last = tokens.last else { return }
        let range = NSUnionRange(first, last)
        let surface = (copiedContext as NSString).substring(with: range)
        if tokens.count > 1 && parts == nil {
            let rest = Self.tokenPattern.stringByReplacingMatches(in: surface, range: NSRange(location: 0, length: (surface as NSString).length), withTemplate: "")
            guard tokens.count <= 16 && rest.allSatisfy({ $0.isWhitespace }) else {
                setStatus("请选择一段连续的英文短语", symbol: "text.cursor")
                return
            }
        }
        for previous in markedWords {
            contextView.textStorage?.addAttribute(.font, value: passageFont, range: previous)
            contextView.textStorage?.addAttribute(.foregroundColor, value: NSColor.labelColor, range: previous)
        }
        selectedParts = indices
        markedWords = parts == nil ? [range] : tokens
        for mark in markedWords {
            contextView.textStorage?.addAttributes([
                .foregroundColor: NSColor.controlAccentColor,
                .font: NSFontManager.shared.convert(passageFont, toHaveTrait: .boldFontMask)
            ], range: mark)
        }
        contextView.setSelectedRange(NSRange(location: range.location, length: 0))
        let word = tokens.map { (copiedContext as NSString).substring(with: $0) }.joined(separator: " ")
        var hint = ""
        if tokens.count == 1, let swiftRange = Range(range, in: copiedContext) {
            let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
            tagger.string = copiedContext
            tagger.setLanguage(.english, range: copiedContext.startIndex..<copiedContext.endIndex)
            hint = tagger.tag(at: swiftRange.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? ""
            let lexicalClass = tagger.tag(at: swiftRange.lowerBound, unit: .word, scheme: .lexicalClass).0
            if hint.lowercased() == word.lowercased() && lexicalClass == .verb { hint = "" }
        }
        perform(term: word.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "), source: lookupSource, hint: hint)
    }

    @objc func toggleLemma() {
        // Explicitly querying the literal spelling preserves independently valid words.
        let hint = selectedHint == selectedSurface.lowercased() ? "" : selectedSurface.lowercased()
        perform(term: selectedSurface, source: lookupSource, hint: hint)
    }

    func perform(term: String, source: String, hint: String = "") {
        online.isHidden = true
        headword.stringValue = term
        headword.isHidden = false
        info.isHidden = true
        alternate.isHidden = true
        setMeaning("")
        setStatus("正在查词", symbol: "magnifyingglass")
        selectedSurface = term
        selectedHint = hint
        let id = UUID().uuidString
        currentRequest = id
        let request: [String: Any] = ["id": id, "term": term, "source": source, "context": copiedContext, "lemma_hint": hint, "parts": selectedParts]
        pending[id] = request
        send(request)
    }

    private func send(_ request: [String: Any]) {
        if worker?.isRunning != true { startWorker() }
        guard let id = request["id"] as? String else { return }
        guard let pipe = workerInput, worker?.isRunning == true else {
            pending.removeValue(forKey: id)
            return
        }
        pipeQueue.async {
            do {
                let bytes = try JSONSerialization.data(withJSONObject: request)
                try pipe.write(contentsOf: bytes + Data([10]))
            } catch {
                DispatchQueue.main.async {
                    self.pending.removeValue(forKey: id)
                    if self.currentRequest == id { self.setStatus("查词服务不可用，请重试", symbol: "exclamationmark.circle") }
                }
            }
        }
    }

    private var bookFocusObserver: NSObjectProtocol?

    @objc func openBook() {
        let book = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/阅读生词本.app")
        let workspace = NSWorkspace.shared
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let root = ProcessInfo.processInfo.environment["IELTS_LOOKUP_TEST_ROOT"] {
            config.environment = ["IELTS_LOOKUP_TEST_ROOT": root]
        }
        if bookFocusObserver == nil, let bookID = Bundle(url: book)?.bundleIdentifier {
            bookFocusObserver = workspace.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let active = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.panel?.level = active?.bundleIdentifier == bookID ? .normal : .floating
            }
        }
        workspace.openApplication(at: book, configuration: config) { _, error in
            if let error {
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
    }

    @objc func closePanel() {
        currentRequest = ""
        scanID = ""
        panel?.orderOut(nil)
        returnApplication?.activate(options: [])
    }
    func windowWillClose(_ notification: Notification) { closePanel() }
}

@main
enum OptionDApp {
    static func main() {
        let application = NSApplication.shared
        let provider = LookupProvider()
        application.delegate = provider
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(provider) { application.run() }
    }
}
