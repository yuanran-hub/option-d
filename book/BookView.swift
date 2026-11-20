import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum BrowseMode: String, CaseIterable, Identifiable {
    case words = "单词", passages = "原文"
    var id: Self { self }
}

private let tokenRE = try! NSRegularExpression(pattern: "[A-Za-z]+(?:['’‐‑-][A-Za-z]+)*")

private func normalizedForm(_ text: String) -> String {
    text.lowercased().replacingOccurrences(of: "’", with: "'")
        .replacingOccurrences(of: "‐", with: "-").replacingOccurrences(of: "‑", with: "-")
}

func markedText(_ text: String, forms: [String: [String]], selected: String?, links: Bool) -> AttributedString {
    var owners: [String: String] = [:]
    for lemma in forms.keys.sorted() {
        for form in forms[lemma] ?? [] { owners[normalizedForm(form)] = lemma }
    }
    if let selected, let itsForms = forms[selected] {
        for form in itsForms { owners[normalizedForm(form)] = selected }
    }
    let source = text as NSString
    let matches = tokenRE.matches(in: text, range: NSRange(location: 0, length: source.length))
    var labels = Array<String?>(repeating: nil, count: matches.count)
    let lengths = Set(owners.keys.map { $0.split(separator: " ").count }).sorted()
    for length in lengths where length > 0 && length <= matches.count {
        for i in 0...(matches.count - length) {
            let range = NSUnionRange(matches[i].range, matches[i + length - 1].range)
            let spelling = normalizedForm(source.substring(with: range)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard let lemma = owners[spelling] else { continue }
            for j in i..<(i + length) where selected == nil || labels[j] != selected { labels[j] = lemma }
        }
    }
    var result = AttributedString()
    var start = 0
    var i = 0
    while i < matches.count {
        let first = i
        i += 1
        guard let lemma = labels[first] else { continue }
        while i < matches.count && labels[i] == lemma {
            let gap = NSRange(location: NSMaxRange(matches[i-1].range), length: matches[i].range.location - NSMaxRange(matches[i-1].range))
            if !source.substring(with: gap).allSatisfy({ $0.isWhitespace }) { break }
            i += 1
        }
        let range = NSUnionRange(matches[first].range, matches[i-1].range)
        result += AttributedString(source.substring(with: NSRange(location: start, length: range.location - start)))
        var word = AttributedString(source.substring(with: range))
        word.inlinePresentationIntent = .stronglyEmphasized
        word.foregroundColor = .accentColor
        if links {
            var link = URLComponents()
            link.scheme = "readingbook"
            link.host = "word"
            link.queryItems = [URLQueryItem(name: "lemma", value: lemma)]
            word.link = link.url
            if selected == lemma { word.backgroundColor = Color.accentColor.opacity(0.12) }
        }
        result += word
        start = NSMaxRange(range)
    }
    result += AttributedString(source.substring(from: start))
    return result
}

private struct WordHeading: View {
    let word: BookWord
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(word.lemma)
                .font(.system(size: 42, weight: .medium, design: .serif))
                .tracking(-0.7).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let phonetic = word.phonetic, !phonetic.isEmpty {
                Text("/\(phonetic)/").font(.system(size: 15)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

private struct Definition: View {
    let word: BookWord
    private static let prefix = try! NSRegularExpression(pattern: #"^(?:[a-z]{1,7}\.)+(?=\s)"#)
    var body: some View {
        let lines = (word.translation ?? "").split(separator: "\n")
        VStack(alignment: .leading, spacing: 7) {
            if lines.isEmpty { Text("词库暂无中文释义").foregroundStyle(.secondary) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, slice in
                let line = String(slice) as NSString
                if let part = Self.prefix.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length)) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(line.substring(with: part.range)).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                        Text(line.substring(from: NSMaxRange(part.range)).trimmingCharacters(in: .whitespaces))
                    }
                } else { Text(line as String) }
            }
        }.font(.system(size: 16)).lineSpacing(3).textSelection(.enabled)
    }
}

private struct PassageCard: View {
    let text: AttributedString
    var translation: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(text).font(.system(size: 18, design: .serif)).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                if let action {
                    Button(action: action) { Image(systemName: "arrow.up.right").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("查看这段原文中查过的词").accessibilityLabel("查看这段原文")
                }
            }
            if let translation, !translation.isEmpty {
                Text(translation).font(.system(size: 14)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 17).padding(.vertical, 14)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.08)).allowsHitTesting(false))
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
    }
}

