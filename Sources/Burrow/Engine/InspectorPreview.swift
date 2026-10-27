import Foundation
import CoreGraphics
import ImageIO
import Darwin

struct InspectorPreviewInput: Sendable {
    let url: URL
    let isImage: Bool
    let targetLine: Int
}

// CGImage is immutable; only the completed bounded image crosses to MainActor.
enum InspectorPreviewContent: @unchecked Sendable {
    case image(CGImage, width: Int, height: Int)
    case text([(Int, String)])
    case unavailable(String)
}

struct InspectorPreviewLimits: Sendable {
    var imageBytes = 32 * 1024 * 1024
    var originalPixels = 40_000_000
    var thumbnailDimension = 768
    var textBytes = 24 * 1024
}

struct InspectorPreviewHooks: Sendable {
    var beforeOpen: (@Sendable () throws -> Void)? = nil
    var afterRead: (@Sendable () throws -> Void)? = nil
}

final class InspectorPreviewRequest: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private var cancellation: (@Sendable () -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func cancel() {
        lock.lock(); cancelled = true; let action = cancellation; cancellation = nil; lock.unlock()
        action?()
    }
    fileprivate func onCancel(_ action: @escaping @Sendable () -> Void) {
        lock.lock(); let invoke = cancelled; if !invoke { cancellation = action }; lock.unlock()
        if invoke { action() }
    }
    fileprivate func finish() { lock.lock(); finished = true; cancellation = nil; lock.unlock() }
}

/// At most two running and two pending jobs. Canceling a queued request removes
/// it immediately instead of accumulating canceled OperationQueue entries.
final class InspectorPreviewService: @unchecked Sendable {
    typealias Prepare = @Sendable (InspectorPreviewInput, InspectorPreviewRequest) throws -> InspectorPreviewContent
    static let shared = InspectorPreviewService()
    private struct Job: Sendable {
        let input: InspectorPreviewInput
        let request: InspectorPreviewRequest
        let completion: @MainActor @Sendable (InspectorPreviewContent) -> Void
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.burrow.inspector-preview", qos: .userInitiated, attributes: .concurrent)
    private let prepare: Prepare
    private var active = 0
    private var pending: [Job] = []
    init(prepare: @escaping Prepare = { try InspectorPreviewService.read($0, request: $1) }) { self.prepare = prepare }

    @discardableResult
    func start(_ input: InspectorPreviewInput,
               completion: @escaping @MainActor @Sendable (InspectorPreviewContent) -> Void) -> InspectorPreviewRequest {
        let request = InspectorPreviewRequest()
        let id = request.id
        request.onCancel { [weak self] in self?.cancelQueued(id) }
        let job = Job(input: input, request: request, completion: completion)
        lock.lock()
        let launchNow = active < 2
        let rejected = !launchNow && pending.count >= 2
        if launchNow { active += 1 } else if !rejected { pending.append(job) }
        lock.unlock()
        if launchNow { launch(job) }
        else if rejected {
            request.finish()
            deliver(job, .unavailable("Podgląd jest zajęty. Użyj przycisku „Ponów podgląd” lub Quick Look."))
        }
        return request
    }

    private func cancelQueued(_ id: UUID) {
        lock.lock()
        let index = pending.firstIndex { $0.request.id == id }
        let removed = index.map { pending.remove(at: $0) }
        lock.unlock()
        removed?.request.finish()
    }

    private func launch(_ job: Job) {
        queue.async { [self] in
            var result: InspectorPreviewContent = .unavailable("Anulowano podgląd.")
            if !job.request.isCancelled {
                do { result = try prepare(job.input, job.request) }
                catch { result = .unavailable(error.localizedDescription) }
            }
            job.request.finish()
            lock.lock()
            active -= 1
            let next = pending.isEmpty ? nil : pending.removeFirst()
            if next != nil { active += 1 }
            lock.unlock()
            if let next { launch(next) }
            deliver(job, result)
        }
    }

