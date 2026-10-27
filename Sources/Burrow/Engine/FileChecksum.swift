import Foundation
import CryptoKit
import Darwin

/// Publication must use the application's live pane owner, not the old
/// ObservedObject reference captured by a SwiftUI view value.
struct FileChecksumPublicationContext: Sendable {
    let requestID: UUID
    let paneID: UUID
    let revision: UInt64
    let path: String

    func canPublish(currentRequestID: UUID, activePaneID: UUID,
                    sourceRevision: UInt64, selectedPath: String?) -> Bool {
        requestID == currentRequestID && paneID == activePaneID &&
        revision == sourceRevision && path == selectedPath
    }
}

struct FileChecksumDigest: Equatable, Sendable {
    let sha256: String
    let md5: String
}

enum FileChecksumFailure: Error, LocalizedError, Sendable {
    case cancelled
    case notRegular
    case changed
    case io(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Anulowano obliczanie sum kontrolnych."
        case .notRegular: return "Sumy kontrolne są dostępne tylko dla zwykłych plików, nie dowiązań ani urządzeń."
        case .changed: return "Plik zmienił się podczas obliczania. Spróbuj ponownie."
        case .io(let reason): return "Nie udało się odczytać pliku: \(reason)"
        }
    }
}

/// Cancellation never closes a descriptor from another thread. A running OS
/// call may finish later; cancellation is checked between all reads. Queued
/// operations are canceled without starting IO and do not deliver callbacks.
final class FileChecksumRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private var finished = false
    private var operation: Operation?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func cancel() {
        lock.lock()
        cancelled = true
        if !started { finished = true }
        let pending = operation
        operation = nil
        lock.unlock()
        pending?.cancel()
    }

    fileprivate func attach(_ value: Operation) {
        lock.lock()
        let rejected = cancelled
        if !rejected { operation = value }
        lock.unlock()
        if rejected { value.cancel() }
    }

    fileprivate func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { finished = true; operation = nil; return false }
        started = true
        return true
    }

    fileprivate func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        operation = nil
    }
}

struct FileChecksumHooks: Sendable {
    var beforeOpen: (@Sendable () throws -> Void)? = nil
    var afterChunk: (@Sendable (Int) throws -> Void)? = nil
}

final class FileChecksumService: @unchecked Sendable {
    static let shared = FileChecksumService()
    private let queue: OperationQueue

    init(maxConcurrentOperations: Int = 2) {
        queue = OperationQueue()
        queue.name = "com.burrow.checksums"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(1, maxConcurrentOperations)
    }

    @discardableResult
    func start(for url: URL, hooks: FileChecksumHooks = FileChecksumHooks(),
               completion: @escaping @MainActor @Sendable (Result<FileChecksumDigest, FileChecksumFailure>) -> Void) -> FileChecksumRequest {
        let request = FileChecksumRequest()
        let operation = BlockOperation {
            guard request.begin() else { return }
            let result: Result<FileChecksumDigest, FileChecksumFailure>
            do { result = .success(try Self.compute(for: url, request: request, hooks: hooks)) }
            catch let failure as FileChecksumFailure { result = .failure(failure) }
            catch { result = .failure(.io(error.localizedDescription)) }
            request.finish()
            guard !request.isCancelled else { return }
            Task { @MainActor in
                guard !request.isCancelled else { return }
                completion(result)
            }
        }
        request.attach(operation)
        queue.addOperation(operation)
        return request
    }

    private static func checkCancellation(_ request: FileChecksumRequest) throws {
        if request.isCancelled { throw FileChecksumFailure.cancelled }
    }

    private static func compute(for url: URL, request: FileChecksumRequest,
                                hooks: FileChecksumHooks) throws -> FileChecksumDigest {
        try checkCancellation(request)
        var entry = stat()
        guard url.path.withCString({ lstat($0, &entry) }) == 0 else {
            throw FileChecksumFailure.io(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription)
        }
        guard entry.st_mode & S_IFMT == S_IFREG else { throw FileChecksumFailure.notRegular }
        try hooks.beforeOpen?()
        try checkCancellation(request)
        // NONBLOCK also protects the lstat/open race if a regular entry is
        // replaced by a FIFO. NOFOLLOW rejects a replacement leaf symlink.
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_NOCTTY) }
        guard fd >= 0 else {
            throw FileChecksumFailure.io(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(fd, &initial) == 0 else { throw FileChecksumFailure.io("fstat") }
        guard initial.st_mode & S_IFMT == S_IFREG else { throw FileChecksumFailure.notRegular }
        guard initial.st_dev == entry.st_dev, initial.st_ino == entry.st_ino,
              initial.st_gen == entry.st_gen, initial.st_size >= 0 else { throw FileChecksumFailure.changed }
        try checkCancellation(request)
        var remaining = initial.st_size
        var sha = SHA256()
        var md5 = Insecure.MD5()
        var chunks = 0
        // Bound work to the initial regular-file size: an indefinitely appended
        // file cannot turn this into an unbounded read-to-EOF loop.
        while remaining > 0 {
            try checkCancellation(request)
            let amount = Int(min(remaining, 1 << 20))
            guard let data = try handle.read(upToCount: amount), !data.isEmpty else { throw FileChecksumFailure.changed }
            remaining -= Int64(data.count)
            chunks += 1
            try hooks.afterChunk?(chunks)
            try checkCancellation(request)
            sha.update(data: data)
            md5.update(data: data)
        }
        try checkCancellation(request)
        var final = stat()
        guard fstat(fd, &final) == 0 else { throw FileChecksumFailure.io("fstat") }
        guard final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else { throw FileChecksumFailure.changed }
        var currentEntry = stat()
        guard url.path.withCString({ lstat($0, &currentEntry) }) == 0,
              currentEntry.st_mode & S_IFMT == S_IFREG,
              currentEntry.st_dev == initial.st_dev, currentEntry.st_ino == initial.st_ino,
              currentEntry.st_gen == initial.st_gen else { throw FileChecksumFailure.changed }
        try checkCancellation(request)
        return FileChecksumDigest(sha256: sha.finalize().map { String(format: "%02x", $0) }.joined(),
                                  md5: md5.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
