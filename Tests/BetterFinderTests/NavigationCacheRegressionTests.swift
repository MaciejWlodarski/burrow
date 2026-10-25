import Foundation
import AppKit

extension NavigationTests {
    private func cacheFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("better-finder-navigation-cache-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }

    @MainActor func testNavigationCannotSelectOldSearchResults() async throws {
        let root = try cacheFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: root.appendingPathComponent("needle.txt"))
        let pane = PaneTabState(initialURL: root)
        pane.searchScope = .currentFolder
        pane.searchQuery = "^needle.txt"
        pane.triggerSearch()
        for _ in 0..<200 where pane.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        try expect(!pane.isSearching && pane.displayedItems.count == 1)
        let staleItem = pane.displayedItems[0]
        pane.select(staleItem)
        pane.navigate(to: other)
        // No await: a worker cannot commit between navigation and these commands.
        try expect(pane.displayedItems.isEmpty)
        pane.selectAll()
        pane.select(staleItem)
        try expect(pane.selectedItems.isEmpty)
        try expect(pane.primarySelectedItem == nil)
        try expect(pane.actionItems(for: staleItem).isEmpty)
        pane.clearSearch()
    }

    @MainActor func testViewModeSwitchRemovesInvisibleOutlineSelection() throws {
        let root = try cacheFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("child".utf8).write(to: sub.appendingPathComponent("child.txt"))
        try Data("top".utf8).write(to: root.appendingPathComponent("top.txt"))
        let pane = PaneTabState(initialURL: root)
        for mode in [FinderViewMode.icons, .columns] {
            pane.viewMode = .list
            let folder = pane.displayedItems.first { $0.path == sub.path }!
            pane.toggleFolderExpansion(for: folder)
            let child = pane.displayedItems.first { $0.name == "child.txt" }!
            pane.select(child)
            pane.viewMode = mode
            try expect(pane.expandedFolderPaths.isEmpty)
            try expect(pane.displayedItems.allSatisfy { $0.parentPath == root.path && $0.treeDepth == 0 })
            try expect(pane.selectedItems.isEmpty && pane.selectionCursorPath == nil)
            try expect(pane.actionItems(for: child).isEmpty)
            pane.selectAll()
            try expect(Set(pane.selectedItems.map(\.name)) == ["sub", "top.txt"])
            pane.moveSelection(by: -1)
            try expect(pane.selectedItems.allSatisfy { $0.parentPath == root.path })
        }
    }

    @MainActor func testVisibleExpandedAndAncestorColumnChangesInvalidate() throws {
        let root = try cacheFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let pane = PaneTabState(initialURL: root)
        pane.toggleFolderExpansion(for: pane.displayedItems[0])
        try expect(pane.isAffectedByDirectoryChanges([sub.path]))
        try expect(!pane.isAffectedByDirectoryChanges([root.path + "-sibling"]))
        try Data("new".utf8).write(to: sub.appendingPathComponent("new.txt"))
        pane.refresh()
        try expect(pane.displayedItems.contains { $0.path == sub.appendingPathComponent("new.txt").path })
        pane.viewMode = .columns
        pane.navigate(to: sub)
        try expect(pane.columnTrailURLs.map(\.path).contains(root.path))
        try expect(pane.isAffectedByDirectoryChanges([root.path]))
        let revision = pane.directoryRevision
        pane.refresh()
        try expect(pane.directoryRevision > revision)
        // Removing a displayed directory is also a parent-directory event.
        try FileManager.default.removeItem(at: sub)
        try expect(pane.isAffectedByDirectoryChanges([root.path]))
        pane.refresh()
        try expect(pane.displayedItems.isEmpty)
        // A vanished folder is reported, not presented as a genuinely empty one.
        try expect(pane.navigationDiagnostic != nil && pane.navigationFailureID != nil)
    }

