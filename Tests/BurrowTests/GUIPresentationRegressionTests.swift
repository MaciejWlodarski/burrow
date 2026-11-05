import Foundation

/// Production presentation helpers, not a replacement for native SwiftUI acceptance.
struct GUIPresentationRegressionTests {
    @MainActor func runAll() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-gui-\(UUID())")
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["one", "two", "three"] {
            try Data(name.utf8).write(to: nested.appendingPathComponent(name))
        }
        try testSelectionBytesCountOnce(root)
        try testSplitAndColumnLayout()
        let pane = PaneTabState(initialURL: root)
        pane.viewMode = .wiztree
        let generation = UUID()
        pane.beginAnalysisProjection(rootPath: root.path, generation: generation)
        let entries = BulkCrawler.crawlTreeResult(roots: [nested.path], skipHeavyDevDirs: false).entries
        let files = entries.map { $0.toFileItem(loadTags: false) }.filter { !$0.isDirectory }
        try expect(files.count == 3)
        pane.publishAnalysisItems(files, rootPath: root.path, generation: generation)
        pane.selectAll()
        let analysis = FinderSelectionSummary(pane: pane)
        try expect(analysis.totalCount == 3)
        try expect(analysis.selectedCount == 3)
        try expect(analysis.isAnalysis)
        try expect(analysis.countDescription == "3 of 3 selected")
        // Clearing the visible analysis must clear the status, even while the
        // ordinary directory snapshot still exists behind it.
        pane.beginAnalysisProjection(rootPath: root.path, generation: UUID())
        try expect(FinderSelectionSummary(pane: pane).totalCount == 0)
        try expect(FinderSelectionSummary(pane: pane).selectedCount == 0)
        pane.viewMode = .list
        try expect(!FinderSelectionSummary(pane: pane).isAnalysis)
        try expect(FinderSelectionSummary(pane: pane).totalCount == pane.displayedItems.count)
        pane.isSearching = true
        try expect(FinderSelectionSummary(pane: pane).countDescription == "Searching…")
        pane.isSearching = false
        print("PASS status summary follows production analysis/list selection and pending search")
        try testPaneActionRouting(root: root, files: files)
        try testQuickSearchSelection()
    }
    @MainActor private func testPaneActionRouting(root: URL, files: [FileItem]) throws {
        // The same synchronous routing helper is invoked by mouse and AX view
        // callbacks. This tests production routing, not native AX event dispatch.
        let app = AppState.shared
        let savedTabs = app.tabs
        let savedActiveID = app.activeTabId
        let savedRight = app.rightPane
        let savedDual = app.isDualPane
        let savedSide = app.activePaneSide
        defer {
            app.tabs = savedTabs
            app.activeTabId = savedActiveID
            app.rightPane = savedRight
            app.isDualPane = savedDual
            app.activePaneSide = savedSide
        }
        let left = PaneTabState(initialURL: root)
        let right = PaneTabState(initialURL: root)
        let rightURLBeforeNavigation = right.currentURL
        try expect(rightURLBeforeNavigation == root.standardizedFileURL)
        app.tabs = [left]
        app.activeTabId = left.id
        app.rightPane = right
        app.isDualPane = true
        app.activePaneSide = .left
        right.viewMode = .wiztree
        let generation = UUID()
        right.beginAnalysisProjection(rootPath: root.path, generation: generation)
        right.publishAnalysisItems(files, rootPath: root.path, generation: generation)
        var activatedBeforeSelection = false
        FinderPaneActionRouting.perform(appState: app, paneSide: .right) {
            activatedBeforeSelection = app.activeTab === right
            right.setAnalysisSelection([files[0]], rootPath: root.path)
        }
        try expect(activatedBeforeSelection)
        try expect(app.activeTab === right)
        try expect(app.activeTab.primarySelectedItem?.path == files[0].path)
        try expect(left.selectedItems.isEmpty)
        // Opening/navigating the other pane must route global toolbar commands
        // before the callback changes the displayed directory.
        var activatedBeforeNavigation = false
        let destination = root.appendingPathComponent("nested")
        FinderPaneActionRouting.perform(appState: app, paneSide: .left) {
            activatedBeforeNavigation = app.activeTab === left
            left.navigate(to: destination)
        }
        try expect(activatedBeforeNavigation)
        try expect(app.activeTab === left)
        try expect(app.activeTab.currentURL == destination)
        try expect(right.currentURL == rightURLBeforeNavigation)
        print("PASS production pane-action routing activates before analysis selection and navigation")
    }

    private func testQuickSearchSelection() throws {
        try expect(QuickSearchSelection.movedIndex(from: 0, count: 0, direction: .down) == nil)
        try expect(QuickSearchSelection.movedIndex(from: 0, count: 0, direction: .up) == nil)
        try expect(QuickSearchSelection.movedIndex(from: 0, count: 1, direction: .down) == 0)
        try expect(QuickSearchSelection.movedIndex(from: 0, count: 1, direction: .up) == 0)
        try expect(QuickSearchSelection.movedIndex(from: 3, count: 8, direction: .down) == 4)
        try expect(QuickSearchSelection.movedIndex(from: 3, count: 8, direction: .up) == 2)
        try expect(QuickSearchSelection.movedIndex(from: 0, count: 100, direction: .up) == 0)
        try expect(QuickSearchSelection.movedIndex(from: 99, count: 100, direction: .down) == 99)
        try expect(QuickSearchSelection.movedIndex(from: 98, count: 100, direction: .down) == 99)
        print("PASS production quick-search selection boundaries for the visible result list")
    }


    /// Two panes keep their minimum width while there is room and split evenly
    /// when there is not; list columns appear at fixed pane widths.
    private func testSplitAndColumnLayout() throws {
        try expect(PaneSplitLayout.leftWidth(available: 1000, fraction: 0.5, minPaneWidth: 260) == 500)
        try expect(PaneSplitLayout.leftWidth(available: 1000, fraction: 0.1, minPaneWidth: 260) == 260)
        try expect(PaneSplitLayout.leftWidth(available: 1000, fraction: 0.95, minPaneWidth: 260) == 740)
        try expect(PaneSplitLayout.leftWidth(available: 400, fraction: 0.2, minPaneWidth: 260) == 200)
        try expect(PaneSplitLayout.clamped(0.3, available: 0, minPaneWidth: 260) == 0.5)
        let widths: ClosedRange<CGFloat> = 300...400
        try expect(widths.clamp(250) == 300 && widths.clamp(450) == 400)
        let narrow = FileListColumns(width: 447), half = FileListColumns(width: 600), wide = FileListColumns(width: 900)
        try expect(!narrow.showDate && narrow.kindWidth == 0)
        try expect(half.showDate && half.kindWidth == 144)
        try expect(wide.showDate && wide.kindWidth == 150)
    }

    /// Search results can list a folder with files inside it and several hard
    /// links to one file; the selection total counts each byte once.
    @MainActor private func testSelectionBytesCountOnce(_ root: URL) throws {
        let folder = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("a.bin"), link = folder.appendingPathComponent("b.bin")
        try Data(repeating: 1, count: 4_000).write(to: original)
        try FileManager.default.linkItem(at: original, to: link)
        try Data(repeating: 2, count: 1_000).write(to: folder.appendingPathComponent("c.bin"))
        let items = BulkCrawler.readDirectoryResult(at: folder.path, includeHidden: false).entries
            .map { $0.toFileItem(loadTags: false) }
        try expect(items.count == 3 && items.filter { $0.hardLinkID != 0 }.count == 2)
        try expect(FinderSelectionSummary.knownBytes(of: items) { _ in nil } == 5_000)
        let parent = BulkCrawler.readDirectoryResult(at: root.path, includeHidden: false).entries
            .map { $0.toFileItem(loadTags: false) }.filter { $0.path == folder.path }
        try expect(parent.count == 1)
        try expect(FinderSelectionSummary.countedItems(parent + items).map(\.path) == [folder.path])
        try expect(FinderSelectionSummary.knownBytes(of: parent + items) { $0 == folder.path ? 5_000 : nil } == 5_000)

        // Crawls stay on one disk: /dev is its own file system inside /.
        try expect(BulkCrawler.otherDisks(inside: ["/"]).contains("/dev"))
        try expect(!BulkCrawler.otherDisks(inside: ["/", "/dev"]).contains("/dev"))
        try expect(!BulkCrawler.otherDisks(inside: ["/dev/fd"]).contains("/dev"))
    }
}
