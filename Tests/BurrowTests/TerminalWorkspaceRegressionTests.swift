import Foundation
import CoreFoundation

@MainActor
struct TerminalWorkspaceRegressionTests {
    func runAll() async throws {
        try TerminalResizeKeyboardFocusRegressionTests.runAll()
        try await testDirectoryEscapeAndWorkerOwnership()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"]!)
        var held: [@Sendable () -> Void] = []
        let lifecycle = TerminalApplicationLifecycle(enqueueWorker: { held.append($0) }, scheduleDeadline: { _, _ in })
        let workspace = TerminalWorkspace(lifecycle: lifecycle)
        let first = workspace.add(directory: root)!
        let second = workspace.add(directory: root.appendingPathComponent("second"))!
        first.commandInput = "draft one"
        second.commandInput = "draft two"
        first.execute("printf first")
        workspace.select(first.id)
        workspace.select(second.id)
        try check(first.isRunning && lifecycle.activeCount == 1, "Switch must retain physical worker")
        try check(first.commandInput == "draft one" && second.commandInput == "draft two", "Inputs must be independent")
        try check(first.commandHistory == ["printf first"] && second.commandHistory.isEmpty, "Histories must be independent")
        let before = second.transcript.lines.map(\.text)
        workspace.close(first.id)
        try check(lifecycle.activeCount == 1 && workspace.selectedID == second.id, "Close cancels, does not release physical registry")
        var quit: [Bool] = []
        try check(lifecycle.beginTermination { quit.append($0) } == .later, "Quit must wait for closed worker")
        held.removeFirst()()
        try await wait { lifecycle.activeCount == 0 }
        try check(quit == [true] && second.transcript.lines.map(\.text) == before, "Stale completion cannot touch selected tab")
        try check(workspace.add(directory: root) != nil, "Creating a UI tab need not launch a process")
        workspace.selected!.execute("printf blocked")
        try check(!workspace.selected!.isRunning && lifecycle.activeCount == 0, "Quit rejects start")

        let bounded = TerminalWorkspace()
        for _ in 0..<TerminalWorkspace.tabLimit { _ = bounded.add(directory: root) }
        try check(bounded.add(directory: root) == nil, "Tab count bounded")
        let a = bounded.tabs[0], b = bounded.tabs[1]
        bounded.close(a.id)
        try check(bounded.tabs.contains { $0.id == b.id }, "Close cannot replace other tab identity")

        var capWorkers: [@Sendable () -> Void] = []
        let capLifecycle = TerminalApplicationLifecycle(enqueueWorker: { capWorkers.append($0) }, scheduleDeadline: { _, _ in })
        let capWorkspace = TerminalWorkspace(lifecycle: capLifecycle)
        for _ in 0..<8 {
            let closing = capWorkspace.add(directory: root)!
            closing.execute("printf held")
            capWorkspace.close(closing.id)
        }
        let ninth = capWorkspace.add(directory: root)!
        ninth.execute("printf rejected")
        try check(capLifecycle.activeCount == 8 && !ninth.isRunning && capWorkers.count == 8, "Closed physical workers still consume capacity")
        capWorkers.removeFirst()()
        try await wait { capLifecycle.activeCount == 7 }
        ninth.execute("printf admitted")
        try check(ninth.isRunning && capLifecycle.activeCount == 8, "Capacity opens only after physical completion")
        capWorkspace.close(ninth.id)
        for work in capWorkers { work() }
        try await wait { capLifecycle.activeCount == 0 }

        let normal = TerminalApplicationLifecycle()
        var reconciled: [String] = []
        let tab = TerminalTab(directory: root, lifecycle: normal, reconcile: { reconciled.append($0) })
        tab.execute("printf hello")
        try await wait { !tab.isRunning }
        try check(tab.transcript.lines.contains { $0.text.contains("hello") }, "Output retained")
        try check(reconciled == [root.path], "Completion reconciles original cwd without pane authority")
        let child = root.appendingPathComponent("terminal-cd-child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        tab.execute("cd terminal-cd-child")
        try await wait { !tab.isRunning }
        try check(tab.directory.path == child.path && reconciled.count == 1, "cd local to terminal tab, not filesystem mutation")
        tab.execute("cd missing-terminal-directory")
        try await wait { !tab.isRunning }
        try check(tab.directory.path == child.path, "Invalid cd retains cwd")
        let quoted = child.appendingPathComponent("a'b $ literal")
        try FileManager.default.createDirectory(at: quoted, withIntermediateDirectories: true)
        tab.execute("cd " + TerminalTab.shellQuote("a'b $ literal"))
        try await wait { !tab.isRunning }
        try check(tab.directory.path == quoted.path, "Standalone cd uses quoted absolute target, not CDPATH or expansion")
        try check(normal.activeCount == 0, "Workers physically released")
        // Establish the newly created fixture in the index before warming its size.
        // Later pane reconciliation should compare an unchanged tree.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            FSearchIndex.shared.enqueueDirectoryRefresh(root.path) { continuation.resume() }
        }
        let cache = FolderSizeCache.shared
        cache.requestSizeIfNeeded(for: child.path)
        try await wait { cache.result(for: child.path) != nil }
        // No suspension through the following preservation assertions: callbacks
        // for genuine filesystem changes cannot interleave with these operations.
        try check(cache.result(for: child.path) != nil, "Pane creation starts with a cached size")
        let pane = PaneTabState(initialURL: root)
        try check(cache.result(for: child.path) != nil, "New pane must preserve unchanged cached size")
        let state = AppState.shared
        state.addNewTab(at: child)
        let createdTabID = state.activeTab.id
        try check(cache.result(for: child.path) != nil, "New tab with inherited preferences must preserve cached size")
        state.closeTab(createdTabID)
        try check(pane.navigate(to: child), "Navigate to cached child")
        try check(cache.result(for: child.path) != nil, "Navigation must not discard unchanged cached size")
        pane.reloadDirectory(invalidateCaches: false)
        try check(cache.result(for: child.path) != nil, "Event reload must not invalidate a second time")
        pane.refresh()
        try check(cache.result(for: child.path) == nil, "Explicit Refresh still invalidates sizes")
        print("PASS terminal tabs preserve independent state, close ownership and quit barrier")
    }

