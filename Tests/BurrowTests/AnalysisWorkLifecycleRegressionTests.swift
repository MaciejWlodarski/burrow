import Foundation

/// Physical workers remain inside this condition until explicitly released.
/// Cancellation is observed on the worker itself without returning its slot.
private final class AnalysisWorkerGate: @unchecked Sendable {
    private struct Call {
        let name: String
        var released = false
        var requestedProbes = 0
        var observations: [Bool] = []
    }
    private let condition = NSCondition()
    private var calls: [Call] = []
    private var active = 0
    private var peak = 0
    private var releasedAll = false

    func perform(_ name: String, token: AnalysisRequestToken) -> String {
        condition.lock()
        let index = calls.count
        calls.append(Call(name: name))
        active += 1
        peak = max(peak, active)
        condition.broadcast()
        while !releasedAll && !calls[index].released {
            if calls[index].observations.count < calls[index].requestedProbes {
                condition.unlock()
                let cancelled = token.isCancelled
                condition.lock()
                calls[index].observations.append(cancelled)
                condition.broadcast()
            } else {
                condition.wait()
            }
        }
        active -= 1
        condition.broadcast()
        condition.unlock()
        // Intentionally ignore cancellation for the returned value: the service
        // must reject late results even when a blocked operation cannot stop.
        return name
    }

    var names: [String] {
        condition.lock(); defer { condition.unlock() }
        return calls.map(\.name)
    }
    var activeCount: Int {
        condition.lock(); defer { condition.unlock() }
        return active
    }
    var peakCount: Int {
        condition.lock(); defer { condition.unlock() }
        return peak
    }
    func requestProbe(_ index: Int) -> Int {
        condition.lock(); defer { condition.unlock() }
        let probe = calls[index].requestedProbes
        calls[index].requestedProbes += 1
        condition.broadcast()
        return probe
    }
    func observation(_ index: Int, probe: Int) -> Bool? {
        condition.lock(); defer { condition.unlock() }
        guard calls.indices.contains(index), calls[index].observations.indices.contains(probe) else { return nil }
        return calls[index].observations[probe]
    }
    func release(_ index: Int) {
        condition.lock(); defer { condition.unlock() }
        calls[index].released = true
        condition.broadcast()
    }
    func releaseAll() {
        condition.lock(); defer { condition.unlock() }
        releasedAll = true
        condition.broadcast()
    }
}

@MainActor
struct AnalysisWorkLifecycleRegressionTests {
    @MainActor private final class Deliveries {
        var values: [String] = []
    }

