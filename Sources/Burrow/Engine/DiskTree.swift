import Foundation
import Darwin

/// Immutable-layout snapshot of a scanned tree, stored as one contiguous node
/// table so a whole disk fits in a few hundred MB. Sizes change only when a
/// trashed item is removed; background readers go through `read`.
public final class DiskTree: @unchecked Sendable {
    public typealias NodeID = Int32
    public static let rootID: NodeID = 0

    struct Node {
        var parent: NodeID
        var nameOffset: UInt32
        var nameLength: UInt16
        var category: UInt8
        var flags: UInt8
        var allocated: Int64
        var logical: Int64
        var modified: Int64
        var fileCount: Int32
        var firstChild: Int32
        var childCount: Int32
    }

    enum Flag {
        static let directory: UInt8 = 1
        static let symlink: UInt8 = 2
        static let unreadable: UInt8 = 4
        static let alias: UInt8 = 8
        static let synthetic: UInt8 = 16
        static let removed: UInt8 = 32
    }

    public static let syntheticName = "<Niezeskanowane / systemowe>"
    private static let categories = FileKindCategory.allCases

    public let rootPath: String
    public let scannedAt: Date
    public let elapsedMilliseconds: Double
    public let isComplete: Bool
    public let reachedEntryLimit: Bool
    public let unreadableDirectoryCount: Int
    public let datalessDirectoryCount: Int
    public let skippedMountCount: Int
    public let volumeFreeBytes: Int64?
    public let unaccountedBytes: Int64
    private let lock = NSLock()
    private var nodes: ContiguousArray<Node>
    private var children: ContiguousArray<NodeID>
    private let nameBytes: ContiguousArray<UInt8>

    init(rootPath: String, nodes: ContiguousArray<Node>, children: ContiguousArray<NodeID>,
         nameBytes: ContiguousArray<UInt8>, elapsedMilliseconds: Double, isComplete: Bool,
         reachedEntryLimit: Bool, unreadableDirectoryCount: Int, datalessDirectoryCount: Int,
         skippedMountCount: Int, volumeFreeBytes: Int64?, unaccountedBytes: Int64) {
        self.rootPath = rootPath
        self.nodes = nodes
        self.children = children
        self.nameBytes = nameBytes
        self.elapsedMilliseconds = elapsedMilliseconds
        self.isComplete = isComplete
        self.reachedEntryLimit = reachedEntryLimit
        self.unreadableDirectoryCount = unreadableDirectoryCount
        self.datalessDirectoryCount = datalessDirectoryCount
        self.skippedMountCount = skippedMountCount
        self.volumeFreeBytes = volumeFreeBytes
        self.unaccountedBytes = unaccountedBytes
        scannedAt = Date()
    }

    public var nodeCount: Int { nodes.count }

    /// Off-main readers hold this for one pass; the only writer is `remove`.
    public func read<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func name(_ id: NodeID) -> String {
        if id == Self.rootID { return rootPath == "/" ? "/" : (rootPath as NSString).lastPathComponent }
        let node = nodes[Int(id)]
        if isSynthetic(id) { return Self.syntheticName }
        let start = Int(node.nameOffset)
        return String(decoding: nameBytes[start..<(start + Int(node.nameLength))], as: UTF8.self)
    }

    public func path(_ id: NodeID) -> String {
        if id == Self.rootID { return rootPath }
        var parts: [String] = []
        var current = id
        while current != Self.rootID {
            parts.append(name(current))
            current = nodes[Int(current)].parent
        }
        let suffix = parts.reversed().joined(separator: "/")
        return rootPath == "/" ? "/" + suffix : rootPath + "/" + suffix
    }

