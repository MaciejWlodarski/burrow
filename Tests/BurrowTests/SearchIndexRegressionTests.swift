import Foundation
import Darwin

/// Native tests of the production parser/crawler/index. These are NOT Python
/// models. Run through scripts/run_tests.sh on macOS with BURROW_TESTING.
struct SearchIndexRegressionTests {
    static func runAll() async throws {
        try parserValidationAndQuotes()
        try crawlerBudgetAndCoverage()
        try await recursiveSearchAndRefresh()
        try await wholeIndexRespectsHiddenAncestors()
        try samePathSubtreeReplacementIsReconciled()
        try grepBeyondCandidateBudgetAndPreservedMtime()
        try cacheRejectsTruncationAndConfigurationMismatch()
        try freshGitSnapshotClearsStatuses()
        try socketHandlesFragmentationAndTimeout()
        #if BURROW_TESTING
        try refreshReadsAreSerialized()
        try await queuedRefreshDoesNotWaitForInitialCrawl()
        try refreshStormCoalescesAndRetainsSecondPass()
        try await eventsDuringInitialCrawlAreReconciled()
        try await supplementalScopesSurviveFullRebuildInterleavings()
        try await cacheRetainsCrawlConfigurationWhenSettingsChangeBeforeWrite()
        #endif
        print("PASS search/index parser, crawl, rename, memory, grep, cache, Git and serialization regressions")
    }

    private static func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bf-index-regression-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func engine(_ root: URL) -> FSearchIndex {
        let result = FSearchIndex(roots: [root.path], enableMonitoring: false)
        result.usePersistentMMapCache = false
        result.skipHeavyDevDirs = false
        return result
    }

    private static func query(_ engine: FSearchIndex, _ text: String, _ root: URL,
                              scope: SearchScopeMode = .wholeIndex, includeHidden: Bool = true) -> FSearchResultBundle {
        engine.search(rawQuery: text, scope: scope, scopeDirectory: root.path, includeHidden: includeHidden, fuzzyEnabled: false)
    }