    private static func until(_ description: String, _ predicate: () -> Bool) async throws {
        // This deadline can only fail a test. Successful ordering and negative
        // assertions are established by physical gates and scheduler snapshots.
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            if Date() >= deadline {
                throw RegressionFailure(description: "Analysis worker watchdog expired: \(description)")
            }
            await Task.yield()
        }
    }

    @discardableResult
    private static func submit(_ name: String, consumer: String,
                               service: AnalysisWorkService, gate: AnalysisWorkerGate,
                               deliveries: Deliveries) -> AnalysisWorkRequest {
        let token = AnalysisRequestToken(rootPath: "/analysis-test/\(name)")
        return service.submit(consumer: .init(rawValue: consumer), token: token,
            work: { gate.perform(name, token: token) },
            completion: { deliveries.values.append($0) })
    }

    private static func probe(_ expected: Bool, _ index: Int, gate: AnalysisWorkerGate) async throws {
        let probe = gate.requestProbe(index)
        try await until("worker cancellation observation") { gate.observation(index, probe: probe) != nil }
        try expect(gate.observation(index, probe: probe) == expected)
    }

    static func runAll() async throws -> Int {
        try await testCancellationRetainsPhysicalBudget()
        try await testSameConsumerCannotOverlapWithSpareCapacity()
        try await testNewestReplacementPreservesFIFO()
        try await testPendingCapDefersWithoutHiddenRetry()
        try await testCancelledQueuedWorkDoesNotRun()
        try await testPreCancelledRequestDoesNotRun()
        try await testCancellationDuringFinishedCallbackRejectsDelivery()
        try await testReentrantCancellationReleasesReservedSlot()
        try await testRepeatedCancellationNotifiesOnce()
        return 9
    }

    private static func testCancellationRetainsPhysicalBudget() async throws {
        let service = AnalysisWorkService(maxWorkers: 2, maxPending: 2)
        let gate = AnalysisWorkerGate(), deliveries = Deliveries()
        defer { gate.releaseAll() }
        let first = submit("old-a", consumer: "a", service: service, gate: gate, deliveries: deliveries)
        let second = submit("old-b", consumer: "b", service: service, gate: gate, deliveries: deliveries)
        try await until("both physical workers") { gate.names.count == 2 }
        first.cancel(); second.cancel()
        let third = submit("fresh-c", consumer: "c", service: service, gate: gate, deliveries: deliveries)
        let fourth = submit("fresh-d", consumer: "d", service: service, gate: gate, deliveries: deliveries)
        try await probe(true, 0, gate: gate)
        try await probe(true, 1, gate: gate)
        try expect(first.state == .cancelling && second.state == .cancelling)
        try expect(third.state == .queued && fourth.state == .queued)
        try expect(service.debugSnapshot.running == 2 && service.debugSnapshot.pending == 2)
        try expect(gate.activeCount == 2 && gate.names.count == 2 && deliveries.values.isEmpty)
        gate.release(0)
        try await until("one replacement after actual worker return") { gate.names.count == 3 }
        try expect(gate.names[2] == "fresh-c")
        try expect(service.debugSnapshot.running == 2 && service.debugSnapshot.pending == 1)
        try expect(deliveries.values.isEmpty && gate.peakCount == 2)
        gate.release(1)
        try await until("second replacement after actual worker return") { gate.names.count == 4 }
        try expect(gate.names[3] == "fresh-d")
        try expect(first.state == .cancelled && second.state == .cancelled)
        gate.release(2); gate.release(3)
        try await until("physical budget test drained") { service.debugSnapshot.running == 0 }
        try expect(Set(deliveries.values) == Set(["fresh-c", "fresh-d"]) && deliveries.values.count == 2)
        try expect(third.state == .finished && fourth.state == .finished)
        try expect(gate.activeCount == 0 && gate.peakCount == 2)
    }

    private static func testSameConsumerCannotOverlapWithSpareCapacity() async throws {
        let service = AnalysisWorkService(maxWorkers: 2, maxPending: 3)
        let gate = AnalysisWorkerGate(), deliveries = Deliveries()
        defer { gate.releaseAll() }
        let old = submit("old", consumer: "surface", service: service, gate: gate, deliveries: deliveries)
        try await until("old surface started") { gate.names == ["old"] }
        let latest = submit("latest", consumer: "surface", service: service, gate: gate, deliveries: deliveries)
        try await probe(true, 0, gate: gate)
        try expect(old.state == .cancelling && latest.state == .queued)
        try expect(service.debugSnapshot.running == 1 && service.debugSnapshot.pending == 1)
        try expect(gate.names == ["old"] && gate.activeCount == 1)
        // FIFO is among eligible consumers: an unrelated surface can use the
        // spare slot rather than wait behind a still-physical cancelled worker.
        let independent = submit("independent", consumer: "other", service: service, gate: gate, deliveries: deliveries)
        try await until("independent consumer uses spare slot") { gate.names.count == 2 }
        try expect(gate.names == ["old", "independent"])
        gate.release(1)
        try await until("independent delivery") { independent.state == .finished }
        try expect(service.debugSnapshot.running == 1 && service.debugSnapshot.pending == 1)
        try expect(latest.state == .queued && gate.names.count == 2)
        gate.release(0)
        try await until("same surface replacement after return") { gate.names.count == 3 }
        try expect(gate.names[2] == "latest" && old.state == .cancelled)
        try expect(deliveries.values == ["independent"])
        gate.release(2)
        try await until("same consumer drained") { service.debugSnapshot.running == 0 }
        try expect(deliveries.values == ["independent", "latest"] && gate.peakCount == 2)
    }

    private static func testNewestReplacementPreservesFIFO() async throws {
        let service = AnalysisWorkService(maxWorkers: 1, maxPending: 3)
        let gate = AnalysisWorkerGate(), deliveries = Deliveries()
        defer { gate.releaseAll() }
        submit("blocker", consumer: "blocker", service: service, gate: gate, deliveries: deliveries)
        try await until("FIFO blocker") { gate.names.count == 1 }
        var obsolete = [submit("a-0", consumer: "a", service: service, gate: gate, deliveries: deliveries)]
        let b = submit("b", consumer: "b", service: service, gate: gate, deliveries: deliveries)
        let c = submit("c", consumer: "c", service: service, gate: gate, deliveries: deliveries)
        for index in 1...100 {
            obsolete.append(submit("a-\(index)", consumer: "a", service: service, gate: gate, deliveries: deliveries))
            try expect(service.debugSnapshot.running == 1 && service.debugSnapshot.pending == 3)
            try expect(obsolete.dropLast().allSatisfy { $0.state == .cancelled && $0.token.isCancelled })
        }
        try expect(obsolete.last?.state == .queued && b.state == .queued && c.state == .queued)
        try expect(gate.names == ["blocker"])
        let expected = ["blocker", "a-100", "b", "c"]
        for index in expected.indices {
            try await until("FIFO worker \(index)") { gate.names.count == index + 1 }
            try expect(gate.names == Array(expected.prefix(index + 1)))
            gate.release(index)
            try await until("FIFO delivery \(index)") { deliveries.values.count == index + 1 }
        }
        try expect(deliveries.values == expected && gate.names == expected)
        try expect(service.debugSnapshot.running == 0 && service.debugSnapshot.pending == 0)
        try expect(obsolete.last?.state == .finished && gate.peakCount == 1)
    }

    private static func testPendingCapDefersWithoutHiddenRetry() async throws {
        let service = AnalysisWorkService(maxWorkers: 1, maxPending: 2)
        let gate = AnalysisWorkerGate(), deliveries = Deliveries()
        defer { gate.releaseAll() }
        submit("running", consumer: "running", service: service, gate: gate, deliveries: deliveries)
        try await until("overflow blocker") { gate.names.count == 1 }
        submit("pending-a", consumer: "a", service: service, gate: gate, deliveries: deliveries)
        submit("pending-b", consumer: "b", service: service, gate: gate, deliveries: deliveries)
        let overflow = (0..<50).map {
            submit("overflow-\($0)", consumer: "overflow-\($0)", service: service, gate: gate, deliveries: deliveries)
        }
        try expect(overflow.allSatisfy { $0.state == .deferred })
        try expect(service.debugSnapshot.running == 1 && service.debugSnapshot.pending == 2)
        for index in 0..<3 {
            try await until("bounded admitted worker \(index)") { gate.names.count == index + 1 }
            gate.release(index)
            try await until("bounded admitted result \(index)") { deliveries.values.count == index + 1 }
        }
        try expect(service.debugSnapshot.running == 0 && service.debugSnapshot.pending == 0)
        try expect(gate.names == ["running", "pending-a", "pending-b"])
        try expect(overflow.allSatisfy { $0.state == .deferred })
        // Deferred means no hidden retry queue; only fresh explicit demand runs.
        let retry = submit("overflow-0", consumer: "overflow-0", service: service, gate: gate, deliveries: deliveries)
        try await until("explicit overflow retry") { gate.names.count == 4 }
        try expect(gate.names[3] == "overflow-0" && overflow[0].state == .deferred)
        gate.release(3)
        try await until("explicit retry drained") { service.debugSnapshot.running == 0 }
        try expect(retry.state == .finished && deliveries.values.count == 4 && gate.peakCount == 1)
    }

    private static func testCancelledQueuedWorkDoesNotRun() async throws {
        let service = AnalysisWorkService(maxWorkers: 1, maxPending: 2)
        let gate = AnalysisWorkerGate(), deliveries = Deliveries()
        defer { gate.releaseAll() }
        submit("blocker", consumer: "blocker", service: service, gate: gate, deliveries: deliveries)
        try await until("queued cancellation blocker") { gate.names.count == 1 }
        let dropped = submit("never-io", consumer: "dropped", service: service, gate: gate, deliveries: deliveries)
        let survivor = submit("survivor", consumer: "survivor", service: service, gate: gate, deliveries: deliveries)
        dropped.cancel(); dropped.cancel()
        try expect(dropped.state == .cancelled && dropped.token.isCancelled)
        try expect(service.debugSnapshot.pending == 1 && service.debugSnapshot.running == 1)
        gate.release(0)
        try await until("survivor bypasses removed queued closure") { gate.names.count == 2 }
        try expect(gate.names == ["blocker", "survivor"])
        gate.release(1)
        try await until("queued cancellation drained") { service.debugSnapshot.running == 0 }
        try expect(survivor.state == .finished && service.debugSnapshot.pending == 0)
        try expect(gate.names == ["blocker", "survivor"] && deliveries.values == gate.names)
    }

    private static func testPreCancelledRequestDoesNotRun() async throws {
        let service = AnalysisWorkService(maxWorkers: 1, maxPending: 1)
        let gate = AnalysisWorkerGate(), deliveries = Deliveries()
        defer { gate.releaseAll() }
        let token = AnalysisRequestToken(rootPath: "/analysis-test/pre-cancelled")
        token.cancel()
        let request = service.submit(consumer: .init(rawValue: "cancelled"), token: token,
            work: { gate.perform("never-io", token: token) },
            completion: { deliveries.values.append($0) })
        try expect(request.state == .cancelled)
        try expect(service.debugSnapshot.running == 0 && service.debugSnapshot.pending == 0)
        submit("sentinel", consumer: "sentinel", service: service, gate: gate, deliveries: deliveries)
        try await until("sentinel after pre-cancelled request") { gate.names.count == 1 }
        try expect(gate.names == ["sentinel"])
        gate.release(0)
        try await until("pre-cancelled test drained") { service.debugSnapshot.running == 0 }
        try expect(deliveries.values == ["sentinel"] && gate.names == ["sentinel"])
    }

    private static func testCancellationDuringFinishedCallbackRejectsDelivery() async throws {
        let service = AnalysisWorkService(maxWorkers: 1, maxPending: 1)
        let gate = AnalysisWorkerGate(), deliveries = Deliveries()
        defer { gate.releaseAll() }
        let token = AnalysisRequestToken(rootPath: "/analysis-test/same-root")
        var states: [AnalysisWorkRequest.State] = []
        let request = service.submit(consumer: .init(rawValue: "surface"), token: token,
            stateChanged: { state in
                states.append(state)
                if state == .finished { token.cancel() }
            }, work: { gate.perform("stale", token: token) },
            completion: { deliveries.values.append($0) })
        try await until("late delivery worker") { gate.names == ["stale"] }
        try await probe(false, 0, gate: gate)
        gate.release(0)
        try await until("finished callback processed") { service.debugSnapshot.running == 0 }
        try expect(request.state == .finished && states == [.running, .finished])
        try expect(token.isCancelled && deliveries.values.isEmpty)
        // A later successful delivery proves the queue is live and the absence
        // above was rejection, not a watchdog or an unprocessed callback.
        submit("fresh", consumer: "surface", service: service, gate: gate, deliveries: deliveries)
        try await until("fresh delivery worker") { gate.names.count == 2 }
        gate.release(1)
        try await until("fresh delivery processed") { service.debugSnapshot.running == 0 }
        try expect(deliveries.values == ["fresh"] && gate.names == ["stale", "fresh"])
    }

    private static func testReentrantCancellationReleasesReservedSlot() async throws {
        let service = AnalysisWorkService(maxWorkers: 1, maxPending: 1)
        let gate = AnalysisWorkerGate(), deliveries = Deliveries()
        defer { gate.releaseAll() }
        let blockerToken = AnalysisRequestToken(rootPath: "/analysis-test/reentrant-blocker")
        let replacementToken = AnalysisRequestToken(rootPath: "/analysis-test/reentrant-replacement")
        var replacement: AnalysisWorkRequest?
        var replacementStates: [AnalysisWorkRequest.State] = []
        var reservedSlotObserved = false
        let blocker = service.submit(consumer: .init(rawValue: "blocker"), token: blockerToken,
            stateChanged: { state in
                guard state == .finished else { return }
                // finish removes the blocker before this callback. Replacing
                // the sole pending job now reserves the freed running slot.
                replacement = service.submit(consumer: .init(rawValue: "target"), token: replacementToken,
                    stateChanged: { replacementStates.append($0) },
                    work: { gate.perform("replacement-never-io", token: replacementToken) },
                    completion: { deliveries.values.append($0) })
            }, work: { gate.perform("blocker", token: blockerToken) },
            completion: { deliveries.values.append($0) })
        try await until("reentrant blocker physically held") { gate.names == ["blocker"] }
        let oldToken = AnalysisRequestToken(rootPath: "/analysis-test/reentrant-old")
        let old = service.submit(consumer: .init(rawValue: "target"), token: oldToken,
            stateChanged: { state in
                guard state == .cancelled else { return }
                reservedSlotObserved = service.debugSnapshot.running == 1 && service.debugSnapshot.pending == 0
                // Cancels between reservation and launch, without yielding.
                replacementToken.cancel()
            }, work: { gate.perform("old-never-io", token: oldToken) },
            completion: { deliveries.values.append($0) })
        try expect(old.state == .queued && service.debugSnapshot.pending == 1)
        gate.release(0)
        try await until("reentrant replacement submission returned") { replacement != nil }
        try expect(reservedSlotObserved && replacementToken.isCancelled)
        try expect(blocker.state == .finished && old.state == .cancelled)
        try expect(replacement?.state == .cancelled && replacementStates == [.cancelled])
        try expect(service.debugSnapshot.running == 0 && service.debugSnapshot.pending == 0)
        try expect(gate.names == ["blocker"] && deliveries.values == ["blocker"])
        submit("sentinel", consumer: "sentinel", service: service, gate: gate, deliveries: deliveries)
        try await until("sentinel proves reserved slot was released") { gate.names.count == 2 }
        try expect(gate.names == ["blocker", "sentinel"])
        gate.release(1)
        try await until("reentrant cancellation drained") { service.debugSnapshot.running == 0 }
        try expect(deliveries.values == ["blocker", "sentinel"] && gate.names == deliveries.values)
        try expect(service.debugSnapshot.pending == 0 && gate.peakCount == 1)
    }

    private static func testRepeatedCancellationNotifiesOnce() async throws {
        let service = AnalysisWorkService(maxWorkers: 1, maxPending: 1)
        let gate = AnalysisWorkerGate(), deliveries = Deliveries()
        defer { gate.releaseAll() }
        let token = AnalysisRequestToken(rootPath: "/analysis-test/repeated-cancellation")
        var states: [AnalysisWorkRequest.State] = []
        let request = service.submit(consumer: .init(rawValue: "target"), token: token,
            stateChanged: { states.append($0) },
            work: { gate.perform("blocked", token: token) },
            completion: { deliveries.values.append($0) })
        try await until("repeated cancellation worker physically held") { gate.names == ["blocked"] }
        for _ in 0..<100 { request.cancel() }
        try await probe(true, 0, gate: gate)
        try expect(states == [.running, .cancelling] && request.state == .cancelling)
        try expect(service.debugSnapshot.running == 1 && gate.activeCount == 1)
        gate.release(0)
        try await until("repeated cancellation worker returned") { service.debugSnapshot.running == 0 }
        request.cancel()
        try expect(states == [.running, .cancelling, .cancelled] && request.state == .cancelled)
        try expect(deliveries.values.isEmpty && service.debugSnapshot.pending == 0)
        try expect(gate.names == ["blocked"] && gate.activeCount == 0)
    }

}
