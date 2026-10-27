import Foundation

/// Bytes observed during a bounded walk. Incomplete walks are lower bounds,
/// never exact sizes; unreadable directories and entry limits remain explicit.
public struct FolderSizeResult: Sendable, Equatable {
    public let bytes: Int64
    public let isComplete: Bool
    public let skippedDirectoryCount: Int
    public let unreadableDirectoryCount: Int

    public init(bytes: Int64, isComplete: Bool, skippedDirectoryCount: Int = 0, unreadableDirectoryCount: Int = 0) {
        self.bytes = bytes
        self.isComplete = isComplete
        self.skippedDirectoryCount = skippedDirectoryCount
        self.unreadableDirectoryCount = unreadableDirectoryCount
    }
}

/// Cancellation is cooperative: a blocked filesystem call still occupies its slot.
private final class FolderSizeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@MainActor
public final class FolderSizeCache: ObservableObject {
    public static let shared = FolderSizeCache()
    public enum Status: Equatable { case deferred, queued, scanning, complete, partial }
    public enum DemandPriority { case background, visible, interactive }

    @Published public private(set) var results: [String: FolderSizeResult] = [:]
    @Published private var activityRevision: UInt64 = 0
    /// Derived from the authoritative result map, never a second mutable cache.
    public var sizes: [String: Int64] { results.compactMapValues { $0.isComplete ? $0.bytes : nil } }
    private let maxWorkers: Int
    private let maxDemand: Int
    private let maxResults: Int
    private var owners: [UUID: Set<String>] = [:]
    private var priorities: [UUID: DemandPriority] = [:]
    private var demand: [String: Set<UUID>] = [:]
    private var pending: [String] = []
    private var current: [String: FolderSizeCancellation] = [:]
    private var running: [UUID: (path: String, token: FolderSizeCancellation)] = [:]
    private var recency: [String: UInt64] = [:]
    private var tick: UInt64 = 0
    private var oneShotOwners: [String: UUID] = [:]
    private let workerQueue = DispatchQueue(label: "com.burrow.foldersize", qos: .utility, attributes: .concurrent)
    private let calculator: @Sendable (String, @Sendable () -> Bool) -> FolderSizeResult

    init(maxWorkers: Int = 2, maxDemand: Int = 256, maxResults: Int = 512,
         cancellableCalculator: @escaping @Sendable (String, @Sendable () -> Bool) -> FolderSizeResult = {
             FolderSizeCache.calculateFolderSize(at: $0, maxEntries: 15_000, isCancelled: $1)
         }) {
        precondition(maxWorkers > 0 && maxDemand > 0 && maxResults >= maxDemand)
        self.maxWorkers = maxWorkers
        self.maxDemand = maxDemand
        self.maxResults = maxResults
        self.calculator = cancellableCalculator
    }

    convenience init(calculator: @escaping @Sendable (String) -> FolderSizeResult) {
        self.init(cancellableCalculator: { path, _ in calculator(path) })
    }

    /// Lexical cache keys only: rendering/sorting must never probe a volume.
    /// Preserve `..`: removing it could change the target through a symlink.
    /// Preserve /private, case, percent escapes and tilde literally as well.
    /// Production callers provide absolute paths; relative input stays relative
    /// rather than consulting the process working directory or home directory.
    nonisolated static func normalizedKey(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let absolute = path.hasPrefix("/")
        let components = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        let body = components.joined(separator: "/")
        return absolute ? "/" + body : (body.isEmpty ? "." : body)
    }
    private func key(_ path: String) -> String { Self.normalizedKey(path) }
    public func size(for folderPath: String) -> Int64? {
        guard let result = results[key(folderPath)], result.isComplete else { return nil }
        return result.bytes
    }
    public func result(for folderPath: String) -> FolderSizeResult? { results[key(folderPath)] }
    public func displaySize(for folderPath: String) -> String? {
        guard let result = result(for: folderPath) else { return nil }
        return (result.isComplete ? "" : "≥ ") + FormatHelpers.formatBytes(result.bytes)
    }
    public func status(for folderPath: String) -> Status {
        let path = key(folderPath)
        if let result = results[path] { return result.isComplete ? .complete : .partial }
        guard let token = current[path] else { return .deferred }
        return running.values.contains { $0.token === token } ? .scanning : .queued
    }
    public func statusText(for folderPath: String) -> String {
        switch status(for: folderPath) {
        case .deferred: return "Odroczono (limit)"
        case .queued: return "W kolejce…"
        case .scanning: return "Obliczanie…"
        case .complete, .partial: return displaySize(for: folderPath) ?? "Niedostępny"
        }
    }

