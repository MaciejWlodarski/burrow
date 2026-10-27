import Foundation

/// Logical cancellation does not release a physical IO slot. A blocked system
/// call may finish later; only worker return removes an entry from `running`.
@MainActor
final class AnalysisWorkRequest {
    enum State: Equatable { case queued, running, cancelling, cancelled, deferred, finished }
    let token: AnalysisRequestToken
    private(set) var state: State = .queued
    private var cancellation: (() -> Void)?
    private var notifiedState: State?
    private var changed: (@MainActor (State) -> Void)?

    init(token: AnalysisRequestToken, changed: @escaping @MainActor (State) -> Void) {
        self.token = token
        self.changed = changed
    }
    func cancel() { cancellation?() }
    fileprivate func installCancellation(_ action: @escaping () -> Void) { cancellation = action }
    fileprivate func transition(_ value: State) {
        guard notifiedState != value else { return }
        notifiedState = value
        state = value
        let notify = changed
        if value == .cancelled || value == .deferred || value == .finished {
            cancellation = nil
            changed = nil
        }
        notify?(value)
    }
}

@MainActor
final class AnalysisWorkService {
    static let shared = AnalysisWorkService()
    /// Stable surface keys survive refreshes and tab replacement. A new request
    /// cannot overlap the old physical call belonging to the same surface.
    struct Consumer: Hashable, Sendable {
        let rawValue: String
        static func analysis(_ side: PaneSide) -> Self { Self(rawValue: "analysis-" + side.rawValue) }
        static let comparison = Self(rawValue: "comparison")
    }
    private struct Job: Sendable {
        let consumer: Consumer
        let request: AnalysisWorkRequest
        let token: AnalysisRequestToken
        let perform: @Sendable () -> (@MainActor @Sendable () -> Void)
    }
    private let maxWorkers: Int
    private let maxPending: Int
    private let queue = DispatchQueue(label: "com.burrow.analysis", qos: .userInitiated, attributes: .concurrent)
    private var running: [UUID: Job] = [:]
    private var pending: [Job] = []

    init(maxWorkers: Int = 2, maxPending: Int = 4) {
        precondition(maxWorkers > 0 && maxPending > 0)
        self.maxWorkers = maxWorkers
        self.maxPending = maxPending
    }

    @discardableResult
    func submit<Value: Sendable>(consumer: Consumer, token: AnalysisRequestToken,
        stateChanged: @escaping @MainActor (AnalysisWorkRequest.State) -> Void = { _ in },
        work: @escaping @Sendable () -> Value,
        completion: @escaping @MainActor @Sendable (Value) -> Void) -> AnalysisWorkRequest {
        let request = AnalysisWorkRequest(token: token, changed: stateChanged)
        guard !token.isCancelled else {
            request.transition(.cancelled)
            return request
        }
        let job = Job(consumer: consumer, request: request, token: token, perform: {
            let result = work()
            return { completion(result) }
        })
        request.installCancellation { [weak self] in self?.cancel(token.id) }
        // Replace in place, preserving FIFO position. Never accumulate cancelled
        // closures in an OperationQueue or a deferred retry registry.
        let replacement = pending.firstIndex { $0.consumer == consumer }
        let oldPending = replacement.map { pending.remove(at: $0) }
        let oldRunning = running.values.filter { $0.consumer == consumer }
        for old in oldRunning { old.token.cancel() }
        oldPending?.token.cancel()
        let canLaunch = running.count < maxWorkers && oldRunning.isEmpty && pending.isEmpty
        if token.isCancelled {
            request.transition(.cancelled)
        } else if canLaunch {
            running[token.id] = job
        } else if replacement != nil || pending.count < maxPending {
            pending.insert(job, at: min(replacement ?? pending.count, pending.count))
        } else {
            request.transition(.deferred)
        }
        oldPending?.request.transition(.cancelled)
        for old in oldRunning { old.request.transition(.cancelling) }
        if canLaunch {
            // A reentrant cancellation callback may have cancelled this reserved
            // job. launch must finalize it rather than leak the reserved slot.
            launch(job)
        } else if pending.contains(where: { $0.token.id == token.id }) {
            request.transition(.queued)
        }
        drain()
        return request
    }

    private func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.token.id == id }) {
            let job = pending.remove(at: index)
            job.token.cancel()
            job.request.transition(.cancelled)
        } else if let job = running[id] {
            job.token.cancel()
            job.request.transition(.cancelling)
        }
        drain()
    }
    private func drain() {
        while running.count < maxWorkers,
              let index = pending.firstIndex(where: { next in
                  !running.values.contains { $0.consumer == next.consumer }
              }) {
            let job = pending.remove(at: index)
            if job.token.isCancelled { job.request.transition(.cancelled); continue }
            running[job.token.id] = job
            launch(job)
        }
    }
    private func launch(_ job: Job) {
        guard running[job.token.id] != nil else { return }
        guard !job.token.isCancelled else {
            finish(job.token.id, delivery: nil)
            return
        }
        job.request.transition(.running)
        queue.async {
            // Cancellation before dispatch causes zero filesystem work.
            let delivery = job.token.isCancelled ? nil : job.perform()
            Task { @MainActor in
                self.finish(job.token.id, delivery: delivery)
            }
        }
    }
    private func finish(_ id: UUID, delivery: (@MainActor @Sendable () -> Void)?) {
        guard let job = running.removeValue(forKey: id) else { return }
        job.request.transition(job.token.isCancelled ? .cancelled : .finished)
        // A state callback may invalidate the request; recheck before delivery.
        if !job.token.isCancelled { delivery?() }
        drain()
    }
    var debugSnapshot: (running: Int, pending: Int) { (running.count, pending.count) }
}