    private func testDirectoryEscapeAndWorkerOwnership() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"]!)
            .appendingPathComponent("terminal-cd-regression-" + UUID().uuidString, isDirectory: true)
        let original = root.appendingPathComponent("original", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let nested = destination.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = TerminalApplicationLifecycle()
        var reconciled: [String] = []
        let tab = TerminalTab(directory: original, lifecycle: lifecycle, reconcile: { reconciled.append($0) })
        try FileManager.default.removeItem(at: original)
        tab.execute("cd " + TerminalTab.shellQuote(destination.path))
        try await wait { !tab.isRunning }
        try check(tab.directory.path == destination.path, "Absolute cd escapes a removed cwd")
        try check(!tab.transcript.lines.contains(where: \.isError), "Successful escape has no spawn/chdir error")
        tab.execute("cd nested")
        try await wait { !tab.isRunning }
        try check(tab.directory.path == nested.path, "Relative cd resolves against tab cwd, not stable launch root")
        tab.execute("cd ..")
        try await wait { !tab.isRunning }
        try check(tab.directory.path == destination.path, "Parent cd preserves relative semantics")

        let renamed = root.appendingPathComponent("renamed", isDirectory: true)
        try FileManager.default.moveItem(at: destination, to: renamed)
        tab.clear()
        tab.execute("cd " + TerminalTab.shellQuote(root.appendingPathComponent("missing").path))
        try await wait { !tab.isRunning }
        try check(tab.directory.path == destination.path, "Invalid target from renamed cwd preserves tab directory")
        try check(tab.transcript.lines.contains { $0.isError && $0.text.contains("błędem") }, "Invalid target is validated by builtin cd, not spawn cwd")
        let regularFile = root.appendingPathComponent("file")
        try Data("not a directory".utf8).write(to: regularFile)
        tab.execute("cd " + TerminalTab.shellQuote(regularFile.path))
        try await wait { !tab.isRunning }
        try check(tab.directory.path == destination.path, "cd rejects a regular file")
        tab.execute("cd " + TerminalTab.shellQuote(renamed.path))
        try await wait { !tab.isRunning }
        try check(tab.directory.path == renamed.path, "Absolute cd also escapes a renamed cwd")
        try check(lifecycle.activeCount == 0 && reconciled.isEmpty, "cd retains worker lifecycle without filesystem reconciliation")

        var held: [@Sendable () -> Void] = []
        let queued = TerminalApplicationLifecycle(enqueueWorker: { held.append($0) }, scheduleDeadline: { _, _ in })
        let pending = TerminalTab(directory: root, lifecycle: queued, reconcile: { _ in })
        let transient = root.appendingPathComponent("transient", isDirectory: true)
        try FileManager.default.createDirectory(at: transient, withIntermediateDirectories: true)
        pending.execute("cd " + TerminalTab.shellQuote(transient.path))
        try check(pending.isRunning && queued.activeCount == 1 && held.count == 1, "cd admission precedes worker validation")
        try check(pending.directory.path == root.path, "cd cannot commit before its worker completes")
        // Removing the target after admission must be observed by the worker.
        try FileManager.default.removeItem(at: transient)
        held.removeFirst()()
        try await wait { !pending.isRunning }
        try check(pending.directory.path == root.path && queued.activeCount == 0, "Target validation occurs inside the worker")

        pending.execute("cd " + TerminalTab.shellQuote(renamed.path))
        pending.cancel()
        held.removeFirst()()
        try await wait { !pending.isRunning }
        try check(pending.directory.path == root.path && queued.activeCount == 0, "Cancellation before spawn cannot commit cd")
        try check(pending.transcript.lines.contains { $0.isError && $0.text.contains("przerwane") }, "Cancelled cd reports cancellation")

        pending.execute("cd " + TerminalTab.shellQuote(renamed.path))
        // Complete physical work, then close before the main-loop completion.
        held.removeFirst()()
        pending.close()
        let closedTranscript = pending.transcript.lines.map(\.text)
        try await wait { queued.activeCount == 0 }
        try check(pending.directory.path == root.path && pending.transcript.lines.map(\.text) == closedTranscript,
                  "Closed tab token fences even a successful late cd completion")

        var capacityWorkers: [@Sendable () -> Void] = []
        let capped = TerminalApplicationLifecycle(enqueueWorker: { capacityWorkers.append($0) }, scheduleDeadline: { _, _ in })
        var tabs: [TerminalTab] = []
        for _ in 0..<8 {
            let admitted = TerminalTab(directory: root, lifecycle: capped, reconcile: { _ in })
            admitted.execute("cd " + TerminalTab.shellQuote(renamed.path))
            tabs.append(admitted)
        }
        let rejected = TerminalTab(directory: root, lifecycle: capped, reconcile: { _ in })
        rejected.execute("cd " + TerminalTab.shellQuote(renamed.path))
        try check(!rejected.isRunning && rejected.directory.path == root.path && capacityWorkers.count == 8,
                  "cd respects the global eight-worker admission cap")
        var replies: [Bool] = []
        try check(capped.beginTermination { replies.append($0) } == .later, "Quit waits for admitted cd workers")
        rejected.execute("cd " + TerminalTab.shellQuote(renamed.path))
        try check(!rejected.isRunning && capacityWorkers.count == 8, "Quit rejects cd admission")
        for work in capacityWorkers { work() }
        try await wait { capped.activeCount == 0 }
        try check(replies == [true] && tabs.allSatisfy { !$0.isRunning && $0.directory.path == root.path },
                  "Quit cancels cd before launch and releases all physical leases")
        print("PASS cd escapes stale cwd, validates targets in workers, and preserves relative paths, cancellation and admission")
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            CFRunLoopRunInMode(.defaultMode, 0.002, false)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(message: "Timed out waiting for terminal worker")
    }
    private func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    private struct Failure: Error { let message: String }
}