    /// Atomic lease replacement. At most maxDemand paths are retained globally.
    /// Overflow is deliberately NOT queued or retried on result publication.
    /// A refresh, changed selection, or reappearance retries deferred demand.
    public func updateDemand(owner: UUID, paths: [String], priority: DemandPriority = .interactive) {
        // A lease's class is stable while it owns any paths. Reserving capacity, rather than
        // preempting existing leases, avoids re-request/eviction storms.
        let priority = priorities[owner] ?? priority
        priorities[owner] = priority
        let requested = Set(paths.map(key))
        let previous = owners[owner] ?? []
        for path in previous.subtracting(requested) { removeInterest(owner: owner, path: path) }
        var accepted = previous.intersection(requested)
        for path in requested.subtracting(accepted).sorted() {
            guard canAdmit(path: path, priority: priority) else { continue }
            let needsRevalidation = demand[path] == nil && results[path] != nil
            demand[path, default: []].insert(owner)
            accepted.insert(path)
            touch(path)
            enqueueIfNeeded(path, refreshingCached: needsRevalidation)
        }
        owners[owner] = accepted.isEmpty ? nil : accepted
        if accepted.isEmpty { priorities.removeValue(forKey: owner) }
        drain()
        changed()
    }

    public func release(owner: UUID) {
        for path in owners.removeValue(forKey: owner) ?? [] { removeInterest(owner: owner, path: path) }
        priorities.removeValue(forKey: owner)
        drain()
        changed()
    }
    private func canAdmit(path: String, priority: DemandPriority) -> Bool {
        guard demand[path] != nil || demand.count < maxDemand else { return false }
        let reserve = min(32, maxDemand / 4)
        func hasOwner(_ path: String, matching predicate: (DemandPriority) -> Bool) -> Bool {
            (demand[path] ?? []).contains { owner in priorities[owner].map(predicate) ?? false }
        }
        if priority == .background {
            let alreadyBackground = hasOwner(path, matching: { $0 == .background })
            let backgroundCount = demand.keys.filter { hasOwner($0, matching: { $0 == .background }) }.count
            guard alreadyBackground || backgroundCount < maxDemand - 2 * reserve else { return false }
        }
        if priority != .interactive {
            let alreadyNonInteractive = hasOwner(path, matching: { $0 != .interactive })
            let nonInteractiveCount = demand.keys.filter { hasOwner($0, matching: { $0 != .interactive }) }.count
            guard alreadyNonInteractive || nonInteractiveCount < maxDemand - reserve else { return false }
        }
        return true
    }

    private func removeInterest(owner: UUID, path: String) {
        demand[path]?.remove(owner)
        if demand[path]?.isEmpty == true {
            demand.removeValue(forKey: path)
            current.removeValue(forKey: path)?.cancel()
            pending.removeAll { $0 == path }
        }
    }
    private func enqueueIfNeeded(_ path: String, refreshingCached: Bool = false) {
        guard demand[path] != nil, (results[path] == nil || refreshingCached), current[path] == nil else { return }
        current[path] = FolderSizeCancellation()
        pending.append(path)
    }
    private func schedulingRank(_ path: String) -> Int {
        (demand[path] ?? []).map { owner in
            switch priorities[owner] ?? .background {
            case .interactive: return 0
            case .visible: return 1
            case .background: return 2
            }
        }.min() ?? 2
    }
    private func drain() {
        while running.count < maxWorkers {
            // Do not overlap replacement scans for a still-running old generation.
            let eligible = pending.indices.filter { index in
                !running.values.contains { $0.path == pending[index] }
            }
            guard let index = eligible.min(by: { lhs, rhs in
                let leftRank = schedulingRank(pending[lhs])
                let rightRank = schedulingRank(pending[rhs])
                return leftRank == rightRank ? lhs < rhs : leftRank < rightRank
            }) else { break }
            let path = pending.remove(at: index)
            guard let token = current[path], demand[path] != nil else { continue }
            let id = UUID()
            running[id] = (path, token)
            let calculate = calculator
            workerQueue.async {
                let computed = calculate(path, { token.isCancelled })
                Task { @MainActor in self.finish(id: id, computed: computed) }
            }
        }
    }
    private func finish(id: UUID, computed: FolderSizeResult) {
        // The physical slot is released only here, after calculator return.
        guard let job = running.removeValue(forKey: id) else { return }
        if current[job.path] === job.token, !job.token.isCancelled, demand[job.path] != nil {
            current.removeValue(forKey: job.path)
            // Trim before publishing, including for synchronous subscribers.
            evictIdleResults(reserving: results[job.path] == nil ? 1 : 0)
            results[job.path] = computed
            touch(job.path)
            if let owner = oneShotOwners.removeValue(forKey: job.path) { release(owner: owner) }
        }
        drain()
        changed()
    }
    private func touch(_ path: String) {
        guard results[path] != nil else { return }
        tick &+= 1
        recency[path] = tick
    }
    private func evictIdleResults(reserving slots: Int) {
        while results.count + slots > maxResults {
            guard let victim = results.keys.filter({ demand[$0] == nil }).min(by: {
                (recency[$0] ?? 0) < (recency[$1] ?? 0)
            }) else { break }
            results.removeValue(forKey: victim)
            recency.removeValue(forKey: victim)
        }
    }
    private func changed() { activityRevision &+= 1 }

