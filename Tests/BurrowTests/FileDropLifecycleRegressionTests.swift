import Foundation
import AppKit

@MainActor
struct FileDropLifecycleRegressionTests {
    @MainActor private final class Probe {
        var callbacks: [(@Sendable (Result<URL, FileDropLoadingError>) -> Void)?] = []
        var handles: [Progress] = []
        func source() -> FileDropSource {
            FileDropSource { callback in
                self.callbacks.append(callback)
                let progress = Progress(totalUnitCount: 1)
                self.handles.append(progress)
                return progress
            }
        }
        func complete(_ index: Int, _ result: Result<URL, FileDropLoadingError>) {
            callbacks[index]?(result)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw RegressionFailure(description: "Timed out waiting for injected drop lifecycle state")
    }

    func runAll() async throws {
        try await testDeadlineFailsWholeBatchAndCancelsProgress()
        try await testOrderingDeduplicationAndBoundedConcurrency()
        try await testErrorsAndMalformedPayloadsFailWholeBatch()
        try await testCancellationAndReplacementCannotCommitLateResults()
        try await testCancellationBeforeStartAndProviderLimit()
        try await testCommitRevalidatesPaneBeforeDeferredViewObservers()
        try await testPausedGlobalResultsRejectRowDropsAtAdmissionAndCommit()
        print("PASS bounded external drop lifecycle, cancellation, ordering and fail-closed batches")
    }

    private func testDeadlineFailsWholeBatchAndCancelsProgress() async throws {
        let probe = Probe()
        let sources = [probe.source(), probe.source(), probe.source()]
        let controller = FileDropLoadController()
        var commits = 0
        controller.begin(destination: URL(fileURLWithPath: "/captured"), load: {
            try await FileDropLoader.urls(from: sources, concurrency: 2, timeoutNanoseconds: 500_000_000)
        }) { _ in commits += 1 }
        try await waitUntil { probe.callbacks.count == 2 }
        probe.complete(1, .success(URL(fileURLWithPath: "/second")))
        try await waitUntil { probe.callbacks.count == 3 }
        // Provider zero never calls back. Remaining work is not head-of-line blocked.
        try await waitUntil { !controller.isLoading }
        try expect(commits == 0 && controller.diagnostic != nil)
        try expect(probe.handles[0].isCancelled && probe.handles[2].isCancelled)
        let diagnostic = controller.diagnostic
        probe.complete(0, .success(URL(fileURLWithPath: "/late")))
        probe.complete(2, .success(URL(fileURLWithPath: "/late-too")))
        try await Task.sleep(nanoseconds: 10_000_000)
        try expect(commits == 0 && controller.diagnostic == diagnostic)
    }

    private func testOrderingDeduplicationAndBoundedConcurrency() async throws {
        let probe = Probe()
        let sources = (0..<6).map { _ in probe.source() }
        let task = Task { try await FileDropLoader.urls(from: sources, concurrency: 2, timeoutNanoseconds: 2_000_000_000) }
        try await waitUntil { probe.callbacks.count == 2 }
        try expect(probe.callbacks.count == 2)
        let a = URL(fileURLWithPath: "/a")
        let b = URL(fileURLWithPath: "/b")
        probe.complete(1, .success(b))
        probe.complete(1, .failure(.providerFailed)) // A duplicate cannot change the outcome.
        try await waitUntil { probe.callbacks.count == 3 }
        probe.complete(2, .success(a))
        try await waitUntil { probe.callbacks.count == 4 }
        probe.complete(3, .success(b))
        try await waitUntil { probe.callbacks.count == 5 }
        probe.complete(4, .success(URL(fileURLWithPath: "/c")))
        try await waitUntil { probe.callbacks.count == 6 }
        probe.complete(5, .success(a))
        probe.complete(0, .success(a))
        let result = try await task.value
        try expect(result == [a, b, URL(fileURLWithPath: "/c")])
    }

    private func testErrorsAndMalformedPayloadsFailWholeBatch() async throws {
        for failure in [Result<URL, FileDropLoadingError>.failure(.providerFailed),
                        .failure(.invalidPayload), .success(URL(string: "https://example.com/file")!)] {
            let controller = FileDropLoadController()
            let probe = Probe()
            var commits = 0
            controller.begin(destination: URL(fileURLWithPath: "/original"), load: {
                try await FileDropLoader.urls(from: [probe.source(), probe.source()], timeoutNanoseconds: 2_000_000_000)
            }) { _ in commits += 1 }
            try await waitUntil { probe.callbacks.count == 2 }
            probe.complete(0, .success(URL(fileURLWithPath: "/valid")))
            probe.complete(1, failure)
            try await waitUntil { !controller.isLoading }
            try expect(commits == 0 && controller.diagnostic != nil)
        }
        let malformed: [Any?] = [nil, "not a file", Data([0xFF, 0x00]), URL(string: "https://example.com")!]
        for value in malformed {
            if case .success = FileDropLoader.decodeItem(value) {
                throw RegressionFailure(description: "Malformed payload was accepted")
            }
        }
        let fileURL = URL(fileURLWithPath: "/valid-data")
        let decoded = try FileDropLoader.decodeItem(fileURL.dataRepresentation).get()
        try expect(decoded == fileURL)
        if case .success = FileDropLoader.decodeItem(fileURL, failed: true) {
            throw RegressionFailure(description: "Provider error with a valid payload was accepted")
        }
        try expect(!FileDropLoader.isValidFileURL(URL(string: "file://remote-server/path")!))
        try expect(!FileDropLoader.isValidFileURL(URL(string: "file:///path?query=value")!))
        try expect(!FileDropLoader.isValidFileURL(URL(string: "file:///path#fragment")!))
    }