    @MainActor func testTypeSelectAndBoundaryKeys() throws {
        let root = try cacheFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["alfa.txt", "Beta.txt", "bezik.txt", "żółw.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        let pane = PaneTabState(initialURL: root)
        let start = Date()
        try expect(pane.typeSelect("b", now: start) && pane.primarySelectedItem?.name == "Beta.txt")
        try expect(pane.typeSelect("ez", now: start.addingTimeInterval(0.3)) && pane.primarySelectedItem?.name == "bezik.txt")
        // After a pause the prefix restarts; diacritics are ignored like Finder.
        try expect(pane.typeSelect("z", now: start.addingTimeInterval(2)) && pane.primarySelectedItem?.name == "żółw.txt")
        pane.selectBoundary(last: false)
        try expect(pane.primarySelectedItem?.name == "alfa.txt")
        pane.selectBoundary(last: true)
        try expect(pane.primarySelectedItem?.name == "żółw.txt")
    }

    @MainActor func testAnalysisSelectionIsBoundedToModeAndRoot() throws {
        let root = try cacheFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("child".utf8).write(to: sub.appendingPathComponent("child.txt"))
        try Data("second".utf8).write(to: sub.appendingPathComponent("second.txt"))
        let items = BulkCrawler.readDirectoryFast(at: sub.path).map { $0.toFileItem() }.sorted { $0.name < $1.name }
        let item = items[0]
        let pane = PaneTabState(initialURL: root)
        pane.viewMode = .wiztree
        let generation = UUID()
        pane.beginAnalysisProjection(rootPath: root.path, generation: generation)
        pane.publishAnalysisItems(items, rootPath: root.path, generation: generation)
        try expect(pane.selectedItems.isEmpty && pane.selectableItems.count == 2)
        pane.moveSelection(by: 1)
        try expect(pane.primarySelectedItem?.path == items[0].path)
        pane.moveSelection(by: 1, extending: true)
        try expect(pane.selectedItems.count == 2)
        pane.moveSelection(by: -1, extending: true)
        try expect(pane.selectedItems.map(\.path) == [items[0].path])
        pane.selectAll()
        try expect(pane.selectedItems.count == 2)
        pane.setAnalysisSelection([item], rootPath: root.path)
        try expect(pane.primarySelectedItem?.path == item.path)
        try expect(pane.selectableItems.count == 2)
        pane.moveSelection(by: 1)
        try expect(pane.primarySelectedItem?.path == items[1].path)
        pane.renamingItemPath = item.path
        try expect(pane.renamingItem?.path == item.path)
        try expect(!pane.displayedItems.contains { $0.path == item.path })
        let replacementGeneration = UUID()
        pane.beginAnalysisProjection(rootPath: root.path, generation: replacementGeneration)
        try expect(pane.renamingItemPath == nil)
        pane.publishAnalysisItems(items, rootPath: root.path, generation: generation)
        try expect(pane.selectableItems.isEmpty)
        pane.publishAnalysisItems([item], rootPath: root.path, generation: replacementGeneration)
        pane.setAnalysisSelection([items[1]], rootPath: root.path)
        try expect(pane.selectedItems.isEmpty)
        pane.setAnalysisSelection([item], rootPath: root.path)
        pane.viewMode = .list
        try expect(pane.selectedItems.isEmpty)
        pane.viewMode = .wiztree
        pane.beginAnalysisProjection(rootPath: root.path, generation: generation)
        pane.publishAnalysisItems(items, rootPath: root.path + "-wrong", generation: generation)
        try expect(pane.selectableItems.isEmpty)
        pane.publishAnalysisItems(items, rootPath: root.path, generation: generation)
        pane.setAnalysisSelection([item], rootPath: root.path)
        pane.navigate(to: sub)
        try expect(pane.selectedItems.isEmpty)
        pane.publishAnalysisItems(items, rootPath: root.path, generation: generation)
        pane.setAnalysisSelection([item], rootPath: root.path)
        try expect(pane.selectedItems.isEmpty)
    }

    @MainActor func testThumbnailInvalidationRejectsLateGeneration() async throws {
        let root = try cacheFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("image.png")
        try Data("image".utf8).write(to: imageURL)
        let item = BulkCrawler.readDirectoryFast(at: root.path).first!.toFileItem()
        var completions: [(NSImage?) -> Void] = []
        let cache = FileIconCache(thumbnailGenerator: { _, completion in completions.append(completion); return {} })
        let oldImage = NSImage(size: NSSize(width: 1, height: 1))
        let newImage = NSImage(size: NSSize(width: 2, height: 2))
        cache.requestThumbnailIfNeeded(for: item)
        // Same path, same metadata, but an external replacement event arrived.
        cache.invalidate(containing: root.path)
        cache.requestThumbnailIfNeeded(for: item)
        try expect(completions.count == 2)
        completions[0](oldImage)
        try await Task.sleep(for: .milliseconds(20))
        try expect(cache.thumbnails[item.path] == nil)
        completions[1](newImage)
        for _ in 0..<200 where cache.thumbnails[item.path] == nil { try await Task.sleep(for: .milliseconds(10)) }
        try expect(cache.thumbnails[item.path] === newImage)
        cache.invalidate(containing: item.path)
        cache.requestThumbnailIfNeeded(for: item)
        try expect(completions.count == 3 && cache.thumbnails[item.path] == nil)
        completions[2](oldImage)
        for _ in 0..<200 where cache.thumbnails[item.path] == nil { try await Task.sleep(for: .milliseconds(10)) }
        try expect(cache.thumbnails[item.path] === oldImage)
    }

    @MainActor func testFolderSizesExposePartialAndCountDeepFiles() async throws {
        let root = try cacheFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var deep = root
        for _ in 0..<7 { deep.appendPathComponent("nested", isDirectory: true) }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: 1024).write(to: deep.appendingPathComponent("payload.bin"))
        let complete = FolderSizeCache.calculateFolderSize(at: root.path, maxEntries: 100)
        try expect(complete.isComplete && complete.bytes == 1024)
        let partial = FolderSizeCache.calculateFolderSize(at: root.path, maxEntries: 2)
        try expect(!partial.isComplete && partial.bytes == 0)
        let cache = FolderSizeCache(calculator: { _ in partial })
        cache.requestSizeIfNeeded(for: root.path)
        for _ in 0..<200 where cache.result(for: root.path) == nil { try await Task.sleep(for: .milliseconds(10)) }
        try expect(cache.result(for: root.path) == partial)
        try expect(cache.size(for: root.path) == nil)
        try expect(cache.displaySize(for: root.path)?.hasPrefix("≥ ") == true)
        cache.invalidate(containing: deep.path)
        try expect(cache.result(for: root.path) == nil)
    }