struct DirectoryReconciliationRegressionTests {
    static func runAll() async throws {
        func entry(_ name: String, parent: String = "/root", size: Int64 = 1, nanos: Int64 = 1) -> IndexedFileEntry {
            IndexedFileEntry(name: name, lowerNameUTF8: Array(name.utf8), parentPath: parent, ext: "", charMask: 0,
                             size: size, mtimeEpoch: 1, isDirectory: false, isSymlink: false, isHidden: false, mtimeNanoseconds: nanos)
        }
        let a = entry("a"), b = entry("b", parent: "/root/sub")
        guard FSearchIndex.changedDirectoryPaths(previous: [a,b], replacement: [b,a]).isEmpty else { throw Failure() }
        guard FSearchIndex.changedDirectoryPaths(previous: [a,b], replacement: [a,entry("b", parent: "/root/sub", size: 2)]) == ["/root/sub"] else { throw Failure() }
        guard FSearchIndex.changedDirectoryPaths(previous: [a,b], replacement: [a,entry("b", parent: "/root/sub", nanos: 2)]) == ["/root/sub"] else { throw Failure() }
        guard FSearchIndex.changedDirectoryPaths(previous: [a], replacement: [a,b]) == ["/root/sub"] else { throw Failure() }
        guard FSearchIndex.changedDirectoryPaths(previous: [a,b], replacement: [a]) == ["/root/sub"] else { throw Failure() }
        guard FSearchIndex.changedDirectoryPaths(previous: [a], replacement: [entry("renamed")]) == ["/root"] else { throw Failure() }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"]!).appendingPathComponent("reconcile-tree")
        let nested = root.appendingPathComponent("sub/deep/file")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("one".utf8).write(to: nested)
        let index = FSearchIndex(roots: [root.path], enableMonitoring: false)
        index.usePersistentMMapCache = false; index.skipHeavyDevDirs = false
        _ = index.refreshDirectoryInIndex(root.path)
        guard index.refreshDirectoryInIndex(root.path).isEmpty else { throw Failure() }
        try Data("changed and larger".utf8).write(to: nested)
        guard index.refreshDirectoryInIndex(root.path).contains(nested.deletingLastPathComponent().path) else { throw Failure() }
        guard index.refreshDirectoryInIndex(root.path).isEmpty else { throw Failure() }
        try FileManager.default.removeItem(at: nested)
        guard index.refreshDirectoryInIndex(root.path).contains(nested.deletingLastPathComponent().path) else { throw Failure() }
        let events = EventRecorder()
        index.onDirectoryChangedOnDisk = { events.record($0) }
        index.onIndexUpdated = { _, _ in events.indexUpdate() }
        func reconcile() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                index.enqueueDirectoryRefresh(root.path) { continuation.resume() }
            }
        }
        await reconcile()
        guard events.snapshot().0.isEmpty && events.snapshot().1 == 0 else { throw Failure() }
        try Data("new".utf8).write(to: nested)
        await reconcile()
        guard events.snapshot().0.contains(nested.deletingLastPathComponent().path) else { throw Failure() }
        let count = events.snapshot().1
        await reconcile()
        guard events.snapshot().1 == count else { throw Failure() }
        let renamed = nested.deletingLastPathComponent().appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: nested, to: renamed)
        // Revisit an already-indexed unmonitored tree after mutation while away.
        index.ensureDirectoryIndexed(root.path)
        // Do not enqueue a second refresh here: this must exercise the revisit path alone.
        for _ in 0..<500 {
            if events.snapshot().1 > count { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard events.snapshot().1 > count else { throw Failure() }
        print("PASS unchanged reconciliation emits no refresh; nested changes, creation, deletion and rename detected")
    }
    private final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var paths = Set<String>()
        private var count = 0
        func record(_ value: Set<String>) { lock.lock(); paths.formUnion(value); lock.unlock() }
        func indexUpdate() { lock.lock(); count += 1; lock.unlock() }
        func snapshot() -> (Set<String>, Int) { lock.lock(); defer { lock.unlock() }; return (paths, count) }
    }
    private struct Failure: Error {}
}