private struct BookNotice: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    var retrySync = false
}

private struct DeletionReceipt: Codable {
    let word: String
    let token: String
}

struct BookView: View {
    @ObservedObject var store: BookStore
    @ObservedObject var controls: BookDelegate
    @State private var mode: BrowseMode = .words
    @State private var query = ""
    @State private var wordIDs: [String] = []
    @State private var passages: [Passage] = []
    @State private var wordShuffle = BookShuffle("words")
    @State private var passageShuffle = BookShuffle("passages")
    @State private var selectedWord: String?
    @State private var detailPosition = ScrollPosition(edge: .top)
    @State private var selectedPassage: String?
    @State private var passageWord: String?
    @AppStorage("readingBookOrder") private var order: BookOrder = .newest
    @AppStorage("readingBookUndo") private var undoData = Data()
    @State private var editingWord = false
    @State private var editingSearch = false
    @State private var notice: BookNotice?
    @State private var backingUp = false
    @FocusState private var searching: Bool
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 204, idealWidth: 240, maxWidth: 278)
            VStack(spacing: 0) {
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                if activeWord != nil || undoReceipt != nil { reviewBar }
            }.frame(minWidth: 405, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 665, minHeight: 430)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("打开 Word 文稿") {
                        if !NSWorkspace.shared.open(store.location.wordDocument) {
                            notice = BookNotice(title: "未能打开文稿", detail: "请确认 Word 文稿已生成，并且 Mac 上有可以打开它的应用。")
                        }
                    }
                    Button("导出完整词库（JSON）…") { save(.json) }
                    Divider()
                    Button("备份词库…") { save(.zip) }.disabled(backingUp)
                } label: { Label("导出与备份", systemImage: "square.and.arrow.up") }
                .menuIndicator(.hidden).help("导出与备份")
            }
        }
        .onAppear { updateResults(newRound: order == .random) }
        .onChange(of: store.revision) { updateResults() }
        .onChange(of: order) { updateResults(preferMatch: true, newRound: order == .random) }
        .onChange(of: selectedPassage) { choosePassageWord() }
        .onChange(of: mode) { endSearch() }
        .onChange(of: phase) { if phase == .active { store.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .bookFind)) { _ in beginSearch() }
        .onReceive(NotificationCenter.default.publisher(for: .bookMove)) { note in
            if let direction = note.object as? Int { moveSelection(by: direction) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookReopen)) { _ in endSearch() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in controls.cancelHold() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in controls.cancelHold() }
        .alert(item: $notice) { message in
            if message.retrySync {
                return Alert(title: Text(message.title), message: Text(message.detail),
                             primaryButton: .default(Text("重新同步")) { edit("sync", receipt: DeletionReceipt(word: "", token: "")) },
                             secondaryButton: .cancel(Text("稍后")))
            }
            return Alert(title: Text(message.title), message: Text(message.detail), dismissButton: .default(Text("好")))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    if editingSearch {
                        TextField("搜索单词、中文或原文", text: Binding(get: { query }, set: setQuery))
                            .textFieldStyle(.plain).focused($searching)
                            .accessibilityLabel("搜索单词、中文或原文").onSubmit { endSearch() }
                            .onAppear { searching = true }
                    } else {
                        Text(query.isEmpty ? "搜索单词、中文或原文" : query)
                            .foregroundStyle(query.isEmpty ? .secondary : .primary)
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isButton).accessibilityAction { beginSearch() }
                    }
                    if !query.isEmpty {
                        Button { setQuery("") } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                    }
                }
                .contentShape(Rectangle()).onTapGesture { beginSearch() }
                .font(.system(size: 13)).padding(.horizontal, 12).frame(height: 33)
                .glassEffect(.regular, in: Capsule())
                HStack {
                    modePicker
                    Spacer(minLength: 6)
                    Menu {
                        Picker("排序", selection: $order) {
                            ForEach(BookOrder.allCases) { value in Text(value.title).tag(value) }
                        }.pickerStyle(.inline).labelsHidden()
                        if order == .random {
                            Divider()
                            Button("重新洗牌", systemImage: "shuffle") { updateResults(newRound: true) }
                                .disabled((mode == .words ? wordIDs.count : passages.count) < 2)
                        }
                    } label: { Image(systemName: order == .random ? "shuffle" : "arrow.up.arrow.down") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .padding(.horizontal, 6).frame(minWidth: 32, minHeight: 27)
                        .glassEffect(.regular, in: Capsule())
                        .accessibilityLabel("排序")
                        .help("排序 · " + order.title)
                }
            }.padding(.horizontal, 13).padding(.top, 15).padding(.bottom, 10)
            if mode == .words {
                CenteredWordList(words: wordIDs, selection: $selectedWord)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(passages) { passage in
                                Button { selectedPassage = passage.id } label: {
                                    Text(passage.text).font(.system(size: 14, design: .serif))
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background {
                                    if selectedPassage == passage.id {
                                        Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                                    }
                                }
                                .accessibilityAddTraits(selectedPassage == passage.id ? .isSelected : [])
                            }
                        }.padding(.horizontal, 7).padding(.vertical, 4)
                    }
                    .onChange(of: selectedPassage, initial: true) {
                        if let selectedPassage { reader.scrollTo(selectedPassage) }
                    }
                    .accessibilityLabel("原文列表")
                }
            }
            if backingUp {
                HStack { ProgressView().controlSize(.small); Text("正在备份词库").font(.caption) }
                    .padding(12)
            }
            if let problem = store.problem {
                VStack(alignment: .leading, spacing: 4) {
                    Text("词库暂时无法更新").font(.callout)
                    Button("重新读取") { store.refresh() }.help(problem)
                }.padding(12)
            }
        }.frame(maxHeight: .infinity)
        .background {
            LinearGradient(colors: [.cyan.opacity(0.075), .clear, .indigo.opacity(0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .background(.regularMaterial)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(BrowseMode.allCases) { item in
                Button { mode = item } label: {
                    Text(item.rawValue).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(mode == item ? .primary : .secondary)
                        .frame(width: 45, height: 27).contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == item ? .isSelected : [])
            }
        }
        .background(alignment: .leading) {
            Color.clear.frame(width: 45, height: 27)
                .glassEffect(.regular, in: Capsule())
                .offset(x: mode == .words ? 0 : 45)
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: mode)
                .allowsHitTesting(false)
        }
        .padding(2).background(.primary.opacity(0.07), in: Capsule())
        .accessibilityElement(children: .contain).accessibilityLabel("浏览方式")
    }

    @ViewBuilder private var detail: some View {
        if !store.loaded {
            ProgressView().controlSize(.small)
        } else if mode == .words, let id = selectedWord, let word = store.index.byWord[id], wordIDs.contains(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    WordHeading(word: word)
                    if controls.showsMeaning { Definition(word: word) }
                    if let contexts = word.contexts, !contexts.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel(text: "阅读原文")
                            ForEach(contexts, id: \.text) { c in
                                PassageCard(text: markedText(c.text, forms: [id: c.forms ?? [id]], selected: id, links: false),
                                            action: { openPassage(c.text, lemma: id) })
                            }
                        }
                    } else if let example = word.example {
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel(text: "例句")
                            PassageCard(text: markedText(example.text, forms: [id: [id] + (word.forms ?? [])], selected: id, links: false),
                                        translation: controls.showsMeaning ? example.translation : nil)
                        }
                    }
                }.padding(30).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($detailPosition)
            .onChange(of: id, initial: true) { detailPosition.scrollTo(edge: .top) }
            .accessibilityLabel("词条详情")
        } else if mode == .passages, let passage = currentPassage {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SectionLabel(text: "阅读原文")
                    PassageCard(text: markedText(passage.text, forms: passage.words, selected: passageWord, links: true))
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "readingbook",
                                  let lemma = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
                                  passage.words[lemma] != nil else { return .discarded }
                            passageWord = lemma
                            return .handled
                        })
                    Picker("原文中的词", selection: $passageWord) {
                        ForEach(orderedWords(passage), id: \.self) { lemma in Text(lemma).tag(Optional(lemma)) }
                    }.pickerStyle(.menu).fixedSize().accessibilityLabel("选择原文中的词")
                    if let id = passageWord, let word = store.index.byWord[id] {
                        Divider()
                        WordHeading(word: word)
                        if controls.showsMeaning { Definition(word: word) }
                        Button("查看这个词的全部原文") { openWord(id) }.buttonStyle(.link)
                    }
                }.padding(30).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }.id(passage.id)
        } else if mode == .words ? !wordIDs.isEmpty : !passages.isEmpty {
            ContentUnavailableView(mode == .words ? "选择一个单词" : "选择一段原文", systemImage: "book")
        } else if !query.isEmpty {
            ContentUnavailableView("没有匹配的结果", systemImage: "magnifyingglass", description: Text("试试单词原形、中文释义，或原句中的几个词。"))
        } else if store.problem != nil && store.index.words.isEmpty {
            ContentUnavailableView("无法读取词库", systemImage: "book.closed", description: Text("请使用左下方的「重新读取」。"))
        } else {
            ContentUnavailableView(mode == .words ? "生词本还是空的" : "尚未收录原文", systemImage: "book",
                                   description: Text(mode == .words ? "复制英文后按 ⌥D，查过的词会出现在这里。" : "复制一段英文后按 ⌥D，再点选其中的词。"))
        }
    }

    private var currentPassage: Passage? { passages.first { $0.id == selectedPassage } }
    private func orderedWords(_ passage: Passage) -> [String] {
        var positions: [String: Int] = [:]
        let source = passage.text as NSString
        for match in tokenRE.matches(in: passage.text, range: NSRange(location: 0, length: source.length)) {
            let key = normalizedForm(source.substring(with: match.range))
            if positions[key] == nil { positions[key] = match.range.location }
        }
        func offset(_ id: String) -> Int {
            (passage.words[id] ?? [id]).compactMap { positions[normalizedForm($0)] }.min() ?? NSNotFound
        }
        return passage.words.keys.sorted {
            let a = offset($0), b = offset($1)
            return a == b ? $0 < $1 : a < b
        }

    }
    private func choosePassageWord() {
        guard let passage = currentPassage else { passageWord = nil; return }
        if let id = passageWord, passage.words[id] != nil { return }
        passageWord = orderedWords(passage).first
    }
    private func updateResults(preferMatch: Bool = false, newRound: Bool = false) {
        let oldWordIndex = selectedWord.flatMap { wordIDs.firstIndex(of: $0) } ?? 0
        let oldPassageIndex = passages.firstIndex { $0.id == selectedPassage } ?? 0
        let index = store.index
        let text = BookIndex.searchText(query)
        wordIDs = order.arrange(index.words, matching: { text.isEmpty || index.wordText[$0.id]?.contains(text) == true },
                                added: { $0.first_seen ?? $0.last_seen ?? "" },
                                shuffle: wordShuffle, newRound: newRound).map(\.id)
        passages = order.arrange(index.passages, matching: { text.isEmpty || index.passageText[$0.id]?.contains(text) == true },
                                 added: { $0.added }, shuffle: passageShuffle, newRound: newRound)
        if newRound {
            controls.cancelHold()
            selectedWord = wordIDs.first
            selectedPassage = passages.first?.id
        } else if preferMatch {
            let exact = BookIndex.searchText(query)
            selectedWord = wordIDs.first { id in
                ([id] + (store.index.byWord[id]?.forms ?? [])).contains { BookIndex.searchText($0) == exact }
            } ?? wordIDs.first
            selectedPassage = passages.first?.id
        } else {
            if selectedWord.map(wordIDs.contains) != true {
                selectedWord = wordIDs.isEmpty ? nil : wordIDs[min(oldWordIndex, wordIDs.count - 1)]
            }
            if !passages.contains(where: { $0.id == selectedPassage }) {
                selectedPassage = passages.isEmpty ? nil : passages[min(oldPassageIndex, passages.count - 1)].id
            }
        }
        choosePassageWord()
    }
    private func openPassage(_ text: String, lemma: String) {
        query = ""
        updateResults()
        selectedPassage = text
        passageWord = lemma
        mode = .passages
    }
    private func openWord(_ lemma: String) {
        query = ""
        updateResults()
        mode = .words
        selectedWord = lemma
        searching = false
    }
    private var activeWord: String? {
        mode == .words ? selectedWord : passageWord
    }
    private var undoReceipt: DeletionReceipt? {
        try? JSONDecoder().decode(DeletionReceipt.self, from: undoData)
    }
    private func beginSearch() {
        controls.cancelHold()
        editingSearch = true
        searching = true
    }
    private func setQuery(_ value: String) {
        query = value
        updateResults(preferMatch: true)
    }
    private func endSearch() {
        searching = false
        editingSearch = false
    }
    private func moveSelection(by direction: Int) {
        guard !editingWord, let id = activeWord else { return }
        let sequence = mode == .words ? wordIDs : currentPassage.map(orderedWords) ?? []
        guard let index = sequence.firstIndex(of: id), sequence.indices.contains(index + direction) else { return }
        let next = sequence[index + direction]
        if mode == .words { selectedWord = next } else { passageWord = next }
    }

    private var reviewBar: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 10) {
                if let id = activeWord {
                    Button {
                        edit("delete", receipt: DeletionReceipt(word: id, token: UUID().uuidString))
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.glass).buttonBorderShape(.circle).help("删除「" + id + "」及其原文记录")
                    .accessibilityLabel("删除词条 " + id).disabled(editingWord)
                }
                if let undo = undoReceipt {
                    Button("撤销删除") { edit("undo", receipt: undo) }
                        .buttonStyle(.glass).font(.callout).disabled(editingWord)
                        .help("恢复「" + undo.word + "」及原文")
                }
                Spacer()
                if activeWord != nil {
                    Text("方向键切词").font(.caption).foregroundStyle(.secondary)
                    Label("按住空格看释义", systemImage: controls.showsMeaning ? "eye.fill" : "eye")
                        .font(.callout).padding(.horizontal, 12).frame(height: 29)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .contentShape(Capsule())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in if !controls.pointerHeld { controls.pointerHeld = true } }
                            .onEnded { _ in controls.pointerHeld = false })
                        .onDisappear { if controls.pointerHeld { controls.pointerHeld = false } }
                        .help("也可以用鼠标按住这里查看释义，松开即遮住")
                }
            }.padding(.horizontal, 23).frame(height: 49)
        }
    }

    private func edit(_ action: String, receipt: DeletionReceipt) {
        guard !editingWord else { return }
        editingWord = true
        let root = store.location.root
        BookDelegate.beginWrite()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try BookTools.run("book_edit.py", [root.path, action, receipt.word, receipt.token])
                let result = try JSONDecoder().decode(EditResult.self, from: data)
                DispatchQueue.main.async {
                    if action == "delete" { undoData = (try? JSONEncoder().encode(receipt)) ?? Data() }
                    if action == "undo" { undoData = Data() }
                    if let warning = result.warning {
                        notice = BookNotice(title: "词库已保存，文稿同步未完成", detail: warning, retrySync: true)
                    }
                    editingWord = false
                    store.refresh()
                    BookDelegate.endWrite()
                }
            } catch {
                DispatchQueue.main.async {
                    editingWord = false
                    notice = BookNotice(title: "操作未完成", detail: error.localizedDescription)
                    store.refresh()
                    BookDelegate.endWrite()
                }
            }
        }
    }

    private struct EditResult: Decodable { let warning: String? }
    private func save(_ type: UTType) {
        let isBackup = type == .zip
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = isBackup ? "阅读生词本备份.zip" : "阅读生词本.json"
        panel.begin { answer in
            guard answer == .OK, let destination = panel.url else { return }
            let location = store.location
            BookDelegate.beginWrite()
            if isBackup { backingUp = true }
            DispatchQueue.global(qos: .utility).async {
                do {
                    if isBackup {
                        _ = try BookTools.run("book_backup.py", [location.root.path, destination.path])
                    } else {
                        try Data(contentsOf: location.json).write(to: destination, options: .atomic)
                    }
                    DispatchQueue.main.async {
                        if isBackup { backingUp = false }
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                        BookDelegate.endWrite()
                    }
                } catch {
                    DispatchQueue.main.async {
                        if isBackup { backingUp = false }
                        notice = BookNotice(title: isBackup ? "备份未完成" : "导出未完成", detail: error.localizedDescription)
                        BookDelegate.endWrite()
                    }
                }
            }
        }
    }
}

enum BookTools {
    static func run(_ script: String, _ arguments: [String]) throws -> Data {
        let resources = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let task = pythonProcess(resources: resources)
        task.arguments = ["-B", resources.appendingPathComponent("runtime/book/" + script).path] + arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "ReadingBook", code: 1, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return data
    }
}

extension Notification.Name {
    static let bookFind = Self("ReadingBook.Find")
    static let bookMove = Self("ReadingBook.Move")
    static let bookReopen = Self("ReadingBook.Reopen")
}
