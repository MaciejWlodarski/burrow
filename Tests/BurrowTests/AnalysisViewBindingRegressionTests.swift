import Foundation

/// Exercises the exact context used by comparison publication and action guards.
/// Native SwiftUI observation/rendering still requires a macOS UI acceptance run.
struct AnalysisViewBindingRegressionTests {
    @MainActor func runAll() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-compare-binding-\(UUID())")
        let leftURL = root.appendingPathComponent("left"), rightURL = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: leftURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let left = PaneTabState(initialURL: leftURL)
        let right = PaneTabState(initialURL: rightURL)
        let original = FolderComparisonContext(left: left, right: right)
        try expect(original == FolderComparisonContext(left: left, right: right))

        // A refreshed same-path directory invalidates the old comparison even when
        // neither URL, tab identity nor hidden-file preference changes.
        try Data("left change".utf8).write(to: leftURL.appendingPathComponent("new-file"))
        left.reloadDirectory()
        let afterLeftRefresh = FolderComparisonContext(left: left, right: right)
        try expect(original != afterLeftRefresh)
        try expect(original.leftPath == afterLeftRefresh.leftPath)
        try expect(original.rightPath == afterLeftRefresh.rightPath)
        right.reloadDirectory()
        let afterRightRefresh = FolderComparisonContext(left: left, right: right)
        try expect(afterLeftRefresh != afterRightRefresh)

        left.showHiddenFiles.toggle()
        let afterLeftHidden = FolderComparisonContext(left: left, right: right)
        try expect(afterLeftHidden != afterRightRefresh)
        right.showHiddenFiles.toggle()
        let afterRightHidden = FolderComparisonContext(left: left, right: right)
        try expect(afterLeftHidden != afterRightHidden)

        // Replacing a tab at the same URL must not reuse a task from the old pane.
        let replacement = PaneTabState(initialURL: leftURL)
        replacement.showHiddenFiles = left.showHiddenFiles
        try expect(FolderComparisonContext(left: replacement, right: right).leftID != afterRightHidden.leftID)
        try expect(FolderComparisonContext(left: replacement, right: right) != afterRightHidden)
        right.navigate(to: leftURL)
        try expect(FolderComparisonContext(left: left, right: right) != afterRightHidden)
        print("PASS comparison context invalidates on both pane revisions, hidden settings, roots and identity")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let leftFile = leftURL.appendingPathComponent("same-size-same-time")
        let rightFile = rightURL.appendingPathComponent("same-size-same-time")
        try Data("old".utf8).write(to: leftFile)
        try Data("new".utf8).write(to: rightFile)
        for file in [leftFile, rightFile] {
            try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: file.path)
        }
        let comparison = FolderComparison.compare(left: leftURL, right: rightURL, includeHidden: true,
            token: AnalysisRequestToken(rootPath: leftURL.path))
        try expect(comparison.entries.first { $0.name == "same-size-same-time" }?.status == .modified)
        try testScanPublishesWholeVisibleProjection(in: root)
        try testPendingSearchRefreshInvalidatesComparisonImmediately(in: root)
    }

    @MainActor private func testPendingSearchRefreshInvalidatesComparisonImmediately(in fixtureRoot: URL) throws {
        let leftURL = fixtureRoot.appendingPathComponent("search-left")
        let rightURL = fixtureRoot.appendingPathComponent("search-right")
        for url in [leftURL, rightURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("old contents".utf8).write(to: url.appendingPathComponent("match.txt"))
        }
        let left = PaneTabState(initialURL: leftURL)
        let right = PaneTabState(initialURL: rightURL)
        defer { left.clearSearch(); right.clearSearch() }

        for pane in [left, right] {
            pane.searchScope = .currentFolder
            pane.searchQuery = "^match.txt"
            pane.triggerSearch()
            try expect(pane.isSearching)
            let beforeRefresh = FolderComparisonContext(left: left, right: right)
            let revision = pane.directoryRevision
            try Data("changed contents".utf8).write(to: pane.currentURL.appendingPathComponent("match.txt"))
            pane.reloadDirectory()
            // Deliberately no await: detached results cannot publish on MainActor
            // yet, but the context used by comparison action guards must be stale.
            try expect(pane.isSearching)
            try expect(pane.searchQuery == "^match.txt")
            try expect(pane.directoryRevision > revision)
            let pendingContext = FolderComparisonContext(left: left, right: right)
            try expect(pendingContext != beforeRefresh)
            try expect(pendingContext.leftPath == beforeRefresh.leftPath)
            try expect(pendingContext.rightPath == beforeRefresh.rightPath)
        }
        print("PASS same-root refresh invalidates comparison immediately while local searches remain pending")
    }

    @MainActor private func testScanPublishesWholeVisibleProjection(in fixtureRoot: URL) throws {
        let root = fixtureRoot.appendingPathComponent("analysis")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["a", "b"] { try Data("same".utf8).write(to: root.appendingPathComponent(name)) }
        try Data("unique payload".utf8).write(to: root.appendingPathComponent("c"))
        let pane = PaneTabState(initialURL: root)
        pane.viewMode = .wiztree
        let token = AnalysisRequestToken(rootPath: root.path)
        let scan = BulkCrawler.crawlTreeResult(roots: [root.path], skipHeavyDevDirs: false)
        try expect(scan.isComplete)
        let groups = DuplicateFileSafety.groups(from: scan.entries, token: token).groups
        let largest = scan.entries.map { $0.toFileItem(loadTags: false) }.sorted { $0.size > $1.size }
        let duplicates = WizTreeSelectionProjection.items(mode: .duplicates, treeRows: [], largestFiles: largest, duplicateGroups: groups)
        pane.beginAnalysisProjection(rootPath: root.path, generation: token.id)
        pane.publishAnalysisItems(duplicates, rootPath: root.path, generation: token.id)
        // No preceding click is required for Cmd+A or keyboard traversal.
        pane.selectAll()
        try expect(Set(pane.selectedItems.map(\.name)) == Set(["a", "b"]))
        pane.setAnalysisSelection([duplicates[0]], rootPath: root.path)
        pane.moveSelection(by: 1)
        try expect(pane.primarySelectedItem?.path == duplicates[1].path)

        let next = AnalysisRequestToken(rootPath: root.path)
        pane.beginAnalysisProjection(rootPath: root.path, generation: next.id)
        // A late geometry/scan publication from the previous mode cannot restore it.
        pane.publishAnalysisItems(duplicates, rootPath: root.path, generation: token.id)
        try expect(pane.selectableItems.isEmpty)
        let allLargest = WizTreeSelectionProjection.items(mode: .largestFiles, treeRows: [], largestFiles: largest, duplicateGroups: groups)
        pane.publishAnalysisItems(allLargest, rootPath: root.path, generation: next.id)
        pane.selectAll()
        try expect(pane.selectedItems.count == 3)

        // Treemap keyboard items are the displayed tree rows, without repeats.
        // A file of a collapsed folder is not actionable merely because it was scanned.
        let treemap = WizTreeSelectionProjection.items(mode: .treemap, treeRows: [duplicates[0], duplicates[0]],
            largestFiles: largest, duplicateGroups: groups)
        try expect(treemap.map(\.path) == [duplicates[0].path])
        print("PASS actual crawl/duplicate scan publishes ordered mode projections, keyboard traversal and generation rejection")
    }

}
