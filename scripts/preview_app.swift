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
        let session = try JSONEncoder().encode(FinderSessionSnapshot(
            tabs: [FinderPaneSession(path: fixture.path)], right: FinderPaneSession(path: fixture.path),
            activeIndex: 0, dualPane: false, activeSide: "left"))
        UserDefaults.standard.setVolatileDomain([
            FinderSessionStore.dataKey: session, "bf.showInspector": false,
            "bf.showSidebar": true, "bf.isDualPane": false,
            "bf.onboarding.fullDiskAccessOffered": true
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
                // Large-folder rendering and real scroll restoration, using only fixtures.
                let many = fixture.appendingPathComponent("Many files", isDirectory: true)
                try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
                for i in 0..<3_000 {
                    try Data().write(to: many.appendingPathComponent(String(format: "Document-%04d.txt", i)))
                }
                pane.viewMode = .list
                pane.navigate(to: many)
                try? await Task.sleep(for: .milliseconds(600))
                guard let source = fileResponder(in: window.contentView) as? FileDragSourceView else {
                    require(false, "missing large folder drag source"); return
                }
                let measured = source.frameStore?.frames.count ?? 0
                require(measured > 0 && measured < 200, "large folder must lay out a bounded set of rows, got \(measured)")
                capture(window, to: base.appendingPathComponent("large-list.png"))
                guard let scroll = largeScroll(in: window.contentView) else {
                    require(false, "missing large folder scroll view"); return
                }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 10_013))
                scroll.reflectScrolledClipView(scroll.contentView)
                try? await Task.sleep(for: .milliseconds(300))
                let originalOffset = scroll.contentView.bounds.minY
                require(originalOffset > 9_000, "large folder must scroll far down")
                pane.navigate(to: fixture)
                try? await Task.sleep(for: .milliseconds(200))
                var backFrames: [ScrollFrame] = []
                var expectedRoot = many
                // Observe after Core Animation's usual commit observer. Do not
                // filter on the keeper's context: row identity is the oracle.
                let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                    true, 2_000_001) { _, _ in
                    MainActor.assumeIsolated {
                        guard let scroll = scrollKeeper(in: window.contentView)?.enclosingScrollView else { return }
                        let rows = visibleRows(in: scroll)
                        guard visibleRows(in: scroll, intersectViewport: false).contains(where: {
                            $0.hasPrefix(expectedRoot.path + "/")
                        }) else { return }
                        backFrames.append(ScrollFrame(y: scroll.contentView.bounds.minY,
                            height: scroll.documentView?.frame.height ?? 0, rows: rows))
                    }
                }!
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                pane.goBack()
                try? await Task.sleep(for: .milliseconds(500))
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                require(!backFrames.isEmpty, "must observe a committed Back frame with actual file rows")
                require(backFrames.allSatisfy {
                    abs($0.y - originalOffset) < 2 && $0.height > 50_000
                        && $0.rows.contains(many.appendingPathComponent("Document-0500.txt").path)
                }, "Back must commit the correct rows and offset together: \(backFrames)")
                print("BACK COMMITTED FRAMES: \(backFrames)")
                guard let restored = largeScroll(in: window.contentView) else {
                    require(false, "missing restored scroll view"); return
                }
                require(abs(restored.contentView.bounds.minY - originalOffset) < 2,
                        "Back must restore exact scroll pixels: \(restored.contentView.bounds.minY) vs \(originalOffset)")
                capture(window, to: base.appendingPathComponent("large-list-return.png"))
                print("LARGE LIST: 3000 files, \(measured) measured rows; restored y=\(restored.contentView.bounds.minY)")
                let other = fixture.appendingPathComponent("Many other files", isDirectory: true)
                try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
                for i in 0..<1_200 {
                    try Data().write(to: other.appendingPathComponent(String(format: "Other-%04d.txt", i)))
                }
                pane.navigate(to: other)
                try? await Task.sleep(for: .milliseconds(300))
                guard let otherScroll = largeScroll(in: window.contentView) else {
                    require(false, "missing second large folder scroll view"); return
                }
                otherScroll.contentView.scroll(to: NSPoint(x: 0, y: 5_013))
                otherScroll.reflectScrolledClipView(otherScroll.contentView)
                try? await Task.sleep(for: .milliseconds(150))
                backFrames.removeAll()
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                pane.goBack()
                try? await Task.sleep(for: .milliseconds(350))
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                require(!backFrames.isEmpty && backFrames.allSatisfy {
                    abs($0.y - originalOffset) < 2 && $0.rows.contains(many.appendingPathComponent("Document-0500.txt").path)
                }, "large-to-large Back must commit the correct rows: \(backFrames)")
                print("LARGE-TO-LARGE BACK: \(backFrames)")
                expectedRoot = other
                backFrames.removeAll()
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                pane.goForward()
                try? await Task.sleep(for: .milliseconds(350))
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                require(!backFrames.isEmpty && backFrames.allSatisfy {
                    abs($0.y - 5_013) < 2 && $0.rows.contains(other.appendingPathComponent("Other-0250.txt").path)
                }, "large-to-large Forward must commit the correct rows: \(backFrames)")
                print("LARGE-TO-LARGE FORWARD: \(backFrames)")

                pane.goBack()
                try? await Task.sleep(for: .milliseconds(250))
                pane.navigate(to: fixture)
                pane.goBack() // A→B→A is coalesced into one SwiftUI update.
                try? await Task.sleep(for: .milliseconds(200))
                guard let rapidScroll = largeScroll(in: window.contentView) else {
                    require(false, "missing rapid-return scroll view"); return
                }
                rapidScroll.contentView.scroll(to: NSPoint(x: 0, y: 10_221))
                rapidScroll.reflectScrolledClipView(rapidScroll.contentView)
                try? await Task.sleep(for: .milliseconds(200))
                require(abs(pane.scrollHistory.offset(for: pane.scrollContext) - 10_221) < 2,
                        "rapid A-B-A must keep recording new positions")
                print("RAPID RETURN: recorded y=\(pane.scrollHistory.offset(for: pane.scrollContext))")
                let summary = "PASS native window, initial focus, arrow/Shift selection, rename sheet, tabs, search, text Command-A, compact/dual/light/dark layouts"
                try? summary.write(to: base.appendingPathComponent("verification.txt"), atomically: true, encoding: .utf8)
                print(summary)
                fflush(stdout)
                exit(0)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
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

    struct ScrollFrame: CustomStringConvertible {
        let y: CGFloat
        let height: CGFloat
        let rows: [String]
        var description: String { "y=\(y) height=\(height) rows=\(rows.map { ($0 as NSString).lastPathComponent })" }
    }
    @MainActor static func visibleRows(in scroll: NSScrollView, intersectViewport: Bool = true) -> [String] {
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        guard let document = scroll.documentView else { return [] }
        return views(document).compactMap { $0 as? FileRowPreviewMarkerView }.filter { marker in
            guard marker.window != nil, !marker.isHiddenOrHasHiddenAncestor,
                  (!intersectViewport || marker.convert(marker.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds)) else { return false }
            var ancestor: NSView? = marker
            var opacity: CGFloat = 1
            while let view = ancestor {
                opacity *= view.alphaValue * CGFloat(view.layer?.opacity ?? 1)
                ancestor = view.superview
            }
            return opacity > 0.01
        }.map(\.path)
    }

    @MainActor static func scrollKeeper(in view: NSView?) -> ScrollKeeperView? {
        guard let view else { return nil }
        if let keeper = view as? ScrollKeeperView { return keeper }
        for child in view.subviews { if let keeper = scrollKeeper(in: child) { return keeper } }
        return nil
    }

    @MainActor static func largeScroll(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > 20_000 { return scroll }
        for child in view.subviews { if let scroll = largeScroll(in: child) { return scroll } }
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
