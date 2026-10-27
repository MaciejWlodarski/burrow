import Foundation
import AppKit

/// AppKit terminateLater pumps modalPanel mode, possibly inside an active main-
/// dispatch callback. Main-queue/Task hops cannot reliably escape that nesting.
/// Deliver directly through the main run loop without changing its common modes.
enum TerminalMainRunLoop {
    static func perform(_ work: @escaping @MainActor @Sendable () -> Void) {
        let main = CFRunLoopGetMain()
        // eventTracking preserves completion/timeout service during UI tracking.
        let modes = [RunLoop.Mode.default.rawValue, RunLoop.Mode.modalPanel.rawValue,
                     RunLoop.Mode.eventTracking.rawValue] as CFArray
        CFRunLoopPerformBlock(main, modes) {
            // CFRunLoopGetMain guarantees main-thread execution. This checked
            // synchronous bridge must not enqueue another main-actor Task.
            MainActor.assumeIsolated { work() }
        }
        CFRunLoopWakeUp(main)
    }

    static func after(_ delay: TimeInterval, work: @escaping @MainActor @Sendable () -> Void) {
        // Monotonic deadline timing must also be independent of the main queue.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
            perform(work)
        }
    }
}


/// Owns admitted drawer workers independently of SwiftUI view identity/lifetime.
/// This barrier covers normal application quit and the existing session's foreground
/// process-group cleanup, not forced exit or deliberately detached/background jobs.
@MainActor
final class TerminalApplicationLifecycle {
    static let shared = TerminalApplicationLifecycle()

    enum TerminationDecision: Equatable { case now, later }
    typealias DeadlineScheduler = (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    typealias WorkerEnqueuer = (@escaping @Sendable () -> Void) -> Void
    private let enqueueWorker: WorkerEnqueuer
    private var sessions: [ObjectIdentifier: TerminalCommandSession] = [:]
    private var acceptingCommands = true
    private var attempt: UUID?
    private var reply: ((Bool) -> Void)?
    private let scheduleDeadline: DeadlineScheduler
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 5,
         enqueueWorker: @escaping WorkerEnqueuer = { work in
             DispatchQueue.global(qos: .userInitiated).async(execute: work)
         }, scheduleDeadline: @escaping DeadlineScheduler = { delay, work in
        TerminalMainRunLoop.after(delay, work: work)
    }) {
        self.enqueueWorker = enqueueWorker
        self.timeout = timeout
        self.scheduleDeadline = scheduleDeadline
    }

    var activeCount: Int { sessions.count }

    // Main-actor admission precedes enqueue, closing the startup/quit race.
    @discardableResult
    func admit(_ session: TerminalCommandSession) -> Bool {
        let key = ObjectIdentifier(session)
        guard acceptingCommands, sessions[key] == nil else { return false }
        sessions[key] = session
        return true
    }

    func start(command: String, directory: URL,
               completion: @escaping @MainActor (Result<TerminalCommandResult, Error>) -> Void) -> TerminalCommandSession? {
        // Closed tabs may still own physically running workers during cancellation.
        guard sessions.count < 8 else { return nil }
        let session = TerminalCommandSession()
        guard admit(session) else { return nil }
        enqueueWorker {
            let result = Result { try session.run(command: command, directory: directory) }
            TerminalMainRunLoop.perform {
                // Unconditional ownership release, even if the drawer was replaced.
                self.finished(session)
                completion(result)
            }
        }
        return session
    }

    func finished(_ session: TerminalCommandSession) {
        guard sessions.removeValue(forKey: ObjectIdentifier(session)) != nil else { return }
        guard sessions.isEmpty, attempt != nil else { return }
        let callback = reply
        attempt = nil
        reply = nil
        // Keep admission closed while AppKit processes the successful reply.
        callback?(true)
    }

    func beginTermination(reply: @escaping (Bool) -> Void) -> TerminationDecision {
        guard attempt == nil else { return .later }
        acceptingCommands = false
        guard !sessions.isEmpty else { return .now }
        let identifier = UUID()
        attempt = identifier
        self.reply = reply
        for session in sessions.values { session.cancel() }
        scheduleDeadline(timeout) { [weak self] in
            guard let self, self.attempt == identifier else { return }
            let callback = self.reply
            self.attempt = nil
            self.reply = nil
            // Do not discard unfinished ownership or assume cancellation completed.
            self.acceptingCommands = true
            callback?(false)
        }
        return .later
    }
}
