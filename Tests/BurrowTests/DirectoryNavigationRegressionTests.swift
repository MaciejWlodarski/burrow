import Foundation
import Darwin

/// Isolated directories plus injected read failures: no permissions changes and
/// no real application launches, including replacement-file history cases.
struct DirectoryNavigationRegressionTests {
    @MainActor func runAll() async throws {
        for forward in [false, true] {
            for failure in ["missing", "file", "denied", "partial", "error", "incomplete"] {
                try testFailedHistory(forward: forward, failure: failure)
            }
        }
        try testSystemTrashRoutesWithoutListingOrPaneMutation()
        try testPermissionDiagnosticAndGuardedDismissal()
        try testCommitAndSnapshotOwnership()
        try testPreparedEmptySnapshotIsInstalledOnce()
        try await testRightPaneVisibility()
        try await testFailedNavigationCancelsResume()
        try testRetryRejectsReplacementFileAndChangedContext()
        try await testRetryIsSupersededBySavedSearchAndResume()
        try testRetainedRetryActionCannotRouteToReplacedPane()
        print("21 directory navigation/history regression groups passed")
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bf-navigation-\(UUID().uuidString)")
        for name in ["A", "B", "C", "D"] {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: dir.appendingPathComponent("\(name).txt"))
        }
        // Match the production URL contract on macOS (/var and /private/var).
        return root.standardizedFileURL
    }

    @MainActor private func testFailedHistory(forward: Bool, failure: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A").standardizedFileURL, b = root.appendingPathComponent("B").standardizedFileURL
        let pane = PaneTabState(initialURL: a)
        var opened = 0
        pane.fileOpener = { _ in opened += 1 }
        try expect(pane.navigate(to: b))
        if forward { pane.goBack() }
        let target = forward ? b : a
        let current = pane.currentURL, back = pane.historyBack, next = pane.historyForward
        let paths = pane.directoryItems.map(\.path)
        pane.selectedPaths = Set(paths)
        pane.expandedFolderPaths = [current.appendingPathComponent("outline").path]
        pane.searchQuery = "retained query"
        let selected = pane.selectedPaths, expanded = pane.expandedFolderPaths
        if failure == "missing" || failure == "file" {
            try FileManager.default.removeItem(at: target)
            if failure == "file" { try Data("not a folder".utf8).write(to: target) }
        } else {
            let partial = BulkCrawler.readDirectoryResult(at: target.path).entries
            pane.navigationDirectoryReader = { _, _ in
                BulkCrawler.DirectoryReadResult(entries: failure == "partial" ? partial : [],
                    isComplete: failure == "error", errorCode: failure == "denied" ? EACCES : (failure == "error" ? EIO : nil))
            }
        }
        if forward { pane.goForward() } else { pane.goBack() }
        try expect(pane.currentURL == current && pane.historyBack == back && pane.historyForward == next)
        try expect(pane.directoryItems.map(\.path) == paths && pane.selectedPaths == selected)
        try expect(pane.searchQuery == "retained query" && pane.expandedFolderPaths == expanded)
        try expect(pane.navigationDiagnostic?.contains(target.path) == true && opened == 0)
        if failure == "file" { try FileManager.default.removeItem(at: target) }
        if failure == "missing" || failure == "file" {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        pane.navigationDirectoryReader = { BulkCrawler.readDirectoryResult(at: $0, includeHidden: $1) }
        pane.retryNavigation()
        try expect(pane.currentURL == target && pane.navigationDiagnostic == nil && opened == 0)
        try expect(forward ? pane.historyBack == [a] && pane.historyForward.isEmpty
                           : pane.historyBack.isEmpty && pane.historyForward == [b])
    }

    @MainActor private func testCommitAndSnapshotOwnership() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A").standardizedFileURL, b = root.appendingPathComponent("B").standardizedFileURL
        let c = root.appendingPathComponent("C").standardizedFileURL, d = root.appendingPathComponent("D").standardizedFileURL
        let pane = PaneTabState(initialURL: a), other = PaneTabState(initialURL: d)
        try expect(pane.navigate(to: b)); try expect(pane.navigate(to: c))
        pane.goBack()
        try expect(pane.currentURL == b && pane.historyBack == [a] && pane.historyForward == [c])
        pane.goForward()
        try expect(pane.currentURL == c && pane.historyBack == [a, b] && pane.historyForward.isEmpty)
        pane.goBack()
        let item = pane.displayedItems[0]
        pane.select(item)
        pane.expandedFolderPaths = [b.appendingPathComponent("outline").path]
        pane.searchQuery = "keep"
        let display = pane.displayedItems.map(\.path), revision = pane.directoryRevision
        try expect(!pane.navigate(to: root.appendingPathComponent("missing").standardizedFileURL, clearSearch: true))
        try expect(pane.currentURL == b && pane.historyBack == [a] && pane.historyForward == [c])
        try expect(pane.selectedItems.map(\.path) == [item.path] && !pane.actionItems(for: item).isEmpty)
        try expect(pane.displayedItems.map(\.path) == display && pane.directoryRevision == revision)
        try expect(pane.searchQuery == "keep" && !pane.expandedFolderPaths.isEmpty)
        try expect(other.navigate(to: a))
        try expect(pane.historyBack == [a] && pane.historyForward == [c])
        try expect(pane.navigate(to: d, clearSearch: true))
        try expect(pane.historyBack == [a, b] && pane.historyForward.isEmpty)
        try expect(pane.selectedPaths.isEmpty && pane.actionItems(for: item).isEmpty)
        try expect(pane.searchQuery.isEmpty && pane.expandedFolderPaths.isEmpty)
        try expect(other.currentURL == a && other.historyBack == [d])
        try expect(pane.navigate(to: d))
        try expect(pane.historyBack == [a, b])
        var opened = 0
        pane.fileOpener = { _ in opened += 1 }
        pane.openFile(d.appendingPathComponent("D.txt"))
        try expect(opened == 1) // explicit file gesture remains separate
    }

    @MainActor private func testPreparedEmptySnapshotIsInstalledOnce() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A").standardizedFileURL, b = root.appendingPathComponent("B").standardizedFileURL
        let pane = PaneTabState(initialURL: a)
        var reads = 0
        pane.navigationDirectoryReader = { _, _ in
            reads += 1
            return BulkCrawler.DirectoryReadResult(entries: [], isComplete: true, errorCode: nil)
        }
        try expect(pane.navigate(to: b))
        // B contains a real file. Any unvalidated second read would expose it.
        try expect(reads == 1 && pane.directoryItems.isEmpty && pane.displayedItems.isEmpty)
        try expect(pane.currentURL == b && pane.historyBack == [a])
    }

    @MainActor private func testRightPaneVisibility() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A").standardizedFileURL, b = root.appendingPathComponent("B").standardizedFileURL
        let c = root.appendingPathComponent("C").standardizedFileURL, d = root.appendingPathComponent("D").standardizedFileURL
        let app = AppState.shared
        let oldTabs = app.tabs, oldID = app.activeTabId, oldRight = app.rightPane
        let oldDual = app.isDualPane, oldSide = app.activePaneSide
        defer {
            app.tabs = oldTabs; app.activeTabId = oldID; app.rightPane = oldRight
            app.isDualPane = oldDual; app.activePaneSide = oldSide
        }
        let left = PaneTabState(initialURL: a), right = PaneTabState(initialURL: d)
        app.tabs = [left]; app.activeTabId = left.id; app.rightPane = right; app.isDualPane = false
        var reads = 0
        right.navigationDirectoryReader = { path, hidden in
            reads += 1
            return BulkCrawler.readDirectoryResult(at: path, includeHidden: hidden)
        }
        app.toggleDualPane()
        try expect(right.currentURL == a && right.historyBack.isEmpty && reads == 1)
        try expect(right.navigate(to: b)); try expect(right.navigate(to: c))
        right.searchQuery = "retained"
        right.selectedPaths = Set(right.displayedItems.map(\.path))
        let selected = right.selectedPaths, back = right.historyBack, next = right.historyForward
        let readCount = reads
        for _ in 0..<2 {
            app.toggleDualPane(); try expect(left.navigate(to: d)); app.toggleDualPane()
            try expect(right.currentURL == c && right.searchQuery == "retained")
            try expect(right.historyBack == back && right.historyForward == next && right.selectedPaths == selected)
            try expect(reads == readCount)
        }
        let paused = FinderPaneSession(path: root.appendingPathComponent("offline").path).makePausedPane()
        paused.navigationDirectoryReader = { _, _ in reads += 1; return .init(entries: [], isComplete: false, errorCode: EIO) }
        app.rightPane = paused
        app.toggleDualPane(); app.toggleDualPane()
        try expect(paused.isSessionPaused && reads == readCount)
        let savedPath = paused.currentURL
        let resumed = await paused.resumeSession { path, _ in
            PreparedSavedSearch(root: URL(fileURLWithPath: path), entries: [])
        }
        try expect(resumed)
        app.toggleDualPane(); app.toggleDualPane()
        try expect(paused.currentURL == savedPath && !paused.isSessionPaused && reads == readCount)
    }

    @MainActor private func testFailedNavigationCancelsResume() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A").standardizedFileURL, b = root.appendingPathComponent("B").standardizedFileURL
        let pane = FinderPaneSession(path: a.path).makePausedPane()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task { @MainActor in
            await pane.resumeSession { path, _ in
                entered.signal(); _ = release.wait(timeout: .now() + 5)
                return PreparedSavedSearch(root: URL(fileURLWithPath: path), entries: [])
            }
        }
        var started = false
        for _ in 0..<200 {
            if entered.wait(timeout: .now()) == .success { started = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(started)
        try expect(!pane.navigate(to: root.appendingPathComponent("missing").standardizedFileURL))
        try expect(pane.currentURL == a && pane.isSessionPaused && pane.historyBack.isEmpty)
        try expect(pane.navigate(to: b))
        release.signal()
        let applied = await task.value
        try expect(!applied && pane.currentURL == b && !pane.isSessionPaused)
        try expect(pane.directoryItems.map(\.name) == ["B.txt"] && pane.historyBack == [a])
        // Failed Back into a saved location does not activate it or fall back home.
        try FileManager.default.removeItem(at: a)
        pane.goBack()
        try expect(pane.currentURL == b && pane.historyBack == [a] && pane.historyForward.isEmpty)
    }
    @MainActor private func testRetryRejectsReplacementFileAndChangedContext() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A").standardizedFileURL, target = root.appendingPathComponent("missing").standardizedFileURL
        let pane = PaneTabState(initialURL: a)
        var opened = 0
        pane.fileOpener = { _ in opened += 1 }
        try expect(!pane.navigate(to: target))
        let failureID = pane.navigationFailureID!
        try Data("replacement".utf8).write(to: target)
        pane.retryNavigation(expectedFailureID: failureID)
        try expect(pane.currentURL == a && pane.historyBack.isEmpty && pane.historyForward.isEmpty)
        try expect(opened == 0 && pane.navigationDiagnostic != nil)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // A retained button from the earlier failure cannot retry a newer one.
        pane.retryNavigation(expectedFailureID: failureID)
        try expect(pane.currentURL == a)
        let latestID = pane.navigationFailureID!
        pane.searchQuery = "new context"
        pane.retryNavigation(expectedFailureID: latestID)
        try expect(pane.currentURL == a && pane.searchQuery == "new context" && pane.navigationDiagnostic == nil)
    }

    @MainActor private func testRetryIsSupersededBySavedSearchAndResume() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A").standardizedFileURL, b = root.appendingPathComponent("B").standardizedFileURL
        for scope in [SearchScopeMode.currentFolder, .wholeIndex] {
            let pane = PaneTabState(initialURL: a)
            let target = root.appendingPathComponent(UUID().uuidString).standardizedFileURL
            try expect(!pane.navigate(to: target))
            let failureID = pane.navigationFailureID!
            let search = SavedSmartFolderItem(title: "New context", query: "B", scope: scope,
                rootPath: scope == .wholeIndex ? nil : b.path, includeHidden: false, fuzzyEnabled: false)
            let applied = try await pane.applySavedSearch(search)
            try expect(applied && pane.navigationDiagnostic == nil && pane.navigationFailureID == nil)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let location = pane.currentURL, back = pane.historyBack
            pane.retryNavigation(expectedFailureID: failureID)
            try expect(pane.currentURL == location && pane.historyBack == back && pane.searchQuery == "B")
        }
        let pane = FinderPaneSession(path: a.path).makePausedPane()
        let target = root.appendingPathComponent("resume-retry").standardizedFileURL
        try expect(!pane.navigate(to: target))
        let failureID = pane.navigationFailureID!
        let resumed = await pane.resumeSession()
        try expect(resumed && pane.navigationDiagnostic == nil && pane.navigationFailureID == nil)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        pane.retryNavigation(expectedFailureID: failureID)
        try expect(pane.currentURL == a && pane.historyBack.isEmpty)
    }

    @MainActor private func testRetainedRetryActionCannotRouteToReplacedPane() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppState.shared
        let oldTabs = app.tabs, oldID = app.activeTabId, oldRight = app.rightPane
        let oldDual = app.isDualPane, oldSide = app.activePaneSide
        defer {
            app.tabs = oldTabs; app.activeTabId = oldID; app.rightPane = oldRight
            app.isDualPane = oldDual; app.activePaneSide = oldSide
        }
        let pane = PaneTabState(initialURL: root.appendingPathComponent("A").standardizedFileURL)
        let replacement = PaneTabState(initialURL: root.appendingPathComponent("B").standardizedFileURL)
        let target = root.appendingPathComponent("retry").standardizedFileURL
        try expect(!pane.navigate(to: target))
        let failureID = pane.navigationFailureID!
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        // The attempted URL was standardized while absent. Recompute only the
        // expected destination now that it is a directory, exactly as navigation
        // does at retry time (Foundation may add directory URL representation).
        let expectedDestination = target.standardizedFileURL
        print("INFO retry fixture URL: before creation=\(target.absoluteString), after creation=\(expectedDestination.absoluteString), equal=\(target == expectedDestination)")
        let originalLocation = pane.currentURL
        var actions = 0
        let action = { actions += 1; pane.retryNavigation(expectedFailureID: failureID) }
        app.tabs = [pane, replacement]; app.activeTabId = replacement.id
        try expect(!FinderPaneActionRouting.performIfCurrent(appState: app, pane: pane, paneSide: .left, action: action))
        app.tabs = [replacement] // closed captured tab
        try expect(!FinderPaneActionRouting.performIfCurrent(appState: app, pane: pane, paneSide: .left, action: action))
        app.rightPane = replacement; app.isDualPane = true; app.activePaneSide = .left
        try expect(!FinderPaneActionRouting.performIfCurrent(appState: app, pane: pane, paneSide: .right, action: action))
        app.rightPane = pane; app.isDualPane = false
        try expect(!FinderPaneActionRouting.performIfCurrent(appState: app, pane: pane, paneSide: .right, action: action))
        try expect(actions == 0 && app.activePaneSide == .left && pane.currentURL != target)
        app.isDualPane = true
        try expect(FinderPaneActionRouting.performIfCurrent(appState: app, pane: pane, paneSide: .right, action: action))
        guard actions == 1 else {
            throw RegressionFailure(description: "Visible retry invoked \(actions) actions; expected exactly one")
        }
        try expect(app.activePaneSide == .right)
        guard pane.currentURL == expectedDestination else {
            throw RegressionFailure(description: "Retry destination mismatch: actual=\(pane.currentURL.absoluteString), expected=\(expectedDestination.absoluteString), attempted=\(target.absoluteString), diagnostic=\(pane.navigationDiagnostic ?? "nil"), failureID=\(String(describing: pane.navigationFailureID))")
        }
        try expect(pane.historyBack == [originalLocation] && pane.historyForward.isEmpty)
        try expect(pane.navigationDiagnostic == nil && pane.navigationFailureID == nil)
    }
    @MainActor private func testSystemTrashRoutesWithoutListingOrPaneMutation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A")
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        let pane = PaneTabState(initialURL: a)
        let oldURL = pane.currentURL, oldHistory = pane.historyBack
        let oldItems = pane.directoryItems.map(\.path)
        var reads = 0, opens = 0
        pane.navigationDirectoryReader = { _, _ in
            reads += 1
            return BulkCrawler.DirectoryReadResult(entries: [], isComplete: false, errorCode: EPERM)
        }
        // No Trash directory exists. Special routing must not stat or enumerate it.
        let outcome = SystemTrashNavigation.open(trash, systemTrashURL: trash, openInFinder: { url in
            opens += 1
            return url == trash
        }, navigate: { _ = pane.navigate(to: $0) })
        try expect(outcome == .openedInFinder && opens == 1 && reads == 0)
        try expect(pane.currentURL == oldURL && pane.historyBack == oldHistory)
        try expect(pane.directoryItems.map(\.path) == oldItems && pane.navigationDiagnostic == nil)
        let failed = SystemTrashNavigation.open(trash, systemTrashURL: trash,
            openInFinder: { _ in false }, navigate: { _ in reads += 1 })
        try expect(failed == .failedToOpenFinder && reads == 0)
        let renamed = SidebarLocationItem(bookmarkPath: "custom-trash", title: "Moje archiwum", iconName: "folder", url: trash, isCustomBookmark: true)
        try expect(SystemTrashNavigation.isSystemTrash(renamed.url, systemTrashURL: trash))
        for unrelated in [root.appendingPathComponent("A/.Trash"), root.appendingPathComponent("Trash"),
                          root.appendingPathComponent(".Trash-old"), URL(string: "smb://server/.Trash")!] {
            var routed: URL?
            let result = SystemTrashNavigation.open(unrelated, systemTrashURL: trash,
                openInFinder: { _ in opens += 1; return true }, navigate: { routed = $0 })
            try expect(result == .navigated && routed == unrelated && opens == 1)
        }
    }

    @MainActor private func testPermissionDiagnosticAndGuardedDismissal() throws {
        try expect(DirectoryNavigationFailure.isPermissionDenied(NSError(domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadNoPermission.rawValue)))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
        try expect(DirectoryNavigationFailure.isPermissionDenied(wrapped))
        try expect(!DirectoryNavigationFailure.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain,
            code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])))
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        let pane = PaneTabState(initialURL: a)
        for code in [EACCES, EPERM, EIO] {
            pane.navigationDirectoryReader = { _, _ in
                BulkCrawler.DirectoryReadResult(entries: [], isComplete: false, errorCode: code)
            }
            try expect(!pane.navigate(to: b))
            try expect(pane.navigationFailureIsPermissionDenied == (code != EIO))
            try expect(pane.navigationDiagnostic?.contains(b.path) == true)
            let id = pane.navigationFailureID!
            pane.dismissNavigationFailure(expectedFailureID: UUID())
            try expect(pane.navigationFailureID == id)
            pane.dismissNavigationFailure(expectedFailureID: id)
            try expect(pane.navigationDiagnostic == nil && pane.navigationFailureID == nil)
            try expect(!pane.navigationFailureIsPermissionDenied && pane.currentURL == a.standardizedFileURL)
        }
    }

}
