import Foundation

struct SavedSearchRegressionTests {
    @MainActor func runAll() async throws {
        try testLegacyMigrationAndRoundTrip()
        try testMalformedLocalRecordsNeverBecomeGlobal()
        try testPureDecodeDoesNotRequireExistingDirectory()
        try testArchivePreservesUnrecognizedRecords()
        try testSearchIdentityIncludesContext()
        try await testApplyRestoresScopeAndOptions()
        try await testUnavailableRootDoesNotMutatePane()
        try await testSaveAndSidebarActivationUseActivePane()
        try await testAsyncPreparationRejectsNavigation()
        try await testGlobalActivationSkipsPreparation()
        try testDuplicateIDDeletionDoesNotResurrect()
        try await testSupersededQueuedPreparationNeverRuns()
        print("12 saved-search context regression checks passed")
    }

    private func decode(_ json: String) throws -> SavedSmartFolderItem {
        try JSONDecoder().decode(SavedSmartFolderItem.self, from: Data(json.utf8))
    }

    private func testLegacyMigrationAndRoundTrip() throws {
        let legacy = try decode(#"{"id":"legacy","title":"PDF","query":"ext:pdf"}"#)
        try expect(legacy.scope == .wholeIndex && legacy.rootPath == nil)
        try expect(!legacy.includeHidden && legacy.fuzzyEnabled && legacy.version == 1)
        let roundTrip = try JSONDecoder().decode(SavedSmartFolderItem.self, from: JSONEncoder().encode(legacy))
        try expect(roundTrip == legacy)
    }

    private func testMalformedLocalRecordsNeverBecomeGlobal() throws {
        let invalid = [
            #"{"version":1,"id":"a","title":"A","query":"a","scope":"Current Folder","includeHidden":false,"fuzzyEnabled":true}"#,
            #"{"version":1,"id":"a","title":"A","query":"a","scope":"Subfolders","rootPath":"relative/path","includeHidden":false,"fuzzyEnabled":true}"#,
            #"{"version":2,"id":"a","title":"A","query":"a"}"#,
            #"{"id":"a","title":"A","query":"a","scope":"Current Folder"}"#,
            #"{"version":1,"id":"a","title":"A","query":"a","scope":"unknown","includeHidden":false,"fuzzyEnabled":true}"#
        ]
        for json in invalid {
            var rejected = false
            do { _ = try decode(json) } catch { rejected = true }
            try expect(rejected)
        }
    }

    private func testPureDecodeDoesNotRequireExistingDirectory() throws {
        let record = try decode(#"{"version":1,"id":"a","title":"Offline","query":"a","scope":"Subfolders","rootPath":"/Volumes/Unavailable-Test-Volume/Project","includeHidden":true,"fuzzyEnabled":false}"#)
        try expect(record.scope == .recursiveFolder)
        try expect(record.rootPath == "/Volumes/Unavailable-Test-Volume/Project")
    }

    private func testArchivePreservesUnrecognizedRecords() throws {
        let json = #"[{"id":"known","title":"Known","query":"pdf"},{"id":"future","version":99,"title":"Future","query":"pdf"},null]"#
        let archive = try SavedSearchArchive(data: Data(json.utf8))
        try expect(archive.items.map(\.id) == ["known"])
        let rewritten = try archive.encoded(replacingItems: archive.items)
        let records = try JSONSerialization.jsonObject(with: rewritten) as! [Any]
        try expect(records.count == 3)
        try expect((records[1] as? [String: Any])?["version"] as? Int == 99)
        try expect(records[2] is NSNull)
        let afterRemoval = try SavedSearchArchive(data: archive.encoded(replacingItems: []))
        try expect(afterRemoval.items.isEmpty)
        let preserved = try JSONSerialization.jsonObject(with: afterRemoval.encoded(replacingItems: [])) as! [Any]
        try expect(preserved.count == 2)
        var rejected = false
        do { _ = try SavedSearchArchive(data: Data("broken".utf8)) } catch { rejected = true }
        try expect(rejected)
    }

    private func testSearchIdentityIncludesContext() throws {
        func item(scope: SearchScopeMode = .currentFolder, path: String = "/tmp/one", hidden: Bool = false, fuzzy: Bool = true) -> SavedSmartFolderItem {
            SavedSmartFolderItem(title: "Title", query: "a", scope: scope, rootPath: path, includeHidden: hidden, fuzzyEnabled: fuzzy)
        }
        let baseline = item()
        try expect(baseline.hasSameSearch(as: item(path: "/tmp/one/")))
        try expect(!baseline.hasSameSearch(as: item(path: "/tmp/two")))
        try expect(!baseline.hasSameSearch(as: item(scope: .recursiveFolder)))
        try expect(!baseline.hasSameSearch(as: item(hidden: true)))
        try expect(!baseline.hasSameSearch(as: item(fuzzy: false)))
        try expect(item(scope: .wholeIndex).hasSameSearch(as: item(scope: .wholeIndex, path: "/tmp/elsewhere")))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saved-search-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor private func testApplyRestoresScopeAndOptions() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data().write(to: destination.appendingPathComponent(".target.txt"))
        let pane = PaneTabState(initialURL: root)
        pane.searchQuery = "old"
        pane.viewMode = .wiztree
        let saved = SavedSmartFolderItem(title: "Hidden", query: "ext:txt", scope: .currentFolder,
                                         rootPath: destination.path, includeHidden: true, fuzzyEnabled: false)
        try await pane.applySavedSearch(saved)
        try expect(pane.currentURL.path == destination.path)
        try expect(pane.searchQuery == "ext:txt" && pane.searchScope == .currentFolder)
        try expect(pane.showHiddenFiles && !pane.fuzzyEnabled && pane.viewMode == .list)
        try expect(saved.matches(pane))
        for _ in 0..<200 where pane.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        try expect(!pane.isSearching)
        try expect(pane.displayedItems.map(\.name) == [".target.txt"])
        pane.clearSearch()
        try expect(pane.displayedItems.map(\.name) == [".target.txt"])
        let global = SavedSmartFolderItem(title: "Global", query: "txt", scope: .wholeIndex,
                                          rootPath: nil, includeHidden: false, fuzzyEnabled: true)
        try await pane.applySavedSearch(global)
        try expect(pane.currentURL.path == destination.path && pane.searchScope == .wholeIndex)
        pane.clearSearch()
        try expect(pane.displayedItems.isEmpty)
    }

    @MainActor private func testUnavailableRootDoesNotMutatePane() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let pane = PaneTabState(initialURL: root)
        pane.searchQuery = "existing"
        pane.searchScope = .recursiveFolder
        pane.viewMode = .icons
        pane.showHiddenFiles = true
        pane.fuzzyEnabled = false
        for path in [root.appendingPathComponent("missing").path, file.path] {
            let saved = SavedSmartFolderItem(title: "Unavailable", query: "new", scope: .currentFolder,
                                             rootPath: path, includeHidden: false, fuzzyEnabled: true)
            var rejected = false
            do { try await pane.applySavedSearch(saved) } catch { rejected = true }
            try expect(rejected)
            try expect(pane.currentURL == root && pane.searchQuery == "existing")
            try expect(pane.searchScope == .recursiveFolder && pane.viewMode == .icons)
            try expect(pane.showHiddenFiles && !pane.fuzzyEnabled)
        }
    }

    @MainActor private func testSaveAndSidebarActivationUseActivePane() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState.shared
        let previous = (state.tabs, state.activeTabId, state.rightPane, state.isDualPane, state.activePaneSide, state.savedSmartFolders)
        defer {
            for item in state.savedSmartFolders { state.removeSmartFolder(item) }
            state.tabs = previous.0; state.activeTabId = previous.1; state.rightPane = previous.2
            state.isDualPane = previous.3; state.activePaneSide = previous.4; state.savedSmartFolders = previous.5
        }
        let left = PaneTabState(initialURL: root)
        let right = PaneTabState(initialURL: root)
        state.tabs = [left]; state.activeTabId = left.id; state.rightPane = right
        state.isDualPane = true; state.activePaneSide = .right; state.savedSmartFolders = []
        right.searchQuery = "  ext:txt \n"
        right.searchScope = .recursiveFolder; right.showHiddenFiles = true; right.fuzzyEnabled = false
        state.saveSmartFolder(from: right)
        state.saveSmartFolder(from: right)
        try expect(state.savedSmartFolders.count == 1 && state.isCurrentSearchSaved(in: right))
        right.searchScope = .currentFolder
        try expect(!state.isCurrentSearchSaved(in: right))
        state.saveSmartFolder(from: right)
        try expect(state.savedSmartFolders.count == 2)
        let saved = state.savedSmartFolders[0]
        right.searchQuery = "changed"; right.showHiddenFiles = false
        state.openSmartFolder(saved)
        for _ in 0..<200 where !saved.matches(right) { try await Task.sleep(for: .milliseconds(10)) }
        try expect(saved.matches(right))
        try expect(left.searchQuery.isEmpty)
        right.clearSearch()
    }
    @MainActor private func testAsyncPreparationRejectsNavigation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("saved", isDirectory: true)
        let newer = root.appendingPathComponent("newer", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        let pane = PaneTabState(initialURL: root)
        let saved = SavedSmartFolderItem(title: "Delayed", query: "txt", scope: .currentFolder,
                                         rootPath: target.path, includeHidden: false, fuzzyEnabled: true)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task { @MainActor in
            try await pane.applySavedSearch(saved, prepare: { item in
                if Thread.isMainThread { throw RegressionFailure(description: "Filesystem preparation ran on main thread") }
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else {
                    throw RegressionFailure(description: "Blocked preparation was not released")
                }
                return try SavedSearchPreparation.prepare(item)
            })
        }
        var began = false
        for _ in 0..<200 {
            if entered.wait(timeout: .now()) == .success { began = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(began && pane.isActivatingSavedSearch)
        // Reaching this statement while the filesystem worker is blocked proves
        // the main actor remains available. New navigation must win on release.
        pane.navigate(to: newer)
        try expect(!pane.isActivatingSavedSearch)
        release.signal()
        let applied = try await task.value
        try expect(!applied && pane.currentURL.path == newer.path && pane.searchQuery.isEmpty)
    }

    @MainActor private func testGlobalActivationSkipsPreparation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneTabState(initialURL: root)
        let global = SavedSmartFolderItem(title: "Global", query: "txt", scope: .wholeIndex,
                                          rootPath: nil, includeHidden: pane.showHiddenFiles, fuzzyEnabled: true)
        let applied = try await pane.applySavedSearch(global, prepare: { _ in
            throw RegressionFailure(description: "Global search unnecessarily probed a directory")
        })
        try expect(applied && pane.searchQuery == "txt" && !pane.isActivatingSavedSearch)
        pane.clearSearch()
        let ignored = try await pane.applySavedSearch(global, shouldApply: { false })
        try expect(!ignored && pane.searchQuery.isEmpty)
    }

    private func testDuplicateIDDeletionDoesNotResurrect() throws {
        let json = #"[{"id":"duplicate","title":"First","query":"a"},{"id":"duplicate","title":"Second","query":"b"}]"#
        let original = try SavedSearchArchive(data: Data(json.utf8))
        try expect(original.items.count == 1)
        let afterRemoval = try SavedSearchArchive(data: original.encoded(replacingItems: [], removingID: "duplicate"))
        try expect(afterRemoval.items.isEmpty)
        let newItem = SavedSmartFolderItem(title: "New", query: "new", scope: .wholeIndex,
                                           rootPath: nil, includeHidden: false, fuzzyEnabled: true)
        let afterAnotherSave = try SavedSearchArchive(data: afterRemoval.encoded(replacingItems: [newItem]))
        try expect(afterAnotherSave.items.map(\.query) == ["new"])
    }

    @MainActor private func testSupersededQueuedPreparationNeverRuns() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let block: @Sendable () throws -> Int = {
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else {
                throw RegressionFailure(description: "Saturated queue workers were not released")
            }
            return 1
        }
        let first = Task { try await SavedSearchPreparation.run(block) }
        let second = Task { try await SavedSearchPreparation.run(block) }
        var started = 0
        for _ in 0..<200 {
            if entered.wait(timeout: .now()) == .success { started += 1 }
            if started == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(started == 2)
        let pane = PaneTabState(initialURL: root)
        let obsoleteRan = DispatchSemaphore(value: 0)
        let old = SavedSmartFolderItem(title: "Old", query: "old", scope: .currentFolder,
                                       rootPath: root.path, includeHidden: false, fuzzyEnabled: true)
        let latest = SavedSmartFolderItem(title: "Latest", query: "latest", scope: .currentFolder,
                                          rootPath: root.path, includeHidden: false, fuzzyEnabled: true)
        let obsolete = Task { @MainActor in
            try await pane.applySavedSearch(old, prepare: { item in
                obsoleteRan.signal()
                return try SavedSearchPreparation.prepare(item)
            })
        }
        for _ in 0..<200 where !pane.isActivatingSavedSearch { try await Task.sleep(for: .milliseconds(5)) }
        try expect(pane.isActivatingSavedSearch)
        let newest = Task { @MainActor in try await pane.applySavedSearch(latest) }
        let oldApplied = try await obsolete.value
        try expect(!oldApplied)
        release.signal(); release.signal()
        _ = try await first.value; _ = try await second.value
        let newApplied = try await newest.value
        try expect(newApplied && pane.searchQuery == "latest")
        try expect(obsoleteRan.wait(timeout: .now()) == .timedOut)
        pane.clearSearch()
    }

}
