import AppKit
import Foundation

@MainActor
struct ThumbnailLifecycleRegressionTests {
    @MainActor private final class Generator {
        struct Call {
            let path: String
            let completion: (NSImage?) -> Void
            var cancelled = false
        }
        var calls: [Call] = []
        func start(_ item: FileItem, _ completion: @escaping (NSImage?) -> Void) -> (() -> Void) {
            let index = calls.count
            calls.append(Call(path: item.path, completion: completion))
            return { self.calls[index].cancelled = true }
        }
    }

    private func item(_ index: Int, size: Int64 = 1) -> FileItem {
        let path = "/thumbnail-tests/\(index).png"
        return FileItem(url: URL(fileURLWithPath: path), name: "\(index).png", path: path,
                        parentPath: "/thumbnail-tests", fileExtension: "png", isDirectory: false,
                        isHidden: false, size: size, modificationDate: .distantPast, kindCategory: .image)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(25)) }

    func runAll() async throws {
        try await testAdmissionAndRetry()
        try await testInvalidationAndReplacement()
        try await testErrorsAndCacheBound()
        try await testNeverCompletingProviderReleasesAdmission()
        try await testExpiredQueueCanRetryAndNotificationsCoalesce()
        try await testTransientTimeoutRetriesAndFailureBudgetSettles()
        try testQuickSearchObservesThumbnailCapacity()
        try testProductionDefaultBudgets()
        print("PASS thumbnail bounded admission, cancellation, identity, retry, timeout and cache")
    }

    private func testAdmissionAndRetry() async throws {
        let generator = Generator()
        let cache = FileIconCache(thumbnailLimits: .init(active: 2, queued: 2, cached: 10),
                                  thumbnailGenerator: generator.start)
        for index in 0..<10 { cache.requestThumbnailIfNeeded(for: item(index)) }
        for _ in 0..<100 { cache.requestThumbnailIfNeeded(for: item(0)) }
        try expect(generator.calls.count == 2)
        try expect(cache.activeThumbnailCount == 2 && cache.queuedThumbnailCount == 2)
        try expect(cache.retainedThumbnailVersionCount == 4)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        // Model the observed views re-reading icon demand after capacity changes.
        // Every accepted key is FIFO, rejected keys have no poison dedupe token.
        for index in 0..<10 {
            try expect(generator.calls.count > index)
            try expect(generator.calls[index].path == item(index).path)
            generator.calls[index].completion(image)
            try await settle()
            for demand in 0..<10 { cache.requestThumbnailIfNeeded(for: item(demand)) }
            try expect(cache.activeThumbnailCount <= 2 && cache.queuedThumbnailCount <= 2)
        }
        try expect(generator.calls.count == 10 && cache.thumbnails.count == 10)
        let revision = cache.thumbnailCapacityRevision
        for demand in 0..<10 { cache.requestThumbnailIfNeeded(for: item(demand)) }
        try await settle()
        try expect(cache.thumbnailCapacityRevision == revision && generator.calls.count == 10)
    }

    private func testInvalidationAndReplacement() async throws {
        let generator = Generator()
        let cache = FileIconCache(thumbnailLimits: .init(active: 1, queued: 2, cached: 3),
                                  thumbnailGenerator: generator.start)
        cache.requestThumbnailIfNeeded(for: item(0))
        cache.requestThumbnailIfNeeded(for: item(1))
        cache.requestThumbnailIfNeeded(for: item(2))
        cache.invalidate(containing: "/thumbnail-tests")
        try expect(generator.calls[0].cancelled)
        try expect(cache.activeThumbnailCount == 0 && cache.queuedThumbnailCount == 0)
        try expect(cache.retainedThumbnailVersionCount == 0)
        cache.requestThumbnailIfNeeded(for: item(0))
        let old = NSImage(size: NSSize(width: 1, height: 1))
        generator.calls[0].completion(old)
        try await settle()
        try expect(cache.thumbnails[item(0).path] == nil && cache.activeThumbnailCount == 1)
        // Metadata replacement cancels the exact replacement handle as well.
        cache.requestThumbnailIfNeeded(for: item(0, size: 2))
        try expect(generator.calls[1].cancelled && generator.calls.count == 3)
        generator.calls[1].completion(old)
        let fresh = NSImage(size: NSSize(width: 2, height: 2))
        generator.calls[2].completion(fresh)
        try await settle()
        try expect(cache.thumbnails[item(0).path] === fresh)
        generator.calls[2].completion(old) // duplicate provider callback is harmless
        try await settle()
        try expect(cache.thumbnails[item(0).path] === fresh)
    }

    private func testErrorsAndCacheBound() async throws {
        let generator = Generator()
        let cache = FileIconCache(thumbnailLimits: .init(active: 1, queued: 1, cached: 2),
                                  thumbnailGenerator: generator.start)
        cache.requestThumbnailIfNeeded(for: item(0))
        cache.requestThumbnailIfNeeded(for: item(1))
        generator.calls[0].completion(nil)
        try await settle()
        try expect(generator.calls.count == 2 && cache.activeThumbnailCount == 1)
        for _ in 0..<100 { cache.requestThumbnailIfNeeded(for: item(0)) }
        try expect(generator.calls.count == 2) // failed result is stable
        generator.calls[1].completion(NSImage(size: NSSize(width: 1, height: 1)))
        try await settle()
        for index in 2..<12 {
            cache.requestThumbnailIfNeeded(for: item(index))
            generator.calls[index].completion(NSImage(size: NSSize(width: 1, height: 1)))
            try await settle()
            try expect(cache.thumbnails.count <= 2 && cache.completedThumbnailCount == 2)
            try expect(cache.retainedThumbnailVersionCount == 2)
        }
        cache.invalidate(containing: item(11).path)
        cache.requestThumbnailIfNeeded(for: item(11))
        try expect(generator.calls.count == 13)
    }

    private func testNeverCompletingProviderReleasesAdmission() async throws {
        let generator = Generator()
        let cache = FileIconCache(thumbnailLimits: .init(active: 1, queued: 1, cached: 4, timeout: .milliseconds(30)),
                                  thumbnailGenerator: generator.start)
        cache.requestThumbnailIfNeeded(for: item(0))
        cache.requestThumbnailIfNeeded(for: item(1))
        cache.requestThumbnailIfNeeded(for: item(2)) // rejected, not forgotten forever
        for _ in 0..<100 where generator.calls.count < 2 { try await settle() }
        try expect(generator.calls[0].cancelled && generator.calls.count == 2)
        cache.requestThumbnailIfNeeded(for: item(2))
        for _ in 0..<100 where cache.activeThumbnailCount > 0 { try await settle() }
        try expect(generator.calls.count == 3 && generator.calls.allSatisfy(\.cancelled))
        try expect(cache.activeThumbnailCount == 0 && cache.queuedThumbnailCount == 0)
        for index in 0..<3 { cache.requestThumbnailIfNeeded(for: item(index)) }
        try expect(generator.calls.count == 3)
    }

    private func testExpiredQueueCanRetryAndNotificationsCoalesce() async throws {
        let generator = Generator()
        let cache = FileIconCache(thumbnailLimits: .init(active: 1, queued: 1, cached: 4,
                                                        timeout: .seconds(5), maxQueueAge: .milliseconds(10)),
                                  thumbnailGenerator: generator.start)
        cache.requestThumbnailIfNeeded(for: item(0))
        cache.requestThumbnailIfNeeded(for: item(1))
        try await settle()
        generator.calls[0].completion(nil)
        try await settle()
        try expect(generator.calls.count == 1 && cache.queuedThumbnailCount == 0)
        cache.requestThumbnailIfNeeded(for: item(1))
        try expect(generator.calls.count == 2) // expiration did not poison identity
        let revision = cache.thumbnailCapacityRevision
        for _ in 0..<50 { cache.invalidate(containing: "/thumbnail-tests") }
        try await settle()
        try expect(cache.thumbnailCapacityRevision == revision + 1)
        try expect(generator.calls[1].cancelled)
    }

    private func testTransientTimeoutRetriesAndFailureBudgetSettles() async throws {
        let generator = Generator()
        let cache = FileIconCache(thumbnailLimits: .init(active: 1, queued: 1, cached: 4,
                                                        timeout: .milliseconds(30), retryDelay: .milliseconds(30), retries: 1),
                                  thumbnailGenerator: generator.start)
        cache.requestThumbnailIfNeeded(for: item(0))
        for _ in 0..<100 where cache.activeThumbnailCount > 0 { try await settle() }
        try expect(generator.calls[0].cancelled)
        let afterTimeout = cache.thumbnailCapacityRevision
        try await Task.sleep(for: .milliseconds(80))
        try expect(cache.thumbnailCapacityRevision > afterTimeout)
        cache.requestThumbnailIfNeeded(for: item(0))
        try expect(generator.calls.count == 2) // one-off timeout is not permanent
        let image = NSImage(size: NSSize(width: 1, height: 1))
        generator.calls[1].completion(image)
        try await settle()
        try expect(cache.thumbnails[item(0).path] === image)
        cache.requestThumbnailIfNeeded(for: item(1))
        generator.calls[2].completion(nil)
        try await Task.sleep(for: .milliseconds(80))
        cache.requestThumbnailIfNeeded(for: item(1))
        try expect(generator.calls.count == 4)
        generator.calls[3].completion(nil)
        try await Task.sleep(for: .milliseconds(80))
        let settledRevision = cache.thumbnailCapacityRevision
        for _ in 0..<10 {
            cache.requestThumbnailIfNeeded(for: item(1))
            try await settle()
        }
        try expect(generator.calls.count == 4 && cache.thumbnailCapacityRevision == settledRevision)
        cache.invalidate(containing: item(1).path)
        cache.requestThumbnailIfNeeded(for: item(1))
        try expect(generator.calls.count == 5) // explicit invalidation resets budget
        cache.invalidate(containing: "/thumbnail-tests")
    }

    private func testQuickSearchObservesThumbnailCapacity() throws {
        // Source integration guard complements injected scheduler tests. It does
        // not claim to execute SwiftUI rendering or native observation delivery.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Burrow/Views/SheetsAndModals.swift"), encoding: .utf8)
        guard let start = source.range(of: "struct QuickFSearchSpotlightModal: View {") else {
            throw RegressionFailure(description: "Quick search production view missing")
        }
        let modal = String(source[start.lowerBound...]).components(separatedBy: "\nstruct ")[0]
        try expect(modal.contains("@ObservedObject private var iconCache = FileIconCache.shared"))
        try expect(modal.contains("Image(nsImage: iconCache.icon(for: item))"))
        try expect(!modal.contains("FileIconCache.shared.icon(for:"))
    }

    private func testProductionDefaultBudgets() throws {
        let generator = Generator()
        let cache = FileIconCache(thumbnailGenerator: generator.start)
        for index in 0..<2_000 { cache.requestThumbnailIfNeeded(for: item(index)) }
        try expect(generator.calls.count == 4)
        try expect(cache.activeThumbnailCount == 4 && cache.queuedThumbnailCount == 64)
        try expect(cache.retainedThumbnailVersionCount == 68)
        cache.invalidate(containing: "/thumbnail-tests")
        try expect(generator.calls.allSatisfy(\.cancelled))
    }
}
