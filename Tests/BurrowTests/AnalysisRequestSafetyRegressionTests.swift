import Foundation
import Darwin

/// Deterministic production-seam checks: no sleeps, real Trash, or model reader.
struct AnalysisRequestSafetyRegressionTests {
    @MainActor func runAll() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-request-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try testBoundedReader(root: root)
        try testLiveOwnership(root: root)
    }

    private func rejected(_ operation: () throws -> Void, as expected: DuplicateSafetyError? = nil) throws {
        do {
            try operation()
            throw RegressionFailure(description: "Expected duplicate safety rejection")
        } catch let error as DuplicateSafetyError {
            if let expected { try expect(String(describing: error) == String(describing: expected)) }
        }
    }

    private func testBoundedReader(root: URL) throws {
        let file = root.appendingPathComponent("bounded")
        let megabyte = 1024 * 1024
        let initial = Data(repeating: 0x61, count: 3 * megabyte)
        try initial.write(to: file)
        var chunks = 0
        try rejected({
            _ = try DuplicateFileSafety.hash(at: file, hooks: DuplicateHashHooks(afterChunk: { _ in
                chunks += 1
                let writer = try FileHandle(forWritingTo: file)
                defer { try? writer.close() }
                try writer.seekToEnd()
                try writer.write(contentsOf: Data(repeating: 0x62, count: megabyte))
            }))
        }, as: .changed)
        try expect(chunks == 3) // Newly appended tail is never read.
        try initial.write(to: file)
        chunks = 0
        try rejected({
            _ = try DuplicateFileSafety.hash(at: file, hooks: DuplicateHashHooks(afterChunk: { _ in
                chunks += 1
                let writer = try FileHandle(forWritingTo: file)
                defer { try? writer.close() }
                try writer.truncate(atOffset: 0)
            }))
        }, as: .changed)
        try expect(chunks == 1)

        var touchedFilesystem = false
        try rejected({
            _ = try DuplicateFileSafety.hash(at: file, isCancelled: { true }, hooks: DuplicateHashHooks(beforeSnapshot: {
                touchedFilesystem = true
            }))
        }, as: .cancelled)
        try expect(!touchedFilesystem)

        try Data("payload".utf8).write(to: file)
        let expected = try DuplicateFileSafety.hash(at: file).hash
        var reads = 0
        let recovered = try DuplicateFileSafety.hash(at: file, hooks: DuplicateHashHooks(readChunk: { fd, bytes, count in
            reads += 1
            if reads == 1 { errno = EINTR; return -1 }
            return Darwin.read(fd, bytes, count)
        }))
        try expect(reads == 2 && recovered.hash == expected)
        var cancel = false
        try rejected({
            _ = try DuplicateFileSafety.hash(at: file, isCancelled: { cancel }, hooks: DuplicateHashHooks(afterChunk: { _ in cancel = true }))
        }, as: .cancelled)

        let other = root.appendingPathComponent("other")
        try Data("payload".utf8).write(to: other)
        try rejected {
            _ = try DuplicateFileSafety.hash(at: file, hooks: DuplicateHashHooks(beforeOpen: {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
            }))
        }
        try FileManager.default.removeItem(at: file)
        try Data("payload".utf8).write(to: file)
        try rejected {
            _ = try DuplicateFileSafety.hash(at: file, hooks: DuplicateHashHooks(beforeOpen: {
                try FileManager.default.removeItem(at: file)
                guard mkfifo(file.path, 0o600) == 0 else { throw RegressionFailure(description: "mkfifo fixture failed") }
            }))
        }
        try FileManager.default.removeItem(at: file)
        try Data("payload".utf8).write(to: file)
        try rejected({
            _ = try DuplicateFileSafety.hash(at: file, hooks: DuplicateHashHooks(afterChunk: { _ in
                try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("retained-old-inode"))
                try Data("payload".utf8).write(to: file)
            }))
        }, as: .changed)
        print("PASS analysis hash bounds growth, rejects truncation/replacement, retries EINTR, and cancels before IO")
    }

    @MainActor private func testLiveOwnership(root: URL) throws {
        let app = AppState.shared
        let savedTabs = app.tabs, savedID = app.activeTabId, savedRight = app.rightPane
        let savedDual = app.isDualPane
        defer {
            app.tabs = savedTabs
            app.activeTabId = savedID
            app.rightPane = savedRight
            app.isDualPane = savedDual
        }
        let a = PaneTabState(initialURL: root), b = PaneTabState(initialURL: root)
        a.viewMode = .wiztree
        b.viewMode = .wiztree
        b.showHiddenFiles = a.showHiddenFiles
        app.tabs = [a, b]
        app.activeTabId = a.id
        let token = AnalysisRequestToken(rootPath: root.path,
            context: AnalysisPublicationContext(pane: a, side: .left, mode: .duplicates))
        let accepts = { token.canPublishAnalysis(active: token, appState: app, mode: .duplicates) }
        try expect(accepts())
        // Completion and cleanup both use this exact gate, even before onDisappear.
        app.activeTabId = b.id
        try expect(!accepts())
        var cleanupHandoffs = 0
        if accepts() { cleanupHandoffs += 1 }
        try expect(cleanupHandoffs == 0)
        let fresh = AnalysisRequestToken(rootPath: root.path,
            context: AnalysisPublicationContext(pane: b, side: .left, mode: .duplicates))
        b.beginAnalysisProjection(rootPath: root.path, generation: fresh.id)
        // Explicit input avoids relying on an asynchronous directory publication.
        let projectedURL = root.appendingPathComponent("projected.txt")
        try Data("projection".utf8).write(to: projectedURL)
        let items = [FileItem(url: projectedURL, name: "projected.txt", path: projectedURL.path,
            parentPath: root.path, fileExtension: "txt", isDirectory: false, isHidden: false,
            size: 10, modificationDate: .distantPast)]
        try expect(fresh.canPublishAnalysis(active: fresh, appState: app, mode: .duplicates))
        if fresh.canPublishAnalysis(active: fresh, appState: app, mode: .duplicates) {
            b.publishAnalysisItems(items, rootPath: root.path, generation: fresh.id)
        }
        try expect(b.selectableItems.count == 1)
        try expect(b.selectableItems.map(\.path) == items.map(\.path))
        try expect(!token.canPublishAnalysis(active: fresh, appState: app, mode: .duplicates))
        try expect(!fresh.canPublishAnalysis(active: fresh, appState: app, mode: .treemap))
        // Isolate root/search changes while all other inputs are still valid.
        b.searchQuery = "projected"
        try expect(!fresh.canPublishAnalysis(active: fresh, appState: app, mode: .duplicates))
        b.searchQuery = ""
        try expect(fresh.canPublishAnalysis(active: fresh, appState: app, mode: .duplicates))
        let otherRoot = root.appendingPathComponent("other-root", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        b.currentURL = otherRoot
        try expect(!fresh.canPublishAnalysis(active: fresh, appState: app, mode: .duplicates))
        b.currentURL = root
        try expect(fresh.canPublishAnalysis(active: fresh, appState: app, mode: .duplicates))
        b.showHiddenFiles.toggle()
        try expect(!fresh.canPublishAnalysis(active: fresh, appState: app, mode: .duplicates))
        b.showHiddenFiles.toggle()
        b.viewMode = .list
        try expect(!fresh.canPublishAnalysis(active: fresh, appState: app, mode: .duplicates))
        b.viewMode = .wiztree
        b.reloadDirectory()
        try expect(!fresh.canPublishAnalysis(active: fresh, appState: app, mode: .duplicates))
        app.tabs = [a] // Close/replace the live owner while verification is pending.
        app.activeTabId = a.id
        try expect(!fresh.canPublishAnalysis(active: fresh, appState: app, mode: .duplicates))
        app.rightPane = b
        app.isDualPane = true
        let right = AnalysisRequestToken(rootPath: root.path,
            context: AnalysisPublicationContext(pane: b, side: .right, mode: .duplicates))
        try expect(right.canPublishAnalysis(active: right, appState: app, mode: .duplicates))
        app.isDualPane = false
        try expect(!right.canPublishAnalysis(active: right, appState: app, mode: .duplicates))
        let cancellable = AnalysisRequestToken(rootPath: a.currentURL.path,
            context: AnalysisPublicationContext(pane: a, side: .left, mode: .duplicates))
        try expect(cancellable.canPublishAnalysis(active: cancellable, appState: app, mode: .duplicates))
        cancellable.cancel()
        try expect(!cancellable.canPublishAnalysis(active: cancellable, appState: app, mode: .duplicates))
        print("PASS live analysis owner gates reject switched/closed panes, stale generations and revisions before handoff")
    }
}