    public func parent(_ id: NodeID) -> NodeID? { id == Self.rootID ? nil : nodes[Int(id)].parent }
    public func allocatedSize(_ id: NodeID) -> Int64 { nodes[Int(id)].allocated }
    public func logicalSize(_ id: NodeID) -> Int64 { nodes[Int(id)].logical }
    public func fileCount(_ id: NodeID) -> Int { Int(nodes[Int(id)].fileCount) }
    public func childCount(_ id: NodeID) -> Int { Int(nodes[Int(id)].childCount) }
    public func category(_ id: NodeID) -> FileKindCategory { Self.categories[Int(nodes[Int(id)].category)] }
    public func modificationDate(_ id: NodeID) -> Date { Date(timeIntervalSince1970: TimeInterval(nodes[Int(id)].modified)) }
    public func isDirectory(_ id: NodeID) -> Bool { nodes[Int(id)].flags & Flag.directory != 0 }
    public func isSymlink(_ id: NodeID) -> Bool { nodes[Int(id)].flags & Flag.symlink != 0 }
    public func isUnreadable(_ id: NodeID) -> Bool { nodes[Int(id)].flags & Flag.unreadable != 0 }
    public func isSynthetic(_ id: NodeID) -> Bool { nodes[Int(id)].flags & Flag.synthetic != 0 }
    public func isRemoved(_ id: NodeID) -> Bool { nodes[Int(id)].flags & Flag.removed != 0 }

    /// Sorted by allocated size, largest first; removed items sort to the tail.
    public func children(of id: NodeID) -> [NodeID] {
        let node = nodes[Int(id)]
        let start = Int(node.firstChild)
        return children[start..<(start + Int(node.childCount))].filter { !isRemoved($0) }
    }

    func forEachChild(of id: NodeID, _ body: (NodeID, Node) -> Bool) {
        let node = nodes[Int(id)]
        let start = Int(node.firstChild)
        for index in start..<(start + Int(node.childCount)) {
            let child = children[index]
            if !body(child, nodes[Int(child)]) { return }
        }
    }

    public func contains(path: String) -> Bool { node(forPath: path) != nil }

    /// Component walk from the root; nil outside this tree or for scan-excluded paths.
    public func node(forPath path: String) -> NodeID? {
        if path == rootPath { return Self.rootID }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var current = Self.rootID
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            let bytes = Array(component.utf8)
            var match: NodeID?
            forEachChild(of: current) { child, node in
                guard Int(node.nameLength) == bytes.count, node.flags & (Flag.removed | Flag.synthetic) == 0 else { return true }
                let start = Int(node.nameOffset)
                guard nameBytes[start..<(start + bytes.count)].elementsEqual(bytes) else { return true }
                match = child
                return false
            }
            guard let match else { return nil }
            current = match
        }
        return current
    }

    public func fileItem(_ id: NodeID) -> FileItem {
        let path = path(id), name = name(id), directory = isDirectory(id)
        let url = URL(fileURLWithPath: path, isDirectory: directory)
        return FileItem(url: url, name: name, path: path, parentPath: (path as NSString).deletingLastPathComponent,
            fileExtension: url.pathExtension.lowercased(), isDirectory: directory, isSymlink: isSymlink(id),
            isHidden: name.hasPrefix("."), size: allocatedSize(id), modificationDate: modificationDate(id),
            kindCategory: category(id))
    }

    public struct Summary: Sendable {
        public let categories: [(FileKindCategory, Int64, Int)]
        public let largestFiles: [NodeID]
    }

    /// One walk of a subtree: per-kind totals and the largest regular files.
    public func summary(of scope: NodeID, largestLimit: Int = 500, isCancelled: () -> Bool = { false }) -> Summary {
        var totals = [(bytes: Int64, count: Int)](repeating: (0, 0), count: Self.categories.count)
        var largest: [(size: Int64, id: NodeID)] = []
        var threshold = Int64.min
        var stack: [NodeID] = [scope]
        var visited = 0
        while let id = stack.popLast() {
            visited += 1
            if visited & 0xFFFF == 0, isCancelled() { break }
            let node = nodes[Int(id)]
            if node.flags & Flag.removed != 0 { continue }
            if node.flags & Flag.directory != 0 {
                let start = Int(node.firstChild)
                stack.append(contentsOf: children[start..<(start + Int(node.childCount))])
            } else if node.flags & Flag.synthetic == 0 {
                totals[Int(node.category)].bytes += node.allocated
                totals[Int(node.category)].count += 1
                if node.flags & Flag.symlink == 0, node.allocated > threshold {
                    largest.append((node.allocated, id))
                    // Amortized top-N: keep twice the limit between compactions.
                    if largest.count >= largestLimit * 2 {
                        largest.sort { $0.size > $1.size }
                        largest.removeLast(largest.count - largestLimit)
                        threshold = largest.last?.size ?? threshold
                    }
                }
            }
        }
        largest.sort { $0.size > $1.size }
        let categories = totals.enumerated().filter { $0.element.count > 0 }
            .map { (Self.categories[$0.offset], $0.element.bytes, $0.element.count) }
            .sorted { $0.1 > $1.1 }
        return Summary(categories: categories, largestFiles: largest.prefix(largestLimit).map(\.id))
    }

    /// Drops a trashed item without a rescan. Ancestors shrink and stay sorted.
    public func remove(_ id: NodeID) {
        guard id != Self.rootID else { return }
        lock.lock()
        defer { lock.unlock() }
        guard nodes[Int(id)].flags & Flag.removed == 0 else { return }
        let removed = nodes[Int(id)]
        nodes[Int(id)].flags |= Flag.removed
        var current = removed.parent
        while true {
            nodes[Int(current)].allocated -= removed.allocated
            nodes[Int(current)].logical -= removed.logical
            nodes[Int(current)].fileCount -= removed.fileCount
            sortChildren(of: current)
            if current == Self.rootID { break }
            sortChildren(of: nodes[Int(current)].parent)
            current = nodes[Int(current)].parent
        }
    }

    private func sortChildren(of id: NodeID) {
        let parent = nodes[Int(id)]
        let start = Int(parent.firstChild)
        let range = start..<(start + Int(parent.childCount))
        let nodes = self.nodes
        func rank(_ child: NodeID) -> Int64 {
            let node = nodes[Int(child)]
            return node.flags & Flag.removed != 0 ? Int64.min : node.allocated
        }
        children[range].sort { rank($0) > rank($1) }
    }
}

