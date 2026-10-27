import Foundation

/// A calculator that does not return until the test permits it. Cancellation
/// probes run on the calculator's own worker, without freeing its physical slot.
private final class FolderSizeCalculatorGate: @unchecked Sendable {
    private struct Call {
        let path: String
        var requestedProbes = 0
        var cancellationObservations: [Bool] = []
        var result: FolderSizeResult?
    }

    private let condition = NSCondition()
    private var calls: [Call] = []
    private var active = 0
    private var peakActive = 0
    private var releasedAll = false

    func calculate(_ path: String, isCancelled: @Sendable () -> Bool) -> FolderSizeResult {
        condition.lock()
        let index = calls.count
        calls.append(Call(path: path))
        active += 1
        peakActive = max(peakActive, active)
        condition.broadcast()
        while true {
            if releasedAll || calls[index].result != nil {
                let result = calls[index].result ?? FolderSizeResult(bytes: 0, isComplete: false)
                active -= 1
                condition.broadcast()
                condition.unlock()
                return result
            }
            if calls[index].cancellationObservations.count < calls[index].requestedProbes {
                condition.unlock()
                let cancelled = isCancelled()
                condition.lock()
                calls[index].cancellationObservations.append(cancelled)
                condition.broadcast()
                continue
            }
            condition.wait()
        }
    }

    var startedPaths: [String] {
        condition.lock()
        defer { condition.unlock() }
        return calls.map(\.path)
    }

    var activeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return active
    }

    var maximumActiveCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return peakActive
    }

    func requestCancellationProbe(_ index: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        let probe = calls[index].requestedProbes
        calls[index].requestedProbes += 1
        condition.broadcast()
        return probe
    }

    func cancellationObservation(_ index: Int, probe: Int) -> Bool? {
        condition.lock()
        defer { condition.unlock() }
        guard calls.indices.contains(index), calls[index].cancellationObservations.indices.contains(probe) else {
            return nil
        }
        return calls[index].cancellationObservations[probe]
    }

    func complete(_ index: Int, bytes: Int64, isComplete: Bool = true,
                  skipped: Int = 0, unreadable: Int = 0) {
        condition.lock()
        defer { condition.unlock() }
        calls[index].result = FolderSizeResult(bytes: bytes, isComplete: isComplete,
            skippedDirectoryCount: skipped, unreadableDirectoryCount: unreadable)
        condition.broadcast()
    }

    /// Failure cleanup also releases workers admitted after the failure, so a
    /// failed assertion cannot strand the process on one of these test gates.
    func releaseAll() {
        condition.lock()
        releasedAll = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Turns cancellation on only after traversal has begun, without wall-clock races.
private final class FolderSizeCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observations = 0

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        observations += 1
        return observations >= 3
    }

    var observationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }
}

@MainActor
struct FolderSizeLifecycleRegressionTests {
    private func waitFor(_ description: String, until predicate: () -> Bool) async throws {
        // Yielding is only a bounded delivery watchdog. All ordering and negative
        // assertions use the calculator gate, not elapsed time or sleeps.
        for _ in 0..<200_000 {
            if predicate() { return }
            await Task.yield()
        }
        throw RegressionFailure(description: "Folder size watchdog expired: \(description)")
    }

    private func expectCancellation(_ expected: Bool, call: Int,
                                    gate: FolderSizeCalculatorGate) async throws {
        let probe = gate.requestCancellationProbe(call)
        try await waitFor("cancellation probe \(call):\(probe)") {
            gate.cancellationObservation(call, probe: probe) != nil
        }
        try expect(gate.cancellationObservation(call, probe: probe) == expected)
    }

    func runAll() async throws {
        try await testSharedOwnersCoalesceRepeatedDemand()
        try await testOnlyLastOwnerCancelsAndDropsQueuedDemand()
        try await testInvalidationBeforeFirstResultRestartsAutomatically()
        try await testRepeatedInvalidationRetainsOneReplacement()
        try await testRepeatedInvalidationWithBothSlotsBlocked()
        try await testReleasedGenerationCannotPublishAfterReacquisition()
        try await testCancelledWorkersKeepPhysicalSlots()
        try await testAdmissionCapMakesOverflowDeferredAndRetryable()
        try await testCacheHitAtAdmissionCapDoesNotEraseResult()
        try await testSaturatedBackgroundAndVisibleDemandPreservesInspectorAdmission()
        try await testSharedPriorityLeasesPreserveReservationAfterRelease()
        try await testDeniedBackgroundCacheAttachmentPreservesDisplay()
        try await testOwnerReplacementRemovesObsoleteDemand()
        try await testIdleLRUEvictionPreservesOwnedResults()
        try await testPartialResultsNeverBecomeExact()
        try await testContainingInvalidationUsesDirectoryBoundaries()
        try testCrawlerCancellationReachesRealTraversal()
        try testColumnDemandOnlyForSizeSortedDirectories()
        try await testProductionDefaultsBoundLargeSnapshots()
        try testNormalizedKeyPureContract()
        try await testNormalizedAliasesCoalesceAcrossPublicAPI()
        try await testParentComponentsRemainDistinctCacheKeys()
        try testNormalizedKeyPreservesSymlinkParentSpelling()
        try await testReacquiredCachedDemandRevalidatesWithoutErasingValue()
        try await testRevalidationRetainsPhysicalSlotsAndRejectsOldResult()
        print("PASS 25 folder-size lifecycle checks: ownership, bounded admission, cancellation, invalidation, LRU, demand and lexical keys")
    }