    /// Compatibility for one-shot clients; GUI uses explicit shared leases.
    /// One-shot ownership ends on completion and is subject to the same cap.
    public func requestSizeIfNeeded(for folderPath: String) {
        let path = key(folderPath)
        guard results[path] == nil, oneShotOwners[path] == nil else { return }
        let owner = UUID()
        updateDemand(owner: owner, paths: [path])
        if owners[owner] != nil { oneShotOwners[path] = owner }
    }
    public func invalidate(_ folderPath: String) {
        invalidatePaths([key(folderPath)])
    }
    private func invalidatePaths(_ paths: [String]) {
        for path in paths {
            results.removeValue(forKey: path)
            recency.removeValue(forKey: path)
            current.removeValue(forKey: path)?.cancel()
            pending.removeAll { $0 == path }
            enqueueIfNeeded(path)
        }
        drain()
        changed()
    }
    public func invalidate(containing changedPath: String) {
        let normalized = key(changedPath)
        let affected = Set(results.keys).union(demand.keys).filter { cached in
            guard cached.hasPrefix("/") == normalized.hasPrefix("/") else { return false }
            return cached == normalized || normalized.hasPrefix(cached == "/" ? "/" : cached + "/")
                || cached.hasPrefix(normalized == "/" ? "/" : normalized + "/")
        }
        invalidatePaths(Array(affected))
    }

    /// The search index intentionally skips trees that size calculation includes.
    /// Recheck live consumers on navigation/command completion without clearing
    /// their last value. Existing worker and demand limits still own every scan.
    public func revalidate(containing changedPath: String) {
        let normalized = key(changedPath)
        let affected = demand.keys.filter { cached in
            cached == normalized || normalized.hasPrefix(cached == "/" ? "/" : cached + "/")
                || cached.hasPrefix(normalized == "/" ? "/" : normalized + "/")
        }
        for path in affected {
            current.removeValue(forKey: path)?.cancel()
            pending.removeAll { $0 == path }
            enqueueIfNeeded(path, refreshingCached: true)
        }
        drain()
        changed()
    }

    static func columnDemandPaths(items: [FileItem], sortBySize: Bool) -> [String] {
        sortBySize ? items.filter(\.isDirectory).map(\.path).sorted() : []
    }
    var debugSnapshot: (running: Int, queued: Int, demanded: Int, completed: Int) {
        (running.count, pending.count, demand.count, results.count)
    }

    nonisolated static func calculateFolderSize(at rootPath: String, maxEntries: Int,
        isCancelled: @Sendable () -> Bool = { false }) -> FolderSizeResult {
        let crawl = BulkCrawler.crawlTreeResult(roots: [rootPath], skipHeavyDevDirs: false,
                                                maxEntries: maxEntries, includeHidden: true, isCancelled: isCancelled)
        var total: Int64 = 0
        var overflowed = false
        for entry in crawl.entries where !entry.isDirectory || entry.isSymlink {
            let (sum, overflow) = total.addingReportingOverflow(max(0, entry.size))
            if overflow { total = .max; overflowed = true; break }
            total = sum
        }
        return FolderSizeResult(bytes: total, isComplete: crawl.isComplete && !overflowed,
            skippedDirectoryCount: crawl.skippedDirectoryCount,
            unreadableDirectoryCount: crawl.unreadableDirectoryCount)
    }
}
