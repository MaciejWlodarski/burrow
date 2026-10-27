import Foundation

struct SessionRestorationRegressionTests {
    @MainActor func runAll() async throws {
        try testRoundTripBothPanesAndOptions()
        try testLegacyMigrationPreservesOfflineOrderDuplicatesAndClamps()
        try testInvalidLegacyProtectsOriginal()
        try testUnknownCorruptAndPartialDataAreProtected()
        try testDisabledFutureDataCannotBeOverwritten()
        try testClearDisablesWritesAndPreservesSmartFolders()
        try testLimitsAndExternalChanges()
        try testPausedConstructionAndRefreshAreInert()
        try await testExplicitActivationAndUnavailablePath()
        try await testFileReplacementIsNotOpened()
        try await testCancellationRejectsLateResult()
        try await testTimeoutPreservesLocation()
        try await testAppCloseCancelsRestoration()
        try await testResumedRightPaneSurvivesVisibilityToggle()
        try await testClearBeatsPendingAppDebounce()
        try await testGlobalSearchPreservesPausedBrowsing()
        try testSuccessfulSaveClearsTransientNotice()
        print("17 session restoration regression groups passed")
    }

    private func withStore(_ body: (UserDefaults, FinderSessionStore) throws -> Void) throws {
        let name = "Burrow.SessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, FinderSessionStore(defaults: defaults))
    }

    private func sample() -> FinderSessionSnapshot {
        var left = FinderPaneSession(path: "/Volumes/Offline/Project")
        left.view = "columns"; left.sort = "modified"; left.ascending = false
        left.hidden = true; left.fuzzy = false; left.foldersOnTop = false
        left.query = "ext:swift"; left.scope = "recursiveFolder"
        var right = FinderPaneSession(path: "/Volumes/Other/Photos")
        right.view = "wiztree"; right.sort = "size"
        return FinderSessionSnapshot(tabs: [left, FinderPaneSession(path: "/tmp"), left],
            right: right, activeIndex: 2, dualPane: true, activeSide: "right")
    }

    private func testRoundTripBothPanesAndOptions() throws {
        let source = sample()
        let result = FinderSessionStore.decode(try JSONEncoder().encode(source))
        try expect(result.snapshot == source && result.canWrite)
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
        try expect(Set(fields.keys) == Set(["version", "tabs", "right", "activeIndex", "dualPane", "activeSide"]))
        let pane = (fields["tabs"] as! [[String: Any]])[0]
        try expect(Set(pane.keys) == Set(["path", "view", "sort", "ascending", "foldersOnTop", "hidden", "fuzzy", "query", "scope"]))
    }

    private func testLegacyMigrationPreservesOfflineOrderDuplicatesAndClamps() throws {
        try withStore { defaults, store in
            let paths = ["/Volumes/Absent/One", "/Volumes/Absent/Two", "/Volumes/Absent/One"]
            defaults.set(paths, forKey: "bf.openTabPaths")
            defaults.set(999, forKey: "bf.activeTabIndex")
            let result = store.load(defaultRightPath: "/home/test")
            try expect(result.snapshot?.tabs.map(\.path) == paths)
            try expect(result.snapshot?.activeIndex == 2 && result.canWrite)
            try expect(store.save(result.snapshot!))
            try expect(store.load(defaultRightPath: "/different").snapshot?.tabs.map(\.path) == paths)
        }
    }

    private func testInvalidLegacyProtectsOriginal() throws {
        try withStore { defaults, store in
            let paths = ["/valid", "relative", "/also-valid"]
            defaults.set(paths, forKey: "bf.openTabPaths")
            defaults.set(2, forKey: "bf.activeTabIndex")
            let result = store.load(defaultRightPath: "/home")
            try expect(result.snapshot?.tabs.map(\.path) == ["/valid", "/also-valid"])
            try expect(result.snapshot?.activeIndex == 1 && !result.canWrite)
            try expect(!store.save(sample()) && defaults.stringArray(forKey: "bf.openTabPaths") == paths)
        }
    }

