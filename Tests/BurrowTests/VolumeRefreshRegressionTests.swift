import Foundation

private final class VolumeTestGate: @unchecked Sendable {
    private let lock = NSCondition()
    private var results: [Int: VolumeRefreshResult] = [:]
    private var count = 0
    private var active = 0
    private var peak = 0
    private var workerOnMain = false
    private var releasedAll = false
    func perform() -> VolumeRefreshResult {
        lock.lock(); defer { lock.unlock() }
        let index = count; count += 1; active += 1
        peak = max(peak, active)
        workerOnMain = workerOnMain || Thread.isMainThread
        while results[index] == nil && !releasedAll { lock.wait() }
        active -= 1
        return results.removeValue(forKey: index) ?? .failure
    }
    func release(_ index: Int, _ result: VolumeRefreshResult) {
        lock.lock(); results[index] = result; lock.broadcast(); lock.unlock()
    }
    func finish() { lock.lock(); releasedAll = true; lock.broadcast(); lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var maximumActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var touchedMain: Bool { lock.lock(); defer { lock.unlock() }; return workerOnMain }
}

private final class VolumeTestSource: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private(set) var subscriptions = 0
    private(set) var cancellations = 0
    func subscribe(_ callback: @escaping @Sendable () -> Void) -> () -> Void {
        lock.lock(); self.callback = callback; subscriptions += 1; lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.callback = nil; self.cancellations += 1; self.lock.unlock()
        }
    }
    func send() { lock.lock(); let callback = self.callback; lock.unlock(); callback?() }
}

@MainActor struct VolumeRefreshRegressionTests {
    private static func until(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            if Date() >= deadline { throw RegressionFailure(description: "Volume refresh watchdog expired") }
            await Task.yield()
        }
    }
    private static func snapshot(_ name: String) -> VolumeRefreshResult {
        .success(VolumeSnapshot(items: [VolumeInfoItem(name: name,
            url: URL(fileURLWithPath: "/fake/\(name)"), totalBytes: 0, freeBytes: 0, isRemovable: false)]))
    }
    static func runAll() async throws {
        try NetworkVolumeGroupingRegressionTests.runAll()
        var refreshes = 0
        let fakeURL = URL(fileURLWithPath: "/fake/eject")
        try VolumeEjectAction.perform(fakeURL, eject: { _ in }, refresh: { refreshes += 1 })
        do {
            try VolumeEjectAction.perform(fakeURL,
                eject: { _ in throw RegressionFailure(description: "fake eject failure") },
                refresh: { refreshes += 1 })
            throw RegressionFailure(description: "Eject failure was swallowed")
        } catch { try expect(refreshes == 1) }
        let gate = VolumeTestGate()
        let source = VolumeTestSource()
        let service = VolumeRefreshService(provider: { gate.perform() }, subscribe: source.subscribe)
        var deliveries = 0
        var inventory = VolumeInventoryState()
        defer { service.stop(); gate.finish() }
        service.start { deliveries += 1; inventory.apply($0) }
        service.start { _ in fatalError("Start must be idempotent") }
        try await until { gate.calls == 1 }
        // Reaching this actor continuation while provider is held proves responsiveness.
        try expect(!gate.touchedMain && source.subscriptions == 1)
        let stormDelivered = DispatchSemaphore(value: 0)
        let stale = snapshot("stale")
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<1000 { source.send() }
            // Actor delivery is still pending while the old physical scan returns.
            gate.release(0, stale)
            stormDelivered.signal()
        }
        // Only a watchdog: this producer never waits for MainActor. Holding the
        // actor here establishes that pending ingress, not its delivery, invalidates A.
        try expect(stormDelivered.wait(timeout: .now() + 10) == .success)
        try expect(gate.calls == 1)
        // One initial actor delivery plus exactly one delivery for the held storm.
        // This fails an implementation that schedules a Task for every event.
        try expect(service.ingressDeliveryCountForTesting == 2)
        try await until { gate.calls == 2 }
        try expect(deliveries == 0 && gate.maximumActive == 1)
        gate.release(1, snapshot("mounted"))
        try await until { deliveries == 1 }
        try expect(inventory.items.first?.name == "mounted")
        source.send()
        try await until { gate.calls == 3 }
        gate.release(2, snapshot("renamed"))
        try await until { deliveries == 2 }
        try expect(inventory.items.first?.name == "renamed")
        service.requestRefresh() // Same seam used after successful in-app eject.
        try await until { gate.calls == 4 }
        gate.release(3, .failure)
        try await until { deliveries == 3 }
        try expect(inventory.items.first?.name == "renamed" && inventory.notice != nil)
        source.send()
        try await until { gate.calls == 5 }
        service.stop(); source.send()
        service.start { deliveries += 1; inventory.apply($0) }
        try expect(gate.calls == 5 && source.cancellations == 1 && source.subscriptions == 2)
        gate.release(4, snapshot("stopped"))
        try await until { gate.calls == 6 }
        try expect(deliveries == 3 && gate.maximumActive == 1)
        gate.release(5, .success(VolumeSnapshot(items: [])))
        try await until { deliveries == 4 }
        try expect(inventory.items.isEmpty && inventory.canShowEmpty)
        service.stop()
        try expect(source.cancellations == 2)
        var reentrantDeliveries = 0
        service.start { _ in
            reentrantDeliveries += 1
            service.stop()
            service.start { _ in reentrantDeliveries += 1 }
        }
        try await until { gate.calls == 7 }
        gate.release(6, snapshot("before-restart"))
        try await until { gate.calls == 8 }
        try expect(reentrantDeliveries == 1 && gate.maximumActive == 1)
        gate.release(7, snapshot("after-restart"))
        try await until { reentrantDeliveries == 2 }
        service.stop()
        try expect(source.subscriptions == 4 && source.cancellations == 4)
        var firstFailure = VolumeInventoryState()
        firstFailure.apply(.failure)
        try expect(!firstFailure.hasSnapshot && !firstFailure.canShowEmpty && firstFailure.notice != nil)
        firstFailure.apply(.success(VolumeSnapshot(items: [], partial: true)))
        try expect(firstFailure.notice != nil)
        print("PASS bounded volume refresh, stale results, stop/restart, errors and empty inventory")
    }
}
