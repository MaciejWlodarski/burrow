import Foundation

/// Scans that later commands can reuse instead of walking the disk again. A
/// cached scan answers for its own folder and any folder inside it. The MCP
/// server keeps them in memory; `--cache` also keeps them on disk between runs.
final class ScanCache {
    let directory: URL?
    var maxAge: TimeInterval
    private var trees: [String: DiskTree] = [:]
    /// Disk copies stay this long at most, whatever `maxAge` a run asks for.
    static let fileLifetime: TimeInterval = 24 * 60 * 60

    init(directory: URL?, maxAge: TimeInterval) {
        self.directory = directory
        self.maxAge = maxAge
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Burrow/cli", isDirectory: true)
    }

    /// The freshest usable scan of `path`: its own, or the nearest scanned folder above it.
    func tree(for path: String, maxAge: TimeInterval? = nil, now: Date = Date()) -> DiskTree? {
        let maxAge = maxAge ?? self.maxAge
        var candidate = path
        while true {
            if let tree = cached(root: candidate, maxAge: maxAge, now: now) {
                if candidate == path { return reuse(tree) }
                if let id = tree.node(forPath: path), let subtree = tree.subtree(at: id) { return reuse(subtree) }
            }
            if candidate == "/" { return nil }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
    }

    func store(_ tree: DiskTree) {
        trees[tree.rootPath] = tree
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? tree.archived().write(to: file(for: tree.rootPath), options: .atomic)
        for entry in entries() where Date().timeIntervalSince(entry.info.scannedAt) > Self.fileLifetime {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    /// Keeps cached scans true after `path` went to the Trash: scans above it
    /// lose the item, scans of it or inside it are dropped.
    func removeItem(at path: String) {
        let inside = path == "/" ? "/" : path + "/"
        for (root, tree) in trees {
            if root == path || root.hasPrefix(inside) { trees[root] = nil } else if let id = tree.node(forPath: path) { tree.remove(id) }
        }
        for entry in entries() {
            let root = entry.info.rootPath
            if root == path || root.hasPrefix(inside) {
                try? FileManager.default.removeItem(at: entry.url)
            } else if path.hasPrefix(root == "/" ? "/" : root + "/") {
                // A scan held in memory already lost the item above.
                if let tree = trees[root] {
                    try? tree.archived().write(to: entry.url, options: .atomic)
                } else if let tree = load(entry.url), let id = tree.node(forPath: path) {
                    tree.remove(id)
                    try? tree.archived().write(to: entry.url, options: .atomic)
                }
            }
        }
    }

    struct Entry {
        let url: URL
        let info: DiskTree.ArchiveInfo
        let bytes: Int64
    }

    /// Scans saved on disk, newest first.
    func entries() -> [Entry] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return urls.filter { $0.pathExtension == "tree" }.compactMap { url in
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let info = DiskTree.archiveInfo(data) else { return nil }
            return Entry(url: url, info: info, bytes: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count))
        }.sorted { $0.info.scannedAt > $1.info.scannedAt }
    }

    func clear() -> Int {
        trees.removeAll()
        let removed = entries()
        for entry in removed { try? FileManager.default.removeItem(at: entry.url) }
        return removed.count
    }

    private var reused = Set<ObjectIdentifier>()

    /// Whether `tree` came out of this cache rather than a scan just now.
    func isReused(_ tree: DiskTree) -> Bool { reused.contains(ObjectIdentifier(tree)) }

    private func reuse(_ tree: DiskTree) -> DiskTree {
        reused.insert(ObjectIdentifier(tree))
        return tree
    }

    private func cached(root: String, maxAge: TimeInterval, now: Date) -> DiskTree? {
        if let tree = trees[root], now.timeIntervalSince(tree.scannedAt) <= maxAge { return tree }
        guard directory != nil else { return nil }
        let url = file(for: root)
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let info = DiskTree.archiveInfo(data),
              info.rootPath == root, now.timeIntervalSince(info.scannedAt) <= maxAge,
              let tree = DiskTree.unarchived(data) else { return nil }
        trees[root] = tree
        return tree
    }

    private func load(_ url: URL) -> DiskTree? {
        (try? Data(contentsOf: url, options: .alwaysMapped)).flatMap(DiskTree.unarchived)
    }

    /// FNV-1a of the path keeps names short and free of separators.
    private func file(for root: String) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in root.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return directory!.appendingPathComponent(String(format: "%016llx.tree", hash))
    }
}