    private func testUnknownCorruptAndPartialDataAreProtected() throws {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sample())) as! [String: Any]
        var future = object; future["version"] = 99
        var tabs = object["tabs"] as! [[String: Any]]
        tabs[1]["view"] = "future-view"
        object["tabs"] = tabs
        let partial = try JSONSerialization.data(withJSONObject: object)
        let recovered = FinderSessionStore.decode(partial)
        try expect(recovered.snapshot?.tabs.count == 2 && recovered.snapshot?.activeIndex == 1 && !recovered.canWrite)
        for bytes in [Data("broken".utf8), try JSONSerialization.data(withJSONObject: future), partial] {
            try withStore { defaults, store in
                defaults.set(bytes, forKey: FinderSessionStore.dataKey)
                _ = store.load(defaultRightPath: "/home")
                try expect(!store.save(sample()))
                try expect(defaults.data(forKey: FinderSessionStore.dataKey) == bytes)
            }
        }
    }

    private func testDisabledFutureDataCannotBeOverwritten() throws {
        try withStore { defaults, store in
            let bytes = Data("unknown format".utf8)
            defaults.set(bytes, forKey: FinderSessionStore.dataKey)
            store.setEnabled(false)
            try expect(store.load(defaultRightPath: "/home").snapshot == nil)
            store.setEnabled(true)
            try expect(!store.save(sample()) && defaults.data(forKey: FinderSessionStore.dataKey) == bytes)
        }
    }

    private func testClearDisablesWritesAndPreservesSmartFolders() throws {
        try withStore { defaults, store in
            let saved = Data("smart-folder archive".utf8)
            defaults.set(saved, forKey: "bf.savedSmartFolders")
            defaults.set(["/legacy"], forKey: "bf.openTabPaths")
            _ = store.load(defaultRightPath: "/home")
            try expect(store.save(sample()))
            store.clearAndDisable()
            try expect(!store.isEnabled && !store.save(sample()))
            try expect(defaults.object(forKey: FinderSessionStore.dataKey) == nil)
            try expect(defaults.object(forKey: "bf.openTabPaths") == nil)
            try expect(defaults.data(forKey: "bf.savedSmartFolders") == saved)
            store.setEnabled(true)
            try expect(store.save(sample()))
        }
    }

    private func testLimitsAndExternalChanges() throws {
        var oversized = sample()
        oversized.tabs = Array(repeating: oversized.tabs[0], count: 129)
        let encodedOversized = try JSONEncoder().encode(oversized)
        try expect(!FinderSessionStore.decode(encodedOversized).canWrite)
        try withStore { defaults, store in
            _ = store.load(defaultRightPath: "/home")
            try expect(!store.save(oversized))
            defaults.set(Data("external newer write".utf8), forKey: FinderSessionStore.dataKey)
            try expect(!store.save(sample()))
        }
    }

    @MainActor private func testPausedConstructionAndRefreshAreInert() throws {
        let pane = FinderPaneSession(path: "/Volumes/Never-Probe-This/Absent").makePausedPane()
        try expect(pane.isSessionPaused && pane.directoryRevision == 0)
        pane.searchQuery = "content:secret"
        pane.searchScope = .recursiveFolder
        pane.refresh(); pane.triggerSearch(); pane.applySortChange()
        try expect(pane.directoryRevision == 0 && !pane.isSearching)
        try expect(pane.directoryItems.isEmpty && pane.displayedItems.isEmpty && pane.selectedItems.isEmpty)
        try expect(pane.historyBack.isEmpty && pane.historyForward.isEmpty && pane.expandedFolderPaths.isEmpty)
        try expect(pane.currentURL.path == "/Volumes/Never-Probe-This/Absent")
    }

    @MainActor private func testExplicitActivationAndUnavailablePath() async throws {
        let path = "/Volumes/Virtual-Preparation-Spy"
        let pane = FinderPaneSession(path: path).makePausedPane()
        let applied = await pane.resumeSession { capturedPath, hidden in
            if Thread.isMainThread { throw RegressionFailure(description: "Session I/O ran on main actor") }
            guard capturedPath == path, !hidden else { throw RegressionFailure(description: "Wrong restoration context") }
            return PreparedSavedSearch(root: URL(fileURLWithPath: path, isDirectory: true), entries: [])
        }
        try expect(applied && !pane.isSessionPaused)
        let unavailable = FinderPaneSession(path: path).makePausedPane()
        let failed = await unavailable.resumeSession { _, _ in throw SavedSearchError.unavailableRoot(path) }
        try expect(!failed && unavailable.isSessionPaused && unavailable.currentURL.path == path)
        guard case .unavailable = unavailable.sessionAvailability else { throw RegressionFailure(description: "Missing explicit unavailable state") }
    }

    @MainActor private func testFileReplacementIsNotOpened() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"]!, isDirectory: true)
        let file = root.appendingPathComponent("session-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let pane = FinderPaneSession(path: file.path).makePausedPane()
        let resumed = await pane.resumeSession()
        try expect(!resumed && pane.currentURL.path == file.path)
        guard case .unavailable(let reason) = pane.sessionAvailability else { throw RegressionFailure(description: "File replacement needs explicit failure") }
        try expect(reason.contains("Nie otwarto"))
    }

    @MainActor private func waitForWorker(_ entered: DispatchSemaphore) async throws {
        for _ in 0..<200 {
            if entered.wait(timeout: .now()) == .success { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RegressionFailure(description: "Restoration worker did not start")
    }

    @MainActor private func testCancellationRejectsLateResult() async throws {
        let pane = FinderPaneSession(path: "/Volumes/Delayed").makePausedPane()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task { @MainActor in
            await pane.resumeSession { path, _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
                return PreparedSavedSearch(root: URL(fileURLWithPath: path, isDirectory: true), entries: [])
            }
        }
        try await waitForWorker(entered)
        pane.showHiddenFiles = true
        let applied = await task.value
        try expect(!applied && pane.sessionAvailability == .paused && pane.directoryRevision == 0)
        release.signal()
    }

    @MainActor private func testTimeoutPreservesLocation() async throws {
        let pane = FinderPaneSession(path: "/Volumes/Slow").makePausedPane()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let result = await pane.resumeSession(timeoutNanoseconds: 30_000_000) { path, _ in
            _ = release.wait(timeout: .now() + 5)
            return PreparedSavedSearch(root: URL(fileURLWithPath: path, isDirectory: true), entries: [])
        }
        try expect(!result && pane.currentURL.path == "/Volumes/Slow")
        guard case .unavailable(let reason) = pane.sessionAvailability else { throw RegressionFailure(description: "Timeout must remain visible") }
        try expect(reason.contains("nie oznacza"))
    }

    @MainActor private func testAppCloseCancelsRestoration() async throws {
        let app = AppState.shared
        let oldTabs = app.tabs, oldID = app.activeTabId, oldSide = app.activePaneSide
        let pane = FinderPaneSession(path: "/Volumes/Closed").makePausedPane()
        defer { app.tabs = oldTabs; app.activeTabId = oldID; app.activePaneSide = oldSide }
        app.tabs.append(pane)
        app.activeTabId = pane.id
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task { @MainActor in
            await pane.resumeSession { path, _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
                return PreparedSavedSearch(root: URL(fileURLWithPath: path, isDirectory: true), entries: [])
            }
        }
        try await waitForWorker(entered)
        app.closeTab(pane.id)
        defer { if app.recentlyClosedTabs.last?.id == pane.id { app.reopenClosedTab() } }
        let applied = await task.value
        try expect(!applied && pane.sessionAvailability == .paused)
    }
    @MainActor private func testResumedRightPaneSurvivesVisibilityToggle() async throws {
        let app = AppState.shared
        let oldRight = app.rightPane, oldDual = app.isDualPane, oldSide = app.activePaneSide
        defer { app.rightPane = oldRight; app.isDualPane = oldDual; app.activePaneSide = oldSide }
        let pane = FinderPaneSession(path: "/Volumes/Retained-Right").makePausedPane()
        let resumed = await pane.resumeSession { path, _ in
            PreparedSavedSearch(root: URL(fileURLWithPath: path, isDirectory: true), entries: [])
        }
        try expect(resumed)
        app.rightPane = pane
        app.isDualPane = true
        app.toggleDualPane()
        app.toggleDualPane()
        try expect(app.rightPane.currentURL.path == "/Volumes/Retained-Right" && !app.rightPane.isSessionPaused)
    }

    @MainActor private func testClearBeatsPendingAppDebounce() async throws {
        let app = AppState.shared
        let enabled = app.restoreSessionEnabled
        let query = app.leftTab.searchQuery
        defer {
            app.leftTab.searchQuery = query
            app.setSessionRestorationEnabled(enabled)
        }
        app.setSessionRestorationEnabled(true)
        app.leftTab.searchQuery = "pending-save"
        app.persistTabsState()
        app.clearSavedSession()
        app.leftTab.searchQuery = "change-after-clear"
        try await Task.sleep(for: .milliseconds(350))
        app.flushSessionState()
        try expect(!app.restoreSessionEnabled && !app.hasPersistedSessionForTesting)
    }

    @MainActor private func testGlobalSearchPreservesPausedBrowsing() async throws {
        let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"]!, isDirectory: true)
        let root = fixtures.appendingPathComponent("session-global-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("visible".utf8).write(to: root.appendingPathComponent("visible.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        for hidden in [false, true] {
            let offline = FinderPaneSession(path: "/Volumes/Unavailable-Session-Global/Offline").makePausedPane()
            let offlineGlobal = SavedSmartFolderItem(title: "Offline global", query: "session-global-no-match", scope: .wholeIndex,
                rootPath: nil, includeHidden: hidden, fuzzyEnabled: true)
            let offlineApplied = try await offline.applySavedSearch(offlineGlobal, prepare: { _ in
                throw RegressionFailure(description: "Global search must not prepare restored location")
            })
            try expect(offlineApplied && offline.sessionAvailability == .paused)
            offline.clearSearch()
            try expect(offline.isSessionPaused && offline.directoryItems.isEmpty)
            let pane = FinderPaneSession(path: root.path).makePausedPane()
            let global = SavedSmartFolderItem(title: "Global", query: "session-global-no-match", scope: .wholeIndex,
                rootPath: nil, includeHidden: hidden, fuzzyEnabled: true)
            let applied = try await pane.applySavedSearch(global)
            try expect(applied && !pane.isSessionPaused && pane.sessionAvailability == .paused)
            try await Task.sleep(for: .milliseconds(50))
            // Even changing hidden must not start a background browsing read.
            try expect(pane.directoryItems.isEmpty)
            pane.refresh()
            try expect(pane.directoryItems.isEmpty)
            let file = root.appendingPathComponent("visible.txt")
            let result = FileItem(url: file, name: "visible.txt", path: file.path,
                parentPath: root.path, fileExtension: "txt", isDirectory: false,
                isHidden: false, size: 7, modificationDate: .distantPast)
            pane.displayedItems = [result]
            pane.selectedPaths = [file.path]
            pane.searchScope = .currentFolder
            try expect(pane.isSessionPaused && pane.displayedItems.isEmpty && pane.selectedPaths.isEmpty)
            pane.searchScope = .wholeIndex
            pane.displayedItems = [result]
            pane.selectedPaths = [file.path]
            pane.clearSearch()
            try expect(pane.isSessionPaused && pane.selectableItems.isEmpty && pane.displayedItems.isEmpty)
            try expect(pane.currentURL.path == root.path)
            let resumed = await pane.resumeSession()
            try expect(resumed && pane.directoryItems.contains(where: { $0.name == "visible.txt" }))
        }
    }

    @MainActor private func testSuccessfulSaveClearsTransientNotice() throws {
        let app = AppState.shared
        let oldTabs = app.tabs, oldID = app.activeTabId, enabled = app.restoreSessionEnabled
        defer { app.tabs = oldTabs; app.activeTabId = oldID; app.setSessionRestorationEnabled(enabled) }
        app.setSessionRestorationEnabled(true)
        app.tabs = (0..<129).map { FinderPaneSession(path: "/Volumes/Limit/\($0)").makePausedPane() }
        app.activeTabId = app.tabs[0].id
        app.flushSessionState()
        try expect(app.sessionPersistenceNotice != nil)
        app.tabs = oldTabs
        app.activeTabId = oldID
        app.flushSessionState()
        try expect(app.sessionPersistenceNotice == nil)
    }

}
