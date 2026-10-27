import Foundation
import Darwin

private final class QuickSearchThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadObserved = false
    private var started = false
    func recordStart() { lock.lock(); started = true; mainThreadObserved = mainThreadObserved || Thread.isMainThread; lock.unlock() }
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return mainThreadObserved }
}

/// These invoke production helpers. They require the macOS SDK and are not a
/// Linux algorithm-model substitute. Every fixture is under a temporary folder.
struct DiskAnalysisRegressionTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-analysis-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func duplicates(in root: URL) -> [DuplicateFileGroup] {
        let token = AnalysisRequestToken(rootPath: root.path)
        let entries = BulkCrawler.crawlTreeResult(roots: [root.path], skipHeavyDevDirs: false).entries
        return DuplicateFileSafety.groups(from: entries, token: token).groups
    }

    private func expectFailure(_ operation: () throws -> Void) throws {
        var failed = false
        do { try operation() } catch { failed = true }
        try expect(failed)
    }

    func testDuplicateContentAndIdentityRevalidation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data("same".utf8).write(to: a)
        try Data("same".utf8).write(to: b)
        let group = try requireGroup(duplicates(in: root))
        try DuplicateFileSafety.validate(group)
        // Same length no longer permits a stale copy to enter the Trash.
        try Data("edit".utf8).write(to: b)
        try expectFailure { try DuplicateFileSafety.validate(group) }
        try expectFailure { try DuplicateFileSafety.validateBeforeTrash(group.files[1], in: group) }
        try Data("same".utf8).write(to: b)
        let fresh = try requireGroup(duplicates(in: root))
        try FileManager.default.removeItem(at: a)
        try expectFailure { try DuplicateFileSafety.validate(fresh) }
        // Same path and bytes, but a replaced inode, must still be rejected.
        try Data("same".utf8).write(to: a)
        try expectFailure { try DuplicateFileSafety.validate(fresh) }
        try expect(FileManager.default.fileExists(atPath: b.path))
    }

    func testLargeEmptyAndLinkedDuplicateFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let large = Data(repeating: 0x41, count: 51 * 1024 * 1024)
        try large.write(to: root.appendingPathComponent("large-a"))
        try large.write(to: root.appendingPathComponent("large-b"))
        try Data().write(to: root.appendingPathComponent("empty-a"))
        try Data().write(to: root.appendingPathComponent("empty-b"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("large-a"), to: root.appendingPathComponent("hard-link"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("symlink"), withDestinationURL: root.appendingPathComponent("large-a"))
        let groups = duplicates(in: root)
        try expect(groups.contains { $0.fileSize > 50 * 1024 * 1024 && $0.files.count == 2 })
        try expect(groups.contains { $0.fileSize == 0 && $0.files.count == 2 })
        try expectFailure { _ = try DuplicateFileSafety.hash(at: root.appendingPathComponent("symlink")) }
    }

    func testAnalysisGenerationsAndScanCompleteness() throws {
        let old = AnalysisRequestToken(rootPath: "/a"), current = AnalysisRequestToken(rootPath: "/b")
        try expect(!old.canPublish(active: current, rootPath: "/b"))
        try expect(!current.canPublish(active: current, rootPath: "/a"))
        try expect(current.canPublish(active: current, rootPath: "/b"))
        current.cancel()
        try expect(!current.canPublish(active: current, rootPath: "/b"))
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b", ".hidden"] { try Data().write(to: root.appendingPathComponent(name)) }
        let limited = BulkCrawler.crawlTreeResult(roots: [root.path], skipHeavyDevDirs: false, maxEntries: 1)
        try expect(!limited.isComplete && limited.reachedEntryLimit)
        let visible = BulkCrawler.crawlTreeResult(roots: [root.path], skipHeavyDevDirs: false, includeHidden: false)
        try expect(visible.isComplete && visible.entries.count == 2)
    }

    func testHonestShallowFolderComparison() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        for url in [left, right] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("project"), withIntermediateDirectories: true)
        }
        try Data("old".utf8).write(to: left.appendingPathComponent("same-size.txt"))
        try Data("new".utf8).write(to: right.appendingPathComponent("same-size.txt"))
        try Data("only child".utf8).write(to: left.appendingPathComponent("project/new.txt"))
        try Data("file".utf8).write(to: left.appendingPathComponent("type-change"))
        try FileManager.default.createDirectory(at: right.appendingPathComponent("type-change"), withIntermediateDirectories: true)
        let result = FolderComparison.compare(left: left, right: right, includeHidden: true, token: AnalysisRequestToken(rootPath: left.path))
        try expect(result.diagnostic == nil)
        try expect(result.entries.first { $0.name == "same-size.txt" }?.status == .modified)
        try expect(result.entries.first { $0.name == "project" }?.status == .notCompared)
        try expect(result.entries.first { $0.name == "type-change" }?.status == .typeConflict)
        let names = FolderComparison.copyCandidates(result.entries, leftToRight: true).map(\.lastPathComponent)
        try expect(names == ["same-size.txt"])
    }

    @MainActor func testQuickSearchGenerationAndCancellation() async throws {
        let probe = QuickSearchThreadProbe()
        let model = QuickSearchModel { request in
            probe.recordStart()
            if request.query == "old" { Thread.sleep(forTimeInterval: 0.15) }
            return FSearchResultBundle(items: [], elapsedMilliseconds: request.query == "old" ? 1 : 2,
                totalIndexedCount: 0, backendName: "test")
        }
        model.schedule("old", rootPath: "/a", includeHidden: false, debounceNanoseconds: 0)
        for _ in 0..<100 where !probe.hasStarted { try await Task.sleep(nanoseconds: 1_000_000) }
        try expect(probe.hasStarted)
        model.schedule("new", rootPath: "/b", includeHidden: false, debounceNanoseconds: 0)
        for _ in 0..<100 where model.isSearching { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        try expect(!probe.usedMainThread && model.elapsedMs == 2 && !model.isSearching)
        model.schedule("old", rootPath: "/b", includeHidden: false, debounceNanoseconds: 0)
        model.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        try expect(model.results.isEmpty && model.elapsedMs == 0 && !model.isSearching)
    }

    func testTerminalMergedOutputLimitAndCancellation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for command in [
            "/usr/bin/head -c 1048576 /dev/zero >&2; printf done",
            "/usr/bin/head -c 1048576 /dev/zero; /usr/bin/head -c 1048576 /dev/zero >&2; printf done"
        ] {
            let session = TerminalCommandSession(outputLimit: 3 * 1024 * 1024)
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { session.cancel() }
            let result = try session.run(command: command, directory: root, shell: "/bin/sh")
            try expect(!result.wasCancelled && result.status == 0 && result.output.hasSuffix("done"))
        }
        let closedOutput = try TerminalCommandSession().run(
            command: "exec 1>&- 2>&-; /bin/sleep 0.25", directory: root, shell: "/bin/sh")
        try expect(closedOutput.status == 0 && closedOutput.output.isEmpty)
        try expect(closedOutput.waitIterations < 30)
        let closedCancelled = TerminalCommandSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { closedCancelled.cancel() }
        let closedStart = Date()
        let closedResult = try closedCancelled.run(
            command: "exec 1>&- 2>&-; trap '' TERM; /bin/sleep 60", directory: root, shell: "/bin/sh")
        try expect(closedResult.wasCancelled && Date().timeIntervalSince(closedStart) < 5)
        try expect(closedResult.waitIterations < 100)
        let inheritedEnvironment = try TerminalCommandSession().run(
            command: "printf '%s' \"$HOME\"", directory: root, shell: "/bin/sh")
        try expect(inheritedEnvironment.status == 0)
        try expect(inheritedEnvironment.output == (ProcessInfo.processInfo.environment["HOME"] ?? ""))
        let failure = try TerminalCommandSession().run(command: "exit 7", directory: root, shell: "/bin/sh")
        try expect(failure.status == 7)
        let limited = TerminalCommandSession(outputLimit: 1024)
        let output = try limited.run(command: "/usr/bin/head -c 1048576 /dev/zero >&2", directory: root, shell: "/bin/sh")
        try expect(output.wasTruncated && output.output.utf8.count == 1024)
        let cancelled = TerminalCommandSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancelled.cancel() }
        let start = Date()
        let result = try cancelled.run(command: "trap '' TERM; /bin/sleep 60 & child=$!; printf '%s' \"$child\"; wait", directory: root, shell: "/bin/sh")
        try expect(result.wasCancelled && Date().timeIntervalSince(start) < 5)
        guard let childPID = Int32(result.output), childPID > 0 else {
            throw RegressionFailure(description: "Expected fixture child PID")
        }
        let childDeadline = Date().addingTimeInterval(2)
        while Darwin.kill(childPID, 0) == 0 && Date() < childDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        try expect(Darwin.kill(childPID, 0) == -1 && errno == ESRCH)
    }

    private func requireGroup(_ groups: [DuplicateFileGroup]) throws -> DuplicateFileGroup {
        guard let group = groups.first else { throw RegressionFailure(description: "Expected duplicate group") }
        return group
    }

    @MainActor func runAll() async throws {
        try testDuplicateContentAndIdentityRevalidation()
        try testLargeEmptyAndLinkedDuplicateFiles()
        try testAnalysisGenerationsAndScanCompleteness()
        try testHonestShallowFolderComparison()
        try await testQuickSearchGenerationAndCancellation()
        try testTerminalMergedOutputLimitAndCancellation()
        print("PASS 6 disk-analysis, comparison, quick-search and terminal regression groups")
    }
}
