import Foundation
import Darwin

/// Real scans of temporary fixtures: no mock stands in for `getattrlistbulk`.
struct DiskMapRegressionTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-map-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    private func scan(_ root: URL, maxEntries: Int = DiskScanner.defaultMaxEntries) throws -> DiskTree {
        guard let tree = DiskScanner.scan(root: root.path, maxEntries: maxEntries) else {
            throw RegressionFailure(description: "Expected a finished scan")
        }
        return tree
    }

    private func node(_ tree: DiskTree, _ url: URL) throws -> DiskTree.NodeID {
        guard let id = tree.node(forPath: url.path) else {
            throw RegressionFailure(description: "Missing node \(url.path)")
        }
        return id
    }

    func testSizesCoverDeepHiddenLinkedAndSparseFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let megabyte = 1024 * 1024
        let big = root.appendingPathComponent("a/b/c/big.mov")
        try write(4 * megabyte, to: big)
        try write(megabyte, to: root.appendingPathComponent("a/.hidden/secret.zip"))
        try write(2 * megabyte, to: root.appendingPathComponent("linked"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("linked"), to: root.appendingPathComponent("a/second-name"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let sparse = root.appendingPathComponent("sparse.raw")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        try expect(truncate(sparse.path, Int64(200 * megabyte)) == 0)

        let tree = try scan(root)
        try expect(tree.isComplete && tree.unreadableDirectoryCount == 0)
        // Deep and hidden files reach the root; the symlink is not walked.
        try expect(tree.fileCount(DiskTree.rootID) == 6)
        let deep = try node(tree, big)
        try expect(tree.path(deep) == big.path && tree.category(deep) == .video)
        let folder = try node(tree, root.appendingPathComponent("a/b"))
        try expect(tree.allocatedSize(folder) >= Int64(4 * megabyte))
        try expect(tree.node(forPath: root.appendingPathComponent("loop/a").path) == nil)
        // A sparse file occupies far less than its logical length.
        let sparseNode = try node(tree, sparse)
        try expect(tree.logicalSize(sparseNode) == Int64(200 * megabyte))
        try expect(tree.allocatedSize(sparseNode) < Int64(megabyte))
        // Two names of one file occupy the disk once.
        let names = [root.appendingPathComponent("linked"), root.appendingPathComponent("a/second-name")]
        let linkSizes = try names.map { tree.allocatedSize(try node(tree, $0)) }.sorted()
        try expect(linkSizes[0] == 0 && linkSizes[1] >= Int64(2 * megabyte))
        // Children are ordered largest-first at every level.
        for parent in [DiskTree.rootID, try node(tree, root.appendingPathComponent("a"))] {
            let sizes = tree.children(of: parent).map(tree.allocatedSize)
            try expect(sizes == sizes.sorted(by: >))
        }
        let summary = tree.summary(of: DiskTree.rootID)
        try expect(tree.path(summary.largestFiles[0]) == big.path)
        try expect(summary.categories.contains { $0.0 == .video && $0.2 == 1 })
        try expect(!summary.largestFiles.contains { tree.isSymlink($0) })
        print("PASS disk tree totals deep, hidden, hard-linked, sparse and symlinked entries honestly")
    }

    func testLimitCancellationUnreadableAndRemoval() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let many = root.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0..<61_000 {
            let descriptor = Darwin.open(many.path + "/\(index)", O_CREAT | O_WRONLY, 0o644)
            try expect(descriptor >= 0)
            close(descriptor)
        }
        // The former 60 000-entry analysis budget no longer truncates a scan.
        let unbounded = try scan(root)
        try expect(unbounded.fileCount(DiskTree.rootID) == 61_000)
        let limited = try scan(root, maxEntries: 100)
        try expect(limited.reachedEntryLimit && !limited.isComplete)
        let control = DiskScanControl()
        control.cancel()
        try expect(DiskScanner.scan(root: root.path, control: control) == nil)

        let locked = root.appendingPathComponent("locked")
        try write(16, to: locked.appendingPathComponent("inside"))
        try expect(chmod(locked.path, 0) == 0)
        defer { chmod(locked.path, 0o755) }
        let partial = try scan(root)
        try expect(partial.unreadableDirectoryCount == 1 && !partial.isComplete)
        let lockedNode = try node(partial, locked)
        try expect(partial.isUnreadable(lockedNode))

        let nested = try fixture()
        defer { try? FileManager.default.removeItem(at: nested) }
        let keep = nested.appendingPathComponent("folder/keep"), drop = nested.appendingPathComponent("folder/drop")
        try write(64 * 1024, to: keep)
        try write(256 * 1024, to: drop)
        let tree = try scan(nested)
        let before = tree.allocatedSize(DiskTree.rootID)
        let dropped = try node(tree, drop)
        let droppedSize = tree.allocatedSize(dropped)
        tree.remove(dropped)
        try expect(tree.allocatedSize(DiskTree.rootID) == before - droppedSize)
        try expect(tree.fileCount(DiskTree.rootID) == 1 && tree.node(forPath: drop.path) == nil)
        let folder = try node(tree, nested.appendingPathComponent("folder"))
        try expect(tree.children(of: folder).map(tree.name) == ["keep"])
        print("PASS scans exceed the old budget, report limits and denials, cancel, and drop trashed items")
    }

    func testBoundaryStaysOnTheScannedDisk() throws {
        try expect(DiskScanBoundary.container(ofDevice: "/dev/disk3s1s1") == "disk3")
        try expect(DiskScanBoundary.container(ofDevice: "/dev/disk12s5") == "disk12")
        try expect(DiskScanBoundary.container(ofDevice: "map auto_home") == nil)
        let wholeDisk = DiskScanBoundary.make(root: "/")
        try expect(wholeDisk.isVolumeRoot && wholeDisk.usedBytes != nil)
        try expect(wholeDisk.excluded.contains("/dev"))
        try expect(wholeDisk.deferred.contains("/System/Volumes/Data"))
        try expect(wholeDisk.excluded.isDisjoint(with: wholeDisk.deferred))
        try expect(DiskMapStore.volumeRoot(of: NSTemporaryDirectory()) == "/")
        try expect(DiskMapStore.volumeRoot(of: "/System/Volumes/Data/Users") == "/")
        try expect(!DiskScanBoundary.make(root: NSTemporaryDirectory()).isVolumeRoot)
        print("PASS scan boundary follows the mount table and whole-disk siblings")
    }

    func testMapDrawsEveryLevelWithinItsBounds() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for top in 0..<4 {
            for inner in 0..<6 {
                try write((top + 1) * (inner + 1) * 64 * 1024,
                          to: root.appendingPathComponent("top\(top)/inner\(inner)/deep/file\(inner).bin"))
            }
        }
        let tree = try scan(root)
        let file = try node(tree, root.appendingPathComponent("top3/inner5/deep/file5.bin"))
        guard let layout = DiskMapLayoutEngine.layout(tree: tree, scope: DiskTree.rootID, width: 1600, height: 900, scale: 2) else {
            throw RegressionFailure(description: "Expected a layout")
        }
        try expect(layout.tiles.allSatisfy { $0.x0 >= 0 && $0.y0 >= 0 && $0.x1 <= 1600 && $0.y1 <= 900 && $0.x1 > $0.x0 && $0.y1 > $0.y0 })
        // Tiles exist four levels down, and a hit resolves to the deepest one.
        guard let tile = layout.tiles.first(where: { $0.node == file }) else {
            throw RegressionFailure(description: "Deep file has no tile")
        }
        try expect(!tile.isFolder)
        try expect(layout.tile(atX: (tile.x0 + tile.x1) / 2, y: (tile.y0 + tile.y1) / 2)?.node == file)
        try expect(layout.tile(for: file, in: tree)?.node == file)
        // Rescoping draws only that folder's contents.
        let scope = try node(tree, root.appendingPathComponent("top0"))
        guard let zoomed = DiskMapLayoutEngine.layout(tree: tree, scope: scope, width: 800, height: 600, scale: 1) else {
            throw RegressionFailure(description: "Expected a zoomed layout")
        }
        try expect(!zoomed.tiles.contains { $0.node == file } && !zoomed.tiles.isEmpty)
        let image = DiskMapRenderer.image(layout: layout, tree: tree, scale: 2)
        try expect(image?.width == 1600 && image?.height == 900)
        try expect(DiskMapLayoutEngine.layout(tree: tree, scope: DiskTree.rootID, width: 1600, height: 900, scale: 2,
                                              isCancelled: { true }) == nil)
        print("PASS treemap places every level inside its bitmap and resolves hits to the deepest tile")
    }

    func testRowsFollowExpansionAndCapHugeFolders() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<(DiskMapPresentation.childRowLimit + 3) {
            FileManager.default.createFile(atPath: root.path + "/\(index)", contents: nil)
        }
        try write(32, to: root.appendingPathComponent("sub/inner"))
        let tree = try scan(root)
        let sub = try node(tree, root.appendingPathComponent("sub"))
        let collapsed = DiskMapPresentation.rows(tree: tree, scope: DiskTree.rootID, expanded: [])
        try expect(collapsed.count == DiskMapPresentation.childRowLimit + 1)
        try expect(collapsed.last?.hiddenChildren == 4 && Set(collapsed.map(\.id)).count == collapsed.count)
        let expanded = DiskMapPresentation.rows(tree: tree, scope: DiskTree.rootID, expanded: [sub])
        let inner = expanded[expanded.firstIndex { $0.node == sub }! + 1]
        try expect(tree.name(inner.node) == "inner" && inner.depth == 1)
        print("PASS size tree expands in place and caps huge folders with a closing row")
    }

    @MainActor func testStoreReusesTreeForDescendants() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(32, to: root.appendingPathComponent("sub/inner"))
        let store = DiskMapStore(treeLimit: 1)
        let path = URL(fileURLWithPath: root.path).standardizedFileURL.path
        store.startScan(root: path)
        try expect(store.scan(covering: path + "/sub") != nil)
        try expect(store.scan(covering: path + "-other") == nil)
        for _ in 0..<500 where !store.scans.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(store.scans.isEmpty)
        // A folder inside a finished scan needs no new one.
        let first = store.tree(covering: path + "/sub")
        try expect(first != nil && first?.tree.isDirectory(first!.node) == true)
        store.startScan(root: path)
        for _ in 0..<500 where !store.scans.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(store.trees.count == 1 && store.trees[0] !== first?.tree)

        store.startScan(root: path)
        if let running = store.scans.first { store.cancel(running) }
        try expect(store.scans.isEmpty)
        print("PASS disk map store shares finished trees, replaces refreshed ones and honours cancel")
    }

    @MainActor func runAll() async throws {
        try testSizesCoverDeepHiddenLinkedAndSparseFiles()
        try testLimitCancellationUnreadableAndRemoval()
        try testBoundaryStaysOnTheScannedDisk()
        try testMapDrawsEveryLevelWithinItsBounds()
        try testRowsFollowExpansionAndCapHugeFolders()
        try await testStoreReusesTreeForDescendants()
    }
}
