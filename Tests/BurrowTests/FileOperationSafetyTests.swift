import Foundation
import Darwin

/// Integration regressions use the actual manager, stacks, subprocess methods,
/// and IO executor. All destructive work is redirected into a disposable fixture.
@MainActor
struct FileOperationSafetyTests {
    private final class Fixture {
        let root: URL
        let sourceDirectory: URL
        let destination: URL
        let trash: URL
        let fm = FileManager.default

        init() throws {
            root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("bf-manager-safety-\(UUID())", isDirectory: true)
            sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
            destination = root.appendingPathComponent("destination", isDirectory: true)
            trash = root.appendingPathComponent("fixture-trash", isDirectory: true)
            for directory in [sourceDirectory, destination, trash] {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        deinit { try? fm.removeItem(at: root) }
        func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }
        func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        func item(_ url: URL) -> FileItem {
            FileItem(url: url, name: url.lastPathComponent, path: url.path,
                     parentPath: url.deletingLastPathComponent().path, fileExtension: url.pathExtension,
                     isDirectory: false, isHidden: false, size: 1, modificationDate: .distantPast)
        }
        var io: FileOperationIO {
            var io = FileOperationIO.live
            io.trash = { [self] url in
                guard url.path.hasPrefix(root.path + "/") else {
                    throw RegressionFailure(description: "Refusing to trash outside fixture")
                }
                let target = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try fm.moveItem(at: url, to: target)
                return target
            }
            return io
        }
        @MainActor func manager(_ io: FileOperationIO? = nil) -> FileOperationsManager {
            FileOperationsManager(fileIO: io ?? self.io, reloadVisiblePanes: {})
        }
    }

    /// Deterministic barriers never block the main actor. Their bounded worker wait
    /// also makes a synchronous-execution regression fail instead of hanging CI.
    private final class Control: @unchecked Sendable {
        private let lock = NSLock()
        let release = DispatchSemaphore(value: 0)
        private var entered = false
        private var mainThread = false
        private var shouldFail = false
        var fail: Bool {
            get { lock.lock(); defer { lock.unlock() }; return shouldFail }
            set { lock.lock(); shouldFail = newValue; lock.unlock() }
        }
        var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
        func hold() throws {
            lock.lock(); entered = true; mainThread = Thread.isMainThread; lock.unlock()
            guard release.wait(timeout: .now() + 3) == .success else {
                throw RegressionFailure(description: "Worker barrier timed out (possibly MainActor IO)")
            }
        }
    }

    private static func idle(_ manager: FileOperationsManager) async throws {
        let deadline = Date().addingTimeInterval(10)
        while manager.isBusy && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try expect(!manager.isBusy)
    }
    private static func entered(_ control: Control) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !control.didEnter && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try expect(control.didEnter)
    }

    static func runAll() async throws -> Int {
        try await testChecksumWatchdogAndLiveOwnership()
        try await testChecksumsMatchKnownRegularFiles()
        try await testChecksumsRejectSpecialEntriesAndOpenRace()
        try await testChecksumsCancelRunningAndQueuedWork()
        try await testChecksumsRejectChangedFiles()
        try await testPermissionEditsPreserveFreshUnrequestedBits()
        try await testPermissionEditsRefuseUnsafeEntriesAndMasks()
        try await testPermissionWorkStaysResponsiveAndGated()
        try await testHistoryRejectsReplacementEntries()
        try await testHistoryAcceptsEditsToSameEntry()
        try await testHistoryRejectsReplacedSymlinkAndRedoEntry()
        try await testHistoryRetainsPartialSuffixAndUnknownIdentity()
        try await testHistoryRecapturesIdentityAfterCrossVolumeStyleMove()
        try await testTransferPreflightStaysResponsiveAndOwned()
        try await testTransferRejectsSymlinkedDescendant()
        try await testTransferThroughParentAliasUsesSameEntryRules()
        try await testCopyingSymbolicLinkDoesNotFollowItsLeaf()
        try testReplacementRejectsAliasedAncestor()
        try testDanglingNamesAndExclusiveCreation()
        try await testDanglingTransferAndTrashRestore()
        try await testBusyGateDuringTransfer()
        try await testDuplicateDoesNotBlockMainActor()
        try await testHistoryDoesNotBlockMainActor()
        try await testPartialHistoryIdentity()
        try testTrashValidationAbortsBatch()
        try await testStandaloneCompressedFiles()
        try await testInvalidCompressedInputAndOccupiedOutput()
        try await testZipOperandsPreserveSources()
        try await testArchivePublicationRacePreservesRival()
        try await testArchivePublicationFailurePreservesOwnedStaging()
        #if BURROW_TESTING
        try await testMutationDoesNotWaitForIndexCrawl()
        #endif
        try testGitDoesNotExecuteLocalHelper()
        try await testGitDoesNotExecuteCleanFilter()
        try testBoundedGitInspectionAndDriverNames()
        try testGitRenameRecordPairs()
        #if BURROW_TESTING
        return 35
        #else
        return 34
        #endif
    }

    private typealias ChecksumResult = Result<FileChecksumDigest, FileChecksumFailure>

