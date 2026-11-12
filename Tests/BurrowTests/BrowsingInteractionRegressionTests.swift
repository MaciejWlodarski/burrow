import AppKit
import Combine
import CoreServices

@MainActor
struct BrowsingInteractionRegressionTests {
    func runAll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-interactions-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        for i in 0..<2_000 { try Data().write(to: root.appendingPathComponent(String(format: "%04d.txt", i))) }
        let pane = PaneTabState(initialURL: root)
        var directoryPublications = 0, displayPublications = 0
        let subscription = pane.$directoryItems.dropFirst().sink { _ in directoryPublications += 1 }
        let displayed = pane.$displayedItems.dropFirst().sink { _ in displayPublications += 1 }
        for _ in 0..<500 where pane.cachedTags(for: root.appendingPathComponent("1999.txt").path) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(pane.cachedTags(for: root.appendingPathComponent("1999.txt").path) != nil)
        try expect(directoryPublications < 10 && displayPublications < 10)
        withExtendedLifetime((subscription, displayed)) {}

        var opened: [URL] = []
        pane.fileOpener = { opened.append($0) }
        let files = pane.displayedItems.filter { !$0.isDirectory }.prefix(3)
        pane.selectedPaths = Set(files.map(\.path))
        pane.openSelectedItems()
        try expect(opened == files.map(\.url))
        opened.removeAll()
        let stale = Array(files)
        let originalContext = pane.scrollContext
        pane.scrollHistory.record(713.5, for: originalContext)
        try expect(pane.navigate(to: child))
        pane.openItems(stale)
        try expect(opened.isEmpty)
        pane.goBack()
        try expect(pane.currentURL == root.standardizedFileURL)
        try expect(pane.scrollHistory.offset(for: pane.scrollContext) == 713.5)
        pane.goForward()
        try expect(pane.currentURL == child.standardizedFileURL)

