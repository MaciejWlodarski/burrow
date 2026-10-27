import Foundation
import AppKit

struct VolumeSnapshot: Sendable {
    let items: [VolumeInfoItem]
    let partial: Bool
    init(items: [VolumeInfoItem], partial: Bool = false) { self.items = items; self.partial = partial }
}

enum VolumeRefreshResult: Sendable {
    case success(VolumeSnapshot)
    case failure
}

/// Failure is not a successful empty inventory; retain the last known rows.
public struct VolumeInventoryState {
    public private(set) var items: [VolumeInfoItem] = []
    public private(set) var hasSnapshot = false
    public private(set) var notice: String? = "Wczytywanie woluminów…"
    public private(set) var canShowEmpty = false
    mutating func apply(_ result: VolumeRefreshResult) {
        switch result {
        case .success(let snapshot):
            items = snapshot.items; hasSnapshot = true
            canShowEmpty = items.isEmpty
            notice = snapshot.partial ? "Część informacji o woluminach jest niedostępna." : nil
        case .failure:
            canShowEmpty = false
            notice = "Nie można odświeżyć woluminów. Ostatnie dane mogą być nieaktualne."
        }
    }
}

/// Coalesces arbitrary-thread ingress BEFORE creating main-actor work.
private final class VolumeRefreshIngress: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var scheduled = false
    private var revision: UInt64 = 0
    #if BURROW_TESTING
    private var deliveriesScheduled = 0
    var deliveryCount: Int {
        lock.lock(); defer { lock.unlock() }; return deliveriesScheduled
    }
    #endif
    func request(_ deliver: @escaping @Sendable () -> Void) {
        lock.lock()
        guard active else { lock.unlock(); return }
        revision &+= 1
        let enqueue = !scheduled
        scheduled = true
        #if BURROW_TESTING
        if enqueue { deliveriesScheduled += 1 }
        #endif
        lock.unlock()
        if enqueue { deliver() }
    }
    func drain() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        scheduled = false
        return active ? revision : nil
    }
    func current() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return active ? revision : nil
    }
    func stop() { lock.lock(); active = false; lock.unlock() }
}

@MainActor final class VolumeRefreshService {
    typealias Subscribe = (@escaping @Sendable () -> Void) -> (() -> Void)
    private let provider: @Sendable () -> VolumeRefreshResult
    private let subscribe: Subscribe
    private let queue = DispatchQueue(label: "com.burrow.volumes", qos: .utility)
    private var ingress: VolumeRefreshIngress?
    private var cancelSubscription: (() -> Void)?
    private var running = false
    private var completedRevision: UInt64?
    private var onUpdate: ((VolumeRefreshResult) -> Void)?

    init(provider: @escaping @Sendable () -> VolumeRefreshResult, subscribe: @escaping Subscribe) {
        self.provider = provider; self.subscribe = subscribe
    }
    deinit { cancelSubscription?() }

    func start(onUpdate: @escaping (VolumeRefreshResult) -> Void) {
        guard ingress == nil else { return }
        self.onUpdate = onUpdate
        let bridge = VolumeRefreshIngress()
        ingress = bridge
        completedRevision = nil
        cancelSubscription = subscribe { [weak self, bridge] in
            bridge.request { [weak self, bridge] in
                Task { @MainActor [weak self] in self?.receive(bridge) }
            }
        }
        requestRefresh()
    }
    func stop() {
        ingress?.stop(); ingress = nil
        cancelSubscription?(); cancelSubscription = nil
        onUpdate = nil; completedRevision = nil
        // Never release running here: a blocked synchronous provider still owns its slot.
    }
    #if BURROW_TESTING
    var ingressDeliveryCountForTesting: Int { ingress?.deliveryCount ?? 0 }
    #endif
    func requestRefresh() {
        guard let bridge = ingress else { return }
        bridge.request { [weak self, bridge] in
            Task { @MainActor [weak self] in self?.receive(bridge) }
        }
    }
    private func receive(_ bridge: VolumeRefreshIngress) {
        guard ingress === bridge, bridge.drain() != nil else { return }
        launchIfNeeded()
    }
    private func launchIfNeeded() {
        guard !running, let bridge = ingress, let revision = bridge.current(),
              completedRevision != revision else { return }
        running = true
        let provider = self.provider
        queue.async { [weak self, bridge] in
            let result = provider()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.running = false
                if self.ingress === bridge, bridge.current() == revision {
                    self.completedRevision = revision
                    self.onUpdate?(result)
                }
                self.launchIfNeeded()
            }
        }
    }

    static func production() -> VolumeRefreshService {
        VolumeRefreshService(provider: enumerate, subscribe: { callback in
            let workspace = NSWorkspace.shared.notificationCenter
            let names: [Notification.Name] = [NSWorkspace.didMountNotification,
                NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification]
            let tokens = names.map { name in
                workspace.addObserver(forName: name, object: nil, queue: nil) { _ in callback() }
            }
            let activation = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in callback() }
            return {
                for token in tokens { workspace.removeObserver(token) }
                NotificationCenter.default.removeObserver(activation)
            }
        })
    }
    nonisolated private static func enumerate() -> VolumeRefreshResult {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeIsRemovableKey,
            .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeURLForRemountingKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) else { return .failure }
        var seen = Set<String>()
        var items: [VolumeInfoItem] = []
        var partial = false
        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            let values = try? url.resourceValues(forKeys: keys)
            if values == nil { partial = true }
            items.append(VolumeInfoItem(name: values?.volumeName ?? (url.path == "/" ? "/" : url.lastPathComponent),
                url: url, totalBytes: values?.volumeTotalCapacity.map(Int64.init),
                freeBytes: values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init),
                isRemovable: values?.volumeIsRemovable == true || values?.volumeIsEjectable == true ||
                    (values?.volumeIsInternal == false && url.path != "/"),
                isNetwork: values?.volumeIsLocal == false,
                networkServer: NetworkServerIdentity.parse(remountURL: values?.volumeURLForRemounting)))
        }
        items.sort { $0.url.path < $1.url.path }
        return .success(VolumeSnapshot(items: items, partial: partial))
    }
}

/// Keeps the successful-eject refresh contract testable without touching devices.
@MainActor enum VolumeEjectAction {
    static func perform(_ url: URL, eject: (URL) throws -> Void, refresh: () -> Void) throws {
        try eject(url)
        refresh()
    }
}
