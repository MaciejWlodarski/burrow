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
        try expect(analysis.countDescription == "Zaznaczono 3 z 3")
        // Clearing the visible analysis must clear the status, even while the
        // ordinary directory snapshot still exists behind it.
        pane.beginAnalysisProjection(rootPath: root.path, generation: UUID())
        try expect(FinderSelectionSummary(pane: pane).totalCount == 0)
        try expect(FinderSelectionSummary(pane: pane).selectedCount == 0)
        pane.viewMode = .list
        try expect(!FinderSelectionSummary(pane: pane).isAnalysis)
        try expect(FinderSelectionSummary(pane: pane).totalCount == pane.displayedItems.count)
        pane.isSearching = true
        try expect(FinderSelectionSummary(pane: pane).countDescription == "Wyszukiwanie…")
        pane.isSearching = false
        print("PASS status summary follows production analysis/list selection and pending search")
        try testPaneActionRouting(root: root, files: files)
        try testQuickSearchSelection()
        try testBreadcrumbLayoutMetrics()
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

    private func testBreadcrumbLayoutMetrics() throws {
        try expect(BreadcrumbLayoutMetrics.finiteWidth(nil) == 280)
        try expect(BreadcrumbLayoutMetrics.finiteWidth(.infinity) == 280)
        try expect(BreadcrumbLayoutMetrics.finiteWidth(.nan) == 280)
        try expect(BreadcrumbLayoutMetrics.finiteWidth(-10) == 0)
        let unbounded = BreadcrumbLayoutMetrics(availableWidth: .infinity, idealCurrentWidth: .nan, hasAncestors: true)
        try expect(unbounded.currentWidth.isFinite && unbounded.ancestorWidth.isFinite)
        let regular = BreadcrumbLayoutMetrics(availableWidth: 800, idealCurrentWidth: 100, hasAncestors: true)
        try expect(regular.currentWidth == 100)
        try expect(regular.ancestorWidth == 698)
        try expect(regular.spacing == 2)
        let long = BreadcrumbLayoutMetrics(availableWidth: 800, idealCurrentWidth: 2000, hasAncestors: true)
        try expect(long.currentWidth == 280)
        let compact = BreadcrumbLayoutMetrics(availableWidth: 200, idealCurrentWidth: 2000, hasAncestors: true)
        try expect(abs(compact.currentWidth - 118.8) < 0.001)
        try expect(abs(compact.ancestorWidth - 79.2) < 0.001)
        let root = BreadcrumbLayoutMetrics(availableWidth: 200, idealCurrentWidth: 2000, hasAncestors: false)
        try expect(root.currentWidth == 200)
        try expect(root.ancestorWidth == 0 && root.spacing == 0)
        for width in [CGFloat(0), 1, 40, 120, 279, 280, 281, 1000] {
            for ideal in [CGFloat(0), 30, 100, 2000] {
                for ancestors in [false, true] {
                    let layout = BreadcrumbLayoutMetrics(availableWidth: width, idealCurrentWidth: ideal, hasAncestors: ancestors)
                    try expect(layout.currentWidth >= 0 && layout.currentWidth <= 280)
                    try expect(layout.ancestorWidth >= 0)
                    try expect(layout.currentWidth + layout.ancestorWidth + layout.spacing <= width + 0.001)
                    if ancestors {
                        try expect(abs(layout.currentWidth + layout.ancestorWidth + layout.spacing - width) < 0.001)
                    }
                }
            }
        }
        print("PASS pinned breadcrumb width allocation, long names, root and narrow viewports")
    }

}