    private static func parserValidationAndQuotes() throws {
        for value in ["9999999999999999999", "9223372036854775808", "999999999999gb", "-1", "2..1", "1b2", String(repeating: "9", count: 400)] {
            let parsed = ParsedFSearchQuery.parse("size:\(value)")
            try expect(parsed.validationError != nil)
            try expect(parsed.sizeFilters.isEmpty)
        }
        let maximum = ParsedFSearchQuery.parse("size:9223372036854775807")
        try expect(maximum.validationError == nil)
        try expect(maximum.sizeFilters.first?.bytes == Int64.max)
        try expect(ParsedFSearchQuery.parse("size:1.5kb").sizeFilters.first?.bytes == 1536)
        try expect(ParsedFSearchQuery.parse("size:0").sizeFilters.first?.bytes == 0)
        let quoted = ParsedFSearchQuery.parse(#"grep:"hello world" in:'My Documents' regex:"\\d+ report""#)
        try expect(quoted.validationError == nil)
        try expect(quoted.grepPattern == "hello world")
        try expect(quoted.pathSubstrings == ["my documents"])
        try expect(quoted.regexPattern == #"\d+ report"#)
        try expect(quoted.pills.first?.rawToken == #"grep:"hello world""#)
        try expect(ParsedFSearchQuery.parse(#"grep:"say \"hi\"""#).grepPattern == "say \"hi\"")
        try expect(ParsedFSearchQuery.parse("grep:don't").grepPattern == "don't")
        try expect(ParsedFSearchQuery.parse("don't.txt").validationError == nil)
        try expect(ParsedFSearchQuery.parse("regex:[").validationError != nil)
        try expect(ParsedFSearchQuery.parse("grep:\"unfinished").validationError != nil)
    }

    private static func crawlerBudgetAndCoverage() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<20 { try write("x", to: root.appendingPathComponent("file-\(index)")) }
        let capped = BulkCrawler.crawlTreeResult(roots: [root.path], skipHeavyDevDirs: false, maxEntries: 1)
        try expect(capped.entries.count == 1)
        try expect(capped.reachedEntryLimit && !capped.isComplete)
        try expect(BulkCrawler.readDirectoryResult(at: root.path, maxEntries: 1).entries.count == 1)
        try write("hidden", to: root.appendingPathComponent(".hidden/deep.txt"))
        try write("excluded", to: root.appendingPathComponent("node_modules/package.txt"))
        let skipped = BulkCrawler.crawlTreeResult(roots: [root.path], skipHeavyDevDirs: true)
        try expect(!skipped.isComplete && skipped.skippedDirectoryCount == 1)
        let all = BulkCrawler.crawlTreeResult(roots: [root.path], skipHeavyDevDirs: false)
        try expect(all.isComplete)
        try expect(all.entries.contains { $0.name == "deep.txt" })
        try expect(all.entries.contains { $0.name == "package.txt" })
        let visible = BulkCrawler.crawlTreeResult(roots: [root.path], skipHeavyDevDirs: false, includeHidden: false)
        try expect(!visible.entries.contains { $0.name == "deep.txt" })
        let overlap = BulkCrawler.crawlTreeResult(roots: [root.path, root.appendingPathComponent("node_modules").path], skipHeavyDevDirs: false)
        try expect(Set(overlap.entries.map(\.fullPath)).count == overlap.entries.count)
        try expect(overlap.entries.count == all.entries.count)
        let cancelled = BulkCrawler.crawlTreeResult(roots: [root.path], isCancelled: { true })
        try expect(cancelled.wasCancelled && !cancelled.isComplete && cancelled.entries.isEmpty)
        let missing = BulkCrawler.readDirectoryResult(at: root.appendingPathComponent("missing").path)
        try expect(!missing.isComplete && missing.errorCode == ENOENT)
        let link = root.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("node_modules"))
        try expect(BulkCrawler.readDirectoryFast(at: link.path).contains { $0.name == "package.txt" })
    }

    private static func recursiveSearchAndRefresh() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old")
        try write("payload", to: old.appendingPathComponent("deep/needle.txt"))
        let index = engine(root)
        // Search must scan the whole subtree even after navigation has populated
        // some/all immediate children, and outside configured roots too.
        index.refreshDirectoryInIndex(root.path)
        try expect(query(index, "^needle.txt", root, scope: .recursiveFolder).items.count == 1)
        index.configuredRoots = []
        try expect(query(index, "^needle.txt", root, scope: .recursiveFolder).items.count == 1)
        index.startIndexing(roots: [root.path])
        for _ in 0..<1000 where index.isIndexing { try await Task.sleep(for: .milliseconds(10)) }
        try expect(!index.isIndexing)
        let new = root.appendingPathComponent("new")
        try FileManager.default.moveItem(at: old, to: new)
        index.refreshDirectoryInIndex(root.path)
        index.refreshDirectoryInIndex(new.path)
        let renamed = query(index, "^needle.txt", root)
        try expect(renamed.items.count == 1)
        try expect(renamed.items.first?.path == new.appendingPathComponent("deep/needle.txt").path)
        try expect(!renamed.items.contains { $0.path.contains("/old/") })
        let expectedCount = index.indexedCount
        for _ in 0..<100 { index.refreshDirectoryInIndex(root.path) }
        try expect(index.indexedCount == expectedCount)
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        index.refreshDirectoryInIndex(root.path)
        index.refreshDirectoryInIndex(empty.path)
        try expect(query(index, "^empty", root).items.count == 1)
        try FileManager.default.removeItem(at: new)
        index.refreshDirectoryInIndex(root.path)
        try expect(query(index, "^needle.txt", root).items.isEmpty)
        let invalid = query(index, "regex:[", root, scope: .currentFolder)
        try expect(invalid.items.isEmpty && invalid.diagnostic != nil)
    }

    private static func samePathSubtreeReplacementIsReconciled() throws {
        let root = try fixture()
        let outside = try fixture()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let project = root.appendingPathComponent("project")
        try write("old", to: project.appendingPathComponent("sub/old.txt"))
        let index = engine(root)
        index.refreshDirectoryInIndex(root.path)
        try expect(query(index, "^old.txt", root).items.count == 1)
        try FileManager.default.moveItem(at: project, to: outside.appendingPathComponent("old-project"))
        try write("new", to: project.appendingPathComponent("sub/new.txt"))
        // Both directory path names are unchanged. Refreshes must reconcile their
        // contents rather than inferring identity from project/sub's old name.
        index.refreshDirectoryInIndex(root.path)
        index.refreshDirectoryInIndex(project.path)
        try expect(query(index, "^old.txt", root).items.isEmpty)
        try expect(query(index, "^new.txt", root).items.map(\.path) == [project.appendingPathComponent("sub/new.txt").path])
        try expect(index.indexedCount == 3)
    }

    private static func wholeIndexRespectsHiddenAncestors() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("hidden ancestor", to: root.appendingPathComponent(".hidden/visible-name.txt"))
        try write("hidden basename", to: root.appendingPathComponent("visible/.hidden-name.txt"))
        try write("visible", to: root.appendingPathComponent("visible/dot.in.name.txt"))
        let index = engine(root)
        index.startIndexing()
        for _ in 0..<1000 where index.isIndexing { try await Task.sleep(for: .milliseconds(10)) }
        try expect(!index.isIndexing)
        let wholeVisible = query(index, "type:file", root, includeHidden: false)
        let recursiveVisible = query(index, "type:file", root, scope: .recursiveFolder, includeHidden: false)
        try expect(wholeVisible.items.map(\.name) == ["dot.in.name.txt"])
        try expect(Set(wholeVisible.items.map(\.path)) == Set(recursiveVisible.items.map(\.path)))
        try expect(query(index, "type:file", root, includeHidden: true).items.count == 3)
        // Explicitly entering a hidden directory still permits browsing/searching
        // its visible children; only descendants hidden relative to that scope
        // are suppressed by the local crawler.
        let hiddenRoot = root.appendingPathComponent(".hidden")
        try expect(query(index, "type:file", hiddenRoot, scope: .currentFolder, includeHidden: false).items.map(\.name) == ["visible-name.txt"])
        try expect(query(index, "type:file", hiddenRoot, scope: .recursiveFolder, includeHidden: false).items.map(\.name) == ["visible-name.txt"])
    }

    private static func grepBeyondCandidateBudgetAndPreservedMtime() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = engine(root)
        let old = root.appendingPathComponent("old.txt")
        try write("needle", to: old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: old.path)
        for i in 0..<1501 { try write("nothing", to: root.appendingPathComponent("new-\(i).txt")) }
        let match = query(index, "grep:needle limit:10000", root, scope: .currentFolder)
        try expect(match.items.map(\.name) == ["old.txt"])
        let mutable = root.appendingPathComponent("mutable.txt")
        let sameTime = Date(timeIntervalSince1970: 1_700_000_000)
        try write("aaa", to: mutable)
        try FileManager.default.setAttributes([.modificationDate: sameTime], ofItemAtPath: mutable.path)
        try expect(query(index, "^mutable.txt grep:aaa", root, scope: .currentFolder).items.count == 1)
        // Preserve timestamp and length; no metadata-keyed cache may reject bbb.
        try write("bbb", to: mutable)
        try FileManager.default.setAttributes([.modificationDate: sameTime], ofItemAtPath: mutable.path)
        index.refreshDirectoryInIndex(root.path)
        try expect(query(index, "^mutable.txt grep:bbb", root, scope: .currentFolder).items.count == 1)
        try write("hello world", to: mutable)
        try expect(query(index, #"^mutable.txt grep:"hello world""#, root, scope: .currentFolder).items.count == 1)
        let huge = root.appendingPathComponent("huge.txt")
        try Data(repeating: 120, count: 15 * 1024 * 1024 + 1).write(to: huge)
        let partial = query(index, "^huge.txt grep:x", root, scope: .currentFolder)
        try expect(partial.isPartial && partial.diagnostic != nil)
    }

    private static func cacheRejectsTruncationAndConfigurationMismatch() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("hello", to: root.appendingPathComponent("cache.txt"))
        let index = engine(root)
        let entries = BulkCrawler.readDirectoryFast(at: root.path)
        let data = index.encodeIndexCache(entries)
        try expect(index.decodeIndexCache(data)?.count == 1)
        for length in 0..<data.count { try expect(index.decodeIndexCache(Data(data.prefix(length))) == nil) }
        var trailing = data
        trailing.append(0)
        try expect(index.decodeIndexCache(trailing) == nil)
        var badCount = data
        badCount[8] = 2
        try expect(index.decodeIndexCache(badCount) == nil)
        index.configuredRoots = [root.appendingPathComponent("different").path]
        try expect(index.decodeIndexCache(data) == nil)
        index.configuredRoots = [root.path]
        index.skipHeavyDevDirs = true
        try expect(index.decodeIndexCache(data) == nil)
    }

    private static func freshGitSnapshotClearsStatuses() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try expect(process.terminationStatus == 0)
        }
        try git(["init", "-q"])
        let file = root.appendingPathComponent("tracked.txt")
        try write("original", to: file)
        try git(["add", "--", "tracked.txt"])
        try git(["-c", "user.name=Regression", "-c", "user.email=regression@example.invalid", "commit", "-qm", "fixture"])
        let index = engine(root)
        try write("modified content", to: file)
        let modified = query(index, "git:modified", root, scope: .currentFolder)
        if modified.items.map(\.name) != ["tracked.txt"] {
            let snapshot = FileOperationsManager.fetchGitStatusSnapshot(for: root.path)
            let entries = BulkCrawler.readDirectoryResult(at: root.path).entries
            print("Git fixture diagnostic: root=\(root.path); candidates=\(entries.map(\.fullPath)); results=\(modified.items.map(\.path)); partial=\(modified.isPartial); diagnostic=\(modified.diagnostic ?? "none"); snapshotRoot=\(snapshot?.repositoryRoot ?? "unavailable"); statuses=\(snapshot?.statuses.description ?? "unavailable")")
        }
        try expect(modified.items.map(\.name) == ["tracked.txt"])
        let modifiedSnapshot = FileOperationsManager.fetchGitStatusSnapshot(for: root.path)
        try expect(modifiedSnapshot?.repositoryRoot == root.path)
        try expect(modifiedSnapshot?.statuses[file.path] == .modified)
        try write("original", to: file)
        try expect(query(index, "git:modified", root, scope: .currentFolder).items.isEmpty)
        let snapshot = FileOperationsManager.fetchGitStatusSnapshot(for: root.path)
        try expect(snapshot != nil && snapshot?.statuses.isEmpty == true)
    }

    private static func socketHandlesFragmentationAndTimeout() throws {
        let index = FSearchIndex(roots: [], enableMonitoring: false)
        func serve(response: Data?, stall: Bool = false) throws -> [FileItem]? {
            let directory = URL(fileURLWithPath: "/tmp/bf-sock-\(UUID().uuidString.prefix(12))", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("s").path
            let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            try expect(listener >= 0)
            defer { Darwin.close(listener); unlink(path) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            try expect(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
            withUnsafeMutableBytes(of: &address.sun_path) { pointer in
                for (i, byte) in bytes.enumerated() { pointer[i] = UInt8(bitPattern: byte) }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try expect(bound == 0 && Darwin.listen(listener, 1) == 0)
            let completed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { completed.signal() }
                let client = Darwin.accept(listener, nil, nil)
                guard client >= 0 else { return }
                defer { Darwin.close(client) }
                var noSigPipe: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                var request = [UInt8](repeating: 0, count: 1024)
                // Tiny receives also exercise the production partial-write loop
                // with a large request payload.
                while true {
                    let count = Darwin.read(client, &request, request.count)
                    if count <= 0 || request[..<count].contains(10) { break }
                }
                if stall { Thread.sleep(forTimeInterval: 2.3); return }
                guard let response = response else { return }
                var offset = 0
                while offset < response.count {
                    let count = response.withUnsafeBytes {
                        Darwin.write(client, $0.baseAddress!.advanced(by: offset), min(997, response.count - offset))
                    }
                    if count <= 0 { return }
                    offset += count
                }
            }
            let started = Date()
            let result = index.queryExternalFSearchSocket(rawQuery: String(repeating: "x", count: 100_000), limit: 5000, socketPath: path)
            if stall { try expect(Date().timeIntervalSince(started) < 3.5) }
            try expect(completed.wait(timeout: .now() + 5) == .success)
            return result
        }
        let rows: [[String: Any]] = (0..<2000).map { ["path": "/tmp/fake-result-\($0)-long-name.txt", "size": 12] }
        var payload = try JSONSerialization.data(withJSONObject: ["results": rows])
        payload.append(10)
        try expect(payload.count > 65_536)
        let fragmented = try serve(response: payload)
        try expect(fragmented?.count == 2000)
        let empty = try serve(response: Data("{\"results\":[]}\n".utf8))
        try expect(empty?.isEmpty == true)
        let malformed = try serve(response: Data("{\"results\":[".utf8))
        try expect(malformed == nil)
        let timeout = try serve(response: nil, stall: true)
        try expect(timeout == nil)
    }

    #if BURROW_TESTING
    private final class ReadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func beforeRead() {
            lock.lock()
            calls += 1
            let first = calls == 1
            lock.unlock()
            if first { entered.signal(); _ = release.wait(timeout: .now() + 10) }
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    private static func refreshReadsAreSerialized() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("before", to: root.appendingPathComponent("old.txt"))
        let index = engine(root)
        let gate = ReadGate()
        index.refreshReadHookForTesting = { _ in gate.beforeRead() }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { index.refreshDirectoryInIndex(root.path); group.leave() }
        try expect(gate.entered.wait(timeout: .now() + 5) == .success)
        group.enter()
        DispatchQueue.global().async { index.refreshDirectoryInIndex(root.path); group.leave() }
        // The second refresh cannot reach its disk read until the first releases.
        Thread.sleep(forTimeInterval: 0.05)
        try expect(gate.count == 1)
        try write("new", to: root.appendingPathComponent("new.txt"))
        gate.release.signal()
        try expect(group.wait(timeout: .now() + 10) == .success)
        try expect(gate.count == 2)
        try expect(query(index, "^new.txt", root).items.count == 1)
        index.refreshReadHookForTesting = nil
    }
    private static func refreshStormCoalescesAndRetainsSecondPass() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("existing", to: root.appendingPathComponent("existing.txt"))
        let index = engine(root)
        let gate = ReadGate()
        index.refreshReadHookForTesting = { _ in gate.beforeRead() }
        index.enqueueDirectoryRefresh(root.path)
        try expect(gate.entered.wait(timeout: .now() + 5) == .success)
        defer { gate.release.signal() }
        for i in 0..<300 { index.enqueueDirectoryRefresh(root.appendingPathComponent("changed-\(i)").path) }
        try expect(index.pendingRefreshPathCountForTesting <= 128)
        let completed = DispatchSemaphore(value: 0)
        index.enqueueDirectoryRefresh(root.path) { completed.signal() }
        try write("new", to: root.appendingPathComponent("storm-new.txt"))
        gate.release.signal()
        try expect(completed.wait(timeout: .now() + 10) == .success)
        // The active first pass does not swallow subsequent requests, and all
        // 300 descendant events collapse into one root pass rather than 300 jobs.
        try expect(gate.count == 2)
        try expect(query(index, "^storm-new.txt", root).items.count == 1)
    }

    @MainActor private static func queuedRefreshDoesNotWaitForInitialCrawl() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("existing", to: root.appendingPathComponent("child/existing.txt"))
        let index = engine(root)
        let gate = ReadGate()
        index.crawlProgressHookForTesting = { _ in gate.beforeRead() }
        index.startIndexing()
        try expect(gate.entered.wait(timeout: .now() + 5) == .success)
        defer { gate.release.signal() }
        let completed = DispatchSemaphore(value: 0)
        let started = Date()
        index.enqueueDirectoryRefresh(root.path) { completed.signal() }
        try expect(Date().timeIntervalSince(started) < 0.5)
        // The MainActor can yield and resume while the queued refresh is waiting
        // for the full crawl. No fixture file operation occurs before release.
        await Task.yield()
        try expect(completed.wait(timeout: .now()) == .timedOut)
        try write("late", to: root.appendingPathComponent("queued-new.txt"))
        gate.release.signal()
        try expect(completed.wait(timeout: .now() + 10) == .success)
        try expect(query(index, "^queued-new.txt", root).items.count == 1)
    }

    private static func cacheRetainsCrawlConfigurationWhenSettingsChangeBeforeWrite() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        try write("old snapshot", to: original.appendingPathComponent("original.txt"))
        try write("new scope", to: replacement.appendingPathComponent("replacement.txt"))
        let index = engine(original)
        index.usePersistentMMapCache = true
        // Deterministically change settings AFTER the crawl's freshness check,
        // before the encoder labels its payload. Never label A's entries as B.
        index.beforeCacheWriteHookForTesting = { [weak index] in
            index?.configuredRoots = [replacement.path]
        }
        index.startIndexing()
        for _ in 0..<1000 where index.isIndexing { try await Task.sleep(for: .milliseconds(10)) }
        try expect(!index.isIndexing)
        let data = try Data(contentsOf: URL(fileURLWithPath: index.cacheFilePath))
        try expect(index.configuredRoots == [replacement.path])
        try expect(index.decodeIndexCache(data) == nil)
        index.configuredRoots = [original.path]
        try expect(index.decodeIndexCache(data)?.map(\.name) == ["original.txt"])
    }

    private static func supplementalScopesSurviveFullRebuildInterleavings() async throws {
        let configured = try fixture()
        let supplemental = try fixture()
        defer {
            try? FileManager.default.removeItem(at: configured)
            try? FileManager.default.removeItem(at: supplemental)
        }
        try write("configured", to: configured.appendingPathComponent("configured.txt"))
        try write("supplemental", to: supplemental.appendingPathComponent("needle.txt"))
        func awaitFullCrawl(_ index: FSearchIndex) async throws {
            for _ in 0..<1000 where index.isIndexing { try await Task.sleep(for: .milliseconds(10)) }
            try expect(!index.isIndexing)
        }
        func assertBoth(_ index: FSearchIndex) throws {
            try expect(query(index, "^needle.txt", configured).items.map(\.path) == [supplemental.appendingPathComponent("needle.txt").path])
            try expect(query(index, "^configured.txt", configured).items.count == 1)
            try expect(index.indexedCount == 2)
        }

        // A full rebuild (also used after dropped events) must not erase an
        // already committed, explicitly registered out-of-root scope B.
        let ordinary = engine(configured)
        ordinary.usePersistentMMapCache = true
        let ready = DispatchSemaphore(value: 0)
        ordinary.enqueueDirectoryRefresh(supplemental.path) { ready.signal() }
        try expect(ready.wait(timeout: .now() + 5) == .success)
        ordinary.startIndexing()
        try await awaitFullCrawl(ordinary)
        try assertBoth(ordinary)
        let cacheData = try Data(contentsOf: URL(fileURLWithPath: ordinary.cacheFilePath))
        try expect(ordinary.decodeIndexCache(cacheData)?.map(\.name) == ["configured.txt"])

        // B registers and commits after startIndexing returns but before the
        // full worker obtains updateLock. A scope snapshot taken at start time
        // would miss B and overwrite its successful refresh.
        let beforeLock = engine(configured)
        let beforeGate = ReadGate()
        beforeLock.beforeCrawlLockHookForTesting = { beforeGate.beforeRead() }
        beforeLock.startIndexing()
        try expect(beforeGate.entered.wait(timeout: .now() + 5) == .success)
        defer { beforeGate.release.signal() }
        let beforeReady = DispatchSemaphore(value: 0)
        beforeLock.enqueueDirectoryRefresh(supplemental.path) { beforeReady.signal() }
        try expect(beforeReady.wait(timeout: .now() + 5) == .success)
        try expect(query(beforeLock, "^needle.txt", configured).items.count == 1)
        beforeGate.release.signal()
        try await awaitFullCrawl(beforeLock)
        try assertBoth(beforeLock)

        // B arrives while a full scan holds updateLock. Its queued pass runs
        // after installation, so the request is neither lost nor published early.
        let during = engine(configured)
        let duringGate = ReadGate()
        during.crawlProgressHookForTesting = { _ in duringGate.beforeRead() }
        during.startIndexing()
        try expect(duringGate.entered.wait(timeout: .now() + 5) == .success)
        defer { duringGate.release.signal() }
        let duringReady = DispatchSemaphore(value: 0)
        during.enqueueDirectoryRefresh(supplemental.path) { duringReady.signal() }
        try expect(duringReady.wait(timeout: .now()) == .timedOut)
        duringGate.release.signal()
        try expect(duringReady.wait(timeout: .now() + 10) == .success)
        try await awaitFullCrawl(during)
        try assertBoth(during)
    }

    private static func eventsDuringInitialCrawlAreReconciled() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("existing", to: root.appendingPathComponent("child/existing.txt"))
        let index = FSearchIndex(roots: [root.path], enableMonitoring: true)
        index.usePersistentMMapCache = false
        index.skipHeavyDevDirs = false
        let gate = ReadGate()
        index.crawlProgressHookForTesting = { _ in gate.beforeRead() }
        index.startIndexing()
        try expect(gate.entered.wait(timeout: .now() + 5) == .success)
        // The root directory has already been read but its child has not. This
        // file is absent from the eventual crawl snapshot and needs FSEvents.
        try write("late", to: root.appendingPathComponent("late-during-crawl.txt"))
        gate.release.signal()
        var observed = false
        for _ in 0..<1000 {
            if !index.isIndexing && query(index, "^late-during-crawl.txt", root).items.count == 1 {
                observed = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(observed)
        // Leave the hook installed until the engine is destroyed; never mutate a
        // callback while the watcher might trigger another background rebuild.
    }
    #endif
}