        // Native clip view: keep exact pixels, restore a second location at the
        // top and restore the first location after switching back.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 20_000))
        scroll.documentView = document
        let keeper = ScrollKeeperView(frame: .zero)
        document.addSubview(keeper)
        let history = PaneScrollHistory()
        keeper.update(history: history, context: "A")
        keeper.layoutSubtreeIfNeeded()
        keeper.viewWillDraw()
        try expect(scroll.contentView.bounds.minY == 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 713.5))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        try expect(history.offset(for: "A") == 713.5)
        keeper.update(history: history, context: "B")
        keeper.layoutSubtreeIfNeeded()
        keeper.viewWillDraw()
        try expect(scroll.contentView.bounds.minY == 0)
        keeper.update(history: history, context: "A")
        keeper.layoutSubtreeIfNeeded()
        keeper.viewWillDraw()
        // No queue turn or actor suspension: layout itself restores the offset.
        try expect(scroll.contentView.bounds.minY == 713.5)
        // The model may commit A→B→A before SwiftUI updates this keeper.
        keeper.update(history: pane.scrollHistory, context: pane.scrollContext)
        keeper.layoutSubtreeIfNeeded()
        keeper.viewWillDraw()
        let roundTripContext = pane.scrollContext
        pane.navigate(to: root)
        pane.goBack()
        try expect(pane.scrollContext == roundTripContext)
        keeper.update(history: pane.scrollHistory, context: pane.scrollContext)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 5_000))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        try expect(pane.scrollHistory.offset(for: roundTripContext) == 5_000)
        // Geometry from the old context cannot overwrite its saved offset.
        pane.navigate(to: root)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 6_000))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        try expect(pane.scrollHistory.offset(for: roundTripContext) == 5_000)
        pane.goBack()
        keeper.update(history: pane.scrollHistory, context: pane.scrollContext)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 5_013))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        try expect(pane.scrollHistory.offset(for: roundTripContext) == 5_013)

        document.setFrameSize(NSSize(width: 600, height: 0))
        keeper.update(history: pane.scrollHistory, context: pane.scrollContext, contentIsEmpty: true)
        keeper.layoutSubtreeIfNeeded()
        keeper.viewWillDraw()
        try expect(scroll.contentView.bounds.minY == 0)
        try expect(pane.scrollHistory.offset(for: roundTripContext) == 0)
        document.setFrameSize(NSSize(width: 600, height: 20_000))
        keeper.layoutSubtreeIfNeeded()
        keeper.viewWillDraw()
        try expect(scroll.contentView.bounds.minY == 0)

        let nested = child.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("leaf.txt"))
        pane.navigate(to: root)
        pane.toggleFolderExpansion(for: pane.displayedItems.first { $0.path == child.path }!)
        pane.toggleFolderExpansion(for: pane.displayedItems.first { $0.path == nested.path }!)
        let expanded = pane.expandedFolderPaths
        let outline = pane.displayedItems.map(\.path)
        pane.navigate(to: child)
        pane.goBack()
        try expect(pane.expandedFolderPaths == expanded)
        try expect(pane.displayedItems.map(\.path) == outline)
        pane.goForward()
        try expect(pane.expandedFolderPaths.isEmpty)
        keeper.detach()

        let skipped: Set<String> = [".build", ".git", "node_modules"]
        try expect(FSearchIndex.isExcludedEventPath("/dev/project/.build/debug/x", roots: ["/dev"], skippedNames: skipped))
        try expect(!FSearchIndex.isExcludedEventPath("/dev/project/Sources/x.swift", roots: ["/dev"], skippedNames: skipped))
        try expect(!FSearchIndex.isExcludedEventPath("/dev/node_modules/own.txt", roots: ["/dev/node_modules"], skippedNames: skipped))
        try expect(!FSearchIndex.isContentChange(FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)))
        try expect(FSearchIndex.isContentChange(FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)))
        for name in skipped {
            let excluded = "/dev/project/" + name
            try expect(FSearchIndex.eventRefreshDirectories(path: excluded, isDirectory: true, roots: ["/dev"],
                skipHeavy: true, skippedNames: skipped) == ["/dev/project"])
            try expect(FSearchIndex.eventRefreshDirectories(path: excluded + "/child", isDirectory: true, roots: ["/dev"],
                skipHeavy: true, skippedNames: skipped).isEmpty)
        }
        try expect(FSearchIndex.eventRefreshDirectories(path: "/Users/u/Library", isDirectory: true, roots: ["/Users/u"],
            skipHeavy: true, skippedNames: [], home: "/Users/u") == ["/Users/u"])
        try expect(FSearchIndex.eventRefreshDirectories(path: "/Users/u/Library/Caches", isDirectory: true, roots: ["/Users/u"],
            skipHeavy: true, skippedNames: [], home: "/Users/u").isEmpty)

        let eventRoot = root.appendingPathComponent("event-fixture", isDirectory: true)
        let build = eventRoot.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data().write(to: build.appendingPathComponent("not-indexed.txt"))
        let eventIndex = FSearchIndex(roots: [eventRoot.path], enableMonitoring: false)
        eventIndex.usePersistentMMapCache = false
        eventIndex.skipHeavyDevDirs = true
        eventIndex.skippedDirectoryNames = skipped
        func refreshBuildEvent() {
            for directory in FSearchIndex.eventRefreshDirectories(path: build.path, isDirectory: true, roots: [eventRoot.path],
                skipHeavy: true, skippedNames: skipped) { eventIndex.refreshDirectoryInIndex(directory) }
        }
        func indexed(_ query: String) -> [FileItem] {
            eventIndex.search(rawQuery: query, scope: .wholeIndex, scopeDirectory: eventRoot.path,
                includeHidden: true, fuzzyEnabled: false).items
        }
        refreshBuildEvent()
        try expect(indexed("^.build").map(\.path) == [build.path])
        try expect(indexed("^not-indexed.txt").isEmpty)
        try FileManager.default.removeItem(at: build)
        refreshBuildEvent()
        try expect(indexed("^.build").isEmpty)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        refreshBuildEvent()
        try expect(indexed("^.build").map(\.path) == [build.path])
        let index = FSearchIndex(roots: [root.path], enableMonitoring: false)
        index.usePersistentMMapCache = false
        index.refreshDirectoryInIndex(root.path)
        try Data().write(to: root.appendingPathComponent("after-snapshot.txt"))
        index.crawlProgressHookForTesting = { _ in index.cancelIndexing() }
        index.startIndexing()
        for _ in 0..<500 where index.isIndexing { try await Task.sleep(for: .milliseconds(10)) }
        try expect(!index.isIndexing && index.scannedCount > 0)
        try expect(index.search(rawQuery: "^after-snapshot.txt", scope: .wholeIndex, scopeDirectory: root.path,
                                includeHidden: true, fuzzyEnabled: false).items.isEmpty)
        index.crawlProgressHookForTesting = nil
        index.startIndexing()
        for _ in 0..<500 where index.isIndexing { try await Task.sleep(for: .milliseconds(10)) }
        try expect(!index.isIndexing)
        try expect(index.search(rawQuery: "^after-snapshot.txt", scope: .wholeIndex, scopeDirectory: root.path,
                                includeHidden: true, fuzzyEnabled: false).items.count == 1)
        print("PASS large-folder metadata publications, batch opening, scroll history and index event filtering")
    }
}
