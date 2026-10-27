import Foundation

struct IndexingPreferencesLifecycleRegressionTests {
    private final class Events: @unchecked Sendable {
        let lock = NSLock()
        private var events: [IndexingLifecycleEvent] = []
        let idle = DispatchSemaphore(value: 0)
        func append(_ event: IndexingLifecycleEvent) {
            lock.lock(); events.append(event); lock.unlock()
            if !event.isIndexing && event.generation > 0 { idle.signal() }
        }
        var snapshot: [IndexingLifecycleEvent] {
            lock.lock(); defer { lock.unlock() }; return events
        }
    }
    private final class PassGate: @unchecked Sendable {
        let lock = NSLock()
        var passes = 0
        let first = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        func enter() {
            lock.lock(); passes += 1; let pass = passes; lock.unlock()
            if pass == 1 { first.signal(); _ = releaseFirst.wait(timeout: .now() + 10) }
            if pass == 2 { second.signal(); _ = releaseSecond.wait(timeout: .now() + 10) }
        }
    }

    static func runAll() throws {
        #if BURROW_TESTING
        try preferencesRoundTripAndFailClosed()
        try failedWritesKeepConfigurationAndOriginal()
        try restoredCompositionVisitsOnlySavedRoots()
        try cacheDisableAuthorizationBoundary()
        try queuedReplacementHasOneBusyInterval()
        try cacheSnapshotDoesNotFinishLifecycle()
        print("PASS indexing preference restoration, fail-closed repair and generation lifecycle regressions")
        #endif
    }

