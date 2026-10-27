import Foundation
import CoreGraphics
import ImageIO

@MainActor
struct InspectorPreviewRegressionTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bf-preview-\(UUID())", isDirectory: true)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    }
    private final class Gate: @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var entered = false
        private var onMain = false
        var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
        func hold() throws {
            lock.lock(); entered = true; onMain = Thread.isMainThread; lock.unlock()
            guard release.wait(timeout: .now() + 4) == .success else { throw RegressionFailure(description: "Preview gate timed out") }
        }
    }
    @MainActor private final class Waiter {
        var continuation: CheckedContinuation<InspectorPreviewContent, Error>?
        var request: InspectorPreviewRequest?
        var deadline: Task<Void, Never>?
        init(_ continuation: CheckedContinuation<InspectorPreviewContent, Error>) { self.continuation = continuation }
        func finish(_ result: Result<InspectorPreviewContent, Error>, cancel: Bool = false) {
            guard let continuation else { return }
            self.continuation = nil
            deadline?.cancel(); deadline = nil
            if cancel { request?.cancel() }
            request = nil
            continuation.resume(with: result)
        }
    }
    private static func preview(_ input: InspectorPreviewInput, service: InspectorPreviewService = .shared, timeout: Duration = .seconds(5)) async throws -> InspectorPreviewContent {
        try await withCheckedThrowingContinuation { continuation in
            let waiter = Waiter(continuation)
            waiter.request = service.start(input) { waiter.finish(.success($0)) }
            waiter.deadline = Task { @MainActor in
                do { try await Task.sleep(for: timeout) } catch { return }
                waiter.finish(.failure(RegressionFailure(description: "Preview test watchdog timed out")), cancel: true)
            }
        }
    }
    private static func until(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try expect(predicate())
    }
    static func runAll() async throws -> Int {
        try await testTextPrefixIgnoresStaleSize()
        try await testThumbnailDimensionsOrientationAndBudgets()
        try await testChangedAndSymlinkEntries()
        try await testBoundedAdmissionCancellationAndLiveOwner()
        try await testWatchdogCannotMasqueradeAsRejection()
        return 5
    }

    private static func testWatchdogCannotMasqueradeAsRejection() async throws {
        let gate = Gate()
        defer { gate.release.signal() }
        let service = InspectorPreviewService { _, _ in
            try gate.hold()
            return .unavailable("Ordinary production rejection")
        }
        var timedOut = false
        do {
            // No preparation result arrives before the deadline. A normal
            // unavailable value would make all rejection tests falsely pass.
            _ = try await preview(InspectorPreviewInput(url: URL(fileURLWithPath: "/unused"), isImage: false, targetLine: 1),
                                  service: service, timeout: .milliseconds(50))
        } catch let failure as RegressionFailure {
            timedOut = failure.description == "Preview test watchdog timed out"
        }
        try expect(timedOut)
    }

    private static func testTextPrefixIgnoresStaleSize() async throws {
        let f = try Fixture(), url = f.url("large.txt")
        try Data(repeating: 0x61, count: 100_000).write(to: url)
        // No FileItem.size is accepted: actual descriptor size controls reads.
        let input = InspectorPreviewInput(url: url, isImage: false, targetLine: 1)
        guard case .text(let lines) = try await preview(input) else { throw RegressionFailure(description: "Text preview failed") }
        try expect(lines.count == 1 && lines[0].1.utf8.count == 24 * 1024)
        try Data([0, 1, 2, 3]).write(to: url)
        guard case .unavailable = try await preview(input) else { throw RegressionFailure(description: "Binary preview accepted") }
        let canceled = InspectorPreviewRequest(); canceled.cancel()
        do {
            _ = try InspectorPreviewService.read(input, request: canceled)
            throw RegressionFailure(description: "Canceled read started")
        } catch is CancellationError { }
    }

    private static func testThumbnailDimensionsOrientationAndBudgets() async throws {
        let f = try Fixture(), url = f.url("orientation.jpg")
        guard let context = CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw RegressionFailure(description: "Cannot create image fixture") }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            throw RegressionFailure(description: "Cannot create JPEG destination")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        try expect(CGImageDestinationFinalize(destination))
        try (encoded as Data).write(to: url)
        let input = InspectorPreviewInput(url: url, isImage: true, targetLine: 1)
        guard case .image(let thumbnail, let width, let height) = try await preview(input) else {
            throw RegressionFailure(description: "Image thumbnail failed")
        }
        try expect(width == 1600 && height == 1200)
        try expect(thumbnail.width <= 768 && thumbnail.height <= 768 && thumbnail.height > thumbnail.width)
        try expect(thumbnail.colorSpace != nil)
        // Lower injected limits exercise hostile dimensions/encoded sizes using
        // a modest fixture, not a decompression bomb or giant allocation.
        let pixelLimited = InspectorPreviewService { input, request in
            var limits = InspectorPreviewLimits(); limits.originalPixels = 1000
            return try InspectorPreviewService.read(input, request: request, limits: limits)
        }
        guard case .unavailable = try await preview(input, service: pixelLimited) else { throw RegressionFailure(description: "Pixel limit ignored") }
        let byteLimited = InspectorPreviewService { input, request in
            var limits = InspectorPreviewLimits(); limits.imageBytes = 1
            return try InspectorPreviewService.read(input, request: request, limits: limits)
        }
        guard case .unavailable = try await preview(input, service: byteLimited) else { throw RegressionFailure(description: "Encoded byte limit ignored") }
    }

    private static func testChangedAndSymlinkEntries() async throws {
        for beforeOpen in [true, false] {
            let f = try Fixture(), url = f.url("original.txt"), saved = f.url("saved.txt"), target = f.url("target.txt")
            try Data("original".utf8).write(to: url)
            try Data("other".utf8).write(to: target)
            let mutate: @Sendable () throws -> Void = {
                try FileManager.default.moveItem(at: url, to: saved)
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            }
            let hooks = InspectorPreviewHooks(beforeOpen: beforeOpen ? mutate : nil, afterRead: beforeOpen ? nil : mutate)
            let service = InspectorPreviewService { input, request in
                try InspectorPreviewService.read(input, request: request, hooks: hooks)
            }
            let input = InspectorPreviewInput(url: url, isImage: false, targetLine: 1)
            guard case .unavailable = try await preview(input, service: service) else { throw RegressionFailure(description: "Changed entry published") }
            guard case .unavailable = try await preview(input) else { throw RegressionFailure(description: "Leaf symlink preview accepted") }
        }
    }

    private static func testBoundedAdmissionCancellationAndLiveOwner() async throws {
        let f = try Fixture()
        let gates = (0..<5).map { _ in Gate() }
        defer { gates.forEach { $0.release.signal() } }
        let service = InspectorPreviewService { input, _ in
            let index = Int(input.url.lastPathComponent)!
            try gates[index].hold()
            return .text([(1, String(index))])
        }
        let paneA = UUID(), paneB = UUID(), requestID = UUID()
        var liveOwner = paneA
        var published: Set<Int> = []
        let context = FileChecksumPublicationContext(requestID: requestID, paneID: paneA, revision: 1, path: f.url("0").path)
        let first = service.start(InspectorPreviewInput(url: f.url("0"), isImage: false, targetLine: 1)) { _ in
            if context.canPublish(currentRequestID: requestID, activePaneID: liveOwner, sourceRevision: 1, selectedPath: f.url("0").path) {
                published.insert(0)
            }
        }
        let second = service.start(InspectorPreviewInput(url: f.url("1"), isImage: false, targetLine: 1)) { _ in published.insert(1) }
        try await until { gates[0].didEnter && gates[1].didEnter }
        try expect(!gates[0].ranOnMain && !gates[1].ranOnMain)
        let third = service.start(InspectorPreviewInput(url: f.url("2"), isImage: false, targetLine: 1)) { _ in published.insert(2) }
        let fourth = service.start(InspectorPreviewInput(url: f.url("3"), isImage: false, targetLine: 1)) { _ in published.insert(3) }
        let rejected = try await preview(InspectorPreviewInput(url: f.url("4"), isImage: false, targetLine: 1), service: service)
        guard case .unavailable = rejected else { throw RegressionFailure(description: "Pending budget exceeded") }
        try expect(!gates[2].didEnter && !gates[3].didEnter && !gates[4].didEnter)
        third.cancel() // Frees a pending slot immediately.
        let fifth = service.start(InspectorPreviewInput(url: f.url("4"), isImage: false, targetLine: 1)) { _ in published.insert(4) }
        liveOwner = paneB // Before any deferred SwiftUI cancellation callback.
        second.cancel() // Running cancellation suppresses its completed result.
        gates[0].release.signal(); gates[1].release.signal()
        try await until { gates[3].didEnter && gates[4].didEnter }
        gates[3].release.signal(); gates[4].release.signal()
        try await until { first.isFinished && second.isFinished && third.isFinished && fourth.isFinished && fifth.isFinished && published.contains(3) && published.contains(4) }
        try expect(!gates[2].didEnter && published == Set([3, 4]))
    }
}
