import Foundation
import AppKit

@MainActor
struct TerminalApplicationLifecycleRegressionTests {
    func runAll() async throws {
        try testEmptyAndPendingAdmission()
        try testOwnershipAndAllWorkersBarrier()
        try testTimeoutRetryAndStaleCallbacks()
        try await testHeldProductionStarts()
        try await testProductionWorkerCompletion()
        try await testNestedModalDelivery()
    }

    private func testEmptyAndPendingAdmission() throws {
        let empty = TerminalApplicationLifecycle()
        try expect(empty.beginTermination { _ in preconditionFailure("Empty barrier must not reply") } == .now)
        try expect(!empty.admit(TerminalCommandSession()))

        var deadlines: [@MainActor () -> Void] = []
        let lifecycle = TerminalApplicationLifecycle(scheduleDeadline: { _, work in deadlines.append(work) })
        let queued = TerminalCommandSession()
        try expect(lifecycle.admit(queued))
        try expect(!lifecycle.admit(queued))
        var replies: [Bool] = []
        try expect(lifecycle.beginTermination { replies.append($0) } == .later)
        try expect(queued.isCancelled)
        try expect(!lifecycle.admit(TerminalCommandSession()))
        try expect(lifecycle.beginTermination { _ in preconditionFailure("Repeated quit must not replace reply") } == .later)
        try expect(deadlines.count == 1 && replies.isEmpty)
        // Admission happened before the worker started: no spawn occurs now.
        let result = try queued.run(command: "exit 93", directory: URL(fileURLWithPath: "/tmp"))
        try expect(result.wasCancelled && result.status == 0)
        try expect(replies.isEmpty)
        lifecycle.finished(queued)
        lifecycle.finished(queued)
        deadlines[0]()
        try expect(replies == [true] && lifecycle.activeCount == 0)
        try expect(!lifecycle.admit(TerminalCommandSession()))
    }

    private func testOwnershipAndAllWorkersBarrier() throws {
        let lifecycle = TerminalApplicationLifecycle(scheduleDeadline: { _, _ in })
        var first: TerminalCommandSession? = TerminalCommandSession()
        weak var owned = first
        try expect(lifecycle.admit(first!))
        first = nil // Drawer released its reference, but the app must retain the lease.
        try expect(owned != nil && lifecycle.activeCount == 1)
        let second = TerminalCommandSession()
        try expect(lifecycle.admit(second))
        var replies: [Bool] = []
        _ = lifecycle.beginTermination { replies.append($0) }
        try expect(owned!.isCancelled && second.isCancelled)
        lifecycle.finished(owned!)
        try expect(owned == nil && replies.isEmpty && lifecycle.activeCount == 1)
        lifecycle.finished(TerminalCommandSession()) // Unowned completion is not authority.
        try expect(replies.isEmpty)
        lifecycle.finished(second)
        try expect(replies == [true])
    }

    private func testTimeoutRetryAndStaleCallbacks() throws {
        var deadlines: [@MainActor () -> Void] = []
        let lifecycle = TerminalApplicationLifecycle(scheduleDeadline: { delay, work in
            precondition(delay == 5)
            deadlines.append(work)
        })
        let old = TerminalCommandSession()
        try expect(lifecycle.admit(old))
        var firstReplies: [Bool] = []
        _ = lifecycle.beginTermination { firstReplies.append($0) }
        deadlines[0]()
        try expect(firstReplies == [false] && lifecycle.activeCount == 1)
        let new = TerminalCommandSession()
        try expect(lifecycle.admit(new))
        var retryReplies: [Bool] = []
        _ = lifecycle.beginTermination { retryReplies.append($0) }
        try expect(new.isCancelled && old.isCancelled)
        deadlines[0]() // Old deadline cannot cancel the retry.
        lifecycle.finished(old)
        lifecycle.finished(old)
        try expect(firstReplies == [false] && retryReplies.isEmpty && lifecycle.activeCount == 1)
        lifecycle.finished(new)
        deadlines[1]()
        try expect(retryReplies == [true] && firstReplies == [false])

        // Completion after timeout must never turn a refused quit into an exit.
        let late = TerminalApplicationLifecycle(scheduleDeadline: { _, work in deadlines.append(work) })
        let session = TerminalCommandSession()
        try expect(late.admit(session))
        var lateReplies: [Bool] = []
        _ = late.beginTermination { lateReplies.append($0) }
        deadlines.last!()
        late.finished(session)
        try expect(lateReplies == [false] && late.activeCount == 0)
        try expect(late.admit(TerminalCommandSession()))
    }

    private func testHeldProductionStarts() async throws {
        var workers: [@Sendable () -> Void] = []
        var deadlines: [@MainActor () -> Void] = []
        let lifecycle = TerminalApplicationLifecycle(enqueueWorker: { workers.append($0) },
            scheduleDeadline: { _, work in deadlines.append(work) })
        var completions = 0
        var first = lifecycle.start(command: "exit 91", directory: URL(fileURLWithPath: "/tmp")) { result in
            if case .success(let value) = result, value.wasCancelled, value.status == 0 { completions += 1 }
        }
        weak var firstLease = first
        var second = lifecycle.start(command: "exit 92", directory: URL(fileURLWithPath: "/tmp")) { result in
            if case .success(let value) = result, value.wasCancelled, value.status == 0 { completions += 1 }
        }
        weak var secondLease = second
        first = nil
        second = nil // Both drawers can disappear before either worker starts.
        try expect(firstLease != nil && secondLease != nil && lifecycle.activeCount == 2)
        var replies: [Bool] = []
        try expect(lifecycle.beginTermination { replies.append($0) } == .later)
        try expect(firstLease!.isCancelled && secondLease!.isCancelled && replies.isEmpty)
        try expect(lifecycle.start(command: "exit 93", directory: URL(fileURLWithPath: "/tmp")) { _ in
            preconditionFailure("Rejected worker must not complete")
        } == nil)
        try expect(workers.count == 2)
        workers.removeFirst()()
        // Even a synchronous test enqueuer cannot synchronously release/reply;
        // start() always marshals completion asynchronously to the main actor.
        try expect(replies.isEmpty && completions == 0)
        for _ in 0..<100 where completions < 1 { pumpDefaultRunLoop(); try await Task.sleep(nanoseconds: 1_000_000) }
        try expect(completions == 1 && lifecycle.activeCount == 1 && replies.isEmpty)
        workers.removeFirst()()
        for _ in 0..<100 where completions < 2 { pumpDefaultRunLoop(); try await Task.sleep(nanoseconds: 1_000_000) }
        try expect(completions == 2 && replies == [true] && lifecycle.activeCount == 0)
        try expect(firstLease == nil && secondLease == nil)
        deadlines[0]()
        try expect(replies == [true])
    }