    @MainActor func testExternalChangeInvalidatesFolderSizeWithoutVisiblePane() async throws {
        let root = try cacheFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent("one.bin"))
        let state = AppState.shared
        let cache = FolderSizeCache.shared
        cache.requestSizeIfNeeded(for: root.path)
        for _ in 0..<200 where cache.result(for: root.path) == nil { try await Task.sleep(for: .milliseconds(10)) }
        try expect(cache.size(for: root.path) == 10)
        try Data(repeating: 2, count: 30).write(to: root.appendingPathComponent("two.bin"))
        state.handleDirectoryChanges([root.path])
        try expect(cache.result(for: root.path) == nil)
        cache.requestSizeIfNeeded(for: root.path)
        for _ in 0..<200 where cache.result(for: root.path) == nil { try await Task.sleep(for: .milliseconds(10)) }
        try expect(cache.size(for: root.path) == 40)
        cache.invalidate(containing: root.path)
    }

    @MainActor func testColumnSortUsesPaneRulesAndUnknownSizesSortLast() throws {
        let root = try cacheFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("aaa", isDirectory: true), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("bbb.txt"))
        try Data(repeating: 1, count: 9).write(to: root.appendingPathComponent("ccc.txt"))
        let pane = PaneTabState(initialURL: root)
        pane.viewMode = .columns
        pane.foldersOnTop = false
        pane.sortAscending = false
        try expect(pane.sortItems(pane.directoryItems).map(\.name) == ["ccc.txt", "bbb.txt", "aaa"])
        pane.sortField = .size
        try expect(pane.sortItems(pane.directoryItems).map(\.name) == ["ccc.txt", "bbb.txt", "aaa"])
        pane.sortAscending = true
        try expect(pane.sortItems(pane.directoryItems).map(\.name) == ["bbb.txt", "ccc.txt", "aaa"])
    }

    @MainActor func testInvalidSearchClearsActionTargetsAndShowsDiagnostic() throws {
        let root = try cacheFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("file".utf8).write(to: root.appendingPathComponent("file.txt"))
        let pane = PaneTabState(initialURL: root)
        let item = pane.displayedItems[0]
        pane.select(item)
        pane.searchQuery = "regex:["
        pane.triggerSearch()
        try expect(pane.searchDiagnostic != nil)
        try expect(!pane.isSearching && pane.displayedItems.isEmpty)
        try expect(pane.selectedItems.isEmpty && pane.actionItems(for: item).isEmpty)
    }
}