    private func testReacquiredCachedDemandRevalidatesWithoutErasingValue() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 4, maxResults: 4,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let owner = UUID(), replacement = UUID(), path = "/revisit/project"
        defer { cache.release(owner: owner); cache.release(owner: replacement) }
        cache.updateDemand(owner: owner, paths: [path])
        try await waitFor("initial cached size") { gate.startedPaths.count == 1 }
        gate.complete(0, bytes: 10)
        try await waitFor("published cached size") { cache.size(for: path) == 10 }
        cache.release(owner: owner)
        cache.updateDemand(owner: replacement, paths: [path])
        try expect(cache.size(for: path) == 10)
        try await waitFor("revisit revalidation") { gate.startedPaths.count == 2 }
        gate.complete(1, bytes: 20)
        try await waitFor("fresh revisited size") { cache.size(for: path) == 20 }
    }

    private func testRevalidationRetainsPhysicalSlotsAndRejectsOldResult() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 4, maxResults: 4,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let owner = UUID(), path = "/revisit/project"
        defer { cache.release(owner: owner) }
        cache.updateDemand(owner: owner, paths: [path])
        try await waitFor("initial revalidation fixture") { gate.startedPaths.count == 1 }
        gate.complete(0, bytes: 10)
        try await waitFor("initial revalidation result") { cache.size(for: path) == 10 }
        cache.revalidate(containing: "/revisit")
        try await waitFor("first refresh worker") { gate.startedPaths.count == 2 }
        for _ in 0..<20 { cache.revalidate(containing: "/revisit") }
        try expect(cache.size(for: path) == 10)
        try expect(cache.debugSnapshot.running == 1 && cache.debugSnapshot.queued == 1)
        try await expectCancellation(true, call: 1, gate: gate)
        gate.complete(1, bytes: 999)
        try await waitFor("coalesced refresh worker") { gate.startedPaths.count == 3 }
        try expect(cache.size(for: path) == 10 && gate.maximumActiveCount == 1)
        gate.complete(2, bytes: 30)
        try await waitFor("latest refresh result") { cache.size(for: path) == 30 }
    }

    private func testSharedOwnersCoalesceRepeatedDemand() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 2, maxDemand: 4, maxResults: 4,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let first = UUID(), second = UUID()
        defer { cache.release(owner: first); cache.release(owner: second) }
        let path = "/folder-size/shared"
        for _ in 0..<100 {
            cache.updateDemand(owner: first, paths: [path, path])
            cache.updateDemand(owner: second, paths: [path])
        }
        try await waitFor("one coalesced worker") { gate.startedPaths.count == 1 }
        try expect(cache.debugSnapshot.running == 1 && cache.debugSnapshot.queued == 0)
        try expect(cache.debugSnapshot.demanded == 1)
        gate.complete(0, bytes: 11)
        try await waitFor("shared result") { cache.size(for: path) == 11 }
        try expect(cache.status(for: path) == .complete)
        try expect(cache.debugSnapshot.completed == 1 && cache.debugSnapshot.running == 0)
        cache.release(owner: first)
        try expect(cache.debugSnapshot.demanded == 1 && cache.size(for: path) == 11)
        cache.updateDemand(owner: second, paths: [path])
        try expect(gate.startedPaths == [path])
    }

    private func testOnlyLastOwnerCancelsAndDropsQueuedDemand() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 2, maxResults: 2,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let first = UUID(), second = UUID()
        defer { cache.release(owner: first); cache.release(owner: second) }
        let shared = "/folder-size/a-shared", queued = "/folder-size/z-queued"
        cache.updateDemand(owner: first, paths: [shared, queued])
        cache.updateDemand(owner: second, paths: [shared])
        try await waitFor("shared scan") { gate.startedPaths.count == 1 }
        try expect(cache.status(for: queued) == .queued)
        cache.release(owner: first)
        try await expectCancellation(false, call: 0, gate: gate)
        try expect(cache.debugSnapshot.demanded == 1 && cache.debugSnapshot.queued == 0)
        cache.release(owner: second)
        try await expectCancellation(true, call: 0, gate: gate)
        try expect(cache.debugSnapshot.demanded == 0 && cache.debugSnapshot.queued == 0)
        try expect(cache.debugSnapshot.running == 1 && gate.activeCount == 1)
        gate.complete(0, bytes: 99)
        try await waitFor("abandoned worker return") { cache.debugSnapshot.running == 0 }
        try expect(cache.result(for: shared) == nil && cache.result(for: queued) == nil)
        try expect(gate.startedPaths == [shared])
    }

    private func testInvalidationBeforeFirstResultRestartsAutomatically() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 1, maxResults: 1,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let owner = UUID(), path = "/folder-size/first-invalidation"
        defer { cache.release(owner: owner) }
        cache.updateDemand(owner: owner, paths: [path])
        try await waitFor("initial scan") { gate.startedPaths.count == 1 }
        cache.invalidate(path)
        try await expectCancellation(true, call: 0, gate: gate)
        try expect(cache.debugSnapshot.running == 1 && cache.debugSnapshot.queued == 1)
        try expect(cache.result(for: path) == nil && cache.status(for: path) == .queued)
        gate.complete(0, bytes: 1)
        // No view reappearance or repeated updateDemand is needed to recover.
        try await waitFor("automatic replacement") { gate.startedPaths.count == 2 }
        try expect(cache.result(for: path) == nil && cache.status(for: path) == .scanning)
        gate.complete(1, bytes: 200)
        try await waitFor("replacement result") { cache.size(for: path) == 200 }
        try expect(gate.startedPaths == [path, path])
    }

    private func testRepeatedInvalidationRetainsOneReplacement() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 2, maxDemand: 1, maxResults: 1,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let owner = UUID(), path = "/folder-size/repeated-invalidation"
        defer { cache.release(owner: owner) }
        cache.updateDemand(owner: owner, paths: [path])
        try await waitFor("scan to invalidate repeatedly") { gate.startedPaths.count == 1 }
        for _ in 0..<500 {
            cache.invalidate(path)
            try expect(cache.debugSnapshot.running == 1 && cache.debugSnapshot.queued == 1)
            try expect(cache.debugSnapshot.demanded == 1 && cache.debugSnapshot.completed == 0)
        }
        try await expectCancellation(true, call: 0, gate: gate)
        try expect(gate.startedPaths.count == 1 && gate.maximumActiveCount == 1)
        gate.complete(0, bytes: 10)
        try await waitFor("single surviving replacement") { gate.startedPaths.count == 2 }
        try expect(cache.result(for: path) == nil)
        gate.complete(1, bytes: 20)
        try await waitFor("last generation completion") { cache.size(for: path) == 20 }
        try expect(cache.debugSnapshot.running == 0 && cache.debugSnapshot.queued == 0)
        try expect(gate.startedPaths.count == 2)
    }

    private func testRepeatedInvalidationWithBothSlotsBlocked() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 2, maxDemand: 2, maxResults: 2,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let owner = UUID()
        defer { cache.release(owner: owner) }
        let paths = ["/folder-size/blocked-a", "/folder-size/blocked-b"]
        cache.updateDemand(owner: owner, paths: paths)
        try await waitFor("both scans before repeated invalidation") { gate.startedPaths.count == 2 }
        let originalOrder = gate.startedPaths
        for _ in 0..<500 {
            cache.invalidate(paths[0])
            cache.invalidate(paths[1])
            try expect(cache.debugSnapshot.running == 2 && cache.debugSnapshot.queued == 2)
            try expect(cache.debugSnapshot.demanded == 2 && cache.debugSnapshot.completed == 0)
        }
        try await expectCancellation(true, call: 0, gate: gate)
        try await expectCancellation(true, call: 1, gate: gate)
        try expect(gate.startedPaths.count == 2 && gate.activeCount == 2)
        gate.complete(0, bytes: 1)
        try await waitFor("first surviving replacement after blocked scan returns") { gate.startedPaths.count == 3 }
        try expect(gate.startedPaths[2] == originalOrder[0])
        try expect(cache.debugSnapshot.running == 2 && cache.debugSnapshot.queued == 1)
        try expect(paths.allSatisfy { cache.result(for: $0) == nil })
        gate.complete(1, bytes: 2)
        try await waitFor("second surviving replacement after blocked scan returns") { gate.startedPaths.count == 4 }
        try expect(gate.startedPaths[3] == originalOrder[1])
        try expect(cache.debugSnapshot.running == 2 && cache.debugSnapshot.queued == 0)
        try expect(paths.allSatisfy { cache.result(for: $0) == nil })
        gate.complete(2, bytes: 50)
        gate.complete(3, bytes: 50)
        try await waitFor("both latest generations completed") { cache.debugSnapshot.running == 0 }
        try expect(paths.allSatisfy { cache.size(for: $0) == 50 })
        try expect(gate.startedPaths.count == 4 && gate.maximumActiveCount == 2)
    }

    private func testReleasedGenerationCannotPublishAfterReacquisition() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 2, maxDemand: 1, maxResults: 1,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let oldOwner = UUID(), newOwner = UUID(), path = "/folder-size/reacquired"
        defer { cache.release(owner: oldOwner); cache.release(owner: newOwner) }
        cache.updateDemand(owner: oldOwner, paths: [path])
        try await waitFor("old owner scan") { gate.startedPaths.count == 1 }
        cache.release(owner: oldOwner)
        cache.updateDemand(owner: newOwner, paths: [path])
        try await expectCancellation(true, call: 0, gate: gate)
        try expect(cache.debugSnapshot.running == 1 && cache.debugSnapshot.queued == 1)
        gate.complete(0, bytes: 111)
        try await waitFor("reacquired generation") { gate.startedPaths.count == 2 }
        try expect(cache.result(for: path) == nil && cache.size(for: path) == nil)
        try await expectCancellation(false, call: 1, gate: gate)
        gate.complete(1, bytes: 222)
        try await waitFor("new owner result") { cache.size(for: path) == 222 }
        try expect(cache.debugSnapshot.completed == 1 && gate.maximumActiveCount == 1)
    }

    private func testCancelledWorkersKeepPhysicalSlots() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 2, maxDemand: 4, maxResults: 4,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let first = UUID(), replacement = UUID()
        defer { cache.release(owner: first); cache.release(owner: replacement) }
        let original = ["/folder-size/a", "/folder-size/b", "/folder-size/c"]
        let fresh = ["/folder-size/d", "/folder-size/e"]
        cache.updateDemand(owner: first, paths: original)
        try await waitFor("both physical slots occupied") { gate.startedPaths.count == 2 }
        try expect(Set(gate.startedPaths) == Set(original.prefix(2)))
        cache.release(owner: first)
        cache.updateDemand(owner: replacement, paths: fresh)
        try await expectCancellation(true, call: 0, gate: gate)
        try await expectCancellation(true, call: 1, gate: gate)
        try expect(cache.debugSnapshot.running == 2 && cache.debugSnapshot.queued == 2)
        try expect(gate.startedPaths.count == 2 && gate.activeCount == 2)
        gate.complete(0, bytes: 1)
        try await waitFor("one replacement admitted after actual return") { gate.startedPaths.count == 3 }
        try expect(cache.debugSnapshot.running == 2 && cache.debugSnapshot.queued == 1)
        try expect(gate.maximumActiveCount == 2)
        gate.complete(1, bytes: 2)
        try await waitFor("second replacement admitted after actual return") { gate.startedPaths.count == 4 }
        try expect(Set(gate.startedPaths.suffix(2)) == Set(fresh))
        gate.complete(2, bytes: 30)
        gate.complete(3, bytes: 30)
        try await waitFor("replacement scans complete") { cache.debugSnapshot.running == 0 }
        try expect(fresh.allSatisfy { cache.size(for: $0) == 30 })
        try expect(original.allSatisfy { cache.result(for: $0) == nil })
        try expect(!gate.startedPaths.contains(original[2]) && gate.maximumActiveCount == 2)
    }

    private func testAdmissionCapMakesOverflowDeferredAndRetryable() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 3, maxResults: 3,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let owner = UUID(), retryOwner = UUID()
        defer { cache.release(owner: owner); cache.release(owner: retryOwner) }
        let paths = (0..<8).map { "/folder-size/admission-\($0)" }
        cache.updateDemand(owner: owner, paths: paths)
        try await waitFor("bounded admitted work") { gate.startedPaths.count == 1 }
        try expect(cache.debugSnapshot.demanded == 3 && cache.debugSnapshot.queued == 2)
        try expect(cache.status(for: paths[0]) == .scanning)
        try expect(paths[1..<3].allSatisfy { cache.status(for: $0) == .queued })
        try expect(paths[3...].allSatisfy { cache.status(for: $0) == .deferred })
        for index in 0..<3 {
            try await waitFor("admitted worker \(index)") { gate.startedPaths.count == index + 1 }
            gate.complete(index, bytes: Int64(index + 1))
            try await waitFor("admitted result \(index)") { cache.size(for: paths[index]) == Int64(index + 1) }
        }
        try expect(cache.debugSnapshot.running == 0 && cache.debugSnapshot.queued == 0)
        try expect(cache.debugSnapshot.demanded == 3 && gate.startedPaths.count == 3)
        try expect(paths[3...].allSatisfy { cache.status(for: $0) == .deferred })
        cache.release(owner: owner)
        // Overflow is an explicit deferred state, not an unbounded hidden queue.
        // An explicit renewed lease after capacity is freed must remain usable.
        cache.updateDemand(owner: retryOwner, paths: [paths[3]])
        try await waitFor("deferred path retry") { gate.startedPaths.count == 4 }
        try expect(gate.startedPaths[3] == paths[3])
        gate.complete(3, bytes: 44)
        try await waitFor("retried result") { cache.size(for: paths[3]) == 44 }
        try expect(cache.debugSnapshot.completed == 3 && cache.debugSnapshot.demanded == 1)
    }

    private func testCacheHitAtAdmissionCapDoesNotEraseResult() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 2, maxResults: 3,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let initialOwner = UUID(), occupyingOwner = UUID(), retryOwner = UUID()
        defer {
            cache.release(owner: initialOwner)
            cache.release(owner: occupyingOwner)
            cache.release(owner: retryOwner)
        }
        let cached = "/folder-size/cached-at-cap"
        let occupied = ["/folder-size/occupying-a", "/folder-size/occupying-b"]
        cache.updateDemand(owner: initialOwner, paths: [cached])
        try await waitFor("initial cached scan") { gate.startedPaths.count == 1 }
        gate.complete(0, bytes: 70)
        try await waitFor("initial cached result") { cache.size(for: cached) == 70 }
        cache.release(owner: initialOwner)
        cache.updateDemand(owner: occupyingOwner, paths: occupied)
        try await waitFor("admission occupied by other paths") { gate.startedPaths.count == 2 }
        cache.updateDemand(owner: retryOwner, paths: [cached])
        try expect(cache.debugSnapshot.demanded == 2 && cache.debugSnapshot.completed == 1)
        try expect(cache.size(for: cached) == 70 && cache.status(for: cached) == .complete)
        try expect(cache.debugSnapshot.running == 1 && cache.debugSnapshot.queued == 1)
        cache.release(owner: occupyingOwner)
        cache.updateDemand(owner: retryOwner, paths: [cached])
        try expect(cache.debugSnapshot.demanded == 1 && cache.debugSnapshot.queued == 1)
        try expect(cache.size(for: cached) == 70 && gate.startedPaths.count == 2)
        try await expectCancellation(true, call: 1, gate: gate)
        gate.complete(1, bytes: 99)
        try await waitFor("cached refresh after obsolete occupying scan") { gate.startedPaths.count == 3 }
        try expect(occupied.allSatisfy { cache.result(for: $0) == nil })
        try expect(cache.size(for: cached) == 70 && cache.debugSnapshot.completed == 1)
        try expect(gate.startedPaths[2] == cached && gate.maximumActiveCount == 1)
        gate.complete(2, bytes: 80)
        try await waitFor("reacquired cached result") { cache.size(for: cached) == 80 }
    }

    private func testSaturatedBackgroundAndVisibleDemandPreservesInspectorAdmission() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 8, maxResults: 8,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let backgroundOwner = UUID(), visibleOwner = UUID(), inspectorOwner = UUID()
        defer {
            cache.release(owner: backgroundOwner)
            cache.release(owner: visibleOwner)
            cache.release(owner: inspectorOwner)
        }
        let background = (0..<8).map { "/folder-size/priority-background-\($0)" }
        let visible = (0..<4).map { "/folder-size/priority-visible-\($0)" }
        let inspector = (0..<3).map { "/folder-size/priority-inspector-\($0)" }
        cache.updateDemand(owner: backgroundOwner, paths: background, priority: .background)
        try await waitFor("background worker occupying physical slot") { gate.startedPaths.count == 1 }
        try expect(cache.debugSnapshot.demanded == 4 && cache.debugSnapshot.queued == 3)
        try expect(background[4...].allSatisfy { cache.status(for: $0) == .deferred })
        cache.updateDemand(owner: visibleOwner, paths: visible, priority: .visible)
        try expect(cache.debugSnapshot.demanded == 6 && cache.debugSnapshot.queued == 5)
        try expect(visible[2...].allSatisfy { cache.status(for: $0) == .deferred })
        cache.updateDemand(owner: inspectorOwner, paths: inspector, priority: .interactive)
        try expect(cache.debugSnapshot.demanded == 8 && cache.debugSnapshot.queued == 7)
        try expect(inspector.prefix(2).allSatisfy { cache.status(for: $0) == .queued })
        try expect(cache.status(for: inspector[2]) == .deferred)
        try await expectCancellation(false, call: 0, gate: gate)
        try expect(gate.startedPaths == [background[0]])

        // Priority changes dispatch order, not the physical-worker budget. An
        // inspector must run next, rather than waiting behind the whole column.
        let expectedOrder = [background[0]] + Array(inspector.prefix(2))
            + Array(visible.prefix(2)) + Array(background[1..<4])
        for index in expectedOrder.indices {
            try await waitFor("priority worker \(index)") { gate.startedPaths.count == index + 1 }
            try expect(gate.startedPaths[index] == expectedOrder[index])
            gate.complete(index, bytes: Int64(100 + index))
            try await waitFor("priority result \(index)") {
                cache.size(for: expectedOrder[index]) == Int64(100 + index)
            }
        }
        try expect(cache.debugSnapshot.running == 0 && cache.debugSnapshot.completed == 8)
        try expect(gate.maximumActiveCount == 1 && gate.startedPaths == expectedOrder)
        try expect(cache.status(for: inspector[2]) == .deferred)
    }

    private func testSharedPriorityLeasesPreserveReservationAfterRelease() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 8, maxResults: 8,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let inspectorOwner = UUID(), backgroundOwner = UUID(), deniedOwner = UUID()
        defer {
            cache.release(owner: inspectorOwner)
            cache.release(owner: backgroundOwner)
            cache.release(owner: deniedOwner)
        }
        let shared = "/folder-size/priority-a-shared", denied = "/folder-size/priority-b-denied"
        let background = (0..<3).map { "/folder-size/priority-other-\($0)" }
        cache.updateDemand(owner: inspectorOwner, paths: [shared, denied], priority: .interactive)
        try await waitFor("shared interactive worker") { gate.startedPaths.count == 1 }
        cache.updateDemand(owner: backgroundOwner, paths: background + [shared], priority: .background)
        try expect(cache.debugSnapshot.demanded == 5 && cache.debugSnapshot.queued == 4)
        // Sharing an existing interactive key still consumes a background-class
        // reservation. It cannot sneak a fifth background path past that cap.
        cache.updateDemand(owner: deniedOwner, paths: [denied], priority: .background)
        try expect(cache.debugSnapshot.demanded == 5)
        // A caller cannot silently promote an existing lease to bypass its cap.
        cache.updateDemand(owner: backgroundOwner, paths: background + [shared, denied], priority: .interactive)
        cache.release(owner: inspectorOwner)
        try await expectCancellation(false, call: 0, gate: gate)
        try expect(cache.debugSnapshot.demanded == 4 && cache.debugSnapshot.queued == 3)
        try expect(cache.status(for: denied) == .deferred)
        try expect(cache.status(for: shared) == .scanning && gate.startedPaths == [shared])
        gate.complete(0, bytes: 80)
        try await waitFor("shared result survives inspector release") { cache.size(for: shared) == 80 }
        cache.release(owner: backgroundOwner)
        try expect(cache.debugSnapshot.demanded == 0 && cache.debugSnapshot.queued == 0)
        try expect(cache.size(for: shared) == 80)
    }

    private func testDeniedBackgroundCacheAttachmentPreservesDisplay() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 8, maxResults: 8,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let initialOwner = UUID(), backgroundOwner = UUID(), retryOwner = UUID()
        defer {
            cache.release(owner: initialOwner)
            cache.release(owner: backgroundOwner)
            cache.release(owner: retryOwner)
        }
        let cached = "/folder-size/priority-cached"
        let background = (0..<4).map { "/folder-size/priority-cap-\($0)" }
        cache.updateDemand(owner: initialOwner, paths: [cached], priority: .interactive)
        try await waitFor("cached result before class saturation") { gate.startedPaths.count == 1 }
        gate.complete(0, bytes: 81)
        try await waitFor("cached class-saturation result") { cache.size(for: cached) == 81 }
        cache.release(owner: initialOwner)
        cache.updateDemand(owner: backgroundOwner, paths: background, priority: .background)
        try await waitFor("background class saturated") { gate.startedPaths.count == 2 }
        cache.updateDemand(owner: retryOwner, paths: [cached], priority: .background)
        try expect(cache.debugSnapshot.demanded == 4 && cache.debugSnapshot.completed == 1)
        try expect(cache.size(for: cached) == 81 && cache.status(for: cached) == .complete)
        try expect(cache.displaySize(for: cached) != nil)
        cache.release(owner: backgroundOwner)
        cache.updateDemand(owner: retryOwner, paths: [cached], priority: .background)
        try expect(cache.debugSnapshot.demanded == 1 && cache.debugSnapshot.queued == 1)
        try expect(cache.size(for: cached) == 81 && gate.startedPaths.count == 2)
        try await expectCancellation(true, call: 1, gate: gate)
        gate.complete(1, bytes: 99)
        try await waitFor("cached refresh after retired background scan") { gate.startedPaths.count == 3 }
        try expect(cache.debugSnapshot.completed == 1 && cache.size(for: cached) == 81)
        try expect(background.allSatisfy { cache.result(for: $0) == nil })
        try expect(gate.startedPaths[2] == cached && gate.maximumActiveCount == 1)
        gate.complete(2, bytes: 82)
        try await waitFor("background cached refresh") { cache.size(for: cached) == 82 }
    }

    private func testOwnerReplacementRemovesObsoleteDemand() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 2, maxResults: 2,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let owner = UUID()
        defer { cache.release(owner: owner) }
        let old = "/folder-size/replace-a", retained = "/folder-size/replace-b", new = "/folder-size/replace-c"
        cache.updateDemand(owner: owner, paths: [old, retained])
        try await waitFor("obsolete scan") { gate.startedPaths.count == 1 }
        cache.updateDemand(owner: owner, paths: [retained, new])
        try await expectCancellation(true, call: 0, gate: gate)
        try expect(cache.debugSnapshot.demanded == 2 && cache.debugSnapshot.queued == 2)
        try expect(cache.status(for: old) == .deferred)
        gate.complete(0, bytes: 1)
        try await waitFor("retained queued scan") { gate.startedPaths.count == 2 }
        try expect(gate.startedPaths[1] == retained && cache.result(for: old) == nil)
        gate.complete(1, bytes: 2)
        try await waitFor("new queued scan") { gate.startedPaths.count == 3 }
        try expect(gate.startedPaths[2] == new)
        gate.complete(2, bytes: 3)
        try await waitFor("replacement lease completion") { cache.debugSnapshot.running == 0 }
        try expect(cache.size(for: retained) == 2 && cache.size(for: new) == 3)
        cache.updateDemand(owner: owner, paths: [])
        try expect(cache.debugSnapshot.demanded == 0 && cache.debugSnapshot.queued == 0)
    }

    private func testIdleLRUEvictionPreservesOwnedResults() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 2, maxResults: 3,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let pinnedOwner = UUID(), temporaryOwner = UUID()
        defer { cache.release(owner: pinnedOwner); cache.release(owner: temporaryOwner) }
        let pinned = "/folder-size/lru-pinned", a = "/folder-size/lru-a", b = "/folder-size/lru-b"
        cache.updateDemand(owner: pinnedOwner, paths: [pinned])
        try await waitFor("pinned scan") { gate.startedPaths.count == 1 }
        gate.complete(0, bytes: 100)
        try await waitFor("pinned result") { cache.size(for: pinned) == 100 }
        for (index, path) in [a, b].enumerated() {
            cache.updateDemand(owner: temporaryOwner, paths: [path])
            try await waitFor("idle candidate \(path)") { gate.startedPaths.count == index + 2 }
            gate.complete(index + 1, bytes: Int64(index + 1))
            try await waitFor("idle candidate result \(path)") { cache.result(for: path) != nil }
            cache.release(owner: temporaryOwner)
        }
        // Reacquiring keeps the last value while its bounded recheck makes it recent.
        cache.updateDemand(owner: temporaryOwner, paths: [a])
        try await waitFor("recent cached result recheck") { gate.startedPaths.count == 4 }
        try expect(cache.size(for: a) == 1)
        gate.complete(3, bytes: 1)
        try await waitFor("recent cached recheck completed") { cache.debugSnapshot.running == 0 }
        cache.release(owner: temporaryOwner)
        try expect(cache.size(for: a) == 1 && gate.startedPaths.count == 4)
        for index in 0..<8 {
            let path = "/folder-size/lru-new-\(index)"
            cache.updateDemand(owner: temporaryOwner, paths: [path])
            try await waitFor("eviction candidate \(index)") { gate.startedPaths.count == index + 5 }
            gate.complete(index + 4, bytes: Int64(20 + index))
            try await waitFor("eviction result \(index)") { cache.size(for: path) == Int64(20 + index) }
            try expect(cache.debugSnapshot.completed == 3 && cache.size(for: pinned) == 100)
            if index == 0 {
                try expect(cache.result(for: b) == nil && cache.size(for: a) == 1)
            }
            cache.release(owner: temporaryOwner)
        }
        try expect(gate.startedPaths.filter { $0 == pinned }.count == 1)
    }

    private func testPartialResultsNeverBecomeExact() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 1, maxResults: 1,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let owner = UUID(), path = "/folder-size/partial"
        defer { cache.release(owner: owner) }
        cache.updateDemand(owner: owner, paths: [path])
        try await waitFor("partial scan") { gate.startedPaths.count == 1 }
        gate.complete(0, bytes: 90, isComplete: false, skipped: 2, unreadable: 1)
        try await waitFor("partial result") { cache.result(for: path) != nil }
        try expect(cache.status(for: path) == .partial)
        try expect(cache.size(for: path) == nil && cache.sizes[path] == nil)
        try expect(cache.result(for: path) == FolderSizeResult(bytes: 90, isComplete: false,
            skippedDirectoryCount: 2, unreadableDirectoryCount: 1))
        try expect(cache.displaySize(for: path)?.hasPrefix("≥ ") == true)
        cache.invalidate(path)
        try await waitFor("partial result refresh") { gate.startedPaths.count == 2 }
        try expect(cache.result(for: path) == nil && cache.size(for: path) == nil)
        gate.complete(1, bytes: 100)
        try await waitFor("exact replacement") { cache.size(for: path) == 100 }
        try expect(cache.status(for: path) == .complete && cache.sizes[path] == 100)
    }

    private func testContainingInvalidationUsesDirectoryBoundaries() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 4, maxResults: 4,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let owner = UUID()
        defer { cache.release(owner: owner) }
        let paths = ["/scope", "/scope/child", "/scope/child/grand", "/scope/childish"]
        cache.updateDemand(owner: owner, paths: paths)
        for index in paths.indices {
            try await waitFor("scope result worker \(index)") { gate.startedPaths.count == index + 1 }
            try expect(gate.startedPaths[index] == paths[index])
            gate.complete(index, bytes: Int64(index + 1))
            try await waitFor("scope result \(index)") { cache.result(for: paths[index]) != nil }
        }
        cache.invalidate(containing: "/scope/child/./")
        try expect(paths.prefix(3).allSatisfy { cache.result(for: $0) == nil })
        try expect(cache.size(for: paths[3]) == 4 && cache.status(for: paths[3]) == .complete)
        try expect(cache.debugSnapshot.demanded == 4 && cache.debugSnapshot.completed == 1)
        try expect(cache.debugSnapshot.running == 1 && cache.debugSnapshot.queued == 2)
        try await waitFor("scope invalidation restart") { gate.startedPaths.count == 5 }
        try expect(paths.prefix(3).contains(gate.startedPaths[4]))
    }

    private func testCrawlerCancellationReachesRealTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-size-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x61, count: 37).write(to: root.appendingPathComponent("payload.bin"))
        let cancelled = FolderSizeCache.calculateFolderSize(at: root.path, maxEntries: 100,
            isCancelled: { true })
        try expect(!cancelled.isComplete && cancelled.bytes == 0)
        try expect(cancelled.unreadableDirectoryCount == 0)
        let probe = FolderSizeCancellationProbe()
        let interrupted = FolderSizeCache.calculateFolderSize(at: root.path, maxEntries: 100,
            isCancelled: { probe.isCancelled() })
        try expect(probe.observationCount >= 3)
        try expect(!interrupted.isComplete && interrupted.bytes == 0)
        try expect(interrupted.unreadableDirectoryCount == 0)
        let complete = FolderSizeCache.calculateFolderSize(at: root.path, maxEntries: 100,
            isCancelled: { false })
        try expect(complete.isComplete && complete.bytes == 37)
    }

    private func testColumnDemandOnlyForSizeSortedDirectories() throws {
        func item(_ name: String, isDirectory: Bool) -> FileItem {
            let path = "/folder-size/columns/\(name)"
            return FileItem(url: URL(fileURLWithPath: path), name: name, path: path,
                parentPath: "/folder-size/columns", fileExtension: isDirectory ? "" : "txt",
                isDirectory: isDirectory, isHidden: false, size: 1, modificationDate: .distantPast)
        }
        let folders = [item("z-folder", isDirectory: true), item("a-folder", isDirectory: true)]
        let items = [folders[0], item("file.txt", isDirectory: false), folders[1]]
        try expect(FolderSizeCache.columnDemandPaths(items: items, sortBySize: false).isEmpty)
        try expect(FolderSizeCache.columnDemandPaths(items: items, sortBySize: true) == folders.map(\.path).sorted())
        try expect(FolderSizeCache.columnDemandPaths(items: [], sortBySize: true).isEmpty)
    }

    private func testProductionDefaultsBoundLargeSnapshots() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let owner = UUID()
        defer { cache.release(owner: owner) }
        let paths = (0..<2_000).map { String(format: "/folder-size/defaults/%04d", $0) }
        cache.updateDemand(owner: owner, paths: paths)
        try await waitFor("default worker budget") { gate.startedPaths.count == 2 }
        try expect(cache.debugSnapshot.running == 2 && cache.debugSnapshot.queued == 254)
        try expect(cache.debugSnapshot.demanded == 256 && cache.debugSnapshot.completed == 0)
        try expect(paths[256...].allSatisfy { cache.status(for: $0) == .deferred })
        for _ in 0..<20 { cache.updateDemand(owner: owner, paths: paths) }
        try expect(cache.debugSnapshot.running == 2 && cache.debugSnapshot.queued == 254)
        try expect(cache.debugSnapshot.demanded == 256 && gate.startedPaths.count == 2)
        cache.release(owner: owner)
        try await expectCancellation(true, call: 0, gate: gate)
        try await expectCancellation(true, call: 1, gate: gate)
        try expect(cache.debugSnapshot.demanded == 0 && cache.debugSnapshot.queued == 0)
        try expect(cache.debugSnapshot.running == 2 && gate.maximumActiveCount == 2)
        gate.releaseAll()
        try await waitFor("default workers released") { cache.debugSnapshot.running == 0 }
        try expect(cache.debugSnapshot.completed == 0 && gate.startedPaths.count == 2)
    }

    private nonisolated func testNormalizedKeyPureContract() throws {
        let cases: [(input: String, expected: String)] = [
            ("", ""),
            (".", "."),
            ("./", "."),
            ("././", "."),
            ("/", "/"),
            ("////", "/"),
            ("/././", "/"),
            ("/folder//size/./child///", "/folder/size/child"),
            ("//server///share/./", "/server/share"),
            ("/a/b/../c", "/a/b/../c"),
            ("/a/./../b//", "/a/../b"),
            ("/../a", "/../a"),
            ("/a/..", "/a/.."),
            ("/..", "/.."),
            ("a", "a"),
            ("/a", "/a"),
            ("a//./b/", "a/b"),
            ("../a/./b/../", "../a/b/.."),
            ("..", ".."),
            ("../../", "../.."),
            ("/Case/CASE/case", "/Case/CASE/case"),
            ("/private/tmp/item", "/private/tmp/item"),
            ("/tmp/item", "/tmp/item"),
            ("/root/%2E/%2e%2e/%2F", "/root/%2E/%2e%2e/%2F"),
            ("percent%20name", "percent%20name"),
            ("/~/~user/folder", "/~/~user/folder"),
            ("~", "~"),
            ("~/./folder", "~/folder"),
            ("~someone//folder", "~someone/folder"),
            ("file://host/path%20name", "file:/host/path%20name"),
            (#"/a\b//./c"#, #"/a\b/c"#),
            (#"a\..\b"#, #"a\..\b"#),
        ]
        for entry in cases {
            let normalized = FolderSizeCache.normalizedKey(entry.input)
            try expect(normalized == entry.expected)
            try expect(FolderSizeCache.normalizedKey(normalized) == normalized)
        }
        try expect(FolderSizeCache.normalizedKey("") != FolderSizeCache.normalizedKey("."))
        try expect(FolderSizeCache.normalizedKey(".") != FolderSizeCache.normalizedKey("/"))
        try expect(FolderSizeCache.normalizedKey("a") != FolderSizeCache.normalizedKey("/a"))
        try expect(FolderSizeCache.normalizedKey("/a/../b") != FolderSizeCache.normalizedKey("/b"))
        try expect(FolderSizeCache.normalizedKey("/private/tmp") != FolderSizeCache.normalizedKey("/tmp"))
        try expect(FolderSizeCache.normalizedKey("/Case") != FolderSizeCache.normalizedKey("/case"))
        try expect(FolderSizeCache.normalizedKey("/%2F") != FolderSizeCache.normalizedKey("/"))
    }

    private func testNormalizedAliasesCoalesceAcrossPublicAPI() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 2, maxResults: 2,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let firstOwner = UUID(), secondOwner = UUID()
        defer { cache.release(owner: firstOwner); cache.release(owner: secondOwner) }
        let path = "/folder-size/normalization/child"
        let sibling = "/folder-size/normalization/childish"
        let aliases = [path, "/folder-size//normalization/./child/", "//folder-size/normalization/child//."]
        cache.updateDemand(owner: firstOwner, paths: aliases + [sibling])
        cache.updateDemand(owner: secondOwner, paths: Array(aliases.reversed()))
        try await waitFor("normalized alias worker") { gate.startedPaths.count == 1 }
        try expect(gate.startedPaths == [path])
        try expect(cache.debugSnapshot.demanded == 2 && cache.debugSnapshot.queued == 1)
        try expect(aliases.allSatisfy { cache.status(for: $0) == .scanning })
        try expect(aliases.allSatisfy { cache.result(for: $0) == nil && cache.size(for: $0) == nil })
        try expect(cache.status(for: sibling) == .queued)
        gate.complete(0, bytes: 100)
        try await waitFor("normalized alias result") { aliases.allSatisfy { cache.size(for: $0) == 100 } }
        try expect(aliases.allSatisfy { cache.result(for: $0) == FolderSizeResult(bytes: 100, isComplete: true) })
        try expect(aliases.allSatisfy { cache.status(for: $0) == .complete })
        try await waitFor("normalized sibling worker") { gate.startedPaths.count == 2 }
        try expect(gate.startedPaths[1] == sibling)
        gate.complete(1, bytes: 200)
        try await waitFor("normalized sibling result") { cache.size(for: sibling) == 200 }
        try expect(Set(cache.results.keys) == Set([path, sibling]))
        try expect(Set(cache.sizes.keys) == Set([path, sibling]))

        cache.invalidate(containing: "/folder-size//normalization/./child/./")
        try expect(aliases.allSatisfy { cache.result(for: $0) == nil && cache.size(for: $0) == nil })
        try expect(cache.size(for: sibling) == 200 && cache.status(for: sibling) == .complete)
        try await waitFor("normalized containing invalidation restart") { gate.startedPaths.count == 3 }
        try expect(gate.startedPaths[2] == path)
        try expect(aliases.allSatisfy { cache.status(for: $0) == .scanning })
        gate.complete(2, bytes: 300)
        try await waitFor("normalized containing replacement") { aliases.allSatisfy { cache.size(for: $0) == 300 } }
        try expect(aliases.allSatisfy { cache.result(for: $0) == FolderSizeResult(bytes: 300, isComplete: true) })

        cache.invalidate(aliases[2])
        try expect(aliases.allSatisfy { cache.result(for: $0) == nil })
        try expect(cache.size(for: sibling) == 200)
        try await waitFor("normalized exact invalidation restart") { gate.startedPaths.count == 4 }
        try expect(gate.startedPaths[3] == path)
        gate.complete(3, bytes: 400)
        try await waitFor("normalized exact replacement") { aliases.allSatisfy { cache.size(for: $0) == 400 } }
        try expect(aliases.allSatisfy { cache.status(for: $0) == .complete })
        try expect(gate.startedPaths == [path, sibling, path, path])
    }

    private func testParentComponentsRemainDistinctCacheKeys() async throws {
        let gate = FolderSizeCalculatorGate()
        defer { gate.releaseAll() }
        let cache = FolderSizeCache(maxWorkers: 1, maxDemand: 5, maxResults: 5,
            cancellableCalculator: { gate.calculate($0, isCancelled: $1) })
        let owner = UUID()
        defer { cache.release(owner: owner) }
        let parentSpelling = "/folder-size/link/../payload"
        let collapsedSpelling = "/folder-size/payload"
        let relativeSpelling = "folder-size/payload"
        let paths = ["", "/", parentSpelling, collapsedSpelling, relativeSpelling]
        cache.updateDemand(owner: owner, paths: paths)
        try expect(cache.debugSnapshot.demanded == 5)
        for index in paths.indices {
            try await waitFor("literal spelling worker \(index)") { gate.startedPaths.count == index + 1 }
            try expect(gate.startedPaths[index] == paths[index])
            gate.complete(index, bytes: Int64(index + 1))
            try await waitFor("literal spelling result \(index)") { cache.size(for: paths[index]) == Int64(index + 1) }
        }
        try expect(cache.size(for: parentSpelling) == 3 && cache.size(for: collapsedSpelling) == 4)
        try expect(cache.size(for: relativeSpelling) == 5 && cache.size(for: "/") == 2)
        cache.invalidate("/folder-size//link/./../payload/")
        try expect(cache.result(for: parentSpelling) == nil)
        try expect(cache.size(for: collapsedSpelling) == 4 && cache.size(for: relativeSpelling) == 5)
        try await waitFor("literal parent restart") { gate.startedPaths.count == 6 }
        try expect(gate.startedPaths[5] == parentSpelling)
        gate.complete(5, bytes: 50)
        try await waitFor("literal parent replacement") { cache.size(for: parentSpelling) == 50 }

        // A normalized absolute root reaches all absolute keys, but is not the
        // current directory and must not accidentally claim relative spellings.
        cache.invalidate(containing: "//./")
        let absolutePaths = ["/", parentSpelling, collapsedSpelling]
        try expect(absolutePaths.allSatisfy { cache.result(for: $0) == nil })
        try expect(cache.size(for: "") == 1 && cache.status(for: "") == .complete)
        try expect(cache.size(for: relativeSpelling) == 5 && cache.status(for: relativeSpelling) == .complete)
        try expect(cache.debugSnapshot.completed == 2 && cache.debugSnapshot.demanded == 5)
        try expect(cache.debugSnapshot.running == 1 && cache.debugSnapshot.queued == 2)
        try await waitFor("absolute root restart") { gate.startedPaths.count == 7 }
        try expect(absolutePaths.contains(gate.startedPaths[6]))
    }

    private func testNormalizedKeyPreservesSymlinkParentSpelling() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-size-key-link-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("elsewhere", isDirectory: true)
            .appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let linkPath = root.path + "/link"
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: destination.path)
        let storedDestination = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        try expect(storedDestination == destination.path)
        let input = root.path + "/link//./../payload/"
        let expected = root.path + "/link/../payload"
        // This is a key-spelling contract, not resolved identity or a promise of
        // universal watcher coherence between distinct filesystem aliases.
        try expect(FolderSizeCache.normalizedKey(input) == expected)
        try expect(FolderSizeCache.normalizedKey(input) != root.path + "/payload")
        try FileManager.default.removeItem(at: destination)
        // Changing the link's target availability cannot change a lexical key.
        try expect(FolderSizeCache.normalizedKey(input) == expected)
    }
}