    private func deliver(_ job: Job, _ result: InspectorPreviewContent) {
        Task { @MainActor in
            guard !job.request.isCancelled else { return }
            job.completion(result)
        }
    }

    private static func check(_ request: InspectorPreviewRequest) throws {
        if request.isCancelled { throw CancellationError() }
    }

    static func read(_ input: InspectorPreviewInput, request: InspectorPreviewRequest,
                     limits: InspectorPreviewLimits = InspectorPreviewLimits(),
                     hooks: InspectorPreviewHooks = InspectorPreviewHooks()) throws -> InspectorPreviewContent {
        try check(request)
        guard limits.imageBytes > 0, limits.originalPixels > 0,
              limits.thumbnailDimension > 0, limits.textBytes > 0 else {
            return .unavailable("Nieprawidłowy limit podglądu.")
        }
        var entry = stat()
        guard input.url.path.withCString({ lstat($0, &entry) }) == 0,
              entry.st_mode & S_IFMT == S_IFREG else {
            return .unavailable("Szybki podgląd obsługuje tylko zwykłe pliki, nie dowiązania ani urządzenia.")
        }
        try hooks.beforeOpen?()
        try check(request)
        let fd = input.url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | O_NOCTTY) }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_dev == entry.st_dev, initial.st_ino == entry.st_ino,
              initial.st_gen == entry.st_gen, initial.st_size >= 0 else {
            return .unavailable("Plik zmienił się przed odczytem podglądu.")
        }
        try check(request)
        if initial.st_size == 0 { return .unavailable("Plik jest pusty.") }
        if input.isImage && initial.st_size > Int64(limits.imageBytes) {
            return .unavailable("Obraz przekracza limit szybkiego podglądu (32 MiB). Użyj Quick Look.")
        }
        let byteCount = input.isImage ? Int(initial.st_size) : Int(min(initial.st_size, Int64(limits.textBytes)))
        var data = Data()
        data.reserveCapacity(byteCount)
        while data.count < byteCount {
            try check(request)
            guard let chunk = try handle.read(upToCount: min(256 * 1024, byteCount - data.count)), !chunk.isEmpty else {
                return .unavailable("Plik zmienił się podczas odczytu podglądu.")
            }
            data.append(chunk)
        }
        try check(request)
        try hooks.afterRead?()
        try check(request)
        let result: InspectorPreviewContent
        if input.isImage {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let h = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                return .unavailable("Nie można odczytać obrazu. Użyj Quick Look.")
            }
            let width = w.intValue, height = h.intValue
            guard width > 0, height > 0, width <= limits.originalPixels / height else {
                return .unavailable("Obraz przekracza limit 40 megapikseli szybkiego podglądu. Użyj Quick Look.")
            }
            try check(request)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limits.thumbnailDimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  image.width <= limits.thumbnailDimension, image.height <= limits.thumbnailDimension else {
                return .unavailable("Nie udało się przygotować miniatury obrazu.")
            }
            result = .image(image, width: width, height: height)
        } else if data.prefix(512).contains(0) {
            result = .unavailable("Podgląd treści binarnej jest niedostępny. Użyj Quick Look.")
        } else {
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            // A target beyond the bounded prefix falls back to the file head instead of an empty preview.
            let anchor = max(1, input.targetLine) <= lines.count ? max(1, input.targetLine) : 1
            let start = max(0, anchor - 15)
            let end = min(lines.count, start + 90)
            result = .text((start..<end).map { ($0 + 1, lines[$0]) })
        }
        try check(request)
        var final = stat(), pathEntry = stat()
        guard fstat(fd, &final) == 0,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
              input.url.path.withCString({ lstat($0, &pathEntry) }) == 0,
              pathEntry.st_dev == initial.st_dev, pathEntry.st_ino == initial.st_ino,
              pathEntry.st_gen == initial.st_gen else {
            return .unavailable("Plik zmienił się podczas przygotowywania podglądu. Użyj przycisku „Ponów podgląd”.")
        }
        return result
    }
}
