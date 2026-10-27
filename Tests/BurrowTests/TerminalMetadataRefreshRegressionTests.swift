import Foundation
import Darwin

@MainActor
struct TerminalMetadataRefreshRegressionTests {
    private func wait(_ description: String, until condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw RegressionFailure(description: "Timed out: \(description)")
    }

    func runAll() async throws {
        try await testMetadataOnlyCommandRefreshesOriginWithoutTakingFocus()
        try await testRevisitRefreshesSizesInsideIndexExcludedTree()
        print("PASS metadata-only terminal refresh and index-excluded folder-size revisit")
    }

    private func testMetadataOnlyCommandRefreshesOriginWithoutTakingFocus() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"]!)
            .appendingPathComponent("terminal-metadata-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("fixture".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let unrelated = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-other", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unrelated) }
        let index = FSearchIndex(roots: [root.path], enableMonitoring: false)
        _ = index.refreshDirectoryInIndex(root.path)
        let pane = PaneTabState(initialURL: root), other = PaneTabState(initialURL: unrelated)
        let app = AppState.shared
        let oldTabs = app.tabs, oldActiveID = app.activeTabId
        defer { app.tabs = oldTabs; app.activeTabId = oldActiveID }
        app.tabs = [pane, other]; app.activeTabId = other.id
        let revision = pane.directoryRevision, otherRevision = other.directoryRevision
        let lifecycle = TerminalApplicationLifecycle()
        let tab = TerminalTab(directory: root, lifecycle: lifecycle,
            reconcile: { app.reconcileTerminalCommand(at: $0) })
        tab.execute("chmod u+x file.txt")
        try await wait("chmod command and pane revision") { !tab.isRunning && pane.directoryRevision > revision }
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        try expect(permissions?.intValue == 0o700)
        try expect(index.refreshDirectoryInIndex(root.path).isEmpty)
        try expect(app.activeTabId == other.id && other.directoryRevision == otherRevision)
        try expect(lifecycle.activeCount == 0)
    }

    private func testRevisitRefreshesSizesInsideIndexExcludedTree() async throws {
        let parent = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"]!)
            .appendingPathComponent("size-revisit-\(UUID())", isDirectory: true)
        let project = parent.appendingPathComponent("project", isDirectory: true)
        let file = project.appendingPathComponent("node_modules/pkg/file.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("old".utf8).write(to: file)
        let index = FSearchIndex(roots: [project.path], enableMonitoring: false)
        index.skipHeavyDevDirs = true
        _ = index.refreshDirectoryInIndex(project.path)
        let cache = FolderSizeCache.shared, owner = UUID(), returningOwner = UUID()
        defer { cache.release(owner: owner); cache.release(owner: returningOwner); cache.invalidate(project.path) }
        cache.updateDemand(owner: owner, paths: [project.path])
        try await wait("old project size") { cache.size(for: project.path) == 3 }
        cache.release(owner: owner)
        // In-place content changes do not alter any directory that the index visits.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" and more bytes".utf8))
        try handle.close()
        try expect(index.refreshDirectoryInIndex(project.path).isEmpty)
        let pane = PaneTabState(initialURL: parent)
        try expect(pane.navigate(to: project))
        cache.updateDemand(owner: returningOwner, paths: [project.path])
        try expect(cache.size(for: project.path) == 3)
        try await wait("revalidated excluded-tree size") { cache.size(for: project.path) == 18 }
    }
}
