import Foundation
import Combine

/// Owns finished trees and running scans for every pane. A long disk scan keeps
/// running while the user navigates or leaves the map, and folders inside a
/// finished tree open instantly instead of being rescanned.
@MainActor
public final class DiskMapStore: ObservableObject {
    public static let shared = DiskMapStore()

    public struct RunningScan: Identifiable, Sendable {
        public let id = UUID()
        public let rootPath: String
        public let usedBytesEstimate: Int64?
        let control: DiskScanControl
    }

    @Published public private(set) var trees: [DiskTree] = []
    @Published public private(set) var scans: [RunningScan] = []
    @Published public private(set) var progress: [UUID: DiskScanControl.Progress] = [:]

    private let treeLimit: Int
    private let scanLimit: Int
    private var poller: Timer?

    init(treeLimit: Int = 2, scanLimit: Int = 2) {
        self.treeLimit = treeLimit
        self.scanLimit = scanLimit
    }

    /// The most recently scanned tree that has this path as a node.
    public func tree(covering path: String) -> (tree: DiskTree, node: DiskTree.NodeID)? {
        for tree in trees {
            if let node = tree.node(forPath: path) { return (tree, node) }
        }
        return nil
    }

    public func scan(covering path: String) -> RunningScan? {
        scans.first { path == $0.rootPath || path.hasPrefix($0.rootPath == "/" ? "/" : $0.rootPath + "/") }
    }

    /// A refresh replaces the tree of the same root; an equal running scan is kept.
    public func startScan(root: String) {
        guard !scans.contains(where: { $0.rootPath == root }) else { return }
        while scans.count >= scanLimit, let oldest = scans.first { cancel(oldest) }
        let boundary = DiskScanBoundary.make(root: root)
        let control = DiskScanControl()
        let running = RunningScan(rootPath: root, usedBytesEstimate: boundary.usedBytes, control: control)
        scans.append(running)
        startPolling()
        DispatchQueue.global(qos: .userInitiated).async {
            let tree = DiskScanner.scan(root: root, control: control)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(running, tree: tree) }
            }
        }
    }

    public func cancel(_ scan: RunningScan) {
        scan.control.cancel()
        scans.removeAll { $0.id == scan.id }
        progress[scan.id] = nil
    }

    private func finish(_ scan: RunningScan, tree: DiskTree?) {
        guard scans.contains(where: { $0.id == scan.id }) else { return }
        scans.removeAll { $0.id == scan.id }
        progress[scan.id] = nil
        guard let tree else { return }
        trees.removeAll { $0.rootPath == tree.rootPath }
        trees.insert(tree, at: 0)
        if trees.count > treeLimit { trees.removeLast(trees.count - treeLimit) }
    }

    private func startPolling() {
        guard poller == nil else { return }
        poller = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.scans.isEmpty {
                    self.poller?.invalidate()
                    self.poller = nil
                    return
                }
                for scan in self.scans { self.progress[scan.id] = scan.control.progress }
            }
        }
    }

    /// `/Users/me/x` belongs to `/`, `/Volumes/USB/x` to `/Volumes/USB`.
    public nonisolated static func volumeRoot(of path: String) -> String {
        DiskScanBoundary.volumeRoot(of: path)
    }
}
