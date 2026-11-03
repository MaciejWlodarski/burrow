import Foundation

/// A folder listing read off the main actor, ready to install in a pane.
struct PreparedFolder: Sendable {
    let root: URL?
    let entries: [IndexedFileEntry]
}

/// Owns a queued or running operation and its continuation. Cancellation resumes
/// exactly once immediately, even if the OS call itself cannot be interrupted.
final class BackgroundWork<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: BlockOperation?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        let operation = self.operation
        self.operation = nil
        lock.unlock()
        operation?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    func enqueue(on queue: OperationQueue, continuation: CheckedContinuation<Value, Error>,
                 work: @escaping @Sendable () throws -> Value) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let operation = BlockOperation { [self] in
            guard !isCancelled else { return }
            let result = Result { try work() }
            finish(result)
        }
        self.operation = operation
        lock.unlock()
        queue.addOperation(operation)
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.operation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Two bounded workers for folder reads that may hang (dropped shares,
/// sleeping disks), so a stuck read never blocks the main actor or piles up.
enum BackgroundFolderQueue {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.burrow.background-folder-reads"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T,
                                request: BackgroundWork<T> = BackgroundWork<T>()) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.enqueue(on: queue, continuation: continuation, work: work)
            }
        } onCancel: {
            request.cancel()
        }
    }
}