    private func testCancellationAndReplacementCannotCommitLateResults() async throws {
        let controller = FileDropLoadController()
        let old = Probe()
        var commits: [[URL]] = []
        let destination = URL(fileURLWithPath: "/original")
        controller.begin(destination: destination, load: {
            try await FileDropLoader.urls(from: [old.source()], timeoutNanoseconds: 2_000_000_000)
        }) { commits.append($0) }
        try await waitUntil { old.callbacks.count == 1 }
        controller.cancel()
        try expect(!controller.isLoading && controller.diagnostic == nil)
        try await waitUntil { old.handles[0].isCancelled }
        let newer = Probe()
        controller.begin(destination: destination, load: {
            try await FileDropLoader.urls(from: [newer.source()], timeoutNanoseconds: 2_000_000_000)
        }) { commits.append($0) }
        try await waitUntil { newer.callbacks.count == 1 }
        old.complete(0, .success(URL(fileURLWithPath: "/stale")))
        newer.complete(0, .failure(.providerFailed))
        try await waitUntil { !controller.isLoading }
        let diagnostic = controller.diagnostic
        try await Task.sleep(nanoseconds: 10_000_000)
        try expect(commits.isEmpty && diagnostic != nil && controller.diagnostic == diagnostic)
        try expect(controller.destinationPath == destination.path)

        // Replacing a loading request is also cancellation, not a second commit.
        let replaced = Probe()
        controller.begin(destination: destination, load: {
            try await FileDropLoader.urls(from: [replaced.source()], timeoutNanoseconds: 2_000_000_000)
        }) { commits.append($0) }
        try await waitUntil { replaced.callbacks.count == 1 }
        controller.begin(destination: URL(fileURLWithPath: "/new-destination"), load: {
            [URL(fileURLWithPath: "/fresh")]
        }) { commits.append($0) }
        try await waitUntil { !controller.isLoading && replaced.handles[0].isCancelled }
        replaced.complete(0, .failure(.invalidPayload))
        try await Task.sleep(nanoseconds: 10_000_000)
        try expect(commits == [[URL(fileURLWithPath: "/fresh")]])
        try expect(controller.diagnostic == nil && controller.destinationPath == "/new-destination")
    }

    private func testCommitRevalidatesPaneBeforeDeferredViewObservers() async throws {
        let state = AppState.shared
        let pane = state.leftTab
        let originalURL = pane.currentURL
        let originalTabID = state.activeTabId
        let originalTabs = state.tabs
        defer {
            pane.currentURL = originalURL
            state.tabs = originalTabs
            state.activeTabId = originalTabID
        }
        let destination = originalURL.appendingPathComponent("captured-drop-folder")
        var committedDestinations: [URL] = []

        for change in 0..<3 {
            let controller = FileDropLoadController()
            let probe = Probe()
            let context = FileDropPaneContext(pane: pane)
            controller.begin(destination: destination, load: {
                try await FileDropLoader.urls(from: [probe.source()], timeoutNanoseconds: 2_000_000_000)
            }) { _ in
                guard context.allowsCommit(in: state, side: .left) else { return }
                committedDestinations.append(destination)
            }
            try await waitUntil { probe.callbacks.count == 1 }
            // No view is mounted and no onChange cancellation is invoked.
            if change == 2 {
                let replacement = PaneTabState(initialURL: originalURL)
                state.tabs.append(replacement)
                state.activeTabId = replacement.id
            } else {
                pane.currentURL = originalURL.appendingPathComponent("different-context")
                if change == 1 { pane.currentURL = originalURL }
            }
            probe.complete(0, .success(originalURL.appendingPathComponent("source")))
            try await waitUntil { !controller.isLoading }
            try expect(committedDestinations.isEmpty)
            try expect(controller.destinationPath == destination.path)
            pane.currentURL = originalURL
            state.tabs = originalTabs
            state.activeTabId = originalTabID
        }
        let context = FileDropPaneContext(pane: pane)
        try expect(context.allowsCommit(in: state, side: .left))
        // Navigating another pane does not redirect or cancel this captured drop.
        let otherURL = state.rightPane.currentURL
        state.rightPane.currentURL = otherURL.appendingPathComponent("unrelated")
        try expect(context.allowsCommit(in: state, side: .left))
        state.rightPane.currentURL = otherURL

        let controller = FileDropLoadController()
        let valid = Probe()
        var modifierChoice = true
        let capturedCopyChoice = modifierChoice
        var committedCopyChoices: [Bool] = []
        controller.begin(destination: destination, load: {
            try await FileDropLoader.urls(from: [valid.source()], timeoutNanoseconds: 2_000_000_000)
        }) { _ in
            guard context.allowsCommit(in: state, side: .left) else { return }
            committedDestinations.append(destination)
            committedCopyChoices.append(capturedCopyChoice)
        }
        try await waitUntil { valid.callbacks.count == 1 }
        modifierChoice = false
        valid.complete(0, .success(originalURL.appendingPathComponent("source")))
        try await waitUntil { !controller.isLoading }
        try expect(committedDestinations == [destination])
        try expect(committedCopyChoices == [true] && !modifierChoice)
    }

