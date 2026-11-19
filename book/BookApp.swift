import AppKit
import SwiftUI

final class BookDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private static var writes = 0
    private static var quitting = false
    private var keys: Any?
    @Published private(set) var spaceHeld = false
    @Published var pointerHeld = false
    var showsMeaning: Bool { spaceHeld || pointerHeld }

    func applicationDidFinishLaunching(_ notification: Notification) {
        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.route(event, in: NSApp.keyWindow)
        }
    }

    func cancelHold() {
        if spaceHeld { spaceHeld = false }
        if pointerHeld { pointerHeld = false }
    }

    func applicationWillResignActive(_ notification: Notification) { cancelHold() }

    func route(_ event: NSEvent, in keyWindow: NSWindow?) -> NSEvent? {
        // A key can be released after the modifiers or first responder have changed.
        if event.type == .keyUp {
            if event.keyCode == 49 && spaceHeld { spaceHeld = false; return nil }
            return event
        }
        guard let window = keyWindow, event.window == nil || window == event.window, !(window is NSPanel),
              window.sheetParent == nil, window.attachedSheet == nil, NSApp.modalWindow == nil,
              RunLoop.current.currentMode != .eventTracking,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
        let editor = window.firstResponder as? NSTextView
        switch event.keyCode {
        case 53 where editor?.hasMarkedText() != true:
            cancelHold()
            window.performClose(nil)
            return nil
        case 49 where editor?.isEditable != true:
            if !event.isARepeat && !spaceHeld { spaceHeld = true }
            return nil
        case 123, 124, 125, 126:
            guard editor?.isEditable != true else { return event }
            let direction = (event.keyCode == 124 || event.keyCode == 125) ? 1 : -1
            NotificationCenter.default.post(name: .bookMove, object: direction)
            return nil
        default:
            return event
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        cancelHold()
        NotificationCenter.default.post(name: .bookReopen, object: nil)
        return true
    }

    static func beginWrite() { writes += 1 }
    static func endWrite() {
        writes -= 1
        if writes == 0 && quitting { NSApp.reply(toApplicationShouldTerminate: true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.writes > 0 else { return .terminateNow }
        Self.quitting = true
        return .terminateLater
    }
}

@main
struct ReadingBookApp: App {
    @NSApplicationDelegateAdaptor(BookDelegate.self) private var delegate
    @StateObject private var store = BookStore()
    var body: some Scene {
        Window("阅读生词本", id: "reading-book") { BookView(store: store, controls: delegate) }
            .defaultSize(width: 870, height: 555)
            .commands {
                CommandGroup(after: .textEditing) {
                    Button("搜索词库") { NotificationCenter.default.post(name: .bookFind, object: nil) }
                        .keyboardShortcut("f", modifiers: .command)
                }
            }
    }
}
