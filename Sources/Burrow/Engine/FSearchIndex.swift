import Foundation
import CoreServices
import Darwin

public struct FSearchResultBundle: Sendable {
    public let items: [FileItem]
    public let elapsedMilliseconds: Double
    public let totalIndexedCount: Int
    public let backendName: String
    public let isPartial: Bool
    public let diagnostic: String?

    public init(items: [FileItem], elapsedMilliseconds: Double, totalIndexedCount: Int,
                backendName: String, isPartial: Bool = false, diagnostic: String? = nil) {
        self.items = items
        self.elapsedMilliseconds = elapsedMilliseconds
        self.totalIndexedCount = totalIndexedCount
        self.backendName = backendName
        self.isPartial = isPartial
        self.diagnostic = diagnostic
    }
}

/// High-performance fsearch-compatible search & indexing engine with mmap persistence, trigram Bloom filters & FSEvents
public final class FSearchIndex: @unchecked Sendable {
    public static let shared: FSearchIndex = {
        #if BURROW_TESTING
        return FSearchIndex()
        #else
        return FSearchIndex(preferences: IndexingPreferences(defaults: UserDefaults.standard))
        #endif
    }()
    private var preferences: IndexingPreferences?
    private var configurationBlocked = false
    private var preferencesNeedRepair = false
    public var indexingPreferencesNotice: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard preferencesNeedRepair else { return nil }
        return configurationBlocked
            ? "Nie można odczytać ustawień indeksu. Automatyczne indeksowanie i zapis są wstrzymane. Napraw jawnie ustawienia poniżej; oryginał zostanie zachowany."
            : "Nie można odczytać zapisanych ustawień indeksu. Zachowano bieżącą konfigurację. Napraw jawnie ustawienia poniżej; oryginał zostanie zachowany."
    }
    public convenience init(preferences: IndexingPreferences, defaultConfiguration: IndexingConfiguration? = nil,
                            enableMonitoring: Bool = true) {
        self.init(roots: [], enableMonitoring: enableMonitoring)
        self.preferences = preferences
        switch preferences.load(defaultConfiguration: defaultConfiguration ?? Self.applicationDefaultConfiguration()) {
        case .configuration(let configuration): applyConfiguration(configuration)
        case .blocked: configurationBlocked = true; preferencesNeedRepair = true; applyConfiguration(.disabled)
        }
    }
    private static func applicationDefaultConfiguration() -> IndexingConfiguration {
        #if BURROW_TESTING
        return .disabled
        #else
        let home = NSHomeDirectory()
        return IndexingConfiguration(roots: ["\(home)/Desktop", "\(home)/Documents", "\(home)/Downloads",
            "\(home)/dev", "\(home)/Projects", "\(home)/Developer", "/Applications"].filter { FileManager.default.fileExists(atPath: $0) },
            skippedDirectoryNames: BulkCrawler.defaultSkippedDirectoryNames,
            skipHeavyDevDirs: true, usePersistentMMapCache: true)
        #endif
    }
    private func applyConfiguration(_ configuration: IndexingConfiguration) {
        _configuredRoots = configuration.roots
        _skippedDirectoryNames = configuration.skippedDirectoryNames
        _skipHeavyDevDirs = configuration.skipHeavyDevDirs
        _usePersistentMMapCache = configuration.usePersistentMMapCache
    }
    public func saveConfigurationAndRebuild(_ configuration: IndexingConfiguration,
                                            explicitlyRepair: Bool = false) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard configuration.isValid else { throw IndexingPreferences.SaveError.invalidConfiguration }
        do {
            try preferences?.save(configuration, explicitlyRepair: explicitlyRepair)
        } catch IndexingPreferences.SaveError.repairRequired {
            preferencesNeedRepair = true
            throw IndexingPreferences.SaveError.repairRequired
        }
        applyConfiguration(configuration)
        configurationBlocked = false
        preferencesNeedRepair = false
        startIndexing()
    }
    private var lifecycleRevision: UInt64 = 0
    private var indexingGeneration: UInt64 = 0
    private var _onIndexingLifecycle: (@Sendable (IndexingLifecycleEvent) -> Void)?
    public var onIndexingLifecycle: (@Sendable (IndexingLifecycleEvent) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onIndexingLifecycle }
        set { stateLock.lock(); defer { stateLock.unlock() }; _onIndexingLifecycle = newValue; publishLifecycle() }
    }
    // Called while holding stateLock; callbacks must not synchronously wait on UI work.
    private func publishLifecycle() {
        lifecycleRevision &+= 1
        _onIndexingLifecycle?(IndexingLifecycleEvent(revision: lifecycleRevision,
            generation: indexingGeneration, isIndexing: _isIndexing))
    }

    private var entries: [IndexedFileEntry] = []
    private var dirToIndices: [String: [Int]] = [:]
    private var eventStream: FSEventStreamRef?
    private let fseventsQueue = DispatchQueue(label: "com.burrow.fsevents", qos: .utility)

    // Trigram Bloom filter cache for content grep: path -> (mtimeEpoch, 64-bit trigram mask)
    private let trigramLock = NSLock()
    private var trigramBloomCache: [String: (Int64, UInt64)] = [:]

    // Global git status map for `git:` queries: fullPath -> GitFileStatus
    private let gitLock = NSLock()
    private var globalGitStatusMap: [String: GitFileStatus] = [:]

    // Configuration/callback/status access is synchronized independently of entry snapshots.
    private let stateLock = NSRecursiveLock()
    // A refresh owns both its disk read and commit; older reads cannot publish last.
    private let updateLock = NSRecursiveLock()
    private let refreshQueue = DispatchQueue(label: "com.burrow.index-refresh", qos: .utility)
    // Owned by stateLock. Only one drain block is ever enqueued, so event storms
    // cannot grow an unbounded GCD backlog of recursive crawls.
    private var pendingRefreshPaths = Set<String>()
    private var pendingRefreshAllRoots = false
    private var pendingRefreshRebuild = false
    // Explicitly requested out-of-root scopes are retained separately from the
    // bounded event backlog. Their count follows distinct user-chosen scopes;
    // we never silently broaden them to '/' or discard their refresh requests.
    private var supplementalRefreshRoots = Set<String>()
    private var pendingRefreshCompletions: [@Sendable () -> Void] = []
    private var refreshWorkerScheduled = false
    private let pendingRefreshLimit = 128
    #if BURROW_TESTING
    var searchDateForTesting: Date?
    var refreshReadHookForTesting: (@Sendable (String) -> Void)?
    var crawlProgressHookForTesting: (@Sendable (Int) -> Void)?
    var beforeCrawlLockHookForTesting: (@Sendable () -> Void)?
    var crawlRootsHookForTesting: (@Sendable ([String]) -> Void)?
    var afterCacheAuthorizationHookForTesting: (@Sendable () -> Void)?
    var beforeCacheWriteHookForTesting: (@Sendable () -> Void)?
    var pendingRefreshPathCountForTesting: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return pendingRefreshPaths.count + (pendingRefreshAllRoots ? 1 : 0)
    }
    #endif
    private var indexIsPartial = true
    private let enableMonitoring: Bool
    private var _configuredRoots: [String] = []
    public var configuredRoots: [String] {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _configuredRoots }
        set { stateLock.lock(); defer { stateLock.unlock() }; _configuredRoots = newValue }
    }
    private var _skippedDirectoryNames: Set<String> = []
    public var skippedDirectoryNames: Set<String> {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _skippedDirectoryNames }
        set { stateLock.lock(); defer { stateLock.unlock() }; _skippedDirectoryNames = newValue }
    }
    private var _skipHeavyDevDirs: Bool = true
    public var skipHeavyDevDirs: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _skipHeavyDevDirs }
        set { stateLock.lock(); defer { stateLock.unlock() }; _skipHeavyDevDirs = newValue }
    }
    private var _usePersistentMMapCache: Bool = true
    public var usePersistentMMapCache: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _usePersistentMMapCache }
        set { stateLock.lock(); defer { stateLock.unlock() }; _usePersistentMMapCache = newValue }
    }
    private var pendingReindex = false
    private var _isIndexing: Bool = false
    public private(set) var isIndexing: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isIndexing }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isIndexing = newValue }
    }
    private var _indexedCount: Int = 0
    public private(set) var indexedCount: Int {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _indexedCount }
        set { stateLock.lock(); defer { stateLock.unlock() }; _indexedCount = newValue }
    }
    private var _lastCrawlDurationMs: Double = 0
    public private(set) var lastCrawlDurationMs: Double {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _lastCrawlDurationMs }
        set { stateLock.lock(); defer { stateLock.unlock() }; _lastCrawlDurationMs = newValue }
    }
    private var _loadedFromMMapCache: Bool = false
    public private(set) var loadedFromMMapCache: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _loadedFromMMapCache }
        set { stateLock.lock(); defer { stateLock.unlock() }; _loadedFromMMapCache = newValue }
    }
    private var _externalFSearchAvailable: Bool = false
    public private(set) var externalFSearchAvailable: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _externalFSearchAvailable }
        set { stateLock.lock(); defer { stateLock.unlock() }; _externalFSearchAvailable = newValue }
    }
    private var _preferExternalDaemonIfAvailable: Bool = false
    public var preferExternalDaemonIfAvailable: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _preferExternalDaemonIfAvailable }
        set { stateLock.lock(); defer { stateLock.unlock() }; _preferExternalDaemonIfAvailable = newValue }
    }
    private var _onIndexUpdated: (@Sendable (Int, Double) -> Void)? = nil
    public var onIndexUpdated: (@Sendable (Int, Double) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onIndexUpdated }
        set { stateLock.lock(); defer { stateLock.unlock() }; _onIndexUpdated = newValue }
    }
    private var _onDirectoryChangedOnDisk: (@Sendable (Set<String>) -> Void)? = nil
    public var onDirectoryChangedOnDisk: (@Sendable (Set<String>) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onDirectoryChangedOnDisk }
        set { stateLock.lock(); defer { stateLock.unlock() }; _onDirectoryChangedOnDisk = newValue }
    }

    private var lockPtr: UnsafeMutablePointer<pthread_rwlock_t>

    public var cacheFilePath: String { validatedCacheFilePath() ?? "Cache unavailable" }

    private func validatedCacheFilePath() -> String? {
        let fm = FileManager.default
        #if BURROW_TESTING
        guard let testRoot = ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"] else { return nil }
        let caches = (testRoot as NSString).appendingPathComponent("index-cache")
        let fallback = caches
        #else
        let caches = ("~/Library/Caches/Burrow" as NSString).expandingTildeInPath
        let fallback = fm.temporaryDirectory.appendingPathComponent("Burrow-\(getuid())").path
        #endif
        for directory in [caches, fallback] {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            var info = stat()
            if lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
               chmod(directory, 0o700) == 0 {
                return directory + "/fsearch_index.bin"
            }
        }
        // No shared, predictable /tmp file fallback. An unusable private location
        // simply disables this best-effort cache.
        return nil
    }

    public init(roots: [String]? = nil, enableMonitoring: Bool = true) {
        #if BURROW_TESTING
        self.enableMonitoring = roots == nil ? false : enableMonitoring
        #else
        self.enableMonitoring = enableMonitoring
        #endif
        lockPtr = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        pthread_rwlock_init(lockPtr, nil)
        #if BURROW_TESTING
        self.configuredRoots = roots ?? ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"].map { [$0] } ?? []
        self.usePersistentMMapCache = false
        #else
        let home = NSHomeDirectory()
        self.configuredRoots = roots ?? ["\(home)/Desktop", "\(home)/Documents", "\(home)/Downloads",
            "\(home)/dev", "\(home)/Projects", "\(home)/Developer", "/Applications"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        #endif
        self.skippedDirectoryNames = BulkCrawler.defaultSkippedDirectoryNames
        checkExternalFSearchDaemon()
    }

    deinit {
        stopFSEvents()
        pthread_rwlock_destroy(lockPtr)
        lockPtr.deallocate()
    }

    public var trigramCacheCount: Int {
        trigramLock.lock()
        defer { trigramLock.unlock() }
        return trigramBloomCache.count
    }

    public func checkExternalFSearchDaemon() {
        let socketPath = ("~/Library/Application Support/FSearch/fsearch.sock" as NSString).expandingTildeInPath
        let binPath1 = ("~/.local/bin/fsearch" as NSString).expandingTildeInPath
        let binPath2 = "/opt/homebrew/bin/fsearch"
        let fm = FileManager.default
        externalFSearchAvailable = fm.fileExists(atPath: socketPath) ||
                                   fm.isExecutableFile(atPath: binPath1) ||
                                   fm.isExecutableFile(atPath: binPath2)
    }

    public func recordGitStatuses(_ map: [String: GitFileStatus], repositoryRoot: String) {
        let root = URL(fileURLWithPath: repositoryRoot).standardizedFileURL.path
        gitLock.lock()
        globalGitStatusMap = globalGitStatusMap.filter { !Self.isWithin($0.key, root: root) }
        for (path, status) in map where Self.isWithin(path, root: root) { globalGitStatusMap[path] = status }
        gitLock.unlock()
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private func installEntries(_ list: [IndexedFileEntry], isPartial: Bool) {
        var seen = Set<String>()
        let unique = list.filter { !$0.name.isEmpty && seen.insert($0.fullPath).inserted }
        var map: [String: [Int]] = [:]
        for (index, item) in unique.enumerated() { map[item.parentPath, default: []].append(index) }
        pthread_rwlock_wrlock(lockPtr)
        entries = unique
        dirToIndices = map
        indexIsPartial = isPartial
        pthread_rwlock_unlock(lockPtr)
        indexedCount = unique.count
    }

    /// The watcher is active BEFORE reading the snapshot. Its serial callback
    /// waits for updateLock, then reconciles changes that arrived during the crawl.
    public func startIndexing(roots: [String]? = nil) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !configurationBlocked else { publishLifecycle(); return }
        if let roots = roots { _configuredRoots = roots }
        indexingGeneration &+= 1
        if _isIndexing { pendingReindex = true; publishLifecycle(); return }
        _isIndexing = true
        publishLifecycle()
        launchCrawlLocked()
    }

    /// Reserves the next pass before releasing stateLock; no false idle gap.
    private func launchCrawlLocked() {
        let targetRoots = _configuredRoots
        let skipHeavy = _skipHeavyDevDirs
        let skippedSet = _skippedDirectoryNames
        let persist = _usePersistentMMapCache
        let configuration = cacheConfigurationData()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            #if BURROW_TESTING
            self.beforeCrawlLockHookForTesting?()
            #endif
            self.updateLock.lock()
            // Watcher ownership is serialized with crawl publication, never while holding stateLock.
            let watcherStarted = self.startFSEvents(watching: targetRoots)
            // Capture explicit scopes only after obtaining the publication lock:
            // a queued refresh may have registered and committed one while this
            // full crawl was waiting to start. Install one combined snapshot.
            self.stateLock.lock()
            let supplementalRoots = Array(self.supplementalRefreshRoots)
            self.stateLock.unlock()
            let crawlRoots = targetRoots + supplementalRoots
            let normalizedConfiguredRoots = targetRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            let unmonitoredSupplementalScope = self.enableMonitoring && supplementalRoots.contains { root in
                !normalizedConfiguredRoots.contains { Self.isWithin(root, root: $0) }
            }
            let t0 = DispatchTime.now().uptimeNanoseconds
            pthread_rwlock_rdlock(self.lockPtr)
            let empty = self.entries.isEmpty
            pthread_rwlock_unlock(self.lockPtr)
            if persist && empty, let cached = self.loadIndexFromDiskMMapCache() {
                self.installEntries(cached, isPartial: true)
                self.loadedFromMMapCache = true
                self.onIndexUpdated?(cached.count, 0)
            }
            #if BURROW_TESTING
            self.crawlRootsHookForTesting?(crawlRoots)
            #endif
            let result = BulkCrawler.crawlTreeResult(roots: crawlRoots, skipHeavyDevDirs: skipHeavy,
                customSkippedDirs: skippedSet, maxEntries: 500_000, progress: { count in
                    #if BURROW_TESTING
                    self.crawlProgressHookForTesting?(count)
                    #endif
                })
            let configurationChanged = configuration != self.cacheConfigurationData()
            self.installEntries(result.entries, isPartial: !result.isComplete || configurationChanged || !watcherStarted || unmonitoredSupplementalScope)
            self.loadedFromMMapCache = false
            self.trigramLock.lock()
            self.trigramBloomCache.removeAll(keepingCapacity: true)
            self.trigramLock.unlock()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            self.lastCrawlDurationMs = ms
            // Session-only supplemental scopes are not part of the cache's
            // configured-root signature. Persist only the configured subset.
            if persist && result.isComplete && !configurationChanged {
                let configuredEntries = result.entries.filter { entry in
                    normalizedConfiguredRoots.contains { Self.isWithin(entry.fullPath, root: $0) }
                }
                self.saveIndexToDiskMMapCache(configuredEntries, configuration: configuration)
            }
            self.stateLock.lock()
            let repeatCrawl = self.pendingReindex || configurationChanged
            self.pendingReindex = false
            self.updateLock.unlock()
            if repeatCrawl {
                self.launchCrawlLocked()
            } else {
                self._isIndexing = false
                self.publishLifecycle()
            }
            self.stateLock.unlock()
            self.onIndexUpdated?(self.indexedCount, ms)
        }
    }

    // MARK: - Persistent Binary MMap Index Serialization

    private func saveIndexToDiskMMapCache(_ list: [IndexedFileEntry], configuration: Data) {
        guard let path = validatedCacheFilePath() else { return }
        #if BURROW_TESTING
        beforeCacheWriteHookForTesting?()
        #endif
        // The label belongs to the crawl that produced these entries. Settings
        // may change after the earlier freshness check, even during encoding.
        let data = encodeIndexCache(list, configuration: configuration)
        stateLock.lock()
        let mayWrite = _usePersistentMMapCache && !configurationBlocked
        stateLock.unlock()
        guard mayWrite else { return }
        #if BURROW_TESTING
        afterCacheAuthorizationHookForTesting?()
        #endif
        // No state/UI lock across filesystem IO. An already admitted write may
        // finish after Save turns caching off; no subsequent write is admitted.
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        _ = chmod(path, 0o600)
    }

    // Shared with the native regression harness; production persistence uses
    // these exact all-or-nothing codec paths, not a duplicated test model.
    func encodeIndexCache(_ list: [IndexedFileEntry], configuration: Data? = nil) -> Data {
        var data = Data()
        data.reserveCapacity(list.count * 64)

        let serializable = list.filter {
            !$0.name.isEmpty && $0.name.utf8.count < 65535 && $0.parentPath.utf8.count < 65535 && $0.ext.utf8.count < 255
        }
        // Header: magic, version, count, context length, configuration context.
        let magic: [UInt8] = [0x46, 0x53, 0x52, 0x43]
        data.append(contentsOf: magic)
        var version: UInt32 = 2
        var count = UInt32(serializable.count)
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        let context = configuration ?? cacheConfigurationData()
        var contextLength = UInt32(context.count)
        withUnsafeBytes(of: &contextLength) { data.append(contentsOf: $0) }
        data.append(context)

        for item in serializable {
            let nameUTF8 = Array(item.name.utf8)
            let parentUTF8 = Array(item.parentPath.utf8)
            let extUTF8 = Array(item.ext.utf8)
            guard nameUTF8.count < 65535, parentUTF8.count < 65535, extUTF8.count < 255 else { continue }

            var nameLen = UInt16(nameUTF8.count)
            var parentLen = UInt16(parentUTF8.count)
            let extLen = UInt8(extUTF8.count)
            let flags: UInt8 = (item.isDirectory ? 1 : 0) | (item.isSymlink ? 2 : 0) | (item.isHidden ? 4 : 0)
            var mask = item.charMask
            var size = item.size
            var mtime = item.mtimeEpoch
            var nanoseconds = item.mtimeNanoseconds

            withUnsafeBytes(of: &nameLen) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &parentLen) { data.append(contentsOf: $0) }
            data.append(extLen)
            data.append(flags)
            withUnsafeBytes(of: &mask) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &mtime) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &nanoseconds) { data.append(contentsOf: $0) }
            data.append(contentsOf: nameUTF8)
            data.append(contentsOf: parentUTF8)
            data.append(contentsOf: extUTF8)
        }

        return data
    }

    private func cacheConfigurationData() -> Data {
        stateLock.lock()
        defer { stateLock.unlock() }
        let config: [String: Any] = ["roots": _configuredRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.sorted(),
            "skipped": _skippedDirectoryNames.sorted(), "skipHeavy": _skipHeavyDevDirs]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data()
    }

    private func loadIndexFromDiskMMapCache() -> [IndexedFileEntry]? {
        guard let path = validatedCacheFilePath() else { return nil }
        let url = URL(fileURLWithPath: path)
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_size <= 512 * 1024 * 1024,
              let data = try? Data(contentsOf: url), data.count >= 16 else {
            return nil
        }

        return decodeIndexCache(data)
    }

    func decodeIndexCache(_ data: Data) -> [IndexedFileEntry]? {
        guard data.count >= 16 else { return nil }
        return data.withUnsafeBytes { rawBuf -> [IndexedFileEntry]? in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let totalBytes = rawBuf.count
            guard base[0] == 0x46, base[1] == 0x53, base[2] == 0x52, base[3] == 0x43 else { return nil }

            let version = rawBuf.baseAddress!.advanced(by: 4).loadUnaligned(as: UInt32.self)
            guard version == 2 else { return nil }
            let expectedCount = Int(rawBuf.baseAddress!.advanced(by: 8).loadUnaligned(as: UInt32.self))

            guard expectedCount <= 500_000 else { return nil }
            let contextLength = Int(rawBuf.baseAddress!.advanced(by: 12).loadUnaligned(as: UInt32.self))
            guard contextLength <= totalBytes - 16,
                  data.subdata(in: 16..<(16 + contextLength)) == cacheConfigurationData() else { return nil }
            var result: [IndexedFileEntry] = []
            result.reserveCapacity(min(expectedCount, 500_000))

            var offset = 16 + contextLength
            for _ in 0..<expectedCount {
                guard totalBytes - offset >= 38 else { return nil }
                let ptr = rawBuf.baseAddress!.advanced(by: offset)
                let nameLen = Int(ptr.loadUnaligned(as: UInt16.self))
                let parentLen = Int(ptr.advanced(by: 2).loadUnaligned(as: UInt16.self))
                let extLen = Int(base[offset + 4])
                let flags = base[offset + 5]
                // The name determines its mask; never trust cached rejection bits.
                let size = ptr.advanced(by: 14).loadUnaligned(as: Int64.self)
                let mtime = ptr.advanced(by: 22).loadUnaligned(as: Int64.self)
                let nanoseconds = ptr.advanced(by: 30).loadUnaligned(as: Int64.self)
                offset += 38
                guard nameLen > 0, parentLen > 0, flags & ~UInt8(7) == 0,
                      (0..<1_000_000_000).contains(nanoseconds),
                      nameLen + parentLen + extLen <= totalBytes - offset else { return nil }
                let nameSlice = UnsafeBufferPointer(start: base.advanced(by: offset), count: nameLen)
                guard let name = String(bytes: nameSlice, encoding: .utf8),
                      !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else { return nil }
                offset += nameLen

                let parentSlice = UnsafeBufferPointer(start: base.advanced(by: offset), count: parentLen)
                guard let parentPath = String(bytes: parentSlice, encoding: .utf8),
                      parentPath.hasPrefix("/"), !parentPath.contains("\0") else { return nil }
                offset += parentLen

                let extSlice = UnsafeBufferPointer(start: base.advanced(by: offset), count: extLen)
                guard let ext = String(bytes: extSlice, encoding: .utf8) else { return nil }
                offset += extLen

                let lowerBytes = Array(ParsedFSearchQuery.normalizedNameSearchText(name).utf8)
                result.append(IndexedFileEntry(
                    name: name,
                    lowerNameUTF8: lowerBytes,
                    parentPath: parentPath,
                    ext: ext,
                    charMask: ParsedFSearchQuery.computeAsciiBitmask(lowerBytes),
                    size: size,
                    mtimeEpoch: mtime,
                    isDirectory: (flags & 1) != 0,
                    isSymlink: (flags & 2) != 0,
                    isHidden: (flags & 4) != 0,
                    mtimeNanoseconds: nanoseconds
                ))
            }
            guard offset == totalBytes, result.count == expectedCount else { return nil }
            return result
        }
    }

    /// Navigation reconciles even previously indexed trees: supplemental/network
    /// roots may not have a reliable watcher. Unchanged scans publish no change.
    public func ensureDirectoryIndexed(_ dirPath: String) {
        enqueueDirectoryRefresh(dirPath)
    }

    /// UI-facing refresh. Never wait for a crawl or filesystem reads on the
    /// caller's actor. Completion runs on the serial utility queue after commit.
    public func enqueueDirectoryRefresh(_ dirPath: String, completion: (@Sendable () -> Void)? = nil) {
        let path = URL(fileURLWithPath: dirPath).standardizedFileURL.path
        stateLock.lock()
        let configured = _configuredRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if !configured.contains(where: { Self.isWithin(path, root: $0) }) &&
            !supplementalRefreshRoots.contains(where: { Self.isWithin(path, root: $0) }) {
            supplementalRefreshRoots = supplementalRefreshRoots.filter { !Self.isWithin($0, root: path) }
            supplementalRefreshRoots.insert(path)
        }
        if !pendingRefreshAllRoots && !pendingRefreshPaths.contains(where: { Self.isWithin(path, root: $0) }) {
            pendingRefreshPaths = pendingRefreshPaths.filter { !Self.isWithin($0, root: path) }
            pendingRefreshPaths.insert(path)
            if pendingRefreshPaths.count > pendingRefreshLimit {
                pendingRefreshPaths.removeAll(keepingCapacity: true)
                pendingRefreshAllRoots = true
            }
        }
        if let completion = completion { pendingRefreshCompletions.append(completion) }
        let schedule = !refreshWorkerScheduled
        refreshWorkerScheduled = true
        stateLock.unlock()
        if schedule {
            refreshQueue.async { [weak self] in self?.drainDirectoryRefreshes() }
        }
    }

    private func enqueueIndexRebuild() {
        stateLock.lock()
        pendingRefreshAllRoots = true
        pendingRefreshRebuild = true
        pendingRefreshPaths.removeAll(keepingCapacity: true)
        let schedule = !refreshWorkerScheduled
        refreshWorkerScheduled = true
        stateLock.unlock()
        if schedule { refreshQueue.async { [weak self] in self?.drainDirectoryRefreshes() } }
    }

    private func drainDirectoryRefreshes() {
        while true {
            stateLock.lock()
            guard pendingRefreshAllRoots || !pendingRefreshPaths.isEmpty else {
                refreshWorkerScheduled = false
                stateLock.unlock()
                return
            }
            let roots: Set<String>
            if pendingRefreshAllRoots {
                let requested = Set(_configuredRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
                    .union(supplementalRefreshRoots)
                roots = Set(requested.filter { root in
                    !requested.contains(where: { $0 != root && Self.isWithin(root, root: $0) })
                })
            } else {
                roots = pendingRefreshPaths
            }
            let completions = pendingRefreshCompletions
            let rebuild = pendingRefreshRebuild
            pendingRefreshPaths.removeAll(keepingCapacity: true)
            pendingRefreshCompletions.removeAll(keepingCapacity: true)
            pendingRefreshAllRoots = false
            pendingRefreshRebuild = false
            stateLock.unlock()
            // New requests stay in the pending set while this batch reads disk.
            // They are never swallowed by the currently running ancestor scan.
            pthread_rwlock_rdlock(lockPtr)
            let wasPartial = indexIsPartial
            pthread_rwlock_unlock(lockPtr)
            var changedDirectories = Set<String>()
            for root in roots.sorted() { changedDirectories.formUnion(refreshDirectoryInIndex(root)) }
            pthread_rwlock_rdlock(lockPtr)
            let isPartial = indexIsPartial
            pthread_rwlock_unlock(lockPtr)
            if !changedDirectories.isEmpty || wasPartial != isPartial {
                onIndexUpdated?(indexedCount, lastCrawlDurationMs)
            }
            if !changedDirectories.isEmpty { onDirectoryChangedOnDisk?(changedDirectories) }
            for completion in completions { completion() }
            // A dropped/root-change event also refreshes the watcher. This runs
            // outside its callback and shares the bounded/coalescing drain.
            if rebuild { startIndexing() }
        }
    }

    /// Synchronous background primitive. The lock owns read and publication, and
    /// reconciliation replaces the entire subtree, not just new child names:
    /// another directory tree can replace an existing path between events.
    @discardableResult
    public func refreshDirectoryInIndex(_ dirPath: String) -> Set<String> {
        updateLock.lock()
        defer { updateLock.unlock() }
        let normalized = URL(fileURLWithPath: dirPath).standardizedFileURL.path
        #if BURROW_TESTING
        refreshReadHookForTesting?(normalized)
        #endif
        // Probe the directory without retaining its children before the bounded
        // recursive read. A missing directory is a deletion, not an I/O failure.
        let probe = BulkCrawler.readDirectoryResult(at: normalized, maxEntries: 0)
        let missing = probe.errorCode == ENOENT || probe.errorCode == ENOTDIR
        pthread_rwlock_rdlock(lockPtr)
        let previous = entries
        var partial = indexIsPartial
        pthread_rwlock_unlock(lockPtr)
        if enableMonitoring && !configuredRoots.contains(where: {
            Self.isWithin(normalized, root: URL(fileURLWithPath: $0).standardizedFileURL.path)
        }) { partial = true }
        if let error = probe.errorCode, error != ENOENT && error != ENOTDIR {
            pthread_rwlock_wrlock(lockPtr); indexIsPartial = true; pthread_rwlock_unlock(lockPtr)
            return []
        }
        var replacement = previous.filter { entry in
            !Self.isWithin(entry.fullPath, root: normalized) || (!missing && entry.fullPath == normalized)
        }
        if !missing {
            let crawl = BulkCrawler.crawlTreeResult(roots: [normalized], skipHeavyDevDirs: skipHeavyDevDirs,
                customSkippedDirs: skippedDirectoryNames, maxEntries: max(0, 500_000 - replacement.count))
            replacement.append(contentsOf: crawl.entries)
            partial = partial || !crawl.isComplete
        }
        let changed = Self.changedDirectoryPaths(previous: previous, replacement: replacement)
        installEntries(replacement, isPartial: partial)
        trigramLock.lock()
        trigramBloomCache = trigramBloomCache.filter { !Self.isWithin($0.key, root: normalized) }
        trigramLock.unlock()
        return changed
    }

    /// Metadata reconciliation, not command execution, is evidence of disk changes.
    static func changedDirectoryPaths(previous: [IndexedFileEntry], replacement: [IndexedFileEntry]) -> Set<String> {
        struct Stamp: Equatable {
            let size: Int64; let seconds: Int64; let nanos: Int64
            let directory: Bool; let symlink: Bool; let hidden: Bool
        }
        func stamp(_ e: IndexedFileEntry) -> Stamp {
            Stamp(size: e.size, seconds: e.mtimeEpoch, nanos: e.mtimeNanoseconds,
                  directory: e.isDirectory, symlink: e.isSymlink, hidden: e.isHidden)
        }
        var old: [String: IndexedFileEntry] = [:]
        for entry in previous { old[entry.fullPath] = entry }
        var changed = Set<String>()
        for entry in replacement {
            if let before = old.removeValue(forKey: entry.fullPath), stamp(before) == stamp(entry) { continue }
            changed.insert(entry.parentPath)
        }
        for entry in old.values { changed.insert(entry.parentPath) }
        return changed
    }

    // MARK: - Sub-millisecond Search Execution

    public func search(
        rawQuery: String,
        scope: SearchScopeMode,
        scopeDirectory: String,
        includeHidden: Bool,
        fuzzyEnabled: Bool = true,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> FSearchResultBundle {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let parsed = ParsedFSearchQuery.parse(rawQuery, fuzzyEnabled: fuzzyEnabled)

        guard parsed.validationError == nil, parsed.hasFiltersOrTerms, !isCancelled() else {
            return FSearchResultBundle(
                items: [],
                elapsedMilliseconds: 0,
                totalIndexedCount: indexedCount,
                backendName: "fsearch-native",
                isPartial: isCancelled(),
                diagnostic: parsed.validationError ?? (isCancelled() ? "Search cancelled." : nil)
            )
        }

        if preferExternalDaemonIfAvailable && scope == .wholeIndex,
           let extItems = queryExternalFSearchSocket(rawQuery: rawQuery, limit: parsed.limit) {
            let t1 = DispatchTime.now().uptimeNanoseconds
            return FSearchResultBundle(
                items: extItems,
                elapsedMilliseconds: Double(t1 - t0) / 1_000_000.0,
                totalIndexedCount: indexedCount,
                backendName: "fsearch.sock"
            )
        }

        let normalizedScopeDir = scopeDirectory.count > 1 && scopeDirectory.hasSuffix("/")
            ? String(scopeDirectory.dropLast())
            : scopeDirectory

        let candidateEntries: [IndexedFileEntry]
        var partial = false
        var diagnostics: [String] = []
        switch scope {
        case .currentFolder:
            let read = BulkCrawler.readDirectoryResult(at: normalizedScopeDir, includeHidden: includeHidden,
                maxEntries: 500_000, isCancelled: isCancelled)
            candidateEntries = read.entries
            partial = !read.isComplete
        case .recursiveFolder:
            // A shallow index entry proves existence, not recursive coverage. A
            // fresh bounded scan also works for roots outside configured indexing.
            let crawl = BulkCrawler.crawlTreeResult(roots: [normalizedScopeDir],
                skipHeavyDevDirs: skipHeavyDevDirs, customSkippedDirs: skippedDirectoryNames,
                maxEntries: 500_000, includeHidden: includeHidden, isCancelled: isCancelled)
            candidateEntries = crawl.entries
            partial = !crawl.isComplete
        case .wholeIndex:
            pthread_rwlock_rdlock(lockPtr)
            candidateEntries = entries
            partial = indexIsPartial
            pthread_rwlock_unlock(lockPtr)
        }
        if partial { diagnostics.append("Partial search: some directories were skipped, unreadable, exceeded the scan limit, or could not be monitored.") }

        let totalCount = candidateEntries.count
        if totalCount == 0 {
            let t1 = DispatchTime.now().uptimeNanoseconds
            return FSearchResultBundle(
                items: [],
                elapsedMilliseconds: Double(t1 - t0) / 1_000_000.0,
                totalIndexedCount: indexedCount,
                backendName: "fsearch-native", isPartial: partial || isCancelled(),
                diagnostic: diagnostics.isEmpty ? nil : diagnostics.joined(separator: " ")
            )
        }

        let compiledRegex: NSRegularExpression?
        if let pattern = parsed.regexPattern {
            do { compiledRegex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }
            catch {
                return FSearchResultBundle(items: [], elapsedMilliseconds: 0, totalIndexedCount: indexedCount,
                    backendName: "fsearch-native", diagnostic: "Invalid regular expression: \(error.localizedDescription)")
            }
        } else {
            compiledRegex = nil
        }

        var gitSnapshot: [String: GitFileStatus] = [:]
        if parsed.gitFilter != nil {
            // Build this query from fresh repository snapshots only, never from
            // indefinitely accumulated statuses of unrelated/previous queries.
            var repositories = Set<String>()
            var checked = Set<String>()
            for entry in candidateEntries {
                if isCancelled() { break }
                var path = entry.parentPath
                while checked.insert(path).inserted {
                    if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
                        repositories.insert(path)
                        break
                    }
                    let parent = (path as NSString).deletingLastPathComponent
                    if parent == path || parent.isEmpty { break }
                    path = parent
                }
            }
            for root in repositories.sorted() {
                if isCancelled() { break }
                if let snapshot = FileOperationsManager.fetchGitStatusSnapshot(for: root) {
                    recordGitStatuses(snapshot.statuses, repositoryRoot: snapshot.repositoryRoot)
                    gitSnapshot.merge(snapshot.statuses) { _, fresh in fresh }
                } else {
                    partial = true
                    diagnostics.append("Git status could not be read for \(root).")
                }
            }
        }

        #if BURROW_TESTING
        let now = searchDateForTesting ?? Date()
        #else
        let now = Date()
        #endif
        let chunkSize = max(2048, (totalCount + 7) / 8)
        let numChunks = (totalCount + chunkSize - 1) / chunkSize

        struct ScoredCandidate: Sendable {
            let index: Int
            let score: Int
        }

        let chunkLock = NSLock()
        var allScored: [ScoredCandidate] = []
        allScored.reserveCapacity(min(parsed.limit * 2, 1024))

        DispatchQueue.concurrentPerform(iterations: numChunks) { chunkIdx in
            let start = chunkIdx * chunkSize
            let end = min(start + chunkSize, totalCount)
            var localMatches: [ScoredCandidate] = []

            for i in start..<end {
                if isCancelled() { break }
                let entry = candidateEntries[i]
                if entry.name.isEmpty { continue }
                if !includeHidden {
                    if entry.isHidden { continue }
                    // The whole index contains descendants of hidden directories
                    // too. A visible basename does not make its hidden ancestry
                    // visible. Local scopes deliberately treat their explicitly
                    // chosen directory as the browsing root instead.
                    if scope == .wholeIndex && entry.parentPath.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                        continue
                    }
                }

                if let score = Self.evaluateEntry(
                    entry,
                    query: parsed,
                    compiledRegex: compiledRegex,
                    gitStatusMap: gitSnapshot,
                    now: now
                ) {
                    localMatches.append(ScoredCandidate(index: i, score: score))
                }
            }

            if !localMatches.isEmpty {
                chunkLock.lock()
                allScored.append(contentsOf: localMatches)
                chunkLock.unlock()
            }
        }

        allScored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let left = candidateEntries[a.index]
            let right = candidateEntries[b.index]
            if left.mtimeEpoch != right.mtimeEpoch { return left.mtimeEpoch > right.mtimeEpoch }
            if left.mtimeNanoseconds != right.mtimeNanoseconds { return left.mtimeNanoseconds > right.mtimeNanoseconds }
            return left.fullPath < right.fullPath
        }

        let finalItems: [FileItem]
        if let grepPattern = parsed.grepPattern, !grepPattern.isEmpty {
            var matches: [FileItem] = []
            var skippedContentFiles = 0
            // Candidates are already ranked. Apply the limit to actual matches,
            // not to the first 1500 names, and stop without allocating a task/file.
            for candidate in allScored {
                if isCancelled() || matches.count >= parsed.limit { break }
                let entry = candidateEntries[candidate.index]
                if entry.isDirectory { continue }
                var skipped = false
                if let snippet = grepFileContentWithTrigramCache(path: entry.fullPath,
                    mtimeEpoch: entry.mtimeEpoch, pattern: grepPattern,
                    needleTrigramMask: ParsedFSearchQuery.computeTrigramBloomMask(Array(grepPattern.utf8)), isCancelled: isCancelled,
                    wasSkipped: &skipped) {
                    matches.append(entry.toFileItem(grepMatch: snippet,
                        gitStatus: gitSnapshot[entry.fullPath], score: candidate.score + 100))
                }
                if skipped { skippedContentFiles += 1 }
            }
            if skippedContentFiles > 0 {
                partial = true
                diagnostics.append("Content was not searched in \(skippedContentFiles) unreadable, binary, or over-15-MiB files.")
            }
            finalItems = matches
        } else {
            let limited = allScored.prefix(parsed.limit)
            finalItems = limited.map { cand in
                let entry = candidateEntries[cand.index]
                return entry.toFileItem(
                    gitStatus: gitSnapshot[entry.fullPath],
                    score: cand.score
                )
            }
        }

        let t1 = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Double(t1 - t0) / 1_000_000.0

        return FSearchResultBundle(
            items: finalItems,
            elapsedMilliseconds: elapsedMs,
            totalIndexedCount: indexedCount,
            backendName: loadedFromMMapCache ? "fsearch-mmap" : "fsearch-native",
            isPartial: partial || isCancelled(),
            diagnostic: isCancelled() ? "Search cancelled." : (diagnostics.isEmpty ? nil : diagnostics.joined(separator: " "))
        )
    }

    // MARK: - Entry Evaluation & Fuzzy / 1-Typo Scoring

    @inline(__always)
    private static func evaluateEntry(
        _ entry: IndexedFileEntry,
        query: ParsedFSearchQuery,
        compiledRegex: NSRegularExpression?,
        gitStatusMap: [String: GitFileStatus],
        now: Date
    ) -> Int? {
        if !query.extensions.isEmpty && !query.extensions.contains(entry.ext) {
            return nil
        }
        if !query.excludedExtensions.isEmpty && query.excludedExtensions.contains(entry.ext) {
            return nil
        }
        if let symOnly = query.symlinkOnly, entry.isSymlink != symOnly {
            return nil
        }
        if !query.typeFilters.isEmpty {
            let kind = FileKindCategory.detect(extension: entry.ext, isDirectory: entry.isDirectory)
            let kindLower = kind.rawValue.lowercased()
            var typeMatched = false
            for tf in query.typeFilters {
                switch tf {
                case "dir", "folder", "d":
                    if entry.isDirectory { typeMatched = true }
                case "file", "f":
                    if !entry.isDirectory { typeMatched = true }
                case "symlink", "sym", "link":
                    if entry.isSymlink { typeMatched = true }
                case "doc", "docs", "document":
                    if kind == .document { typeMatched = true }
                case "img", "image", "photo", "pic":
                    if kind == .image { typeMatched = true }
                case "vid", "video", "movie":
                    if kind == .video { typeMatched = true }
                case "aud", "audio", "music":
                    if kind == .audio { typeMatched = true }
                case "arc", "archive", "zip":
                    if kind == .archive { typeMatched = true }
                case "exec", "app", "bin":
                    if kind == .executable || entry.ext == "app" { typeMatched = true }
                default:
                    if kindLower == tf || entry.ext == tf { typeMatched = true }
                }
                if typeMatched { break }
            }
            if !typeMatched { return nil }
        }

        if !query.sizeFilters.isEmpty {
            for sf in query.sizeFilters {
                if !sf.matches(entry.size) { return nil }
            }
        }

        if !query.mtimeFilters.isEmpty {
            let modDate = entry.modificationDate
            for mf in query.mtimeFilters {
                if !mf.matches(modDate, now: now) { return nil }
            }
        }

        if !query.pathSubstrings.isEmpty {
            let parentLower = entry.parentPath.lowercased()
            for ps in query.pathSubstrings {
                if !parentLower.contains(ps) { return nil }
            }
        }

        if let gf = query.gitFilter {
            guard let status = gitStatusMap[entry.fullPath] else { return nil }
            switch gf {
            case "m", "mod", "modified":
                if status != .modified { return nil }
            case "a", "staged", "added":
                if status != .staged { return nil }
            case "?", "u", "untracked":
                if status != .untracked { return nil }
            default:
                break // "any" or "*" matches any git status
            }
        }

        if !query.tagFilters.isEmpty {
            let url = URL(fileURLWithPath: entry.fullPath, isDirectory: entry.isDirectory)
            let fileTags = Set(FinderTagColor.readTags(for: url))
            if fileTags.isDisjoint(with: query.tagFilters) {
                return nil
            }
        }

        var totalScore = 100

        for term in query.terms {
            switch term {
            case .excluded(let ex):
                let exBytes = Array(ex.utf8)
                if containsSubslice(haystack: entry.lowerNameUTF8, needle: exBytes) {
                    return nil
                }

            case .exact(let ex):
                let exBytes = Array(ex.utf8)
                if entry.lowerNameUTF8 == exBytes {
                    totalScore += 500
                } else if containsSubslice(haystack: entry.lowerNameUTF8, needle: exBytes) {
                    totalScore += 250
                } else {
                    return nil
                }

            case .prefix(let pre):
                let preBytes = Array(pre.utf8)
                if startsWithSubslice(haystack: entry.lowerNameUTF8, prefix: preBytes) {
                    totalScore += 350
                } else {
                    return nil
                }

            case .suffix(let suf):
                let sufBytes = Array(suf.utf8)
                if endsWithSubslice(haystack: entry.lowerNameUTF8, suffix: sufBytes) {
                    totalScore += 300
                } else {
                    return nil
                }

            case .fuzzyOrSubstring(_, let needleBytes, let termMask):
                if needleBytes.isEmpty { continue }

                let missingBits = (termMask & ~entry.charMask).nonzeroBitCount
                let allowOneTypo = query.fuzzyTypoTolerance && needleBytes.count >= 5

                if missingBits == 0 {
                    if entry.lowerNameUTF8 == needleBytes {
                        totalScore += 1000
                        continue
                    }
                    if startsWithSubslice(haystack: entry.lowerNameUTF8, prefix: needleBytes) {
                        totalScore += 650 - min(entry.lowerNameUTF8.count, 50)
                        continue
                    }
                    if let pos = indexOfSubslice(haystack: entry.lowerNameUTF8, needle: needleBytes) {
                        let boundaryBonus: Int
                        if pos > 0 {
                            let prev = entry.lowerNameUTF8[pos - 1]
                            boundaryBonus = (prev == 45 || prev == 95 || prev == 46 || prev == 32) ? 120 : 0
                        } else {
                            boundaryBonus = 150
                        }
                        totalScore += 400 + boundaryBonus - min(pos * 4, 80)
                        continue
                    }
                    if allowOneTypo && hasOneTypoSubstringMatch(haystack: entry.lowerNameUTF8, needle: needleBytes) {
                        totalScore += 280
                        continue
                    }
                    if query.fuzzyTypoTolerance,
                       let fuzzyScore = fuzzySubsequenceScore(haystack: entry.lowerNameUTF8, needle: needleBytes) {
                        totalScore += fuzzyScore
                        continue
                    }
                    return nil
                } else if allowOneTypo && missingBits <= 1 {
                    if hasOneTypoSubstringMatch(haystack: entry.lowerNameUTF8, needle: needleBytes) {
                        totalScore += 240
                        continue
                    }
                    return nil
                } else {
                    return nil
                }
            }
        }

        if let regex = compiledRegex {
            let name = entry.name
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if regex.firstMatch(in: name, options: [], range: range) == nil {
                return nil
            }
            totalScore += 200
        }

        return totalScore
    }

    // MARK: - Ultra-Fast UTF-8 Byte Helpers

    @inline(__always)
    private static func startsWithSubslice(haystack: [UInt8], prefix: [UInt8]) -> Bool {
        guard prefix.count <= haystack.count else { return false }
        for i in 0..<prefix.count {
            if haystack[i] != prefix[i] { return false }
        }
        return true
    }

    @inline(__always)
    private static func endsWithSubslice(haystack: [UInt8], suffix: [UInt8]) -> Bool {
        guard suffix.count <= haystack.count else { return false }
        let offset = haystack.count - suffix.count
        for i in 0..<suffix.count {
            if haystack[offset + i] != suffix[i] { return false }
        }
        return true
    }

    @inline(__always)
    private static func containsSubslice(haystack: [UInt8], needle: [UInt8]) -> Bool {
        indexOfSubslice(haystack: haystack, needle: needle) != nil
    }

    @inline(__always)
    private static func indexOfSubslice(haystack: [UInt8], needle: [UInt8]) -> Int? {
        let hCount = haystack.count
        let nCount = needle.count
        if nCount == 0 { return 0 }
        if nCount > hCount { return nil }
        let first = needle[0]
        let limit = hCount - nCount
        var i = 0
        while i <= limit {
            if haystack[i] == first {
                var matched = true
                for j in 1..<nCount {
                    if haystack[i + j] != needle[j] {
                        matched = false
                        break
                    }
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    @inline(__always)
    private static func fuzzySubsequenceScore(haystack: [UInt8], needle: [UInt8]) -> Int? {
        let hCount = haystack.count
        let nCount = needle.count
        guard nCount <= hCount else { return nil }

        var hIdx = 0
        var nIdx = 0
        var firstMatchIdx = -1
        var lastMatchIdx = -1
        var consecutiveCount = 0

        while hIdx < hCount && nIdx < nCount {
            if haystack[hIdx] == needle[nIdx] {
                if firstMatchIdx == -1 { firstMatchIdx = hIdx }
                if lastMatchIdx == hIdx - 1 {
                    consecutiveCount += 1
                }
                lastMatchIdx = hIdx
                nIdx += 1
            }
            hIdx += 1
        }

        guard nIdx == nCount else { return nil }
        let span = lastMatchIdx - firstMatchIdx + 1
        if span > nCount * 3 + 4 { return nil }
        return max(60, 220 + (consecutiveCount * 25) - (span - nCount) * 12 - firstMatchIdx * 3)
    }

    #if BURROW_TESTING
    static func ageFilteredEntryMatchesForTesting(_ entry: IndexedFileEntry, rawQuery: String, now: Date) -> Bool {
        entrySearchScoreForTesting(entry, rawQuery: rawQuery, fuzzyEnabled: false, now: now) != nil
    }

    static func entrySearchScoreForTesting(_ entry: IndexedFileEntry, rawQuery: String,
                                          fuzzyEnabled: Bool, now: Date) -> Int? {
        let query = ParsedFSearchQuery.parse(rawQuery, fuzzyEnabled: fuzzyEnabled)
        guard query.validationError == nil else { return nil }
        return evaluateEntry(entry, query: query, compiledRegex: nil, gitStatusMap: [:], now: now)
    }

    // Expose the production matcher separately from intentional subsequence fallback.
    static func oneTypoSubstringMatchesForTesting(_ name: String, _ term: String) -> Bool {
        hasOneTypoSubstringMatch(haystack: Array(name.utf8), needle: Array(term.utf8))
    }
    #endif

    @inline(__always)
    private static func hasOneTypoSubstringMatch(haystack: [UInt8], needle: [UInt8]) -> Bool {
        let hLen = haystack.count
        let nLen = needle.count
        guard nLen >= 5, hLen >= nLen - 1 else { return false }

        // After spending the single edit, the rest must match exactly. Trying all
        // admissible tails avoids greedy insertion/deletion choices when bytes repeat.
        // This remains byte-based, allocation-free and O(hLen * nLen).
        func tailMatches(_ haystackStart: Int, _ needleStart: Int) -> Bool {
            let remaining = nLen - needleStart
            guard hLen - haystackStart >= remaining else { return false }
            for offset in 0..<remaining {
                if haystack[haystackStart + offset] != needle[needleStart + offset] { return false }
            }
            return true
        }

        for start in 0...(hLen - (nLen - 1)) {
            var i = start
            var j = 0
            while i < hLen && j < nLen && haystack[i] == needle[j] {
                i += 1
                j += 1
            }
            if j == nLen { return true }
            // Delete one needle byte, including a missing final filename byte.
            if tailMatches(i, j + 1) { return true }
            guard i < hLen else { continue }
            // Substitute, or skip one extra haystack byte.
            if tailMatches(i + 1, j + 1) || tailMatches(i + 1, j) { return true }
            // Preserve the existing adjacent-transposition allowance.
            if i + 1 < hLen && j + 1 < nLen &&
                haystack[i] == needle[j + 1] && haystack[i + 1] == needle[j] &&
                tailMatches(i + 2, j + 2) { return true }
        }
        return false
    }

    // MARK: - Memory-Mapped Content Grep with 64-bit Trigram Bloom Filter Cache

    private func grepFileContentWithTrigramCache(
        path: String,
        mtimeEpoch: Int64,
        pattern: String,
        needleTrigramMask: UInt64,
        isCancelled: @Sendable () -> Bool,
        wasSkipped: inout Bool
    ) -> GrepMatchSnippet? {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { wasSkipped = true; return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        let byteLimit = 15 * 1024 * 1024
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= byteLimit else { wasSkipped = true; return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !isCancelled() {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                wasSkipped = true
                return nil
            }
            guard data.count <= byteLimit - count else { wasSkipped = true; return nil }
            data.append(buffer, count: count)
        }
        guard !isCancelled(), !data.isEmpty else { return nil }

        let checkCount = min(data.count, 512)
        for idx in 0..<checkCount {
            if data[idx] == 0 { wasSkipped = true; return nil }
        }

        // Byte search is ASCII-insensitive; preserve other UTF-8 bytes rather
        // than lowercasing only the needle and creating Unicode false negatives.
        let needleBytes = Array(pattern.utf8).map { ($0 >= 65 && $0 <= 90) ? $0 + 32 : $0 }
        guard !needleBytes.isEmpty else { return nil }
        let nLen = needleBytes.count

        return data.withUnsafeBytes { rawBuffer -> GrepMatchSnippet? in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let count = rawBuffer.count
            guard count >= nLen else { return nil }

            // Recompute from this read. A cached mask is never authoritative for
            // no-match: same-second writes/replacements can preserve all metadata.
            // Compute and cache 64-bit trigram Bloom filter for files <= 256KB
            if needleTrigramMask != 0 && count <= 262_144 && count >= 3 {
                var fileMask: UInt64 = 0
                let triLimit = count - 2
                var k = 0
                while k < triLimit {
                    let b0 = (base[k] >= 65 && base[k] <= 90) ? (base[k] + 32) : base[k]
                    let b1 = (base[k + 1] >= 65 && base[k + 1] <= 90) ? (base[k + 1] + 32) : base[k + 1]
                    let b2 = (base[k + 2] >= 65 && base[k + 2] <= 90) ? (base[k + 2] + 32) : base[k + 2]
                    let hash = (UInt32(b0) &* 31 &+ UInt32(b1)) &* 31 &+ UInt32(b2)
                    fileMask |= (1 << UInt64(hash & 63)) | (1 << UInt64((hash >> 6) & 63))
                    k += 1
                }
                self.trigramLock.lock()
                if self.trigramBloomCache.count > 25_000 {
                    self.trigramBloomCache.removeAll(keepingCapacity: true)
                }
                self.trigramBloomCache[path] = (mtimeEpoch, fileMask)
                self.trigramLock.unlock()

                if (fileMask & needleTrigramMask) != needleTrigramMask {
                    return nil
                }
            }

            let firstLower = needleBytes[0]
            let firstUpper = (firstLower >= 97 && firstLower <= 122) ? (firstLower - 32) : firstLower
            let limit = count - nLen

            var i = 0
            while i <= limit {
                if i & 4095 == 0 && isCancelled() { return nil }
                let b = base[i]
                if b == firstLower || b == firstUpper {
                    var matched = true
                    for j in 1..<nLen {
                        let c = base[i + j]
                        let cl = (c >= 65 && c <= 90) ? (c + 32) : c
                        if cl != needleBytes[j] {
                            matched = false
                            break
                        }
                    }
                    if matched {
                        var lineNum = 1
                        var lineStart = i
                        while lineStart > 0 && base[lineStart - 1] != 10 && base[lineStart - 1] != 13 {
                            lineStart -= 1
                        }
                        for k in 0..<lineStart {
                            if base[k] == 10 { lineNum += 1 }
                        }
                        var lineEnd = i + nLen
                        while lineEnd < count && base[lineEnd] != 10 && base[lineEnd] != 13 && (lineEnd - lineStart) < 220 {
                            lineEnd += 1
                        }
                        let slice = UnsafeBufferPointer(start: base.advanced(by: lineStart), count: lineEnd - lineStart)
                        let lineStr = String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                        return GrepMatchSnippet(
                            lineNumber: lineNum,
                            lineText: lineStr,
                            matchRangeLower: max(0, i - lineStart),
                            matchRangeUpper: max(0, i - lineStart + nLen)
                        )
                    }
                }
                i += 1
            }
            return nil
        }
    }

    // MARK: - macOS FSEvents Real-Time Differential Index Watcher

    private func startFSEvents(watching paths: [String]) -> Bool {
        stopFSEvents()
        guard enableMonitoring, !paths.isEmpty else { return true }

        let cfPaths = paths as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, clientCallBackInfo, numEvents, eventPaths, eventFlags, _) in
            guard let info = clientCallBackInfo else { return }
            let engine = Unmanaged<FSearchIndex>.fromOpaque(info).takeUnretainedValue()
            guard let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            var modifiedDirs = Set<String>()
            var requiresRebuild = false
            let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
                kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
            for i in 0..<min(numEvents, pathsArray.count) {
                var path = URL(fileURLWithPath: pathsArray[i]).standardizedFileURL.path
                for root in engine.configuredRoots.sorted(by: { $0.count > $1.count }) {
                    let url = URL(fileURLWithPath: root).standardizedFileURL
                    let canonical = url.resolvingSymlinksInPath().path
                    if FSearchIndex.isWithin(path, root: canonical) {
                        path = url.path + String(path.dropFirst(canonical.count))
                        break
                    }
                }
                if eventFlags[i] & rescanFlags != 0 { requiresRebuild = true }
                // A directory event changes its parent's listing as well. This is
                // essential for empty-directory creation and subtree renames.
                let parent = (path as NSString).deletingLastPathComponent
                if !parent.isEmpty && engine.configuredRoots.contains(where: {
                    FSearchIndex.isWithin(parent, root: URL(fileURLWithPath: $0).standardizedFileURL.path)
                }) { modifiedDirs.insert(parent) }
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    modifiedDirs.insert(path)
                } else if eventFlags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
                    modifiedDirs.insert(path)
                }
            }
            // Queue reconciliation behind the initial/full snapshot without
            // blocking the event delivery queue. Repeated ancestors coalesce.
            for directory in modifiedDirs.sorted(by: { $0.count < $1.count }) {
                engine.enqueueDirectoryRefresh(directory)
            }
            if !modifiedDirs.isEmpty { engine.onDirectoryChangedOnDisk?(modifiedDirs) }
            if requiresRebuild {
                engine.enqueueIndexRebuild()
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        if let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.12,
            flags
        ) {
            eventStream = stream
            FSEventStreamSetDispatchQueue(stream, fseventsQueue)
            guard FSEventStreamStart(stream) else {
                stopFSEvents()
                return false
            }
            return true
        }
        return false
    }

    private func stopFSEvents() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }
    }

    // MARK: - Optional Bridge to External `noahdunnagan/fsearch` Unix Socket

    func queryExternalFSearchSocket(rawQuery: String, limit: Int, socketPath explicitSocketPath: String? = nil) -> [FileItem]? {
        let socketPath = explicitSocketPath ?? ("~/Library/Application Support/FSearch/fsearch.sock" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        let oldFlags = fcntl(fd, F_GETFL, 0)
        guard oldFlags >= 0, fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK) == 0 else { return nil }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        func waitFor(_ events: Int16) -> Bool {
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let milliseconds = Int32(max(1, min(2000, (deadline - now) / 1_000_000)))
                let result = poll(&descriptor, 1, milliseconds)
                if result < 0 && errno == EINTR { continue }
                guard result > 0, descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else { return false }
                return descriptor.revents & (events | Int16(POLLHUP)) != 0
            }
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            for (idx, b) in pathBytes.enumerated() {
                ptr[idx] = UInt8(bitPattern: b)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS, waitFor(Int16(POLLOUT)) else { return nil }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else { return nil }
        }

        let payload: [String: Any] = ["q": rawQuery, "limit": limit, "offset": 0]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              var lineData = String(data: jsonData, encoding: .utf8)?.data(using: .utf8) else {
            return nil
        }
        lineData.append(0x0A)

        var written = 0
        while written < lineData.count {
            guard waitFor(Int16(POLLOUT)) else { return nil }
            let count = lineData.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: written), ptr.count - written)
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return nil }
            written += count
        }

        // Protocol is one newline-delimited JSON response. Never decode a partial
        // chunk, and never wait forever for an unresponsive or unbounded peer.
        let responseLimit = 16 * 1024 * 1024
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var terminated = false
        while responseData.count < responseLimit {
            guard waitFor(Int16(POLLIN)) else { return nil }
            let count = Darwin.read(fd, &buffer, min(buffer.count, responseLimit - responseData.count))
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { break }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                responseData.append(buffer, count: newline)
                terminated = true
                break
            }
            responseData.append(buffer, count: count)
        }
        guard terminated || responseData.count < responseLimit else { return nil }

        guard let text = String(data: responseData, encoding: .utf8) else { return nil }
        var items: [FileItem] = []
        for line in text.split(separator: "\n") {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = obj["results"] as? [[String: Any]] {
                for r in results {
                    if let p = r["path"] as? String {
                        let url = URL(fileURLWithPath: p)
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
                        items.append(FileItem(
                            url: url,
                            name: url.lastPathComponent,
                            path: p,
                            parentPath: url.deletingLastPathComponent().path,
                            fileExtension: url.pathExtension.lowercased(),
                            isDirectory: isDir.boolValue,
                            isHidden: url.lastPathComponent.hasPrefix("."),
                            size: (r["size"] as? Int64) ?? 0,
                            modificationDate: Date()
                        ))
                    }
                }
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              object["results"] is [[String: Any]] else { return nil }
        return Array(items.prefix(limit))
    }
}
