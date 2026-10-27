import Foundation

struct NavigationTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt", "d.txt", ".hidden.txt"] {
            try Data(name.utf8).write(to: url.appendingPathComponent(name))
        }
        return url
    }

    @MainActor func testShiftSelectionKeepsAnchorAndCanShrink() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneTabState(initialURL: root)
        pane.select(pane.displayedItems[1])
        pane.moveSelection(by: 1, extending: true)
        pane.moveSelection(by: 1, extending: true)
        try expect(pane.selectedItems.map(\.name) == ["b.txt", "c.txt", "d.txt"])
        try expect(pane.primarySelectedItem?.name == "d.txt")
        pane.moveSelection(by: -1, extending: true)
        try expect(pane.selectedItems.map(\.name) == ["b.txt", "c.txt"])
        pane.select(pane.displayedItems[0], extending: true)
        try expect(pane.selectedItems.map(\.name) == ["a.txt", "b.txt"])
    }

    @MainActor func testArrowFromNoSelectionAndSelectAll() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneTabState(initialURL: root)
        pane.moveSelection(by: -1)
        try expect(pane.primarySelectedItem?.name == "d.txt")
        pane.moveSelection(by: 1)
        try expect(pane.primarySelectedItem?.name == "d.txt")
        pane.selectAll()
        try expect(pane.selectedItems.count == 4)
        pane.moveSelection(by: -1)
        try expect(pane.selectedItems.map(\.name) == ["c.txt"])
    }

    @MainActor func testHiddenFilesRefreshAndDescendingOrder() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneTabState(initialURL: root)
        try expect(!pane.displayedItems.contains { $0.isHidden })
        pane.showHiddenFiles = true
        pane.refresh()
        try expect(pane.displayedItems.contains { $0.name == ".hidden.txt" })
        pane.showHiddenFiles = false
        pane.refresh()
        pane.sortAscending = false
        pane.applySortChange()
        try expect(pane.displayedItems.map(\.name) == ["d.txt", "c.txt", "b.txt", "a.txt"])
    }

    @MainActor func testClearingSearchRejectsPendingResults() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneTabState(initialURL: root)
        pane.searchScope = .currentFolder
        pane.searchQuery = "a.txt"
        pane.triggerSearch()
        pane.clearSearch()
        try await Task.sleep(for: .milliseconds(200))
        try expect(!pane.isSearching)
        try expect(pane.searchQuery.isEmpty)
        try expect(pane.displayedItems.count == 4)
    }

    @MainActor func testReloadRerunsActiveSearchAfterDeletion() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneTabState(initialURL: root)
        pane.searchScope = .currentFolder
        pane.searchQuery = "^a.txt"
        pane.triggerSearch()
        for _ in 0..<100 where pane.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        try expect(pane.displayedItems.map(\.name) == ["a.txt"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
        pane.refresh()
        for _ in 0..<100 where pane.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        try expect(!pane.isSearching)
        try expect(pane.displayedItems.isEmpty)
    }

    @MainActor func testNavigationWithLocalQueryRefreshesBrowsingSnapshot() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: destination.appendingPathComponent("new.txt"))
        FSearchIndex.shared.configuredRoots = [root.path]
        FSearchIndex.shared.usePersistentMMapCache = false
        let pane = PaneTabState(initialURL: root)
        pane.searchScope = .currentFolder
        pane.searchQuery = "^a.txt"
        pane.triggerSearch()
        pane.navigate(to: destination)
        pane.clearSearch()
        try await Task.sleep(for: .milliseconds(100))
        try expect(pane.currentURL.path == destination.standardizedFileURL.path)
        try expect(pane.displayedItems.map(\.name) == ["new.txt"])
        try expect(pane.displayedItems.allSatisfy { $0.parentPath == pane.currentURL.path })
    }

    @MainActor func testScopeInvalidationUsesDirectoryBoundaries() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneTabState(initialURL: root)
        pane.searchQuery = "query"
        pane.searchScope = .recursiveFolder
        try expect(pane.isAffectedByDirectoryChanges([root.path + "/child"]))
        try expect(!pane.isAffectedByDirectoryChanges([root.path + "-unrelated"]))
        pane.searchScope = .currentFolder
        try expect(!pane.isAffectedByDirectoryChanges([root.path + "/child"]))
        try expect(pane.isAffectedByDirectoryChanges([root.path]))
        pane.searchScope = .wholeIndex
        try expect(pane.isAffectedByDirectoryChanges(["/unrelated"]))
        pane.searchQuery = ""
        try expect(!pane.isAffectedByDirectoryChanges(["/unrelated"]))
    }

    @MainActor func testNewTabIncludesInheritedHiddenFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        FSearchIndex.shared.configuredRoots = [root.path]
        FSearchIndex.shared.usePersistentMMapCache = false
        let state = AppState.shared
        let previous = state.activeTab
        let previousHidden = previous.showHiddenFiles
        previous.showHiddenFiles = true
        defer { previous.showHiddenFiles = previousHidden; previous.refresh() }
        state.addNewTab(at: root)
        let createdID = state.activeTabId
        defer { state.closeTab(createdID) }
        try expect(state.activeTab.showHiddenFiles)
        try expect(state.activeTab.displayedItems.contains { $0.name == ".hidden.txt" })
    }

    @MainActor func testDropLoadsAllFileProvidersAsOneDeduplicatedBatch() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        let providers = [NSItemProvider(object: a as NSURL), NSItemProvider(object: "not a file" as NSString),
                         NSItemProvider(object: b as NSURL), NSItemProvider(object: a as NSURL)]
        try expect(FileDropLoader.accepts(providers))
        try expect(!FileDropLoader.accepts([NSItemProvider(object: "text" as NSString)]))
        let urls = try await FileDropLoader.urls(from: providers)
        try expect(urls == [a, b])
    }


    @MainActor func testSearchCommitPublishesUpdatedMetadataAndRevision() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneTabState(initialURL: root)
        pane.searchScope = .currentFolder
        pane.searchQuery = "^a.txt"
        pane.triggerSearch()
        for _ in 0..<100 where pane.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        pane.select(pane.displayedItems[0])
        let revision = pane.directoryRevision
        let newContents = Data("updated file contents with a different size".utf8)
        try newContents.write(to: root.appendingPathComponent("a.txt"))
        // This is the index-update path, without a directory reload.
        pane.triggerSearch()
        for _ in 0..<100 where pane.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        try expect(pane.primarySelectedItem?.size == Int64(newContents.count))
        try expect(pane.directoryRevision > revision)
    }


    @MainActor func testDirectoryShowsFilesBeforeTagMetadataCompletes() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let taggedFile = root.appendingPathComponent("a.txt")
        try FinderTagColor.writeTags([.red], to: taggedFile)
        let pane = PaneTabState(initialURL: root)
        try expect(pane.displayedItems.count == 4)
        for _ in 0..<100 where pane.cachedTags(for: taggedFile.path) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(pane.displayedItems.first(where: { $0.path == taggedFile.path })?.tags == [.red])
        try expect(pane.tagMetadataRevision > 0)
    }

}