/// Live counters and cancellation shared between a scan and the store polling it.
public final class DiskScanControl: @unchecked Sendable {
    public struct Progress: Sendable {
        public var entries = 0
        public var bytes: Int64 = 0
        public var currentPath = ""
    }
    private let lock = NSLock()
    private var cancelled = false
    private var state = Progress()

    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public var progress: Progress { lock.lock(); defer { lock.unlock() }; return state }
    func report(_ update: Progress) { lock.lock(); state = update; lock.unlock() }
}

/// Which mounted filesystems a scan may enter. Other disks, snapshots and
/// pseudo filesystems are excluded by the mount table, never by a name list.
struct DiskScanBoundary {
    var excluded: Set<String> = []
    /// Same-container volumes of a whole-disk scan, read after the main queue
    /// drains so firmlinked folders keep their short paths (`/Users`, not
    /// `/System/Volumes/Data/Users`).
    var deferred: Set<String> = []
    var isVolumeRoot = false
    var usedBytes: Int64?
    var freeBytes: Int64?

    private static let dataVolume = "/System/Volumes/Data"

    private static func mounts() -> [(on: String, from: String)] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        let capacity = Int(count) + 8
        let table = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { table.deallocate() }
        let filled = getfsstat(table, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard filled > 0 else { return [] }
        return (0..<Int(filled)).map { index in
            let on = withUnsafeBytes(of: &table[index].f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let from = withUnsafeBytes(of: &table[index].f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return (on, from)
        }
    }

    static func volumeRoot(of path: String) -> String {
        var root = "/"
        for mount in mounts() {
            let prefix = mount.on == "/" ? "/" : mount.on + "/"
            if (path == mount.on || path.hasPrefix(prefix)) && mount.on.count > root.count { root = mount.on }
        }
        // Boot-volume siblings are reached through firmlinks from `/`.
        return root.hasPrefix("/System/Volumes/") ? "/" : root
    }

    /// `/dev/disk3s1s1` and `/dev/disk3s5` are one APFS container: `disk3`.
    static func container(ofDevice device: String) -> String? {
        guard device.hasPrefix("/dev/disk") else { return nil }
        let digits = device.dropFirst("/dev/disk".count).prefix { $0.isNumber }
        return digits.isEmpty ? nil : "disk" + digits
    }

    static func make(root: String) -> DiskScanBoundary {
        var boundary = DiskScanBoundary()
        let mounts = Self.mounts()
        let rootDevice = mounts.first { $0.on == root }?.from
        boundary.isVolumeRoot = root == "/" || rootDevice != nil
        let rootContainer = rootDevice.flatMap(container(ofDevice:))
        let prefix = root == "/" ? "/" : root + "/"
        for mount in mounts where mount.on != root {
            let alias = Self.dataVolume + mount.on
            let inside = mount.on.hasPrefix(prefix) || alias.hasPrefix(prefix)
            guard inside else { continue }
            // Only direct /System/Volumes/<name> siblings: a snapshot's device
            // also names this container and would double every file.
            let isSibling = root == "/" && mount.on.hasPrefix("/System/Volumes/")
                && !mount.on.dropFirst("/System/Volumes/".count).contains("/")
                && rootContainer != nil && container(ofDevice: mount.from) == rootContainer
            if isSibling {
                boundary.deferred.insert(mount.on)
            } else {
                boundary.excluded.insert(mount.on)
                boundary.excluded.insert(alias)
            }
        }
        if boundary.isVolumeRoot {
            var info = statfs()
            if statfs(root, &info) == 0 {
                let block = Int64(info.f_bsize)
                boundary.freeBytes = Int64(info.f_bavail) * block
                boundary.usedBytes = (Int64(info.f_blocks) - Int64(info.f_bavail)) * block
            }
        }
        return boundary
    }
}

/// Whole-tree parallel `getattrlistbulk` scanner. It records on-disk (allocated)
/// and logical sizes, counts hard links once, stays on the scanned disk and
/// never materializes iCloud placeholders.
public enum DiskScanner {
    public static let defaultMaxEntries = 40_000_000
    private static let workerCount = 8
    private static let maxKnownExtensionLength = 8

    private struct Job {
        let path: String
        let node: DiskTree.NodeID
    }

    private struct FileIdentity: Hashable {
        let device: Int32
        let file: UInt64
    }

    private struct Entry {
        var nameOffset: Int
        var nameLength: Int
        var category: UInt8
        var flags: UInt8
        var modified: Int64
        var allocated: Int64
        var logical: Int64
        var fileID: UInt64
        var linkCount: UInt32
    }

    /// All mutable scan state; every access holds `condition`.
    private final class Shared: @unchecked Sendable {
        let condition = NSCondition()
        var nodes = ContiguousArray<DiskTree.Node>()
        var nameBytes = ContiguousArray<UInt8>()
        var stack: [Job] = []
        var deferred: [Job] = []
        var active = 0
        var finished = false
        var visited = Set<FileIdentity>()
        var hardLinks = Set<FileIdentity>()
        var unreadable = 0
        var dataless = 0
        var skippedMounts = 0
        var reachedLimit = false
        var scannedBytes: Int64 = 0
    }

    public static func scan(root rawRoot: String, control: DiskScanControl = DiskScanControl(),
                            maxEntries: Int = defaultMaxEntries) -> DiskTree? {
        let started = DispatchTime.now().uptimeNanoseconds
        let root = URL(fileURLWithPath: rawRoot).standardizedFileURL.path
        let boundary = DiskScanBoundary.make(root: root)
        let shared = Shared()
        shared.nodes.reserveCapacity(1 << 16)
        shared.nodes.append(DiskTree.Node(parent: 0, nameOffset: 0, nameLength: 0,
            category: categoryIndex(.folder), flags: DiskTree.Flag.directory, allocated: 0, logical: 0,
            modified: 0, fileCount: 0, firstChild: 0, childCount: 0))
        shared.stack.append(Job(path: root, node: DiskTree.rootID))
        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            defer { if previous >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) } }
            work(shared: shared, boundary: boundary, root: root, control: control, maxEntries: maxEntries)
        }
        guard !control.isCancelled else { return nil }
        var unaccounted: Int64 = 0
        var nodes = shared.nodes
        rollUpSizes(&nodes)
        if let used = boundary.usedBytes, !shared.reachedLimit {
            unaccounted = max(0, used - nodes[0].allocated)
            if unaccounted > 0 {
                var nameless = nodes[0]
                nameless.parent = DiskTree.rootID
                nameless.flags = DiskTree.Flag.synthetic
                nameless.category = categoryIndex(.other)
                nameless.allocated = unaccounted
                nameless.logical = unaccounted
                nameless.fileCount = 0
                nodes.append(nameless)
                nodes[0].allocated += unaccounted
                nodes[0].logical += unaccounted
            }
        }
        let children = linkChildren(&nodes)
        guard !control.isCancelled else { return nil }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return DiskTree(rootPath: root, nodes: nodes, children: children, nameBytes: shared.nameBytes,
            elapsedMilliseconds: elapsed, isComplete: shared.unreadable == 0 && !shared.reachedLimit,
            reachedEntryLimit: shared.reachedLimit, unreadableDirectoryCount: shared.unreadable,
            datalessDirectoryCount: shared.dataless, skippedMountCount: shared.skippedMounts,
            volumeFreeBytes: boundary.freeBytes, unaccountedBytes: unaccounted)
    }

    private static func work(shared: Shared, boundary: DiskScanBoundary, root: String,
                             control: DiskScanControl, maxEntries: Int) {
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var entries: [Entry] = []
        var names: [UInt8] = []
        var kinds: [String: UInt8] = [:]
        while true {
            shared.condition.lock()
            while shared.stack.isEmpty && !shared.finished {
                if shared.active == 0 {
                    if shared.deferred.isEmpty {
                        shared.finished = true
                        shared.condition.broadcast()
                    } else {
                        shared.stack = shared.deferred
                        shared.deferred = []
                        shared.condition.broadcast()
                    }
                } else {
                    shared.condition.wait()
                }
            }
            guard !shared.finished, let job = shared.stack.popLast() else {
                shared.condition.unlock()
                return
            }
            shared.active += 1
            shared.condition.unlock()

            entries.removeAll(keepingCapacity: true)
            names.removeAll(keepingCapacity: true)
            let outcome = control.isCancelled ? ReadOutcome.cancelled : read(job, root: root, buffer: buffer,
                bufferSize: bufferSize, entries: &entries, names: &names, kinds: &kinds, shared: shared)

            shared.condition.lock()
            shared.active -= 1
            switch outcome {
            case .cancelled:
                shared.stack.removeAll()
                shared.deferred.removeAll()
            case .duplicateDirectory:
                shared.nodes[Int(job.node)].flags |= DiskTree.Flag.alias
            case .failed(let code):
                if code == EDEADLK {
                    shared.dataless += 1
                } else {
                    shared.unreadable += 1
                    shared.nodes[Int(job.node)].flags |= DiskTree.Flag.unreadable
                }
                commit(job, device: 0, entries: entries, names: names, boundary: boundary, shared: shared, maxEntries: maxEntries)
            case .read(let device):
                commit(job, device: device, entries: entries, names: names, boundary: boundary, shared: shared, maxEntries: maxEntries)
            }
            control.report(DiskScanControl.Progress(entries: shared.nodes.count,
                bytes: shared.scannedBytes, currentPath: job.path))
            shared.condition.broadcast()
            shared.condition.unlock()
        }
    }

    private enum ReadOutcome {
        case read(device: Int32)
        case failed(Int32)
        case duplicateDirectory
        case cancelled
    }

    private static func read(_ job: Job, root: String, buffer: UnsafeMutableRawPointer, bufferSize: Int,
                             entries: inout [Entry], names: inout [UInt8], kinds: inout [String: UInt8],
                             shared: Shared) -> ReadOutcome {
        // Only the scan root may be reached through a symlink.
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (job.node == DiskTree.rootID ? 0 : O_NOFOLLOW)
        let fd = Darwin.open(job.path, flags)
        guard fd >= 0 else { return .failed(errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failed(errno) }
        shared.condition.lock()
        let isNew = shared.visited.insert(FileIdentity(device: info.st_dev, file: info.st_ino)).inserted
        shared.condition.unlock()
        guard isNew else { return .duplicateDirectory }

        var request = attrlist()
        request.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count == 0 { return .read(device: info.st_dev) }
            if count < 0 {
                if errno == EINTR { continue }
                return .failed(errno)
            }
            var cursor = buffer
            let end = buffer + bufferSize
            for _ in 0..<count {
                guard cursor + 4 <= end else { return .failed(EIO) }
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                guard length >= 4 + MemoryLayout<attribute_set_t>.size, cursor + length <= end else { return .failed(EIO) }
                parseEntry(cursor, length: length, entries: &entries, names: &names, kinds: &kinds)
                cursor += length
            }
        }
    }

    private static func parseEntry(_ entry: UnsafeMutableRawPointer, length: Int, entries: inout [Entry],
                                   names: inout [UInt8], kinds: inout [String: UInt8]) {
        let returned = (entry + 4).loadUnaligned(as: attribute_set_t.self)
        var offset = 4 + MemoryLayout<attribute_set_t>.size
        func has(_ size: Int) -> Bool { offset + size <= length }
        guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0, has(MemoryLayout<attrreference_t>.size) else { return }
        let reference = (entry + offset).loadUnaligned(as: attrreference_t.self)
        let nameStart = offset + Int(reference.attr_dataoffset)
        let nameLength = Int(reference.attr_length) - 1 // NUL terminated
        guard nameLength > 0, nameLength <= Int(UInt16.max), nameStart >= 0, nameStart + nameLength < length else { return }
        offset += MemoryLayout<attrreference_t>.size
        let name = UnsafeRawBufferPointer(start: entry + nameStart, count: nameLength)
        if nameLength <= 2, name[0] == 0x2E, nameLength == 1 || name[1] == 0x2E { return }

        var type: UInt32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            guard has(4) else { return }
            type = (entry + offset).loadUnaligned(as: UInt32.self)
            offset += 4
        }
        var modified = timespec()
        if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            guard has(MemoryLayout<timespec>.size) else { return }
            modified = (entry + offset).loadUnaligned(as: timespec.self)
            offset += MemoryLayout<timespec>.size
        }
        var fileID: UInt64 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            guard has(8) else { return }
            fileID = (entry + offset).loadUnaligned(as: UInt64.self)
            offset += 8
        }
        var linkCount: UInt32 = 1
        if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            guard has(4) else { return }
            linkCount = (entry + offset).loadUnaligned(as: UInt32.self)
            offset += 4
        }
        var logical: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 {
            guard has(8) else { return }
            logical = (entry + offset).loadUnaligned(as: Int64.self)
            offset += 8
        }
        var allocated: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            guard has(8) else { return }
            allocated = (entry + offset).loadUnaligned(as: Int64.self)
        }

        let isDirectory = type == VDIR.rawValue
        let isSymlink = type == VLNK.rawValue
        var category = categoryIndex(.folder)
        if !isDirectory {
            category = categoryIndex(.other)
            // Hash-like suffixes are not extensions and would only bloat the cache.
            if let dot = name.lastIndex(of: 0x2E), nameLength - dot - 1 <= maxKnownExtensionLength {
                let ext = String(decoding: name[(dot + 1)...], as: UTF8.self)
                if let known = kinds[ext] {
                    category = known
                } else {
                    category = categoryIndex(FileKindCategory.detect(extension: ext, isDirectory: false))
                    kinds[ext] = category
                }
            }
        }
        entries.append(Entry(nameOffset: names.count, nameLength: nameLength, category: category,
            flags: (isDirectory ? DiskTree.Flag.directory : 0) | (isSymlink ? DiskTree.Flag.symlink : 0),
            modified: Int64(modified.tv_sec), allocated: isDirectory ? 0 : allocated,
            logical: isDirectory ? 0 : logical, fileID: fileID, linkCount: linkCount))
        names.append(contentsOf: name)
    }

    /// Caller holds the lock. Appends the listing and schedules subdirectories.
    private static func commit(_ job: Job, device: Int32, entries: [Entry], names: [UInt8],
                               boundary: DiskScanBoundary, shared: Shared, maxEntries: Int) {
        guard shared.nodes.count + entries.count <= maxEntries else {
            shared.reachedLimit = true
            shared.stack.removeAll()
            shared.deferred.removeAll()
            return
        }
        let base = shared.nameBytes.count
        shared.nameBytes.append(contentsOf: names)
        let parentPrefix = job.path == "/" ? "/" : job.path + "/"
        for entry in entries {
            var allocated = entry.allocated
            // A hard-linked file occupies disk once, however many names it has.
            if entry.linkCount > 1, entry.flags & DiskTree.Flag.directory == 0, device != 0,
               !shared.hardLinks.insert(FileIdentity(device: device, file: entry.fileID)).inserted {
                allocated = 0
            }
            let id = DiskTree.NodeID(shared.nodes.count)
            shared.nodes.append(DiskTree.Node(parent: job.node, nameOffset: UInt32(base + entry.nameOffset),
                nameLength: UInt16(entry.nameLength), category: entry.category, flags: entry.flags,
                allocated: allocated, logical: entry.logical, modified: entry.modified,
                fileCount: entry.flags & DiskTree.Flag.directory == 0 ? 1 : 0, firstChild: 0, childCount: 0))
            shared.scannedBytes += allocated
            guard entry.flags & DiskTree.Flag.directory != 0 else { continue }
            let start = names.index(names.startIndex, offsetBy: entry.nameOffset)
            let path = parentPrefix + String(decoding: names[start..<(start + entry.nameLength)], as: UTF8.self)
            if boundary.excluded.contains(path) {
                shared.skippedMounts += 1
            } else if boundary.deferred.contains(path) {
                shared.deferred.append(Job(path: path, node: id))
            } else {
                shared.stack.append(Job(path: path, node: id))
            }
        }
    }

    /// Child IDs are always greater than their parent's, so one reverse pass adds up every folder.
    private static func rollUpSizes(_ nodes: inout ContiguousArray<DiskTree.Node>) {
        nodes.withUnsafeMutableBufferPointer { table in
            var index = table.count - 1
            while index > 0 {
                let node = table[index]
                let parent = Int(node.parent)
                table[parent].allocated += node.allocated
                table[parent].logical += node.logical
                table[parent].fileCount += node.fileCount
                if node.modified > table[parent].modified { table[parent].modified = node.modified }
                index -= 1
            }
        }
    }

    /// Groups children per parent and sorts each group largest-first. Folders
    /// that were aliases of an already visited firmlink target are left out.
    private static func linkChildren(_ nodes: inout ContiguousArray<DiskTree.Node>) -> ContiguousArray<DiskTree.NodeID> {
        let count = nodes.count
        var total = 0
        var starts = ContiguousArray<Int32>(repeating: 0, count: count + 1)
        for index in 1..<max(1, count) where nodes[index].flags & DiskTree.Flag.alias == 0 {
            starts[Int(nodes[index].parent)] += 1
            total += 1
        }
        var running: Int32 = 0
        for index in 0..<count {
            let size = starts[index]
            nodes[index].firstChild = running
            nodes[index].childCount = size
            starts[index] = running
            running += size
        }
        var children = ContiguousArray<DiskTree.NodeID>(repeating: 0, count: total)
        for index in 1..<max(1, count) where nodes[index].flags & DiskTree.Flag.alias == 0 {
            let parent = Int(nodes[index].parent)
            children[Int(starts[parent])] = DiskTree.NodeID(index)
            starts[parent] += 1
        }
        let snapshot = nodes
        let chunks = 64, chunkSize = count / chunks + 1
        children.withUnsafeMutableBufferPointer { list in
            let base = list.baseAddress
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let groups = UnsafeMutableBufferPointer(start: base, count: total)
                for index in min(count, chunk * chunkSize)..<min(count, (chunk + 1) * chunkSize) {
                    let node = snapshot[index]
                    guard node.childCount > 1 else { continue }
                    let start = Int(node.firstChild)
                    groups[start..<(start + Int(node.childCount))].sort {
                        snapshot[Int($0)].allocated > snapshot[Int($1)].allocated
                    }
                }
            }
        }
        return children
    }

    private static func categoryIndex(_ category: FileKindCategory) -> UInt8 {
        UInt8(FileKindCategory.allCases.firstIndex(of: category) ?? 0)
    }
}
