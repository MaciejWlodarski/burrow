import Foundation

private final class AnalysisAdapterGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered: [String] = []
    private var released = Set<String>()
    private var releaseEverything = false
    private var usedMainThread = false
    func hold(_ name: String) {
        condition.lock()
        entered.append(name)
        usedMainThread = usedMainThread || Thread.isMainThread
        condition.broadcast()
        while !releaseEverything && !released.contains(name) { condition.wait() }
        condition.unlock()
    }
    func release(_ name: String) {
        condition.lock(); released.insert(name); condition.broadcast(); condition.unlock()
    }
    func releaseAll() {
        condition.lock(); releaseEverything = true; condition.broadcast(); condition.unlock()
    }
    var names: [String] { condition.lock(); defer { condition.unlock() }; return entered }
    var ranOnMain: Bool { condition.lock(); defer { condition.unlock() }; return usedMainThread }
}

@MainActor
struct AnalysisWorkAdapterRegressionTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bf-analysis-adapters-\(UUID())")
        var left: URL { root.appendingPathComponent("left") }
        var right: URL { root.appendingPathComponent("right") }
        init() throws {
            for dir in [left, right] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for name in ["a.dat", "b.dat"] {
                    let file = dir.appendingPathComponent(name)
                    try Data("same payload".utf8).write(to: file)
                    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: file.path)
                }
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }
    @MainActor private final class Results {
        var scan: AnalysisScanResult?
        var comparison: AnalysisComparisonResult?
        var verification: AnalysisVerificationResult?
        var callbacks = 0
    }
    @MainActor private final class VerificationUI {
        var current: AnalysisRequestToken?
        var busy = true
        var error: String?
        var oldTerminalObserved = false
        var acceptedCompletions = 0
    }
    private static func until(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() {
            if Date() >= deadline { throw RegressionFailure(description: "Analysis adapter watchdog expired") }
            await Task.yield()
        }
    }
    static func runAll() async throws -> Int {
        try await testProductionAdaptersUseSharedAdmission()
        try await testVerificationCancelRestartPreservesScanAndNewestState()
        try await testComparisonReplacementCannotPublishOldResult()
        try await testAdaptersExposeDeferredAndCancelQueuedWork()
        try testRenderedActionsRequireTheirOwnCompletedGeneration()
        try await testCurrentVerificationTerminalCancellationClearsBusy()
        return 6
    }
    private static func completedScan(_ fixture: Fixture, service: AnalysisWorkService) async throws -> (AnalysisRequestToken, AnalysisScanResult) {
        let token = AnalysisRequestToken(rootPath: fixture.left.path)
        let results = Results()
        let request = AnalysisWorkAdapters.startScan(
            AnalysisScanInput(rootURL: fixture.left, showHidden: true, mode: .duplicates),
            consumer: .analysis(.left), token: token, service: service) { result in
                results.scan = result
                results.callbacks += 1
            }
        try await until { results.callbacks == 1 }
        try expect(request.state == .finished && !token.isCancelled)
        guard let scan = results.scan else { throw RegressionFailure(description: "Production scan returned nil") }
        try expect(scan.complete && scan.files.count == 2 && scan.groups.count == 1)
        return (token, scan)
    }
    private static func testProductionAdaptersUseSharedAdmission() async throws {
        let fixture = try Fixture(), service = AnalysisWorkService(maxWorkers: 1, maxPending: 2)
        let gate = AnalysisAdapterGate(), results = Results()
        defer { gate.releaseAll() }
        let scanToken = AnalysisRequestToken(rootPath: fixture.left.path)
        let compareToken = AnalysisRequestToken(rootPath: fixture.left.path)
        let scan = AnalysisWorkAdapters.startScan(
            AnalysisScanInput(rootURL: fixture.left, showHidden: true, mode: .duplicates),
            consumer: .analysis(.left), token: scanToken, service: service,
            hooks: AnalysisWorkHooks(beforeWork: { gate.hold("scan") })) {
                results.scan = $0; results.callbacks += 1
            }
        try await until { gate.names == ["scan"] }
        let compare = AnalysisWorkAdapters.startComparison(
            AnalysisComparisonInput(left: fixture.left, right: fixture.right, includeHidden: true),
            token: compareToken, service: service, hooks: AnalysisWorkHooks(beforeWork: { gate.hold("compare") })) {
                results.comparison = $0; results.callbacks += 1
            }
        try expect(scan.state == .running && compare.state == .queued)
        try expect(service.debugSnapshot.running == 1 && service.debugSnapshot.pending == 1)
        gate.release("scan")
        try await until { gate.names == ["scan", "compare"] }
        guard let result = results.scan else { throw RegressionFailure(description: "Scheduled real scan did not publish") }
        try expect(result.complete && result.groups.count == 1 && result.files.count == 2)
        let verificationToken = AnalysisRequestToken(rootPath: fixture.left.path)
        let verify = AnalysisWorkAdapters.startVerification(result.groups, consumer: .analysis(.left),
            token: verificationToken, service: service, hooks: AnalysisWorkHooks(beforeWork: { gate.hold("verify") })) {
                results.verification = $0; results.callbacks += 1
            }
        try expect(verify.state == .queued && service.debugSnapshot.pending == 1)
        gate.release("compare")
        try await until { gate.names.count == 3 }
        try expect(gate.names == ["scan", "compare", "verify"])
        try expect(results.comparison?.diagnostic == nil && results.comparison?.entries.count == 2)
        try expect(results.comparison?.entries.allSatisfy { $0.status == .identical } == true)
        gate.release("verify")
        try await until { results.callbacks == 3 }
        guard case .verified? = results.verification else { throw RegressionFailure(description: "Real group verification failed") }
        try expect(service.debugSnapshot.running == 0 && !gate.ranOnMain && !scanToken.isCancelled)
    }
    private static func testVerificationCancelRestartPreservesScanAndNewestState() async throws {
        let fixture = try Fixture(), service = AnalysisWorkService(maxWorkers: 2, maxPending: 4)
        let (scanToken, scan) = try await completedScan(fixture, service: service)
        let gate = AnalysisAdapterGate(), ui = VerificationUI()
        defer { gate.releaseAll() }
        let oldToken = AnalysisRequestToken(rootPath: fixture.left.path)
        ui.current = oldToken
        let old = AnalysisWorkAdapters.startVerification(scan.groups, consumer: .analysis(.left), token: oldToken,
            service: service, hooks: AnalysisWorkHooks(beforeWork: { gate.hold("old") }), stateChanged: { state in
                if state == .cancelled { ui.oldTerminalObserved = true }
                // Terminal state uses current-generation ownership, not result
                // publication eligibility. Old cancellation must not reset new UI.
                guard ui.current === oldToken, !scanToken.isCancelled else { return }
                if state == .cancelled { ui.busy = false; ui.error = "old cancellation" }
            }, completion: { _ in ui.acceptedCompletions += 1 })
        try await until { gate.names == ["old"] }
        old.cancel()
        try expect(!scanToken.isCancelled && oldToken.isCancelled)
        let newToken = AnalysisRequestToken(rootPath: fixture.left.path)
        ui.current = newToken
        ui.busy = true
        ui.error = "new request owns state"
        let newer = AnalysisWorkAdapters.startVerification(scan.groups, consumer: .analysis(.left), token: newToken,
            service: service, hooks: AnalysisWorkHooks(beforeWork: { gate.hold("new") }), completion: { result in
                guard newToken.canPublishVerification(active: ui.current, scan: scanToken, activeScan: scanToken) else { return }
                ui.busy = false
                if case .failed(let error) = result { ui.error = error } else { ui.error = nil }
                ui.acceptedCompletions += 1
            })
        try expect(newer.state == .queued && service.debugSnapshot.running == 1)
        gate.release("old")
        try await until { gate.names == ["old", "new"] }
        try expect(ui.oldTerminalObserved && ui.busy && ui.error == "new request owns state")
        try expect(ui.acceptedCompletions == 0 && !scanToken.isCancelled)
        try expect(!oldToken.canPublishVerification(active: newToken, scan: scanToken, activeScan: scanToken))
        gate.release("new")
        try await until { ui.acceptedCompletions == 1 }
        try expect(!ui.busy && ui.error == nil && !scanToken.isCancelled && !gate.ranOnMain)
    }
    private static func testComparisonReplacementCannotPublishOldResult() async throws {
        let fixture = try Fixture(), service = AnalysisWorkService(maxWorkers: 2, maxPending: 4)
        let gate = AnalysisAdapterGate(), results = Results()
        defer { gate.releaseAll() }
        let input = AnalysisComparisonInput(left: fixture.left, right: fixture.right, includeHidden: true)
        let oldToken = AnalysisRequestToken(rootPath: fixture.left.path)
        let old = AnalysisWorkAdapters.startComparison(input, token: oldToken, service: service,
            hooks: AnalysisWorkHooks(beforeWork: { gate.hold("old") })) { _ in results.callbacks += 100 }
        try await until { gate.names == ["old"] }
        old.cancel()
        try Data("different payload".utf8).write(to: fixture.right.appendingPathComponent("a.dat"))
        let token = AnalysisRequestToken(rootPath: fixture.left.path)
        let current = AnalysisWorkAdapters.startComparison(input, token: token, service: service,
            hooks: AnalysisWorkHooks(beforeWork: { gate.hold("current") })) {
                results.comparison = $0; results.callbacks += 1
            }
        try expect(current.state == .queued && service.debugSnapshot.running == 1)
        gate.release("old")
        try await until { gate.names == ["old", "current"] }
        try expect(results.callbacks == 0 && old.state == .cancelled)
        gate.release("current")
        try await until { results.callbacks == 1 }
        try expect(results.comparison?.entries.first { $0.name == "a.dat" }?.status == .modified)
        try expect(results.comparison?.diagnostic == nil && service.debugSnapshot.running == 0)
    }
    private static func testAdaptersExposeDeferredAndCancelQueuedWork() async throws {
        let fixture = try Fixture(), service = AnalysisWorkService(maxWorkers: 1, maxPending: 1)
        let gate = AnalysisAdapterGate(), results = Results()
        defer { gate.releaseAll() }
        let blockerToken = AnalysisRequestToken(rootPath: fixture.root.path)
        service.submit(consumer: .init(rawValue: "blocker"), token: blockerToken,
            work: { gate.hold("blocker"); return true }, completion: { _ in })
        try await until { gate.names == ["blocker"] }
        let scan = AnalysisWorkAdapters.startScan(AnalysisScanInput(rootURL: fixture.left, showHidden: true, mode: .duplicates),
            consumer: .analysis(.left), token: AnalysisRequestToken(rootPath: fixture.left.path), service: service,
            hooks: AnalysisWorkHooks(beforeWork: { gate.hold("forbidden scan") })) { _ in results.callbacks += 1 }
        let compare = AnalysisWorkAdapters.startComparison(
            AnalysisComparisonInput(left: fixture.left, right: fixture.right, includeHidden: true),
            token: AnalysisRequestToken(rootPath: fixture.left.path), service: service,
            hooks: AnalysisWorkHooks(beforeWork: { gate.hold("forbidden compare") })) { _ in results.callbacks += 1 }
        let deferredScanToken = AnalysisRequestToken(rootPath: fixture.right.path)
        let deferredScan = AnalysisWorkAdapters.startScan(
            AnalysisScanInput(rootURL: fixture.right, showHidden: true, mode: .duplicates),
            consumer: .analysis(.right), token: deferredScanToken, service: service,
            hooks: AnalysisWorkHooks(beforeWork: { gate.hold("forbidden deferred scan") }),
            stateChanged: { if $0 == .deferred { deferredScanToken.cancel() } },
            completion: { _ in results.callbacks += 1 })
        try expect(deferredScan.state == .deferred && deferredScanToken.isCancelled)
        try expect(!deferredScanToken.canUseAnalysisResult(active: deferredScanToken,
            resultReady: true, isComplete: true, requiresComplete: false))
        let verify = AnalysisWorkAdapters.startVerification([], consumer: .analysis(.right),
            token: AnalysisRequestToken(rootPath: fixture.right.path), service: service,
            hooks: AnalysisWorkHooks(beforeWork: { gate.hold("forbidden verify") })) { _ in results.callbacks += 1 }
        try expect(scan.state == .queued && compare.state == .deferred && verify.state == .deferred)
        scan.cancel()
        gate.release("blocker")
        try await until { service.debugSnapshot.running == 0 }
        try expect(service.debugSnapshot.pending == 0 && gate.names == ["blocker"] && results.callbacks == 0)
    }
    private static func testRenderedActionsRequireTheirOwnCompletedGeneration() throws {
        let rendered = AnalysisRequestToken(rootPath: "/same-root")
        let replacement = AnalysisRequestToken(rootPath: "/same-root")
        // Completed partial scans permit explicit generic Trash, not automatic cleanup.
        try expect(rendered.canUseAnalysisResult(active: rendered, resultReady: true, isComplete: false, requiresComplete: false))
        try expect(!rendered.canUseAnalysisResult(active: rendered, resultReady: true, isComplete: false, requiresComplete: true))
        try expect(rendered.canUseAnalysisResult(active: rendered, resultReady: true, isComplete: true, requiresComplete: true))
        // Old closures cannot rebind their payload to a new completed generation,
        // even when both scans use the same root and the old token was not cancelled.
        for complete in [false, true] {
            try expect(!rendered.canUseAnalysisResult(active: replacement, resultReady: true, isComplete: complete, requiresComplete: false))
            try expect(!rendered.canUseAnalysisResult(active: replacement, resultReady: true, isComplete: complete, requiresComplete: true))
        }
        try expect(!replacement.canUseAnalysisResult(active: replacement, resultReady: false, isComplete: true, requiresComplete: false))
        replacement.cancel()
        try expect(!replacement.canUseAnalysisResult(active: replacement, resultReady: true, isComplete: true, requiresComplete: false))
    }
    private static func testCurrentVerificationTerminalCancellationClearsBusy() async throws {
        let fixture = try Fixture(), service = AnalysisWorkService(maxWorkers: 1, maxPending: 1)
        let (scanToken, scan) = try await completedScan(fixture, service: service)
        let gate = AnalysisAdapterGate(), ui = VerificationUI()
        defer { gate.releaseAll() }
        let token = AnalysisRequestToken(rootPath: fixture.left.path)
        ui.current = token
        let request = AnalysisWorkAdapters.startVerification(scan.groups, consumer: .analysis(.left),
            token: token, service: service, hooks: AnalysisWorkHooks(beforeWork: { gate.hold("current") }),
            stateChanged: { state in
                guard ui.current === token, !scanToken.isCancelled else { return }
                if state == .cancelled { ui.busy = false; ui.current = nil }
            }, completion: { _ in ui.acceptedCompletions += 1 })
        try await until { gate.names == ["current"] }
        request.cancel()
        try expect(ui.busy && !scanToken.isCancelled)
        gate.release("current")
        try await until { service.debugSnapshot.running == 0 }
        try expect(!ui.busy && ui.current == nil && ui.acceptedCompletions == 0 && !scanToken.isCancelled)
    }

}
