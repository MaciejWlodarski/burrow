import Foundation

/// Real manager/executor/history integration, with every Trash redirected into a
/// disposable fixture. Barriers determine ordering; time limits only fail tests.
@MainActor
struct DuplicateCleanupLifecycleRegressionTests {
    private final class Fixture: @unchecked Sendable {
        let root: URL
        let trash: URL
        let fm = FileManager.default
        init() throws {
            root = fm.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("bf-duplicate-lifecycle-\(UUID())", isDirectory: true)
            trash = root.appendingPathComponent("fixture-trash", isDirectory: true)
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        }
        deinit { try? fm.removeItem(at: root) }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        func item(_ url: URL) -> FileItem {
            FileItem(url: url, name: url.lastPathComponent, path: url.path,
                     parentPath: url.deletingLastPathComponent().path, fileExtension: url.pathExtension,
                     isDirectory: false, isHidden: false, size: 4, modificationDate: .distantPast)
        }
        func group(_ names: [String]) throws -> DuplicateFileGroup {
            let files = names.map { item(url($0)) }
            for file in files where !exists(file.url) { try write("same", file.url) }
            var snapshots: [String: DuplicateFileSnapshot] = [:]
            for file in files { snapshots[file.path] = try DuplicateFileSafety.snapshot(at: file.url) }
            return DuplicateFileGroup(id: UUID().uuidString, sha256: "fixture-verified", fileSize: 4,
                                      files: files, snapshots: snapshots)
        }
        func move(_ source: URL) throws -> URL {
            guard source.path.hasPrefix(root.path + "/") else {
                throw RegressionFailure(description: "Refusing non-fixture Trash")
            }
            let target = trash.appendingPathComponent(source.lastPathComponent)
            try fm.moveItem(at: source, to: target)
            return target
        }
        var history: FileOperationIO {
            var io = FileOperationIO.live
            io.trash = { [self] in try move($0) }
            return io
        }
        var cleanup: DuplicateCleanupIO {
            DuplicateCleanupIO(trash: { [self] source in
                do { return .moved(recoveryURL: try move(source)) }
                catch { return .notConfirmed(error.localizedDescription) }
            })
        }
        @MainActor func manager(_ cleanup: DuplicateCleanupIO? = nil,
                                history: FileOperationIO? = nil) -> FileOperationsManager {
            FileOperationsManager(fileIO: history ?? self.history, duplicateCleanupIO: cleanup ?? self.cleanup,
                                  reloadVisiblePanes: {}, enqueueDirectoryRefresh: { _ in })
        }
    }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func record(_ value: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            values.append(value); return values.count
        }
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var entered = false
        private var main = false
        private var waiter: CheckedContinuation<Void, Error>?
        var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return main }
        func hold() throws {
            lock.lock()
            entered = true; main = Thread.isMainThread
            let waiting = waiter; waiter = nil
            lock.unlock()
            waiting?.resume()
            guard release.wait(timeout: .now() + 10) == .success else {
                throw RegressionFailure(description: "Duplicate worker barrier watchdog expired")
            }
        }
        func open() { release.signal() }
        func waitForEntry() async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if entered { lock.unlock(); continuation.resume(); return }
                waiter = continuation
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + 12) { [self] in
                    lock.lock(); let waiting = waiter; waiter = nil; lock.unlock()
                    waiting?.resume(throwing: RegressionFailure(description: "Worker never entered fixture barrier"))
                }
            }
        }
    }

    private static func idle(_ manager: FileOperationsManager) async throws {
        let deadline = Date().addingTimeInterval(12)
        while manager.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        try expect(!manager.isBusy)
    }
    private static func execute(_ plan: DuplicateCleanupPlan, manager: FileOperationsManager) async throws -> DuplicateCleanupResult {
        var result: DuplicateCleanupResult?
        try expect(manager.startDuplicateCleanup(plan, requestID: UUID()) { result = $0 })
        try await idle(manager)
        guard let result else { throw RegressionFailure(description: "Missing cleanup completion") }
        return result
    }
    private static func cancelled(_ result: DuplicateCleanupResult) throws {
        guard case .cancelled = result.stop else { throw RegressionFailure(description: "Expected cancellation") }
    }
    private static func invalidated(_ result: DuplicateCleanupResult) throws {
        guard case .invalidated = result.stop else { throw RegressionFailure(description: "Expected invalidated batch") }
    }

    static func runAll() async throws -> Int {
        try await testBlockedTrashCancellationAndMutationGate()
        try await testStaleCancellationCannotStopNewCleanup()
        try await testChangedCandidateAndKeeperStopBatch()
        try await testCancellationDuringFinalSnapshot()
        try await testMultipleGroupsReverseUndoAndIdentityReplacement()
        try await testMalformedPlansFailClosed()
        try await testUncertainResultsAndMissingRecoveryIdentity()
        try await testProgressRelayCoalescesAndCloses()
        try await testLiveHandoffAdmissionAndCompletionOwnership()
        try await testBlockedRecoveryIdentityAndGlobalCancel()
        try await testStaleCleanupCancellationDuringGenericTransfer()
        try await testMixedRecoveryHistoryKeepsUnknownPending()
        try await testUnconfirmedOnlyAttemptStillRefreshes()
        return 13
    }

    private static func testBlockedTrashCancellationAndMutationGate() async throws {
        let f = try Fixture(), gate = Gate(), calls = Probe(), snapshots = Probe()
        defer { gate.open() }
        let plan = DuplicateCleanupPlan(groups: [try f.group(["keep", "first", "later"])], onlyPath: nil)
        var io = f.cleanup
        io.snapshot = { url in
            _ = snapshots.record(url.lastPathComponent)
            return try DuplicateFileSafety.snapshot(at: url)
        }
        io.trash = { source in
            _ = calls.record(source.lastPathComponent)
            do { try gate.hold(); return .moved(recoveryURL: try f.move(source)) }
            catch { return .notConfirmed(error.localizedDescription) }
        }
        let manager = f.manager(io), request = UUID()
        // A pre-existing Undo proves the gate rejects actual history, not just an empty stack.
        let existing = manager.createFile(named: "existing", content: "sentinel", in: f.root)
        try expect(existing != nil && manager.undoStack.count == 1)
        var result: DuplicateCleanupResult?
        try expect(manager.startDuplicateCleanup(plan, requestID: request) { result = $0 })
        try await gate.waitForEntry()
        var heartbeat = false
        await Task { @MainActor in heartbeat = true }.value
        try expect(heartbeat && !gate.ranOnMain && manager.isBusy)
        manager.cancelDuplicateCleanup(request)
        try expect(manager.isBusy && manager.activeDuplicateCleanupID == request)
        try expect(manager.activeTransfer?.isCancellable == false && result == nil)
        var rejectedCompletion = false
        try expect(!manager.startDuplicateCleanup(plan, requestID: UUID()) { _ in rejectedCompletion = true })
        try expect(snapshots.calls == ["keep", "first", "keep"] && !rejectedCompletion)
        try expect(manager.createFile(named: "must-not-create", in: f.root) == nil)
        manager.undoLastOperation()
        try expect(f.exists(f.url("existing")) && manager.undoStack.count == 1 && !manager.canUndo)
        gate.open()
        try await idle(manager)
        guard let result else { throw RegressionFailure(description: "Cancellation lost completion") }
        try cancelled(result)
        try expect(calls.calls == ["first"] && result.attempted == 1 && result.confirmedMoved == 1)
        try expect(snapshots.calls.count == 3 && !rejectedCompletion)
        try expect(result.unattempted == 1 && result.undoActions.count == 1 && manager.undoStack.count == 2)
        try expect(!f.exists(f.url("first")) && f.exists(f.url("later")) && f.exists(f.url("keep")))
        try expect(manager.lastStatusMessage == result.summary && manager.activeDuplicateCleanupID == nil)
        manager.undoLastOperation(); try await idle(manager)
        try expect(f.exists(f.url("first")) && manager.undoStack.count == 1)
    }

    private static func testStaleCancellationCannotStopNewCleanup() async throws {
        let f = try Fixture(), gate = Gate()
        defer { gate.open() }
        let oldPlan = DuplicateCleanupPlan(groups: [try f.group(["old-keep", "old-copy"])], onlyPath: nil)
        let nextPlan = DuplicateCleanupPlan(groups: [try f.group(["new-keep", "new-copy"])], onlyPath: nil)
        var io = f.cleanup
        io.trash = { source in
            do {
                if source.lastPathComponent == "new-copy" { try gate.hold() }
                return .moved(recoveryURL: try f.move(source))
            } catch { return .notConfirmed(error.localizedDescription) }
        }
        let manager = f.manager(io), oldID = UUID(), newID = UUID()
        try expect(manager.startDuplicateCleanup(oldPlan, requestID: oldID))
        try await idle(manager)
        var result: DuplicateCleanupResult?
        try expect(manager.startDuplicateCleanup(nextPlan, requestID: newID) { result = $0 })
        try await gate.waitForEntry()
        manager.cancelDuplicateCleanup(oldID)
        try expect(manager.activeDuplicateCleanupID == newID && manager.activeTransfer?.isCancellable == true)
        gate.open(); try await idle(manager)
        guard let result, case .complete = result.stop else { throw RegressionFailure(description: "Stale cancellation affected new cleanup") }
        try expect(result.confirmedMoved == 1 && manager.undoStack.count == 2)
    }

    private static func testChangedCandidateAndKeeperStopBatch() async throws {
        for target in ["later", "keep", "throw"] {
            let f = try Fixture(), calls = Probe()
            let plan = DuplicateCleanupPlan(groups: [try f.group(["keep", "first", "later", "last"])], onlyPath: nil)
            var io = f.cleanup
            io.trash = { source in
                _ = calls.record(source.lastPathComponent)
                do {
                    let recovery = try f.move(source)
                    if source.lastPathComponent == "first" && target != "throw" {
                        try f.write("changed length guarantees snapshot mismatch", f.url(target))
                    }
                    return .moved(recoveryURL: recovery)
                } catch { return .notConfirmed(error.localizedDescription) }
            }
            io.snapshot = { url in
                if target == "throw" && url.lastPathComponent == "later" { throw DuplicateSafetyError.unreadable }
                return try DuplicateFileSafety.snapshot(at: url)
            }
            let manager = f.manager(io)
            let result = try await execute(plan, manager: manager)
            try invalidated(result)
            try expect(calls.calls == ["first"] && result.confirmedMoved == 1 && result.unattempted == 2)
            try expect(result.attempted == 1 && result.undoActions.count == 1 && manager.undoStack.count == 1)
            try expect(f.exists(f.url("keep")) && f.exists(f.url("later")) && f.exists(f.url("last")))
        }
    }

    private static func testCancellationDuringFinalSnapshot() async throws {
        let f = try Fixture(), gate = Gate(), snapshots = Probe(), trash = Probe()
        defer { gate.open() }
        let plan = DuplicateCleanupPlan(groups: [try f.group(["keep", "copy"])], onlyPath: nil)
        var io = f.cleanup
        io.snapshot = { url in
            let value = try DuplicateFileSafety.snapshot(at: url)
            if snapshots.record(url.lastPathComponent) == 3 { try gate.hold() }
            return value
        }
        io.trash = { _ in _ = trash.record("unexpected"); return .notConfirmed("must not run") }
        let manager = f.manager(io), id = UUID()
        var result: DuplicateCleanupResult?
        try expect(manager.startDuplicateCleanup(plan, requestID: id) { result = $0 })
        try await gate.waitForEntry()
        try expect(snapshots.calls == ["keep", "copy", "keep"] && !gate.ranOnMain)
        manager.cancelDuplicateCleanup(id)
        gate.open(); try await idle(manager)
        guard let result else { throw RegressionFailure(description: "Missing snapshot-cancel result") }
        try cancelled(result)
        try expect(trash.calls.isEmpty && result.attempted == 0 && result.unattempted == 1)
        try expect(manager.undoStack.isEmpty && f.exists(f.url("copy")))
    }

    private static func testMultipleGroupsReverseUndoAndIdentityReplacement() async throws {
        let f = try Fixture()
        let plan = DuplicateCleanupPlan(groups: [try f.group(["keep-a", "a", "b"]), try f.group(["keep-c", "c"])], onlyPath: nil)
        let manager = f.manager()
        let result = try await execute(plan, manager: manager)
        try expect(result.total == 3 && result.confirmedMoved == 3 && result.verifiedRecoveryCount == 3)
        try expect(manager.undoStack.count == 1)
        let destinations = result.undoActions.compactMap { action -> String? in
            guard case .restore(_, let to) = action.operation else { return nil }
            return to.lastPathComponent
        }
        try expect(destinations == ["c", "b", "a"])
        // First reverse action succeeds; second is a replaced recovery entry.
        let recoveryB = f.trash.appendingPathComponent("b"), retained = f.url("retained-b")
        try f.fm.moveItem(at: recoveryB, to: retained)
        try f.write("rival recovery must survive", recoveryB)
        let transaction = manager.undoStack.last?.transactionID
        manager.undoLastOperation(); try await idle(manager)
        try expect(f.exists(f.url("c")) && !f.exists(f.url("b")) && !f.exists(f.url("a")))
        try expect((try? String(contentsOf: recoveryB, encoding: .utf8)) == "rival recovery must survive")
        try expect(manager.undoStack.count == 1 && manager.redoStack.count == 1)
        try expect(manager.undoStack.last?.transactionID == transaction && manager.redoStack.last?.transactionID == transaction)
        guard case .actions(let pending) = manager.undoStack[0].kind else { throw RegressionFailure(description: "Missing pending actions") }
        try expect(pending.count == 2)
        try f.fm.moveItem(at: recoveryB, to: f.url("retained-rival"))
        try f.fm.moveItem(at: retained, to: recoveryB)
        manager.undoLastOperation(); try await idle(manager)
        try expect(manager.undoStack.isEmpty && manager.redoStack.count == 1)
        try expect(["a", "b", "c", "keep-a", "keep-c"].allSatisfy { f.exists(f.url($0)) })
    }

    private static func testMalformedPlansFailClosed() async throws {
        for variant in 0..<4 {
            let f = try Fixture(), calls = Probe()
            let first = try f.group(["a", "b"])
            let second: DuplicateFileGroup
            switch variant {
            case 0: second = try f.group(["b", "c"]) // Candidate is another group's keeper.
            case 1: second = try f.group(["c", "b"]) // Candidate selected twice.
            case 2:
                second = DuplicateFileGroup(id: "missing", sha256: "fixture", fileSize: 4,
                                            files: first.files, snapshots: [:])
            default:
                try f.fm.linkItem(at: f.url("a"), to: f.url("alias-a"))
                second = try f.group(["c", "alias-a"]) // Same keeper inode under another path.
            }
            var io = f.cleanup
            io.trash = { _ in _ = calls.record("unexpected"); return .notConfirmed("must not run") }
            let manager = f.manager(io)
            let result = try await execute(DuplicateCleanupPlan(groups: [first, second], onlyPath: nil), manager: manager)
            try invalidated(result)
            try expect(result.attempted == 0 && result.confirmedMoved == 0 && calls.calls.isEmpty)
            try expect(result.unattempted == 2 && manager.undoStack.isEmpty)
            try expect(first.files.allSatisfy { f.exists($0.url) })
        }
    }

    private static func testUncertainResultsAndMissingRecoveryIdentity() async throws {
        let f = try Fixture()
        let plan = DuplicateCleanupPlan(groups: [try f.group(["keep", "no-url", "error", "unknown-id"])], onlyPath: nil)
        var io = f.cleanup
        let attempts = Probe()
        io.trash = { source in
            _ = attempts.record(source.lastPathComponent)
            return DuplicateCleanupIO.captureTrashOutcome {
                let target = try f.move(source)
                if source.lastPathComponent == "error" {
                    // A throw after a physical move is still unconfirmed: neither
                    // retry the source nor promise recovery without returned evidence.
                    throw RegressionFailure(description: "Injected Trash error, no automatic retry")
                }
                return source.lastPathComponent == "no-url" ? nil : target
            }
        }
        let failIdentity = Probe()
        var history = f.history
        let identity = history.identity
        history.identity = { url in
            if url == f.trash.appendingPathComponent("unknown-id") && failIdentity.calls.isEmpty {
                throw RegressionFailure(description: "Recovery identity unavailable")
            }
            return try identity(url)
        }
        let refreshes = Probe()
        var reloads = 0
        let manager = FileOperationsManager(fileIO: history, duplicateCleanupIO: io,
            reloadVisiblePanes: { reloads += 1 }, enqueueDirectoryRefresh: { _ = refreshes.record($0) })
        let result = try await execute(plan, manager: manager)
        try expect(reloads == 1 && Set(refreshes.calls) == Set([f.root.path, f.trash.path]))
        try expect(refreshes.calls.count == 2 && result.touchedDirectories.contains(f.url("error").deletingLastPathComponent().path))
        try expect(result.total == 3 && result.attempted == 3 && result.unattempted == 0)
        try expect(result.confirmedMoved == 2 && result.movedWithoutURL == 1 && result.unconfirmed == 1)
        try expect(result.recoveryIdentityMissing == 1 && result.verifiedRecoveryCount == 0)
        try expect(result.undoActions.count == 1 && result.undoActions[0].identity == nil && manager.undoStack.count == 1)
        try expect(result.summary.contains("⌘Z ich nie przywróci") && result.summary.contains("oczekujące"))
        try expect(!result.summary.contains("⌘Z: zapisano") && result.errors.count == 1)
        try expect(attempts.calls == ["no-url", "error", "unknown-id"])
        try expect(!f.exists(f.url("error")) && f.exists(f.trash.appendingPathComponent("error")))
        try expect(!f.exists(f.url("no-url")) && !f.exists(f.url("unknown-id")))
        // Identity becoming readable must not bind a previously unknown record.
        _ = failIdentity.record("readable now")
        manager.undoLastOperation(); try await idle(manager)
        try expect(manager.undoStack.count == 1 && manager.redoStack.isEmpty)
        try expect(!f.exists(f.url("unknown-id")) && f.exists(f.trash.appendingPathComponent("unknown-id")))
    }

    private static func testProgressRelayCoalescesAndCloses() async throws {
        var deliveries: [Int] = []
        let relay = DuplicateCleanupProgressRelay { deliveries.append($0.attempted) }
        // No actor suspension: the scheduled delivery cannot run until all offers exist.
        for value in 0..<1_000 {
            relay.offer(DuplicateCleanupProgress(currentFile: "file", attempted: value, total: 1_000))
        }
        let deadline = Date().addingTimeInterval(5)
        while deliveries.isEmpty && Date() < deadline { await Task.yield() }
        try expect(deliveries == [999])
        relay.offer(DuplicateCleanupProgress(currentFile: "stale", attempted: 1_000, total: 1_000))
        relay.close()
        relay.offer(DuplicateCleanupProgress(currentFile: "closed", attempted: 1_001, total: 1_000))
        // A main-actor task queued behind the delivery gives it a chance to run.
        await Task { @MainActor in }.value
        try expect(deliveries == [999])
    }

    private static func testLiveHandoffAdmissionAndCompletionOwnership() async throws {
        let f = try Fixture(), gate = Gate(), calls = Probe()
        defer { gate.open() }
        let app = AppState.shared
        let savedTabs = app.tabs, savedID = app.activeTabId, savedRight = app.rightPane
        let savedDual = app.isDualPane
        defer {
            app.tabs = savedTabs; app.activeTabId = savedID
            app.rightPane = savedRight; app.isDualPane = savedDual
        }
        let a = PaneTabState(initialURL: f.root), b = PaneTabState(initialURL: f.root)
        a.viewMode = .wiztree; b.viewMode = .wiztree
        b.showHiddenFiles = a.showHiddenFiles
        app.tabs = [a, b]; app.activeTabId = a.id
        let token = AnalysisRequestToken(rootPath: f.root.path,
            context: AnalysisPublicationContext(pane: a, side: .left, mode: .duplicates))
        let otherToken = AnalysisRequestToken(rootPath: f.root.path,
            context: AnalysisPublicationContext(pane: a, side: .left, mode: .duplicates))
        let plan = DuplicateCleanupPlan(groups: [try f.group(["keeper", "first", "later"])], onlyPath: nil)
        var io = f.cleanup
        io.snapshot = { url in
            _ = calls.record("snapshot")
            return try DuplicateFileSafety.snapshot(at: url)
        }
        io.trash = { url in
            _ = calls.record("trash")
            return DuplicateCleanupIO.captureTrashOutcome { try gate.hold(); return try f.move(url) }
        }
        let manager = f.manager(io), request = UUID()
        var state = DuplicateCleanupViewState(scanToken: token, resultReady: true,
            isComplete: true, mode: .duplicates, cleanupID: request)
        var finishCalls = 0, rescans = 0
        func handoff(_ verification: AnalysisVerificationResult = .verified) -> Bool {
            DuplicateCleanupHandoff.start(verified: verification, plan: plan, scanToken: token,
                requestID: request, appState: app, manager: manager, current: { state }) { mayRescan in
                finishCalls += 1
                if mayRescan { rescans += 1 }
                state = DuplicateCleanupViewState(scanToken: state.scanToken, resultReady: state.resultReady,
                    isComplete: state.isComplete, mode: state.mode, cleanupID: nil)
            }
        }
        app.activeTabId = b.id // Same root is not the same live owner.
        try expect(!handoff())
        app.activeTabId = a.id
        state = DuplicateCleanupViewState(scanToken: token, resultReady: true,
            isComplete: false, mode: .duplicates, cleanupID: request)
        try expect(!handoff())
        state = DuplicateCleanupViewState(scanToken: otherToken, resultReady: true,
            isComplete: true, mode: .duplicates, cleanupID: request)
        try expect(!handoff())
        state = DuplicateCleanupViewState(scanToken: token, resultReady: false,
            isComplete: true, mode: .duplicates, cleanupID: request)
        try expect(!handoff())
        state = DuplicateCleanupViewState(scanToken: token, resultReady: true,
            isComplete: true, mode: .duplicates, cleanupID: request)
        try expect(!handoff(.failed("verification rejected")))
        try expect(calls.calls.isEmpty && !manager.isBusy && manager.undoStack.isEmpty && finishCalls == 0)
        try expect(handoff())
        try await gate.waitForEntry()
        app.activeTabId = b.id
        let newerToken = AnalysisRequestToken(rootPath: f.root.path,
            context: AnalysisPublicationContext(pane: b, side: .left, mode: .duplicates))
        let newerID = UUID()
        state = DuplicateCleanupViewState(scanToken: newerToken, resultReady: false,
            isComplete: false, mode: .duplicates, cleanupID: newerID)
        DuplicateCleanupHandoff.cancelOwned(request, manager: manager)
        try expect(manager.isBusy)
        gate.open(); try await idle(manager)
        try expect(manager.undoStack.count == 1 && manager.lastStatusMessage?.contains("Anulowano") == true)
        try expect(!f.exists(f.url("first")) && f.exists(f.url("later")))
        try expect(finishCalls == 0 && rescans == 0 && state.cleanupID == newerID && state.scanToken === newerToken)
    }

    private static func testBlockedRecoveryIdentityAndGlobalCancel() async throws {
        let f = try Fixture(), gate = Gate(), threads = Probe(), refreshes = Probe()
        defer { gate.open() }
        let plan = DuplicateCleanupPlan(groups: [try f.group(["keeper", "first", "later"])], onlyPath: nil)
        var io = f.cleanup, history = f.history
        io.snapshot = { url in
            _ = threads.record(Thread.isMainThread ? "snapshot-main" : "snapshot-worker")
            return try DuplicateFileSafety.snapshot(at: url)
        }
        io.trash = { url in
            _ = threads.record(Thread.isMainThread ? "trash-main" : "trash-worker")
            return DuplicateCleanupIO.captureTrashOutcome { try f.move(url) }
        }
        let identity = history.identity
        history.identity = { url in
            _ = threads.record(Thread.isMainThread ? "identity-main" : "identity-worker")
            try gate.hold()
            return try identity(url)
        }
        var reloads = 0, completions = 0
        let manager = FileOperationsManager(fileIO: history, duplicateCleanupIO: io,
            reloadVisiblePanes: { reloads += 1 }, enqueueDirectoryRefresh: { _ = refreshes.record($0) })
        var result: DuplicateCleanupResult?
        try expect(manager.startDuplicateCleanup(plan, requestID: UUID()) { result = $0; completions += 1 })
        try await gate.waitForEntry()
        var heartbeat = false
        await Task { @MainActor in heartbeat = true }.value
        try expect(heartbeat && !gate.ranOnMain && manager.isBusy && !f.exists(f.url("first")))
        try expect(result == nil && manager.undoStack.isEmpty && reloads == 0 && refreshes.calls.isEmpty)
        manager.cancelActiveTransfer()
        try expect(manager.isBusy && manager.activeTransfer?.isCancellable == false)
        gate.open(); try await idle(manager)
        guard let result else { throw RegressionFailure(description: "Missing blocked-identity completion") }
        try cancelled(result)
        try expect(result.confirmedMoved == 1 && result.verifiedRecoveryCount == 1 && result.unattempted == 1)
        try expect(threads.calls == ["snapshot-worker", "snapshot-worker", "snapshot-worker", "trash-worker", "identity-worker"])
        try expect(manager.undoStack.count == 1 && f.exists(f.url("later")))
        try expect(completions == 1 && reloads == 1 && manager.lastStatusMessage == result.summary)
        try expect(refreshes.calls.count == 2 && Set(refreshes.calls) == Set([f.root.path, f.trash.path]))
    }

    private static func testStaleCleanupCancellationDuringGenericTransfer() async throws {
        let f = try Fixture(), gate = Gate()
        defer { gate.open() }
        let plan = DuplicateCleanupPlan(groups: [try f.group(["keeper", "duplicate"])], onlyPath: nil)
        let first = f.url("copy-first"), later = f.url("copy-later")
        try f.write("first", first); try f.write("later", later)
        let destination = f.url("destination")
        try f.fm.createDirectory(at: destination, withIntermediateDirectories: false)
        var history = f.history
        let copy = history.copy
        history.copy = { source, target in
            if source == first { try gate.hold() }
            try copy(source, target)
        }
        let manager = f.manager(history: history), oldID = UUID()
        try expect(manager.startDuplicateCleanup(plan, requestID: oldID))
        try await idle(manager)
        manager.performTransfer(sourceURLs: [first, later], into: destination,
                                isMove: false, explicitPolicy: .keepBoth)
        try await gate.waitForEntry()
        try expect(manager.isBusy && manager.activeDuplicateCleanupID == nil)
        DuplicateCleanupHandoff.cancelOwned(oldID, manager: manager)
        gate.open(); try await idle(manager)
        try expect(f.exists(destination.appendingPathComponent("copy-first")))
        try expect(f.exists(destination.appendingPathComponent("copy-later")))
        try expect(manager.undoStack.count == 2)
    }


    private static func testMixedRecoveryHistoryKeepsUnknownPending() async throws {
        let f = try Fixture(), reads = Probe(), readable = Probe()
        let plan = DuplicateCleanupPlan(groups: [try f.group(["keeper", "known", "unknown"])], onlyPath: nil)
        var history = f.history
        let identity = history.identity
        history.identity = { url in
            if url == f.trash.appendingPathComponent("unknown") {
                _ = reads.record("unknown identity read")
                if readable.calls.isEmpty { throw RegressionFailure(description: "Identity unavailable at mutation completion") }
            }
            return try identity(url)
        }
        let manager = f.manager(history: history)
        let result = try await execute(plan, manager: manager)
        try expect(result.confirmedMoved == 2 && result.recoveryIdentityMissing == 1 && result.verifiedRecoveryCount == 1)
        try expect(result.undoActions.count == 2 && result.undoActions[0].identity != nil && result.undoActions[1].identity == nil)
        try expect(result.undoActions.map { $0.sourceURL.lastPathComponent } == ["known", "unknown"])
        try expect(result.summary.contains("⌘Z: zapisano 1") && result.summary.contains("oczekujące"))
        let transaction = manager.undoStack.last?.transactionID
        _ = readable.record("identity available now")
        manager.undoLastOperation(); try await idle(manager)
        try expect(f.exists(f.url("known")) && !f.exists(f.url("unknown")))
        try expect(f.exists(f.trash.appendingPathComponent("unknown")))
        try expect(manager.undoStack.count == 1 && manager.redoStack.count == 1)
        try expect(manager.undoStack.last?.transactionID == transaction && manager.redoStack.last?.transactionID == transaction)
        guard case .actions(let pending) = manager.undoStack[0].kind else { throw RegressionFailure(description: "Missing unknown recovery record") }
        try expect(pending.count == 1 && pending[0].identity == nil)
        manager.undoLastOperation(); try await idle(manager)
        try expect(reads.calls.count == 1 && manager.undoStack.count == 1 && manager.redoStack.count == 1)
        try expect(!f.exists(f.url("unknown")) && f.exists(f.trash.appendingPathComponent("unknown")))
        manager.redoLastOperation(); try await idle(manager)
        try expect(!f.exists(f.url("known")) && f.exists(f.trash.appendingPathComponent("known")))
        try expect(manager.redoStack.isEmpty && manager.undoStack.count == 1)
        try expect(manager.undoStack[0].transactionID == transaction)
        guard case .actions(let reunited) = manager.undoStack[0].kind else {
            throw RegressionFailure(description: "Redo did not reunite the recovery transaction")
        }
        try expect(reunited.count == 2 && reunited[0].identity != nil && reunited[1].identity == nil)
        try expect(reunited.map { $0.sourceURL.lastPathComponent } == ["known", "unknown"])
        manager.undoLastOperation(); try await idle(manager)
        try expect(f.exists(f.url("known")) && !f.exists(f.url("unknown")))
        try expect(manager.undoStack.count == 1 && manager.redoStack.count == 1 && reads.calls.count == 1)
        try expect(manager.undoStack[0].transactionID == transaction && manager.redoStack[0].transactionID == transaction)
        guard case .actions(let stillPending) = manager.undoStack[0].kind else {
            throw RegressionFailure(description: "Unknown identity recovery record was lost")
        }
        try expect(stillPending.count == 1 && stillPending[0].identity == nil)
        try expect(f.exists(f.trash.appendingPathComponent("unknown")))
    }


    private static func testUnconfirmedOnlyAttemptStillRefreshes() async throws {
        let f = try Fixture(), refreshes = Probe(), attempts = Probe()
        let plan = DuplicateCleanupPlan(groups: [try f.group(["keeper", "uncertain"])], onlyPath: nil)
        var io = f.cleanup
        io.trash = { source in
            _ = attempts.record(source.path)
            return DuplicateCleanupIO.captureTrashOutcome {
                _ = try f.move(source)
                throw RegressionFailure(description: "Fixture moved but adapter threw")
            }
        }
        var reloads = 0
        let manager = FileOperationsManager(fileIO: f.history, duplicateCleanupIO: io,
            reloadVisiblePanes: { reloads += 1 }, enqueueDirectoryRefresh: { _ = refreshes.record($0) })
        let result = try await execute(plan, manager: manager)
        try expect(result.attempted == 1 && result.confirmedMoved == 0 && result.unconfirmed == 1)
        try expect(attempts.calls.count == 1 && reloads == 1 && refreshes.calls == [f.root.path])
        try expect(result.touchedDirectories == Set([f.root.path]) && manager.undoStack.isEmpty)
        try expect(!result.summary.contains("⌘Z: zapisano") && !f.exists(f.url("uncertain")))
    }

}