    private static func preferencesRoundTripAndFailClosed() throws {
        let suite = "bf-indexing-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IndexingPreferences(defaults: defaults)
        let fallback = IndexingConfiguration(roots: ["/absent-default"], skippedDirectoryNames: ["default"],
            skipHeavyDevDirs: true, usePersistentMMapCache: true)
        guard case .configuration(let first) = store.load(defaultConfiguration: fallback) else {
            throw RegressionFailure(description: "Absent settings must use supplied first-run defaults")
        }
        try expect(first == fallback && defaults.object(forKey: IndexingPreferences.key) == nil)
        let saved = IndexingConfiguration(roots: ["/offline-volume/retained"], skippedDirectoryNames: ["custom"],
            skipHeavyDevDirs: false, usePersistentMMapCache: false)
        try store.save(saved)
        let engine = FSearchIndex(preferences: IndexingPreferences(defaults: defaults),
            defaultConfiguration: fallback, enableMonitoring: false)
        try expect(engine.configuredRoots == saved.roots)
        try expect(engine.skippedDirectoryNames == saved.skippedDirectoryNames)
        try expect(!engine.skipHeavyDevDirs && !engine.usePersistentMMapCache && !engine.isIndexing)
        let beforeCancel = defaults.data(forKey: IndexingPreferences.key)
        _ = store.load(defaultConfiguration: fallback) // opening/cancelling is read-only
        try expect(defaults.data(forKey: IndexingPreferences.key) == beforeCancel)
        try store.save(.disabled)
        let empty = FSearchIndex(preferences: store, defaultConfiguration: fallback, enableMonitoring: false)
        try expect(empty.configuredRoots.isEmpty && !empty.usePersistentMMapCache)
        let emptyDone = Events(), unexpectedRoots = DispatchSemaphore(value: 0)
        empty.crawlRootsHookForTesting = { if !$0.isEmpty { unexpectedRoots.signal() } }
        empty.onIndexingLifecycle = { emptyDone.append($0) }
        empty.startIndexing()
        try expect(emptyDone.idle.wait(timeout: .now() + 5) == .success)
        try expect(empty.indexedCount == 0 && empty.configuredRoots.isEmpty)
        try expect(unexpectedRoots.wait(timeout: .now()) == .timedOut)

        let future = Data(#"{"version":999,"configuration":{"roots":[],"skippedDirectoryNames":[],"skipHeavyDevDirs":true,"usePersistentMMapCache":false}}"#.utf8)
        let invalid = Data(#"{"version":1,"configuration":{"roots":["relative"],"skippedDirectoryNames":[],"skipHeavyDevDirs":true,"usePersistentMMapCache":true}}"#.utf8)
        for raw in [Data("broken".utf8), future, invalid, "wrong type", Data(repeating: 32, count: 1_048_577)] as [Any] {
            defaults.set(raw, forKey: IndexingPreferences.key)
            let preserved = defaults.object(forKey: IndexingPreferences.key) as! NSObject
            let blocked = FSearchIndex(preferences: store, defaultConfiguration: fallback, enableMonitoring: false)
            let entered = DispatchSemaphore(value: 0)
            blocked.beforeCrawlLockHookForTesting = { entered.signal() }
            blocked.startIndexing()
            try expect(blocked.indexingPreferencesNotice != nil && !blocked.isIndexing)
            try expect(blocked.configuredRoots.isEmpty && !blocked.usePersistentMMapCache)
            try expect(entered.wait(timeout: .now()) == .timedOut)
            do { try store.save(saved); throw RegressionFailure(description: "Implicit repair accepted") }
            catch IndexingPreferences.SaveError.repairRequired { }
            try expect(preserved.isEqual(defaults.object(forKey: IndexingPreferences.key)))
            // Explicit fixture construction ignores even corrupt application preferences.
            let fixture = FSearchIndex(roots: ["/explicit-fixture"], enableMonitoring: false)
            try expect(fixture.configuredRoots == ["/explicit-fixture"] && !fixture.usePersistentMMapCache)
            try store.save(saved, explicitlyRepair: true)
            try expect(defaults.dictionaryRepresentation().contains { key, value in
                key.hasPrefix(IndexingPreferences.key + ".preserved.") && preserved.isEqual(value)
            })
        }
    }

    private final class FaultStorage: IndexingPreferencesStorage {
        var values: [String: Any] = [:]
        var rejectBackups = false
        var rejectConfiguration = false
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) {
            if rejectBackups && key.hasPrefix(IndexingPreferences.key + ".preserved.") { return }
            if rejectConfiguration && key == IndexingPreferences.key { return }
            values[key] = value
        }
    }

    private static func failedWritesKeepConfigurationAndOriginal() throws {
        let raw = Data("damaged original".utf8)
        let storage = FaultStorage(), events = Events()
        storage.values[IndexingPreferences.key] = raw
        let store = IndexingPreferences(defaults: storage)
        let blocked = FSearchIndex(preferences: store, enableMonitoring: false)
        blocked.onIndexingLifecycle = { events.append($0) }
        storage.rejectBackups = true
        do {
            try blocked.saveConfigurationAndRebuild(.disabled, explicitlyRepair: true)
            throw RegressionFailure(description: "Failed backup allowed replacement")
        } catch IndexingPreferences.SaveError.verificationFailed { }
        try expect(storage.values[IndexingPreferences.key] as? Data == raw)
        try expect(blocked.indexingPreferencesNotice != nil && !blocked.isIndexing)
        try expect(events.snapshot.allSatisfy { $0.generation == 0 })
        storage.rejectBackups = false
        try store.save(.disabled, explicitlyRepair: true)
        let engine = FSearchIndex(preferences: store, enableMonitoring: false)
        let original = storage.values[IndexingPreferences.key] as? Data
        storage.rejectConfiguration = true
        let replacement = IndexingConfiguration(roots: ["/not-applied"], skippedDirectoryNames: [],
            skipHeavyDevDirs: false, usePersistentMMapCache: true)
        do {
            try engine.saveConfigurationAndRebuild(replacement)
            throw RegressionFailure(description: "Failed settings write applied configuration")
        } catch IndexingPreferences.SaveError.verificationFailed { }
        try expect(engine.configuredRoots.isEmpty && !engine.usePersistentMMapCache && !engine.isIndexing)
        try expect(storage.values[IndexingPreferences.key] as? Data == original)
        storage.rejectConfiguration = false
        storage.values[IndexingPreferences.key] = raw
        do {
            try engine.saveConfigurationAndRebuild(replacement)
            throw RegressionFailure(description: "Runtime corruption was silently replaced")
        } catch IndexingPreferences.SaveError.repairRequired { }
        try expect(engine.indexingPreferencesNotice != nil && engine.configuredRoots.isEmpty)
        try expect(storage.values[IndexingPreferences.key] as? Data == raw)
        let oversized = IndexingConfiguration(roots: Array(repeating: "/x", count: 1025),
            skippedDirectoryNames: [], skipHeavyDevDirs: true, usePersistentMMapCache: false)
        do { try store.save(oversized, explicitlyRepair: true); throw RegressionFailure(description: "Unbounded roots accepted") }
        catch IndexingPreferences.SaveError.invalidConfiguration { }
        try expect(storage.values[IndexingPreferences.key] as? Data == raw)
    }

    private static func restoredCompositionVisitsOnlySavedRoots() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("bf-restored-\(UUID())")
        let removed = fixture.appendingPathComponent("removed"), kept = fixture.appendingPathComponent("kept")
        for dir in [removed, kept] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data("removed".utf8).write(to: removed.appendingPathComponent("removed.txt"))
        try Data("kept".utf8).write(to: kept.appendingPathComponent("kept.txt"))
        let suite = "bf-restored-settings-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = IndexingConfiguration(roots: [kept.path], skippedDirectoryNames: [],
            skipHeavyDevDirs: false, usePersistentMMapCache: false)
        try IndexingPreferences(defaults: defaults).save(config)
        // This is exactly the injected constructor used by production shared composition.
        let index = FSearchIndex(preferences: IndexingPreferences(defaults: defaults),
            defaultConfiguration: IndexingConfiguration(roots: [removed.path], skippedDirectoryNames: [],
                skipHeavyDevDirs: true, usePersistentMMapCache: true), enableMonitoring: false)
        let events = Events(), badRoot = DispatchSemaphore(value: 0), visited = DispatchSemaphore(value: 0)
        index.onIndexingLifecycle = { events.append($0) }
        index.crawlRootsHookForTesting = { roots in
            if roots != [kept.path] { badRoot.signal() }
            visited.signal()
        }
        index.startIndexing()
        try expect(events.idle.wait(timeout: .now() + 5) == .success)
        try expect(visited.wait(timeout: .now()) == .success && badRoot.wait(timeout: .now()) == .timedOut)
        try expect(index.indexedCount == 1 && index.configuredRoots == [kept.path])
        let found = index.search(rawQuery: "removed", scope: .wholeIndex, scopeDirectory: fixture.path,
            includeHidden: true, fuzzyEnabled: false)
        try expect(found.items.isEmpty)
    }

    private static func cacheDisableAuthorizationBoundary() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("bf-cache-off-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data("fixture".utf8).write(to: fixture.appendingPathComponent("file.txt"))
        for disableBeforeAuthorization in [true, false] {
            let suite = "bf-cache-off-settings-\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let config = IndexingConfiguration(roots: [fixture.path], skippedDirectoryNames: [],
                skipHeavyDevDirs: false, usePersistentMMapCache: true)
            let store = IndexingPreferences(defaults: defaults)
            try store.save(config)
            let index = FSearchIndex(preferences: store, enableMonitoring: false)
            let path = URL(fileURLWithPath: index.cacheFilePath), previous = try? Data(contentsOf: path)
            try? FileManager.default.removeItem(at: path)
            defer {
                if let previous { try? previous.write(to: path) }
                else { try? FileManager.default.removeItem(at: path) }
            }
            let gate = PassGate(), events = Events()
            if disableBeforeAuthorization { index.beforeCacheWriteHookForTesting = { gate.enter() } }
            else { index.afterCacheAuthorizationHookForTesting = { gate.enter() } }
            index.onIndexingLifecycle = { events.append($0) }
            defer { gate.releaseFirst.signal(); gate.releaseSecond.signal() }
            index.startIndexing()
            try expect(gate.first.wait(timeout: .now() + 5) == .success)
            try index.saveConfigurationAndRebuild(.disabled)
            gate.releaseFirst.signal()
            try expect(events.idle.wait(timeout: .now() + 5) == .success)
            try expect(!index.usePersistentMMapCache)
            try expect(FileManager.default.fileExists(atPath: path.path) == !disableBeforeAuthorization)
            let restored = FSearchIndex(preferences: store, enableMonitoring: false)
            try expect(!restored.usePersistentMMapCache && restored.configuredRoots.isEmpty)
        }
    }

    private static func queuedReplacementHasOneBusyInterval() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("bf-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data("only old".utf8).write(to: fixture.appendingPathComponent("old.txt"))
        let index = FSearchIndex(roots: [fixture.path], enableMonitoring: false)
        let events = Events(), gate = PassGate()
        index.onIndexingLifecycle = { events.append($0) }
        index.beforeCrawlLockHookForTesting = { gate.enter() }
        defer { gate.releaseFirst.signal(); gate.releaseSecond.signal() }
        index.startIndexing()
        try expect(gate.first.wait(timeout: .now() + 5) == .success)
        try index.saveConfigurationAndRebuild(.disabled)
        gate.releaseFirst.signal()
        try expect(gate.second.wait(timeout: .now() + 5) == .success)
        try expect(index.isIndexing)
        let inFlight = events.snapshot.filter { $0.generation > 0 }
        try expect(!inFlight.isEmpty && inFlight.allSatisfy(\.isIndexing))
        gate.releaseSecond.signal()
        try expect(events.idle.wait(timeout: .now() + 5) == .success)
        try expect(!index.isIndexing && index.indexedCount == 0 && index.configuredRoots.isEmpty)
        let all = events.snapshot
        try expect(all.filter { !$0.isIndexing && $0.generation > 0 }.count == 1)
        var ui = IndexingLifecycleState()
        for event in all { ui.apply(event) }
        try expect(!ui.isIndexing)
        // Delayed older busy/idle delivery must not overwrite the newest state.
        for event in all.reversed() { ui.apply(event) }
        try expect(!ui.isIndexing)
        if let oldIdle = all.first, let busy = inFlight.last {
            var busyUI = IndexingLifecycleState()
            busyUI.apply(busy); busyUI.apply(oldIdle)
            try expect(busyUI.isIndexing)
        }
    }

    private static func cacheSnapshotDoesNotFinishLifecycle() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("bf-cache-life-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data("cache".utf8).write(to: fixture.appendingPathComponent("cached.txt"))
        let index = FSearchIndex(roots: [fixture.path], enableMonitoring: false)
        index.usePersistentMMapCache = true
        let path = URL(fileURLWithPath: index.cacheFilePath)
        let previous = try? Data(contentsOf: path)
        defer {
            if let previous { try? previous.write(to: path) }
            else { try? FileManager.default.removeItem(at: path) }
        }
        let entries = BulkCrawler.crawlTreeResult(roots: [fixture.path], skipHeavyDevDirs: true).entries
        try index.encodeIndexCache(entries).write(to: path)
        let events = Events()
        let cached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        index.onIndexingLifecycle = { events.append($0) }
        index.onIndexUpdated = { _, duration in
            if duration == 0 { cached.signal(); _ = release.wait(timeout: .now() + 10) }
        }
        index.startIndexing()
        try expect(cached.wait(timeout: .now() + 5) == .success)
        try expect(index.loadedFromMMapCache && index.indexedCount == 1 && index.isIndexing)
        var ui = IndexingLifecycleState()
        events.snapshot.forEach { ui.apply($0) }
        try expect(ui.isIndexing)
        release.signal()
        try expect(events.idle.wait(timeout: .now() + 5) == .success)
        events.snapshot.forEach { ui.apply($0) }
        try expect(!ui.isIndexing && !index.isIndexing)
    }
}