    /// Exactly-once timeout escapes an uninterruptible worker without awaiting
    /// it. A failure reaches TestRunner's exit(1), so a blocked FIFO cannot hold
    /// the native regression process forever. No structured child-task join.
    @MainActor private final class ChecksumWaiter {
        private var continuation: CheckedContinuation<ChecksumResult, Never>?
        private var request: FileChecksumRequest?
        private var deadline: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<ChecksumResult, Never>) { self.continuation = continuation }
        func attach(_ request: FileChecksumRequest, timeout: Duration) {
            guard continuation != nil else { request.cancel(); return }
            self.request = request
            deadline = Task { @MainActor in
                do { try await Task.sleep(for: timeout) } catch { return }
                self.finish(.failure(.io("Checksum watchdog timed out")), cancel: true)
            }
        }
        func finish(_ result: ChecksumResult, cancel: Bool = false) {
            guard let waiting = continuation else { return }
            continuation = nil
            deadline?.cancel()
            deadline = nil
            if cancel { request?.cancel() }
            request = nil
            waiting.resume(returning: result)
        }
    }

    private static func boundedChecksum(timeout: Duration = .seconds(5),
        start: (@escaping @MainActor @Sendable (ChecksumResult) -> Void) -> FileChecksumRequest) async -> ChecksumResult {
        await withCheckedContinuation { continuation in
            let waiter = ChecksumWaiter(continuation)
            let request = start { waiter.finish($0) }
            waiter.attach(request, timeout: timeout)
        }
    }

    private static func checksum(_ url: URL, service: FileChecksumService = .shared,
                                 hooks: FileChecksumHooks = FileChecksumHooks()) async -> ChecksumResult {
        await boundedChecksum { completion in service.start(for: url, hooks: hooks, completion: completion) }
    }

    private static func testChecksumWatchdogAndLiveOwnership() async throws {
        let abandoned = FileChecksumRequest()
        var lateCompletion: (@MainActor @Sendable (ChecksumResult) -> Void)?
        let timeout = await boundedChecksum(timeout: .milliseconds(30)) { completion in
            // Inject a worker that never completes: only the independent
            // deadline can release this await. Deliver late only afterward.
            lateCompletion = completion
            return abandoned
        }
        guard case .failure(.io(let reason)) = timeout else { throw RegressionFailure(description: "Watchdog did not fire") }
        try expect(reason == "Checksum watchdog timed out" && abandoned.isCancelled)
        try expect(lateCompletion != nil)
        lateCompletion?(.success(FileChecksumDigest(sha256: "late", md5: "late")))

        let paneA = UUID(), paneB = UUID(), request = UUID()
        let context = FileChecksumPublicationContext(requestID: request, paneID: paneA, revision: 7, path: "/same-path")
        func accepted(owner: UUID, id: UUID? = nil, revision: UInt64 = 7, path: String? = "/same-path") -> Bool {
            context.canPublish(currentRequestID: id ?? request, activePaneID: owner, sourceRevision: revision, selectedPath: path)
        }
        try expect(accepted(owner: paneA))
        // Live owner changes before deferred onChange cancellation. Old pane's
        // path, revision, and request remain identical, but publication fails.
        try expect(!accepted(owner: paneB))
        let retryID = UUID()
        // ABA: after leaving A and lifecycle cancellation, returning to A at
        // the same path/revision cannot revive the invalidated request nonce.
        try expect(!accepted(owner: paneA, id: retryID))
        try expect(!accepted(owner: paneA, revision: 8))
        try expect(!accepted(owner: paneA, path: nil))
        try expect(!accepted(owner: paneA, path: "/other"))
        let retry = FileChecksumPublicationContext(requestID: retryID, paneID: paneB, revision: 7, path: "/same-path")
        try expect(retry.canPublish(currentRequestID: retryID, activePaneID: paneB, sourceRevision: 7, selectedPath: "/same-path"))
    }

    private static func checksumFinished(_ request: FileChecksumRequest) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !request.isFinished && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try expect(request.isFinished)
    }

    private final class ChecksumProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks = 0
        func record() { lock.lock(); chunks += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return chunks }
    }

    private static func testChecksumsMatchKnownRegularFiles() async throws {
        let f = try Fixture()
        let url = f.sourceDirectory.appendingPathComponent("hash.txt")
        for (text, sha, md5) in [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "d41d8cd98f00b204e9800998ecf8427e"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "900150983cd24fb0d6963f7d28e17f72")
        ] {
            try f.write(text, to: url)
            let result = await checksum(url)
            guard case .success(let digest) = result else { throw RegressionFailure(description: "Regular file checksum failed") }
            try expect(digest.sha256 == sha && digest.md5 == md5)
        }
    }

    private static func testChecksumsRejectSpecialEntriesAndOpenRace() async throws {
        let f = try Fixture()
        let fifo = f.sourceDirectory.appendingPathComponent("fifo")
        try expect(fifo.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
        let link = f.sourceDirectory.appendingPathComponent("zero-link")
        try f.fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/dev/zero")
        for url in [fifo, link, f.sourceDirectory] {
            let result = await checksum(url)
            guard case .failure(.notRegular) = result else { throw RegressionFailure(description: "Special entry accepted") }
        }
        // Race a validated regular path into a FIFO before open. NONBLOCK must
        // prevent an indefinite FIFO open; descriptor validation rejects it.
        let raced = f.sourceDirectory.appendingPathComponent("raced")
        try f.write("original", to: raced)
        let saved = f.sourceDirectory.appendingPathComponent("saved")
        let hooks = FileChecksumHooks(beforeOpen: {
            try FileManager.default.moveItem(at: raced, to: saved)
            guard raced.path.withCString({ Darwin.mkfifo($0, 0o600) }) == 0 else {
                throw RegressionFailure(description: "Cannot create race fixture")
            }
        })
        let raceResult = await checksum(raced, hooks: hooks)
        guard case .failure(.notRegular) = raceResult else { throw RegressionFailure(description: "FIFO open race accepted") }
    }

    private static func testChecksumsCancelRunningAndQueuedWork() async throws {
        let f = try Fixture()
        let url = f.sourceDirectory.appendingPathComponent("large")
        try Data(repeating: 0x61, count: 3 << 20).write(to: url)
        let service = FileChecksumService(maxConcurrentOperations: 2)
        let control = Control()
        defer { control.release.signal() }
        let probe = ChecksumProbe()
        var cancelledCallback = false
        let running = service.start(for: url, hooks: FileChecksumHooks(afterChunk: { chunk in
            probe.record()
            if chunk == 1 { try control.hold() }
        })) { _ in cancelledCallback = true }
        try await entered(control)
        try expect(!control.ranOnMain)
        running.cancel()
        control.release.signal()
        try await checksumFinished(running)
        try expect(probe.count == 1)
        try await Task.sleep(for: .milliseconds(20))
        try expect(!cancelledCallback)

        let controls = [Control(), Control(), Control()]
        defer { controls.forEach { $0.release.signal() } }
        let first = service.start(for: url, hooks: FileChecksumHooks(beforeOpen: { try controls[0].hold() })) { _ in }
        let second = service.start(for: url, hooks: FileChecksumHooks(beforeOpen: { try controls[1].hold() })) { _ in }
        try await entered(controls[0]); try await entered(controls[1])
        var queuedCallback = false
        let queued = service.start(for: url, hooks: FileChecksumHooks(beforeOpen: { try controls[2].hold() })) { _ in queuedCallback = true }
        try await Task.sleep(for: .milliseconds(50))
        try expect(!controls[2].didEnter && !controls[0].ranOnMain && !controls[1].ranOnMain)
        queued.cancel()
        controls[0].release.signal(); controls[1].release.signal()
        try await checksumFinished(first); try await checksumFinished(second)
        try await checksumFinished(queued)
        try await Task.sleep(for: .milliseconds(20))
        try expect(!controls[2].didEnter && !queuedCallback)
        guard case .success = await checksum(url, service: service) else {
            throw RegressionFailure(description: "Canceled queue did not recover")
        }
    }

    private static func testChecksumsRejectChangedFiles() async throws {
        for replacePath in [false, true] {
            let f = try Fixture()
            let url = f.sourceDirectory.appendingPathComponent("changing")
            try Data(repeating: 0x61, count: 2 << 20).write(to: url)
            let saved = f.sourceDirectory.appendingPathComponent("saved")
            let hooks = FileChecksumHooks(afterChunk: { chunk in
                guard chunk == 1 else { return }
                if replacePath {
                    try FileManager.default.moveItem(at: url, to: saved)
                    try Data("replacement".utf8).write(to: url)
                } else {
                    let writer = try FileHandle(forWritingTo: url)
                    defer { try? writer.close() }
                    try writer.seekToEnd()
                    try writer.write(contentsOf: Data("appended".utf8))
                }
            })
            let result = await checksum(url, hooks: hooks)
            guard case .failure(.changed) = result else { throw RegressionFailure(description: "Changed file checksum published") }
        }
    }

    private static func editPermissions(_ manager: FileOperationsManager, _ item: FileItem,
                                        identity: FileEntryIdentity, change: PosixPermissionChange) async -> (PosixPermissionSnapshot?, String?) {
        await withCheckedContinuation { continuation in
            if !manager.updatePosixPermissions(change, for: item, expectedIdentity: identity, completion: { snapshot, error in
                continuation.resume(returning: (snapshot, error))
            }) { continuation.resume(returning: (nil, "Busy")) }
        }
    }

    private static func testPermissionEditsPreserveFreshUnrequestedBits() async throws {
        for initial in [UInt16(0o1777), 0o2750, 0o4755] {
            let f = try Fixture()
            let url = f.sourceDirectory.appendingPathComponent("permissions")
            if initial == 0o1777 { try f.fm.createDirectory(at: url, withIntermediateDirectories: false) }
            else { try f.write("inert fixture, never executed", to: url) }
            try f.io.writePermissions(url, initial)
            let snapshot = try PosixPermissionSnapshot.read(url)
            // External edits after the inspector loaded must survive a one-bit click.
            let fresh = (initial ^ 0o1000) ^ 0o020
            try f.io.writePermissions(url, fresh)
            let manager = f.manager()
            let (result, error) = await editPermissions(manager, f.item(url), identity: snapshot.identity,
                                                       change: .bit(0o004, enabled: true))
            try expect(error == nil && result?.mode == (fresh | 0o004))
            let actual = try f.io.readPermissions(url)
            try expect(actual == (fresh | 0o004))
            let (preset, presetError) = await editPermissions(manager, f.item(url), identity: snapshot.identity,
                                                             change: .ordinaryMode(0o644))
            try expect(presetError == nil && preset?.mode == ((fresh & 0o7000) | 0o644))
            try expect(manager.undoStack.isEmpty) // Permission editor never offered undo.
        }
        try expect(PosixPermissionChange.format(0o1777) == "rwxrwxrwt (1777)")
        try expect(PosixPermissionChange.format(0o7644) == "rwSr-Sr-T (7644)")
        let cleared = try PosixPermissionChange.bit(0o100, enabled: false).applying(to: 0o4755)
        try expect(cleared == 0o4655)
    }

    private static func testPermissionEditsRefuseUnsafeEntriesAndMasks() async throws {
        let f = try Fixture()
        let url = f.sourceDirectory.appendingPathComponent("original")
        try f.write("original", to: url)
        try f.io.writePermissions(url, 0o644)
        let original = try PosixPermissionSnapshot.read(url)
        let manager = f.manager()
        for invalid in [PosixPermissionChange.bit(0, enabled: true), .bit(0o3, enabled: true),
                        .bit(0o4000, enabled: true), .ordinaryMode(0o1777)] {
            let (updated, error) = await editPermissions(manager, f.item(url), identity: original.identity, change: invalid)
            try expect(updated == nil && error != nil)
            let actual = try f.io.readPermissions(url)
            try expect(actual == 0o644)
        }
        try f.fm.moveItem(at: url, to: f.sourceDirectory.appendingPathComponent("saved-original"))
        try f.write("replacement", to: url)
        try f.io.writePermissions(url, 0o600)
        let (replacement, replacementError) = await editPermissions(manager, f.item(url), identity: original.identity,
                                                                    change: .ordinaryMode(0o777))
        try expect(replacement == nil && replacementError != nil)
        let replacementMode = try f.io.readPermissions(url)
        try expect(replacementMode == 0o600)
        let link = f.sourceDirectory.appendingPathComponent("link")
        try f.fm.createSymbolicLink(at: link, withDestinationURL: url)
        let linkIdentity = try FileEntryIdentity.read(link)
        let (linked, linkError) = await editPermissions(manager, f.item(link), identity: linkIdentity, change: .ordinaryMode(0o777))
        try expect(linked == nil && linkError != nil)
        let targetMode = try f.io.readPermissions(url)
        try expect(targetMode == 0o600)
        var unknownIO = f.io
        unknownIO.identity = { _ in throw RegressionFailure(description: "Unknown identity") }
        let unknownManager = f.manager(unknownIO)
        let (unknown, unknownError) = await editPermissions(unknownManager, f.item(url), identity: original.identity,
                                                           change: .ordinaryMode(0o777))
        try expect(unknown == nil && unknownError != nil)
    }

    private static func testPermissionWorkStaysResponsiveAndGated() async throws {
        for blockRead in [true, false] {
            let f = try Fixture()
            let url = f.sourceDirectory.appendingPathComponent("permissions")
            try f.write("fixture", to: url)
            try f.io.writePermissions(url, 0o644)
            let snapshot = try PosixPermissionSnapshot.read(url)
            let control = Control()
            defer { control.release.signal() }
            var io = f.io
            if blockRead {
                io.readPermissions = { url in
                    if !control.didEnter { try control.hold() }
                    return try FileOperationIO.live.readPermissions(url)
                }
            } else {
                io.writePermissions = { url, mode in
                    try control.hold()
                    try FileOperationIO.live.writePermissions(url, mode)
                }
            }
            let manager = f.manager(io)
            var completed = false
            var error: String?
            try expect(manager.updatePosixPermissions(.bit(0o100, enabled: true), for: f.item(url),
                expectedIdentity: snapshot.identity, completion: { result, failure in
                    completed = result != nil
                    error = failure
                }))
            try expect(manager.isBusy && !completed)
            try await entered(control)
            try expect(!control.ranOnMain && !completed)
            try expect(manager.createFile(named: "must-not-exist", in: f.destination) == nil)
            try expect(!manager.updatePosixPermissions(.ordinaryMode(0o777), for: f.item(url),
                expectedIdentity: snapshot.identity, completion: { _, _ in }))
            control.release.signal()
            try await idle(manager)
            try expect(completed && error == nil)
            let actual = try f.io.readPermissions(url)
            try expect(actual == 0o744)
        }
    }

    private static func testHistoryRejectsReplacementEntries() async throws {
        for mode in 0..<10 {
            let f = try Fixture()
            let source = f.sourceDirectory.appendingPathComponent("item.txt")
            try f.write("original", to: source)
            let manager = f.manager()
            let target: URL
            switch mode {
            case 0:
                target = manager.createFile(named: "created.txt", content: "created", in: f.destination)!
            case 1:
                target = manager.createFolder(named: "created-folder", in: f.destination)!
            case 2:
                target = manager.renameItem(f.item(source), to: "renamed.txt")!
            case 3, 4, 8:
                target = f.destination.appendingPathComponent("item.txt")
                if mode == 8 { try f.write("displaced original", to: target) }
                manager.performTransfer(sourceURLs: [source], into: f.destination,
                                        isMove: mode == 4, explicitPolicy: mode == 8 ? .overwrite : .keepBoth)
            case 5:
                target = f.sourceDirectory.appendingPathComponent("item copy.txt")
                manager.duplicateItems([f.item(source)])
            case 6:
                target = f.sourceDirectory.appendingPathComponent("item.zip")
                manager.compressItems([f.item(source)], in: f.sourceDirectory)
            case 9:
                manager.moveToTrash([f.item(source)])
                target = try f.fm.contentsOfDirectory(at: f.trash, includingPropertiesForKeys: nil).first!
            default:
                let archive = f.sourceDirectory.appendingPathComponent("item.zip")
                let compressor = f.manager()
                compressor.compressItems([f.item(source)], in: f.sourceDirectory)
                try await idle(compressor)
                target = f.sourceDirectory.appendingPathComponent("item")
                manager.extractArchive(f.item(archive))
            }
            try await idle(manager)
            try expect(manager.undoStack.count == 1 && f.io.exists(target))
            let retained = f.root.appendingPathComponent("retained-original")
            try f.fm.moveItem(at: target, to: retained)
            try f.write("unrelated sentinel", to: target)
            manager.undoLastOperation()
            try await idle(manager)
            try expect((try? f.text(target)) == "unrelated sentinel" && f.io.exists(retained))
            try expect(manager.undoStack.count == 1 && manager.redoStack.isEmpty)
            try expect(manager.lastStatusMessage?.contains("tożsamości") == true)
        }
    }

    private static func testHistoryAcceptsEditsToSameEntry() async throws {
        let f = try Fixture()
        let manager = f.manager()
        let file = manager.createFile(named: "editable.txt", content: "before", in: f.destination)!
        let originalIdentity = try FileEntryIdentity.read(file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("legitimate edit".utf8))
        try handle.close()
        let editedIdentity = try FileEntryIdentity.read(file)
        try expect(editedIdentity == originalIdentity)
        manager.undoLastOperation()
        try await idle(manager)
        try expect(!f.io.exists(file))
        manager.redoLastOperation()
        try await idle(manager)
        try expect((try? f.text(file)) == "legitimate edit")
        let directory = manager.createFolder(named: "edited-directory", in: f.destination)!
        try f.write("new child", to: directory.appendingPathComponent("child.txt"))
        manager.undoLastOperation()
        try await idle(manager)
        try expect(!f.io.exists(directory))
        manager.redoLastOperation()
        try await idle(manager)
        try expect((try? f.text(directory.appendingPathComponent("child.txt"))) == "new child")
    }

    private static func testHistoryRejectsReplacedSymlinkAndRedoEntry() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("link")
        let destination = f.destination.appendingPathComponent("link")
        let leaf = f.root.appendingPathComponent("leaf.txt")
        try f.write("leaf must survive", to: leaf)
        try f.fm.createSymbolicLink(at: source, withDestinationURL: leaf)
        let manager = f.manager()
        manager.performTransfer(sourceURLs: [source], into: f.destination, isMove: false, explicitPolicy: .keepBoth)
        try await idle(manager)
        try f.fm.moveItem(at: destination, to: f.root.appendingPathComponent("old-link"))
        try f.fm.createSymbolicLink(at: destination, withDestinationURL: leaf)
        manager.undoLastOperation()
        try await idle(manager)
        try expect(manager.undoStack.count == 1 && (try? f.fm.destinationOfSymbolicLink(atPath: destination.path)) != nil)
        try expect((try? f.text(leaf)) == "leaf must survive")

        let redoManager = f.manager()
        let file = redoManager.createFile(named: "redo.txt", content: "ours", in: f.destination)!
        redoManager.undoLastOperation()
        try await idle(redoManager)
        let trashed = try f.fm.contentsOfDirectory(at: f.trash, includingPropertiesForKeys: nil).first!
        let retained = f.root.appendingPathComponent("retained-trash-entry")
        try f.fm.moveItem(at: trashed, to: retained)
        try f.write("unrelated trash sentinel", to: trashed)
        redoManager.redoLastOperation()
        try await idle(redoManager)
        try expect(!f.io.exists(file) && (try? f.text(trashed)) == "unrelated trash sentinel")
        try expect(redoManager.redoStack.count == 1 && redoManager.undoStack.isEmpty)

        let overwrite = try Fixture()
        let incoming = overwrite.sourceDirectory.appendingPathComponent("item.txt")
        let replaced = overwrite.destination.appendingPathComponent("item.txt")
        try overwrite.write("incoming", to: incoming)
        try overwrite.write("original", to: replaced)
        let overwriteManager = overwrite.manager()
        overwriteManager.performTransfer(sourceURLs: [incoming], into: overwrite.destination,
                                         isMove: false, explicitPolicy: .overwrite)
        try await idle(overwriteManager)
        overwriteManager.undoLastOperation()
        try await idle(overwriteManager)
        try expect((try? overwrite.text(replaced)) == "original")
        try overwrite.fm.moveItem(at: replaced, to: overwrite.root.appendingPathComponent("saved-original"))
        try overwrite.write("replacement sentinel", to: replaced)
        overwriteManager.redoLastOperation()
        try await idle(overwriteManager)
        try expect((try? overwrite.text(replaced)) == "replacement sentinel")
        try expect(overwriteManager.redoStack.count == 1 && overwriteManager.undoStack.isEmpty)

        // Failed installation + failed rollback leaves an explicit recovery action.
        // It must still refer to the original displaced entry, not a later occupant.
        let recovery = try Fixture()
        let recoverySource = recovery.sourceDirectory.appendingPathComponent("item.txt")
        let recoveryTarget = recovery.destination.appendingPathComponent("item.txt")
        try recovery.write("incoming", to: recoverySource)
        try recovery.write("original", to: recoveryTarget)
        let failure = Control()
        failure.fail = true
        var recoveryIO = recovery.io
        recoveryIO.move = { from, to in
            if to == recoveryTarget && failure.fail { throw RegressionFailure(description: "Installation/rollback failed") }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let recoveryManager = recovery.manager(recoveryIO)
        recoveryManager.performTransfer(sourceURLs: [recoverySource], into: recovery.destination,
                                        isMove: false, explicitPolicy: .overwrite)
        try await idle(recoveryManager)
        try expect(recoveryManager.undoStack.count == 1 && !recovery.io.exists(recoveryTarget))
        let displaced = try recovery.fm.contentsOfDirectory(at: recovery.trash, includingPropertiesForKeys: nil).first!
        try recovery.fm.moveItem(at: displaced, to: recovery.root.appendingPathComponent("saved-displaced"))
        try recovery.write("recovery sentinel", to: displaced)
        failure.fail = false
        recoveryManager.undoLastOperation()
        try await idle(recoveryManager)
        try expect(!recovery.io.exists(recoveryTarget) && (try? recovery.text(displaced)) == "recovery sentinel")
        try expect(recoveryManager.undoStack.count == 1 && recoveryManager.redoStack.isEmpty)
    }

    private static func testHistoryRetainsPartialSuffixAndUnknownIdentity() async throws {
        let f = try Fixture()
        let a = f.sourceDirectory.appendingPathComponent("a.txt")
        let b = f.sourceDirectory.appendingPathComponent("b.txt")
        try f.write("a", to: a); try f.write("b", to: b)
        let manager = f.manager()
        manager.performTransfer(sourceURLs: [a, b], into: f.destination, isMove: false, explicitPolicy: .keepBoth)
        try await idle(manager)
        let targetA = f.destination.appendingPathComponent("a.txt")
        let targetB = f.destination.appendingPathComponent("b.txt")
        let retained = f.root.appendingPathComponent("retained-a")
        try f.fm.moveItem(at: targetA, to: retained)
        try f.write("sentinel", to: targetA)
        manager.undoLastOperation()
        try await idle(manager)
        try expect(!f.io.exists(targetB) && (try? f.text(targetA)) == "sentinel")
        try expect(manager.undoStack.count == 1 && manager.redoStack.count == 1)
        try expect(manager.undoStack.last?.transactionID == manager.redoStack.last?.transactionID)
        try f.fm.moveItem(at: targetA, to: f.root.appendingPathComponent("retained-sentinel"))
        try f.fm.moveItem(at: retained, to: targetA)
        manager.undoLastOperation()
        try await idle(manager)
        try expect(manager.undoStack.isEmpty && manager.redoStack.count == 1)
        manager.redoLastOperation()
        try await idle(manager)
        try expect((try? f.text(targetA)) == "a" && (try? f.text(targetB)) == "b")

        let unavailable = Control()
        unavailable.fail = true
        var io = f.io
        let readIdentity = io.identity
        io.identity = { url in
            if unavailable.fail { throw RegressionFailure(description: "Identity unavailable") }
            return try readIdentity(url)
        }
        let uncertain = f.manager(io)
        let created = uncertain.createFile(named: "unknown.txt", content: "must survive", in: f.destination)!
        unavailable.fail = false // Must not bind a previously unknown identity lazily.
        uncertain.undoLastOperation()
        try await idle(uncertain)
        try expect((try? f.text(created)) == "must survive" && uncertain.undoStack.count == 1)
        try expect(uncertain.redoStack.isEmpty)
        let retryable = f.manager(io)
        let retryFile = retryable.createFile(named: "retry.txt", content: "retry", in: f.destination)!
        unavailable.fail = true
        retryable.undoLastOperation()
        try await idle(retryable)
        try expect(f.io.exists(retryFile) && retryable.undoStack.count == 1)
        unavailable.fail = false
        retryable.undoLastOperation()
        try await idle(retryable)
        try expect(!f.io.exists(retryFile) && retryable.undoStack.isEmpty && retryable.redoStack.count == 1)
    }

    private static func testHistoryRecapturesIdentityAfterCrossVolumeStyleMove() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("item.txt")
        let target = f.destination.appendingPathComponent("item.txt")
        try f.write("cross-volume-style", to: source)
        var io = f.io
        io.move = { from, to in
            // Emulate FileManager's copy/remove move across volumes: new inode.
            try FileManager.default.copyItem(at: from, to: to)
            try FileManager.default.removeItem(at: from)
        }
        let manager = f.manager(io)
        manager.performTransfer(sourceURLs: [source], into: f.destination, isMove: true, explicitPolicy: .keepBoth)
        try await idle(manager)
        try expect(!f.io.exists(source) && f.io.exists(target))
        manager.undoLastOperation()
        try await idle(manager)
        try expect(f.io.exists(source) && !f.io.exists(target))
        manager.redoLastOperation()
        try await idle(manager)
        try expect(!f.io.exists(source) && (try? f.text(target)) == "cross-volume-style")
        try expect(manager.redoStack.isEmpty && manager.undoStack.count == 1)
    }

    private static func testTransferPreflightStaysResponsiveAndOwned() async throws {
        for mode in 0..<4 {
            let f = try Fixture()
            let source = f.sourceDirectory.appendingPathComponent("item.txt")
            let target = f.destination.appendingPathComponent("item.txt")
            try f.write("incoming", to: source)
            try f.write("existing", to: target)
            let control = Control()
            control.fail = true
            let continuation = Control()
            defer { continuation.release.signal() }
            defer { control.release.signal() }
            var io = f.io
            let resolve = io.resolveEntryPath
            io.resolveEntryPath = { url in
                if control.fail {
                    control.fail = false
                    try? control.hold()
                } else if continuation.fail {
                    continuation.fail = false
                    try? continuation.hold()
                }
                return resolve(url)
            }
            let manager = f.manager(io)
            var request: UUID?
            if mode == 2 {
                manager.handleDropURLs([source], into: f.destination, copyInsteadOfMove: true)
            } else {
                request = manager.performTransfer(sourceURLs: [source], into: f.destination,
                                                  isMove: false, explicitPolicy: .ask)
                try expect(request != nil)
            }
            // Admission/progress are synchronous, but filesystem resolution is not.
            try expect(manager.isBusy && manager.activeTransfer?.isCancellable == true)
            try await entered(control)
            try expect(!control.ranOnMain)
            try expect(manager.createFile(named: "must-not-start", in: f.destination) == nil)
            if mode == 0 || mode == 3 {
                manager.cancelPendingTransferRequest(UUID()) // Another sheet cannot cancel this request.
            } else if let request {
                manager.cancelPendingTransferRequest(request) // Closing the initiating sheet.
            } else {
                manager.cancelActiveTransfer() // Drop preparation can also be cancelled.
            }
            control.release.signal()
            try await idle(manager)
            try expect(manager.undoStack.isEmpty)
            try expect((try? f.text(source)) == "incoming" && (try? f.text(target)) == "existing")
            if (mode == 0 || mode == 3), let request {
                try expect(manager.pendingConflict?.id == request)
                let rejected = manager.performTransfer(sourceURLs: [source], into: f.destination, isMove: false)
                try expect(rejected == nil && manager.pendingConflict?.id == request)
                // Policy selection dismisses only the conflict sheet, then the
                // initiating comparison closes while continuation is resolving.
                let conflict = manager.pendingConflict!
                manager.pendingConflict = nil
                continuation.fail = true
                let continued = manager.performTransfer(
                    sourceURLs: conflict.sourceURLs, into: conflict.destinationDirectory,
                    isMove: conflict.isMove, explicitPolicy: .overwrite,
                    copyAcrossVolumes: conflict.copyAcrossVolumes, requestID: conflict.id)
                try expect(continued == request)
                try await entered(continuation)
                if mode == 0 { manager.cancelPendingTransferRequest(request) }
                continuation.release.signal()
                try await idle(manager)
                try expect(manager.pendingConflict == nil)
                try expect(manager.undoStack.count == (mode == 0 ? 0 : 1))
                try expect((try? f.text(source)) == "incoming")
                try expect((try? f.text(target)) == (mode == 0 ? "existing" : "incoming"))
            } else {
                try expect(manager.pendingConflict == nil)
            }
        }
    }

    private static func testTransferRejectsSymlinkedDescendant() async throws {
        let f = try Fixture()
        let folder = f.sourceDirectory.appendingPathComponent("tree", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try f.fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let alias = f.root.appendingPathComponent("destination-alias")
        try f.fm.createSymbolicLink(at: alias, withDestinationURL: nested)
        let marker = folder.appendingPathComponent("keep.txt")
        try f.write("original", to: marker)
        var io = f.io
        io.copy = { _, _ in throw RegressionFailure(description: "Nested copy must not reach IO") }
        io.move = { _, _ in throw RegressionFailure(description: "Nested move must not reach IO") }
        let manager = f.manager(io)
        for isMove in [false, true] {
            manager.performTransfer(sourceURLs: [folder], into: alias, isMove: isMove, explicitPolicy: .overwrite)
            try await idle(manager)
            try expect(!manager.isBusy && manager.pendingConflict == nil && manager.undoStack.isEmpty)
            try expect(manager.lastStatusMessage == "Nie można umieścić folderu wewnątrz samego siebie")
        }
        try expect((try? f.text(marker)) == "original")
        try expect((try? f.fm.contentsOfDirectory(atPath: nested.path)) == [])
        try expect(FileTransferPaths.destinationIsInsideSource(nested, source: URL(fileURLWithPath: "/")))
        // A common string prefix is not containment.
        let sibling = f.sourceDirectory.appendingPathComponent("tree-other", isDirectory: true)
        try expect(!FileTransferPaths.destinationIsInsideSource(sibling, source: folder))
    }

    private static func testTransferThroughParentAliasUsesSameEntryRules() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("item.txt")
        try f.write("original", to: source)
        let alias = f.root.appendingPathComponent("parent-alias")
        try f.fm.createSymbolicLink(at: alias, withDestinationURL: f.sourceDirectory)
        let manager = f.manager()
        manager.performTransfer(sourceURLs: [source], into: alias, isMove: true, explicitPolicy: .ask)
        try await idle(manager)
        try expect(manager.pendingConflict == nil && manager.undoStack.isEmpty)
        try expect((try? f.text(source)) == "original")
        manager.performTransfer(sourceURLs: [source], into: alias, isMove: false, explicitPolicy: .overwrite)
        try await idle(manager)
        try expect((try? f.text(source)) == "original")
        let copy = f.sourceDirectory.appendingPathComponent("item 1.txt")
        try expect((try? f.text(copy)) == "original")
        try expect(manager.undoStack.count == 1)
        try expect((try? f.fm.contentsOfDirectory(atPath: f.trash.path)) == [])
    }

    private static func testCopyingSymbolicLinkDoesNotFollowItsLeaf() async throws {
        let f = try Fixture()
        let linked = f.sourceDirectory.appendingPathComponent("folder-link")
        try f.fm.createSymbolicLink(at: linked, withDestinationURL: f.destination)
        let manager = f.manager()
        manager.performTransfer(sourceURLs: [linked], into: f.destination, isMove: false, explicitPolicy: .keepBoth)
        try await idle(manager)
        let copy = f.destination.appendingPathComponent("folder-link")
        try expect((try? f.fm.destinationOfSymbolicLink(atPath: copy.path)) == f.destination.path)
        try expect(manager.undoStack.count == 1)
    }

    private static func testReplacementRejectsAliasedAncestor() throws {
        let f = try Fixture()
        let ancestor = f.sourceDirectory.appendingPathComponent("tree", isDirectory: true)
        try f.fm.createDirectory(at: ancestor, withIntermediateDirectories: false)
        let original = ancestor.appendingPathComponent("tree")
        try f.write("must survive", to: original)
        let alias = f.root.appendingPathComponent("ancestor-alias")
        try f.fm.createSymbolicLink(at: alias, withDestinationURL: ancestor)
        let sourceThroughAlias = alias.appendingPathComponent("tree")
        var rejected = false
        do {
            _ = try SafeFileReplacement.replace(source: sourceThroughAlias, target: ancestor, isMove: true, io: f.io)
        } catch is FileOperationFailure {
            rejected = true
        }
        try expect(rejected)
        try expect((try? f.text(original)) == "must survive")
        try expect((try? f.fm.contentsOfDirectory(atPath: f.trash.path)) == [])
    }

    private static func testDanglingNamesAndExclusiveCreation() throws {
        let f = try Fixture()
        let requested = f.destination.appendingPathComponent("item.txt")
        for name in ["item.txt", "item 1.txt", "item copy.txt", "item copy 2.txt"] {
            try f.fm.createSymbolicLink(atPath: f.destination.appendingPathComponent(name).path,
                                       withDestinationPath: "/missing-burrow-fixture-\(UUID())")
        }
        try expect(FileOperationsManager.uniqueURL(for: requested).lastPathComponent == "item 2.txt")
        try expect(FileOperationsManager.uniqueURL(for: requested, suffixWord: " copy").lastPathComponent == "item copy 3.txt")
        let manager = f.manager()
        let created = manager.createFile(named: "item.txt", content: "new", in: f.destination)
        try expect(created?.lastPathComponent == "item 2.txt")
        try expect((try? f.fm.destinationOfSymbolicLink(atPath: requested.path)) != nil)

        let raced = f.destination.appendingPathComponent("race.txt")
        var first = true
        let result = try FileOperationsManager.createUniqueItem(at: raced) { candidate in
            if first { first = false; try f.write("other process", to: candidate) }
            try Data("ours".utf8).write(to: candidate, options: .withoutOverwriting)
        }
        let racedText = try f.text(raced)
        let resultText = try f.text(result)
        try expect(racedText == "other process" && resultText == "ours" && result != raced)
    }

    private static func testDanglingTransferAndTrashRestore() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("item.txt")
        let target = f.destination.appendingPathComponent("item.txt")
        try f.write("incoming", to: source)
        try f.fm.createSymbolicLink(atPath: target.path, withDestinationPath: "/missing-bf-fixture-\(UUID())")
        let manager = f.manager()
        manager.performTransfer(sourceURLs: [source], into: f.destination, isMove: false, explicitPolicy: .ask)
        try await idle(manager)
        try expect(manager.pendingConflict?.conflictingNames == ["item.txt"])
        manager.pendingConflict = nil
        manager.performTransfer(sourceURLs: [source], into: f.destination, isMove: false, explicitPolicy: .keepBoth)
        try await idle(manager)
        let copy = f.destination.appendingPathComponent("item 1.txt")
        let copiedText = try f.text(copy)
        try expect(copiedText == "incoming")
        try expect((try? f.fm.destinationOfSymbolicLink(atPath: target.path)) != nil)
        manager.moveToTrash([f.item(copy)])
        try f.fm.createSymbolicLink(atPath: copy.path, withDestinationPath: "/missing-bf-fixture-\(UUID())")
        manager.undoLastOperation()
        try await idle(manager)
        let restoredText = try f.text(f.destination.appendingPathComponent("item 1 1.txt"))
        try expect(restoredText == "incoming")
        try expect((try? f.fm.destinationOfSymbolicLink(atPath: copy.path)) != nil)
    }

    private static func testBusyGateDuringTransfer() async throws {
        let f = try Fixture()
        let a = f.sourceDirectory.appendingPathComponent("a.txt")
        let b = f.sourceDirectory.appendingPathComponent("b.txt")
        try f.write("a", to: a); try f.write("b", to: b)
        let control = Control()
        defer { control.release.signal() }
        var io = f.io
        io.copy = { from, to in
            if from == b { try control.hold() }
            try FileManager.default.copyItem(at: from, to: to)
        }
        let manager = f.manager(io)
        manager.performTransfer(sourceURLs: [a, b], into: f.destination, isMove: false, explicitPolicy: .keepBoth)
        try await entered(control)
        let copiedA = f.destination.appendingPathComponent("a.txt")
        try expect(manager.isBusy && !control.ranOnMain)
        try expect(manager.renameItem(f.item(copiedA), to: "renamed.txt") == nil)
        manager.duplicateItems([f.item(copiedA)])
        try expect(!f.io.exists(f.destination.appendingPathComponent("a copy.txt")))
        try expect(manager.createFile(named: "new.txt", in: f.destination) == nil)
        try expect(manager.createFolder(named: "new-folder", in: f.destination) == nil)
        let copiedIdentity = try FileEntryIdentity.read(copiedA)
        try expect(!manager.updatePosixPermissions(.ordinaryMode(0o777), for: f.item(copiedA),
            expectedIdentity: copiedIdentity, completion: { _, _ in }))
        manager.moveToTrash([f.item(copiedA)])
        manager.toggleTag(.red, for: [f.item(copiedA)])
        manager.clearTags(for: [f.item(copiedA)])
        manager.undoLastOperation()
        try expect(manager.undoStack.isEmpty && manager.redoStack.isEmpty)
        try expect(f.io.exists(copiedA))
        control.release.signal()
        try await idle(manager)
        try expect(manager.undoStack.count == 1)
    }

    private static func testDuplicateDoesNotBlockMainActor() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("item.txt")
        try f.write("duplicate me", to: source)
        let control = Control()
        defer { control.release.signal() }
        var io = f.io
        io.copy = { from, to in
            try control.hold()
            try FileManager.default.copyItem(at: from, to: to)
        }
        let manager = f.manager(io)
        var completed: [URL] = []
        manager.duplicateItems([f.item(source)]) { completed = $0 }
        try expect(manager.isBusy)
        try await entered(control)
        try expect(!control.ranOnMain && manager.isBusy && completed.isEmpty)
        try expect(manager.renameItem(f.item(source), to: "renamed.txt") == nil)
        control.release.signal()
        try await idle(manager)
        let copy = f.sourceDirectory.appendingPathComponent("item copy.txt")
        let copied = try f.text(copy)
        try expect(copied == "duplicate me" && completed == [copy] && manager.undoStack.count == 1)
        try expect(f.io.exists(source))
    }

    private static func testHistoryDoesNotBlockMainActor() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("item.txt")
        try f.write("incoming", to: source)
        let control = Control()
        defer { control.release.signal() }
        var io = f.io
        io.move = { from, to in
            if to == source { try control.hold() }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let manager = f.manager(io)
        manager.performTransfer(sourceURLs: [source], into: f.destination, isMove: true, explicitPolicy: .keepBoth)
        try await idle(manager)
        manager.undoLastOperation()
        try expect(manager.isBusy && !manager.canUndo && !manager.canRedo)
        try await entered(control)
        // Reaching this assertion while worker IO is suspended proves MainActor liveness.
        try expect(manager.isBusy && !control.ranOnMain)
        control.release.signal()
        try await idle(manager)
        try expect(f.io.exists(source) && manager.redoStack.count == 1)
    }

    private static func testPartialHistoryIdentity() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("item.txt")
        let target = f.destination.appendingPathComponent("item.txt")
        try f.write("incoming", to: source); try f.write("original", to: target)
        let control = Control()
        var io = f.io
        io.move = { from, to in
            if control.fail && from.deletingLastPathComponent() == f.trash && to == target {
                throw RegressionFailure(description: "Injected original restoration failure")
            }
            try FileManager.default.moveItem(at: from, to: to)
        }
        let manager = f.manager(io)
        manager.performTransfer(sourceURLs: [source], into: f.destination, isMove: false, explicitPolicy: .overwrite)
        try await idle(manager)
        let identity = manager.undoStack.last?.transactionID
        control.fail = true
        manager.undoLastOperation(); try await idle(manager)
        try expect(manager.undoStack.count == 1 && manager.redoStack.count == 1 && !f.io.exists(target))
        try expect(manager.undoStack.last?.transactionID == identity && manager.redoStack.last?.transactionID == identity)
        control.fail = false
        manager.redoLastOperation(); try await idle(manager)
        let incoming = try f.text(target)
        try expect(incoming == "incoming" && manager.undoStack.count == 1 && manager.redoStack.isEmpty)
        manager.undoLastOperation(); try await idle(manager)
        let original = try f.text(target)
        try expect(original == "original" && manager.undoStack.isEmpty && manager.redoStack.count == 1)
        manager.redoLastOperation(); try await idle(manager)
        let restored = try f.text(target)
        try expect(restored == "incoming" && manager.undoStack.count == 1)

        // The mirrored case: partial redo -> undo -> redo must stay one operation.
        manager.undoLastOperation(); try await idle(manager)
        control.fail = true
        manager.redoLastOperation(); try await idle(manager)
        try expect(manager.undoStack.count == 1 && manager.redoStack.count == 1)
        control.fail = false
        manager.undoLastOperation(); try await idle(manager)
        let afterReversingRedo = try f.text(target)
        try expect(afterReversingRedo == "original" && manager.redoStack.count == 1 && manager.undoStack.isEmpty)
        manager.redoLastOperation(); try await idle(manager)
        let afterFullRedo = try f.text(target)
        try expect(afterFullRedo == "incoming" && manager.undoStack.count == 1)

        // Retrying the pending suffix also merges the redo prefix, without requiring
        // the user to reverse the partial undo first.
        control.fail = true
        manager.undoLastOperation(); try await idle(manager)
        control.fail = false
        manager.undoLastOperation(); try await idle(manager)
        try expect(manager.undoStack.isEmpty && manager.redoStack.count == 1)
        manager.redoLastOperation(); try await idle(manager)
        let final = try f.text(target)
        try expect(final == "incoming" && manager.undoStack.count == 1)
    }

    private static func testTrashValidationAbortsBatch() throws {
        let f = try Fixture()
        let urls = ["one.txt", "two.txt", "three.txt"].map { f.sourceDirectory.appendingPathComponent($0) }
        for url in urls { try f.write(url.lastPathComponent, to: url) }
        let manager = f.manager()
        manager.moveToTrash(urls.map(f.item)) { item in
            if item.url == urls[1] { throw RegressionFailure(description: "Retained copy changed") }
        }
        try expect(!f.io.exists(urls[0]) && f.io.exists(urls[1]) && f.io.exists(urls[2]))
        try expect(manager.undoStack.count == 1 && manager.lastStatusMessage?.contains("Retained copy changed") == true)
    }

    private static func testStandaloneCompressedFiles() async throws {
        let f = try Fixture()
        let payload = Data("Zażółć 🐈\nnot a tar archive\n".utf8)
        let fixtures: [(String, String, Bool)] = [
            ("payload.gz", "H4sIAAAAAAACA4tKPLrn8OajTUfaFT7Mn9DBlZdfopCoUJJYpJBYlJyRWZbKBQA/WygPIgAAAA==", false),
            ("payload.bz2", "QlpoOTFBWSZTWULBZOkAAANT7IAQQAAAECphlQAQwEAAiAQOAEAAIAAxQaNGgyA0KBpoNNAMgYIhxIQdOR1sN6sOhom+KoKilb4u5IpwoSCFgsnS", false),
            ("payload.xz", "/Td6WFoAAATm1rRGAgAhARYAAAB0L+WjAQAhWmHFvMOzxYLEhyDwn5CICm5vdCBhIHRhciBhcmNoaXZlCgAAAE0wOvIKTyMQAAE6IrYqT9AftvN9AQAAAAAEWVo=", false),
            ("empty.gz", "H4sIAAAAAAACAwMAAAAAAAAAAAA=", true),
            ("empty.bz2", "QlpoORdyRThQkAAAAAA=", true),
            ("empty.xz", "/Td6WFoAAATm1rRGAAAAABzfRCEftvN9AQAAAAAEWVo=", true)
        ]
        for (index, fixture) in fixtures.enumerated() {
            let (name, encoded, empty) = fixture
            // Filename metacharacters must remain data, including a leading '-'.
            let basename = "-\(index) space ' $() " + name
            let source = f.sourceDirectory.appendingPathComponent(basename)
            let compressed = Data(base64Encoded: encoded)!
            try compressed.write(to: source)
            let manager = f.manager()
            manager.extractArchive(f.item(source))
            try await idle(manager)
            let outputName = source.deletingPathExtension().lastPathComponent
            let published = f.sourceDirectory.appendingPathComponent(outputName, isDirectory: true)
            let output = try Data(contentsOf: published.appendingPathComponent(outputName))
            try expect(output == (empty ? Data() : payload))
            try expect((try? Data(contentsOf: source)) == compressed)
            try expect(manager.undoStack.count == 1)
            manager.undoLastOperation()
            try await idle(manager)
            try expect(!f.io.exists(published) && f.io.exists(source))
        }
    }

    private static func testInvalidCompressedInputAndOccupiedOutput() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("broken.gz")
        let bytes = Data([0x1f, 0x8b, 0x08, 0x00, 0x00])
        try bytes.write(to: source)
        let manager = f.manager()
        manager.extractArchive(f.item(source))
        try await idle(manager)
        try expect(manager.undoStack.isEmpty)
        try expect(!f.io.exists(f.sourceDirectory.appendingPathComponent("broken")))
        try expect((try? Data(contentsOf: source)) == bytes)
        let occupied = f.destination.appendingPathComponent("rival.txt")
        try f.write("untouched", to: occupied)
        var rejected = false
        do {
            _ = try FileOperationsManager.decompressSingleFile(from: source, to: occupied)
        } catch {
            rejected = true
        }
        try expect(rejected && (try? f.text(occupied)) == "untouched")
    }

    private static func testZipOperandsPreserveSources() async throws {
        let f = try Fixture()
        let inheritedZipOption = getenv("ZIPOPT").map { String(cString: $0) }
        setenv("ZIPOPT", "-m", 1)
        defer {
            if let inheritedZipOption { setenv("ZIPOPT", inheritedZipOption, 1) } else { unsetenv("ZIPOPT") }
        }
        let sanitized = FileOperationsManager.archiveProcessEnvironment(inherited: ["ZIPOPT": "-m", "TAR_OPTIONS": "--remove-files", "ENV": "/unsafe", "PATH": "/unsafe"])
        try expect(sanitized["ZIPOPT"] == nil && sanitized["TAR_OPTIONS"] == nil && sanitized["ENV"] == nil)
        try expect(sanitized["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        let names = ["-m", "-T", "space name.txt", "line\nbreak.txt", "Zażółć.txt"]
        let urls = names.map { f.sourceDirectory.appendingPathComponent($0) }
        for (name, url) in zip(names, urls) { try f.write("contents:" + name, to: url) }
        let manager = f.manager()
        manager.compressItems(urls.map(f.item), in: f.sourceDirectory)
        try await idle(manager)
        let archive = f.sourceDirectory.appendingPathComponent("Archiwum.zip")
        try expect(f.io.exists(archive) && manager.undoStack.count == 1)
        let unpacked = f.root.appendingPathComponent("unpacked", isDirectory: true)
        try f.fm.createDirectory(at: unpacked, withIntermediateDirectories: false)
        try expect(FileOperationsManager.runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, unpacked.path], in: f.root) == 0)
        for (name, url) in zip(names, urls) {
            let original = try f.text(url)
            let extracted = try f.text(unpacked.appendingPathComponent(name))
            try expect(original == "contents:" + name && extracted == original)
        }
    }

    private static func testGitDoesNotExecuteLocalHelper() throws {
        let f = try Fixture()
        let marker = f.root.appendingPathComponent("helper-executed")
        let helper = f.root.appendingPathComponent("fsmonitor")
        try f.write("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n", to: helper)
        try f.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        func git(_ args: [String]) throws {
            try expect(FileOperationsManager.runProcess("/usr/bin/git", arguments: args, in: f.sourceDirectory) == 0)
        }
        try git(["init", "-q"])
        let baseline = f.sourceDirectory.appendingPathComponent("baseline.txt")
        try f.write("tracked baseline", to: baseline)
        try git(["add", "--", "baseline.txt"])
        try git(["-c", "user.name=Burrow Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"])
        try git(["config", "core.fsmonitor", helper.path])
        // Deliberately unprotected positive control runs ONLY this inert fixture helper.
        try git(["status", "--porcelain=v1", "-z", "-uall"])
        try expect(f.io.exists(marker))
        try f.fm.removeItem(at: marker)
        let file = f.sourceDirectory.appendingPathComponent("file.txt")
        try f.write("untracked", to: file)
        guard let snapshot = FileOperationsManager.fetchGitStatusSnapshot(for: f.sourceDirectory.path) else {
            throw RegressionFailure(description: "Git snapshot unexpectedly failed")
        }
        try expect(!f.io.exists(marker) && snapshot.statuses[file.path] == .untracked)
        try expect(URL(fileURLWithPath: snapshot.repositoryRoot).resolvingSymlinksInPath() == f.sourceDirectory.resolvingSymlinksInPath())
        try f.fm.removeItem(at: file)
        let clean = FileOperationsManager.fetchGitStatusSnapshot(for: f.sourceDirectory.path)
        try expect(clean != nil && clean?.statuses.isEmpty == true && !f.io.exists(marker))
        try expect(FileOperationsManager.fetchGitStatusSnapshot(for: f.destination.path) == nil)
    }

    private static func testGitDoesNotExecuteCleanFilter() async throws {
        let f = try Fixture()
        func git(_ arguments: [String]) throws {
            try expect(FileOperationsManager.runProcess("/usr/bin/git", arguments: arguments, in: f.sourceDirectory) == 0)
        }
        try git(["init", "-q"])
        let tracked = f.sourceDirectory.appendingPathComponent("tracked.txt")
        try f.write("original\n", to: tracked)
        try f.write("*.txt filter=fixture\n", to: f.sourceDirectory.appendingPathComponent(".gitattributes"))
        try git(["add", "--", ".gitattributes", "tracked.txt"])
        try git(["-c", "user.name=Burrow Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture"])
        let marker = f.root.appendingPathComponent("clean-filter-executed")
        let helper = f.root.appendingPathComponent("clean-filter")
        try f.write("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n/bin/cat\n", to: helper)
        try f.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try git(["config", "filter.fixture.clean", helper.path])
        try await Task.sleep(for: .milliseconds(1100))
        try f.write("modified\n", to: tracked) // Same byte count forces a content comparison.
        try git(["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "status", "--porcelain=v1", "-z", "-uall"])
        try expect(f.io.exists(marker))
        try f.fm.removeItem(at: marker)
        let snapshot = FileOperationsManager.fetchGitStatusSnapshot(for: f.sourceDirectory.path)
        try expect(snapshot?.statuses[tracked.path] == .modified && !f.io.exists(marker))
        try expect(snapshot?.usesRawContentComparison == true)

        let processMarker = f.root.appendingPathComponent("process-filter-executed")
        let processHelper = f.root.appendingPathComponent("process-filter")
        // A benign server greeting followed by deliberate EOF proves that even a
        // failed optional process-filter initialization executes configured code.
        try f.write("#!/bin/sh\n/usr/bin/touch '\(processMarker.path)'\nprintf '0016git-filter-server\\n000eversion=2\\n0000'\n", to: processHelper)
        try f.fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: processHelper.path)
        try git(["config", "filter.processor.process", processHelper.path])
        try git(["config", "filter.processor.required", "false"])
        try f.write("*.txt filter=processor\n", to: f.sourceDirectory.appendingPathComponent(".gitattributes"))
        // Deliberate protocol EOF may make Git exit 0 or 128 depending on version;
        // the positive control is helper invocation, not successful filtering.
        _ = FileOperationsManager.runProcess("/usr/bin/git", arguments: ["-c", "core.fsmonitor=false", "status", "--porcelain=v1", "-z", "-uall"], in: f.sourceDirectory)
        try expect(f.io.exists(processMarker))
        try f.fm.removeItem(at: processMarker)
        let processSnapshot = FileOperationsManager.fetchGitStatusSnapshot(for: f.sourceDirectory.path)
        try expect(processSnapshot?.statuses[tracked.path] == .modified && !f.io.exists(processMarker))
    }

    private static func testBoundedGitInspectionAndDriverNames() throws {
        let f = try Fixture()
        let keys = Data("filter.Space Name.clean\0filter.a.b.process\0filter.Space Name.required\0".utf8)
        let options = FileOperationsManager.disabledGitFilterOptions(configurationKeys: keys)
        try expect(options?.contains("filter.Space Name.clean=") == true)
        try expect(options?.contains("filter.a.b.process=") == true)
        try expect(options?.count == 12) // Each distinct driver gets exactly three -c overrides.
        try expect(FileOperationsManager.disabledGitFilterOptions(configurationKeys: Data("filter.a=b.clean\0".utf8)) == nil)
        try expect(FileOperationsManager.disabledGitFilterOptions(configurationKeys: Data("filter.a\nb.clean\0".utf8)) == nil)
        let start = ProcessInfo.processInfo.systemUptime
        let excessiveOutput = FileOperationsManager.runProcessCapturingOutput(
            "/usr/bin/yes", arguments: [], in: f.root, maxOutputBytes: 128, timeout: 2)
        let timedOut = FileOperationsManager.runProcessCapturingOutput(
            "/bin/sleep", arguments: ["2"], in: f.root, timeout: 0.05)
        try expect(excessiveOutput == nil && timedOut == nil)
        try expect(ProcessInfo.processInfo.systemUptime - start < 1.5)
    }


    private static func testGitRenameRecordPairs() throws {
        let records = Data(" R new name.txt\0?? misleading-old-name.txt\0R  other.txt\0old.txt\0?? plain.txt\0".utf8)
        let parsed = FileOperationsManager.parseGitStatusRecords(records, repositoryRoot: "/fixture")
        try expect(parsed.count == 3)
        try expect(parsed["/fixture/new name.txt"] == .renamed && parsed["/fixture/other.txt"] == .renamed)
        try expect(parsed["/fixture/plain.txt"] == .untracked)
        try expect(parsed["/fixture/misleading-old-name.txt"] == nil)
    }


    private static func testArchivePublicationRacePreservesRival() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("incoming.txt")
        try f.write("incoming bytes", to: source)
        let desiredArchive = f.sourceDirectory.appendingPathComponent("incoming.zip")
        var io = f.io
        let first = Control()
        first.fail = true
        let livePublish = io.publishExclusive
        io.publishExclusive = { staged, candidate in
            if first.fail {
                first.fail = false
                // Occupy the candidate AFTER the production unique-name lookup.
                try Data("unrelated archive bytes".utf8).write(to: candidate, options: .withoutOverwriting)
            }
            try livePublish(staged, candidate)
        }
        let manager = f.manager(io)
        manager.compressItems([f.item(source)], in: f.sourceDirectory)
        try await idle(manager)
        let archive = f.sourceDirectory.appendingPathComponent("incoming 1.zip")
        let rivalArchive = try f.text(desiredArchive)
        try expect(rivalArchive == "unrelated archive bytes" && f.io.exists(archive) && manager.undoStack.count == 1)

        let desiredDirectory = f.sourceDirectory.appendingPathComponent("incoming 1", isDirectory: true)
        let extractionIO = f.io
        var extraction = extractionIO
        let next = Control()
        next.fail = true
        extraction.publishExclusive = { staged, candidate in
            if next.fail {
                next.fail = false
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
                try Data("unrelated directory bytes".utf8).write(to: candidate.appendingPathComponent("rival.txt"))
            }
            try extractionIO.publishExclusive(staged, candidate)
        }
        let extractor = f.manager(extraction)
        extractor.extractArchive(f.item(archive))
        try await idle(extractor)
        let publishedDirectory = f.sourceDirectory.appendingPathComponent("incoming 1 1", isDirectory: true)
        let extracted = try f.text(publishedDirectory.appendingPathComponent(source.lastPathComponent))
        try expect(extracted == "incoming bytes" && extractor.undoStack.count == 1)
        extractor.undoLastOperation(); try await idle(extractor)
        let rivalDirectory = try f.text(desiredDirectory.appendingPathComponent("rival.txt"))
        try expect(rivalDirectory == "unrelated directory bytes" && !f.io.exists(publishedDirectory))
        manager.undoLastOperation(); try await idle(manager)
        let rivalAfterUndo = try f.text(desiredArchive)
        let originalAfterUndo = try f.text(source)
        try expect(rivalAfterUndo == "unrelated archive bytes" && originalAfterUndo == "incoming bytes" && !f.io.exists(archive))
    }

    private static func testArchivePublicationFailurePreservesOwnedStaging() async throws {
        let f = try Fixture()
        let source = f.sourceDirectory.appendingPathComponent("incoming.txt")
        try f.write("incoming bytes", to: source)
        var io = f.io
        io.publishExclusive = { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
        let manager = f.manager(io)
        manager.compressItems([f.item(source)], in: f.sourceDirectory)
        try await idle(manager)
        let staging = try f.fm.contentsOfDirectory(at: f.sourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".burrow-archive-") }
        try expect(staging.count == 1 && manager.undoStack.isEmpty)
        try expect(f.io.exists(staging[0].appendingPathComponent("archive.zip")))
        // Directory enumeration may return /private/var while the producer
        // reports the equivalent /var URL from which staging was created.
        let reportedStaging = source.deletingLastPathComponent().appendingPathComponent(staging[0].lastPathComponent)
        try expect(reportedStaging.standardizedFileURL.resolvingSymlinksInPath() == staging[0].standardizedFileURL.resolvingSymlinksInPath())
        try expect(manager.lastStatusMessage?.contains(reportedStaging.path) == true)
        let original = try f.text(source)
        try expect(original == "incoming bytes")
    }

    #if BURROW_TESTING
    private static func testMutationDoesNotWaitForIndexCrawl() async throws {
        let f = try Fixture()
        try f.write("baseline", to: f.sourceDirectory.appendingPathComponent("baseline.txt"))
        let index = FSearchIndex(roots: [f.sourceDirectory.path], enableMonitoring: false)
        index.usePersistentMMapCache = false
        let gate = Control()
        defer { gate.release.signal() }
        index.crawlProgressHookForTesting = { _ in
            if !gate.didEnter { try? gate.hold() }
        }
        index.startIndexing()
        try await entered(gate)
        let refreshed = Control()
        let manager = FileOperationsManager(fileIO: f.io, reloadVisiblePanes: {}, enqueueDirectoryRefresh: { path in
            index.enqueueDirectoryRefresh(path) { refreshed.fail = true }
        })
        let started = ProcessInfo.processInfo.systemUptime
        let created = manager.createFile(named: "created-during-crawl.txt", content: "new", in: f.sourceDirectory)
        try expect(created != nil && ProcessInfo.processInfo.systemUptime - started < 0.5)
        await Task.yield()
        try expect(!refreshed.fail) // Actual index worker still owns updateLock.
        gate.release.signal()
        let deadline = Date().addingTimeInterval(5)
        while !refreshed.fail && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try expect(refreshed.fail)
    }
    #endif

}
