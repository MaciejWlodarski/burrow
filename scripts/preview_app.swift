import SwiftUI
import AppKit

@main
struct NativePreview {
    @MainActor static func main() throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_PREVIEW_OUTPUT"]!, isDirectory: true)
        let fixture = base.appendingPathComponent("Pracownia", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        for folder in ["Dokumenty", "Fotografie", "Projekty", "Archiwum"] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for name in ["Notatki ze spotkania.md", "Plan projektu.txt", "README.md", "Szkice.svg", "Zestawienie.csv"] {
            try Data("Burrow preview\n".utf8).write(to: fixture.appendingPathComponent(name))
        }
        UserDefaults.standard.setVolatileDomain([
            "bf.openTabPaths": [fixture.path], "bf.showInspector": false,
            "bf.showSidebar": true, "bf.isDualPane": false
        ], forName: UserDefaults.argumentDomain)
        FSearchIndex.shared.configuredRoots = [fixture.path]
        FSearchIndex.shared.usePersistentMMapCache = false
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                var candidate: NSWindow?
                for _ in 0..<50 {
                    candidate = NSApp.windows.first(where: { !($0 is NSPanel) })
                    if candidate != nil { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let window = candidate else {
                    print("WINDOWS: \(NSApp.windows.map { "\($0.title): visible=\($0.isVisible), class=\(type(of: $0))" })")
                    require(false, "no app window after launch"); return
                }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.setContentSize(NSSize(width: 1180, height: 730))
                NSApp.appearance = NSAppearance(named: .aqua)
                try? await Task.sleep(for: .milliseconds(400))
                let state = AppState.shared
                let pane = state.activeTab
                require(window.firstResponder is FileDragSourceView, "file pane must receive initial keyboard focus")
                postKey(125, "\u{f701}", window: window)
                try? await Task.sleep(for: .milliseconds(100))
                require(pane.selectedItems.count == 1, "Down must select a file")
                postKey(125, "\u{f701}", modifiers: [.shift], window: window)
                try? await Task.sleep(for: .milliseconds(100))
                require(pane.selectedItems.count == 2, "Shift-Down must extend selection")
                postKey(36, "\r", window: window)
                try? await Task.sleep(for: .milliseconds(250))
                require(window.attachedSheet != nil && pane.renamingItemPath != nil, "Return must open the native rename sheet")
                if let sheet = window.attachedSheet { capture(sheet, to: base.appendingPathComponent("rename.png")) }
                pane.renamingItemPath = nil
                try? await Task.sleep(for: .milliseconds(250))
                pane.selectedPaths = []
                capture(window, to: base.appendingPathComponent("light.png"))

                state.addNewTab(at: fixture.appendingPathComponent("Projekty"))
                let createdID = state.activeTabId
                state.closeTab(createdID)
                state.reopenClosedTab()
                require(state.activeTabId == createdID, "reopened tab must restore the closed tab")
                state.closeTab(createdID)
                pane.searchScope = .currentFolder
                pane.searchQuery = "^README"
                pane.triggerSearch()
                state.focusSearchFieldTrigger += 1
                try? await Task.sleep(for: .milliseconds(300))
                require(pane.displayedItems.map(\.name) == ["README.md"], "search must match the fixture")
                require(window.firstResponder is NSTextView, "Command-F focus must reach search text")
                postKey(0, "a", modifiers: [.command], window: window)
                try? await Task.sleep(for: .milliseconds(100))
                require((window.firstResponder as? NSTextView)?.selectedRange().length == pane.searchQuery.utf16.count,
                        "Command-A in search must select text")
                require(pane.selectedItems.isEmpty, "text editing must not select underlying files")
                capture(window, to: base.appendingPathComponent("search.png"))
                pane.clearSearch()
                if let responder = fileResponder(in: window.contentView) { window.makeFirstResponder(responder) }
                window.setContentSize(NSSize(width: 900, height: 650))
                try? await Task.sleep(for: .milliseconds(250))
                capture(window, to: base.appendingPathComponent("compact.png"))
                window.setContentSize(NSSize(width: 1180, height: 730))
                state.showInspector = true
                pane.selectAll()
                try? await Task.sleep(for: .milliseconds(250))
                capture(window, to: base.appendingPathComponent("inspector.png"))
                state.showInspector = false
                state.showSidebar = false
                state.toggleDualPane()
                state.rightPane.navigate(to: fixture.appendingPathComponent("Projekty"))
                try? await Task.sleep(for: .milliseconds(250))
                capture(window, to: base.appendingPathComponent("dual-pane.png"))
                state.toggleDualPane()
                state.showSidebar = true
                pane.viewMode = .icons
                pane.selectedPaths = []
                NSApp.appearance = NSAppearance(named: .darkAqua)
                try? await Task.sleep(for: .milliseconds(250))
                capture(window, to: base.appendingPathComponent("dark-icons.png"))
                let summary = "PASS native window, initial focus, arrow/Shift selection, rename sheet, tabs, search, text Command-A, compact/dual/light/dark layouts"
                try? summary.write(to: base.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
                print(summary)
                fflush(stdout)
                exit(0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            require(false, "native preview timed out; a graphical macOS session is required")
        }
        BurrowApp.main()
    }

    @MainActor static func require(_ condition: Bool, _ message: String) {
        guard condition else {
            let summary = "FAIL: \(message)"
            let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_PREVIEW_OUTPUT"]!).appendingPathComponent("verification.txt")
            try? summary.write(to: output, atomically: true, encoding: .utf8)
            fputs("PREVIEW \(summary)\n", stderr)
            exit(1)
        }
    }

    @MainActor static func postKey(_ code: UInt16, _ characters: String,
                                   modifiers: NSEvent.ModifierFlags = [], window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    @MainActor static func fileResponder(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is FileDragSourceView { return view }
        for subview in view.subviews { if let found = fileResponder(in: subview) { return found } }
        return nil
    }

    @MainActor static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview else { require(false, "missing window content"); return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { require(false, "cannot render window"); return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { require(false, "cannot encode window render"); return }
        try? png.write(to: url)
        print("CAPTURE \(url.path) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