    private func testPausedGlobalResultsRejectRowDropsAtAdmissionAndCommit() async throws {
        let pane = FinderPaneSession(path: "/Volumes/Unavailable-Drop-Session/Root").makePausedPane()
        let global = SavedSmartFolderItem(title: "Global drop regression", query: "drop-session-no-match",
            scope: .wholeIndex, rootPath: nil, includeHidden: false, fuzzyEnabled: true)
        let applied = try await pane.applySavedSearch(global, prepare: { _ in
            throw RegressionFailure(description: "Global query must not load the paused browsing root")
        })
        try expect(applied && !pane.isSessionPaused && pane.isSessionBrowsingPaused)
        let source = URL(fileURLWithPath: "/tmp/drop-source")
        let providers = [NSItemProvider(object: source as NSURL)]
        try expect(FileDropLoader.accepts(providers))
        let file = FileItem(url: source, name: "drop-source", path: source.path, parentPath: "/tmp",
            fileExtension: "", isDirectory: false, isHidden: false, size: 1, modificationDate: .distantPast)
        for mode in [FinderViewMode.list, .icons] {
            pane.viewMode = mode
            pane.displayedItems = [file]
            try expect(!pane.selectableItems.isEmpty && pane.isSessionBrowsingPaused)
            // List/grid regular-file rows use currentURL as fallback destination.
            // Their common handler must reject before activating/loading anything.
            let rowDestination = file.isDirectory ? file.url : pane.currentURL
            try expect(rowDestination == pane.currentURL)
            try expect(!FileDropPaneContext.accepts(providers, in: pane))
        }

        let state = AppState.shared
        let oldTabs = state.tabs, oldID = state.activeTabId
        defer { state.tabs = oldTabs; state.activeTabId = oldID; pane.clearSearch() }
        state.tabs = [pane]
        state.activeTabId = pane.id
        let context = FileDropPaneContext(pane: pane)
        // All identity/path/revision fields match: only live paused-state checking
        // prevents a stale or already-admitted batch from reaching the manager.
        try expect(context.paneID == pane.id && context.browsingURL == pane.currentURL)
        try expect(context.navigationRevision == pane.navigationRevision)
        try expect(!context.allowsCommit(in: state, side: .left))
        let controller = FileDropLoadController()
        let probe = Probe()
        var commits = 0
        controller.begin(destination: pane.currentURL, load: {
            try await FileDropLoader.urls(from: [probe.source()], timeoutNanoseconds: 2_000_000_000)
        }) { _ in
            guard context.allowsCommit(in: state, side: .left) else { return }
            commits += 1
        }
        try await waitUntil { probe.callbacks.count == 1 }
        probe.complete(0, .success(source))
        try await waitUntil { !controller.isLoading }
        try expect(commits == 0 && pane.isSessionBrowsingPaused)
    }

    private func testCancellationBeforeStartAndProviderLimit() async throws {
        let probe = Probe()
        let task = Task { try await FileDropLoader.urls(from: [probe.source()], timeoutNanoseconds: 2_000_000_000) }
        task.cancel()
        do { _ = try await task.value; throw RegressionFailure(description: "Cancelled load unexpectedly succeeded") }
        catch FileDropLoadingError.cancelled { }
        try expect(probe.callbacks.isEmpty)
        do {
            _ = try await FileDropLoader.urls(from: (0..<257).map { _ in probe.source() })
            throw RegressionFailure(description: "Oversized drop unexpectedly succeeded")
        } catch FileDropLoadingError.tooManyProviders { }
        try expect(probe.callbacks.isEmpty)
    }
}