    // The async CLI runner is not NSApplication.main; explicitly service the
    // default run loop when testing the production delivery mechanism.
    private func pumpDefaultRunLoop() {
        precondition(Thread.isMainThread)
        _ = CFRunLoopRunInMode(.defaultMode, 0.001, false)
    }

    private func testNestedModalDelivery() async throws {
        let failure: String? = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                // Keep this dispatch callback on the stack while pumping modal
                // mode, the boundary created by AppKit's terminateLater contract.
                func pumpModal(until condition: () -> Bool, seconds: TimeInterval) {
                    let limit = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
                    let timer = Timer(timeInterval: 0.01, repeats: true) { _ in }
                    RunLoop.main.add(timer, forMode: .modalPanel)
                    defer { timer.invalidate() }
                    while !condition() && DispatchTime.now().uptimeNanoseconds < limit {
                        _ = CFRunLoopRunInMode(CFRunLoopMode(rawValue: RunLoop.Mode.modalPanel.rawValue as CFString), 0.01, false)
                    }
                }
                var legacyDispatch = false
                var legacyActor = false
                DispatchQueue.main.async { legacyDispatch = true }
                Task { @MainActor in legacyActor = true }
                pumpModal(until: { false }, seconds: 0.05)
                guard !legacyDispatch && !legacyActor else {
                    continuation.resume(returning: "Nested-loop negative control did not reproduce queued delivery starvation")
                    return
                }

                let lifecycle = TerminalApplicationLifecycle(timeout: 1.5)
                var completed = 0
                var replies: [Bool] = []
                _ = lifecycle.start(command: "sleep 30", directory: URL(fileURLWithPath: "/tmp")) { _ in completed += 1 }
                _ = lifecycle.beginTermination { replies.append($0) }
                pumpModal(until: { !replies.isEmpty }, seconds: 2)
                guard replies == [true], completed == 1, lifecycle.activeCount == 0 else {
                    continuation.resume(returning: "Production worker completion did not drain in nested modal mode")
                    return
                }

                var held: [@Sendable () -> Void] = []
                let stalled = TerminalApplicationLifecycle(timeout: 0.05, enqueueWorker: { held.append($0) })
                var refused: [Bool] = []
                _ = stalled.start(command: "exit 0", directory: URL(fileURLWithPath: "/tmp")) { _ in }
                _ = stalled.beginTermination { refused.append($0) }
                pumpModal(until: { !refused.isEmpty }, seconds: 1)
                guard refused == [false], stalled.activeCount == 1, held.count == 1 else {
                    continuation.resume(returning: "Production deadline did not refuse quit and retain lease in modal mode")
                    return
                }
                held.removeFirst()()
                pumpModal(until: { stalled.activeCount == 0 }, seconds: 1)
                guard stalled.activeCount == 0, refused == [false], !legacyDispatch, !legacyActor else {
                    continuation.resume(returning: "Late completion or nested-dispatch ownership violated")
                    return
                }
                continuation.resume(returning: nil)
            }
        }
        if let failure { throw RegressionFailure(description: failure) }
    }

    private func testProductionWorkerCompletion() async throws {
        let lifecycle = TerminalApplicationLifecycle()
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        var result: Result<TerminalCommandResult, Error>?
        let session = lifecycle.start(command: "exit 7", directory: directory) { result = $0 }
        try expect(session != nil && lifecycle.activeCount == 1)
        for _ in 0..<500 where result == nil { pumpDefaultRunLoop(); try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(result != nil && lifecycle.activeCount == 0)
        if case .success(let value) = result { try expect(value.status == 7) }
        else { throw RegressionFailure(description: "Production terminal worker did not return exit 7") }

        // Failure before spawn must release the lease and deliver a single completion.
        var failures = 0
        _ = lifecycle.start(command: "exit 0", directory: directory.appendingPathComponent(UUID().uuidString)) { result in
            if case .failure = result { failures += 1 }
        }
        for _ in 0..<500 where lifecycle.activeCount != 0 { pumpDefaultRunLoop(); try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(failures == 1 && lifecycle.activeCount == 0)

        // Quit can be requested immediately after enqueue, before any main-actor
        // completion. This exercises production launch/finish rather than fake UI.
        var cancellations = 0
        var replies: [Bool] = []
        let cancelling = lifecycle.start(command: "sleep 30", directory: directory) { result in
            if case .success(let value) = result, value.wasCancelled { cancellations += 1 }
        }
        try expect(cancelling != nil)
        try expect(lifecycle.beginTermination { replies.append($0) } == .later)
        for _ in 0..<500 where replies.isEmpty { pumpDefaultRunLoop(); try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(replies == [true] && cancellations == 1 && lifecycle.activeCount == 0)
    }
}
