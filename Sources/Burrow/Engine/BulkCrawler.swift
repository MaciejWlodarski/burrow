import Foundation
import Darwin

/// Compact indexed entry stored in contiguous memory for sub-millisecond fsearch queries
public struct IndexedFileEntry: Sendable {
    public let name: String
    public let lowerNameUTF8: [UInt8]
    public let parentPath: String
    public let ext: String
    public let charMask: UInt64
    public let size: Int64
    public let mtimeEpoch: Int64
    public let mtimeNanoseconds: Int64
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isHidden: Bool

    public init(
        name: String,
        lowerNameUTF8: [UInt8],
        parentPath: String,
        ext: String,
        charMask: UInt64,
        size: Int64,
        mtimeEpoch: Int64,
        isDirectory: Bool,
        isSymlink: Bool,
        isHidden: Bool,
        mtimeNanoseconds: Int64 = 0
    ) {
        self.name = name
        self.lowerNameUTF8 = lowerNameUTF8
        self.parentPath = parentPath
        self.ext = ext
        self.charMask = charMask
        self.size = size
        self.mtimeEpoch = mtimeEpoch
        self.mtimeNanoseconds = mtimeNanoseconds
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isHidden = isHidden
    }

    public var fullPath: String {
        if parentPath == "/" {
            return "/\(name)"
        }
        return "\(parentPath)/\(name)"
    }

    /// Shared by display and age predicates; retain the crawler/cache subsecond value.
    public var modificationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(mtimeEpoch) + TimeInterval(mtimeNanoseconds) / 1_000_000_000)
    }

    public func toFileItem(
        grepMatch: GrepMatchSnippet? = nil,
        gitStatus: GitFileStatus? = nil,
        treeDepth: Int = 0,
        score: Int = 0,
        loadTags: Bool = true
    ) -> FileItem {
        let p = fullPath
        let url = URL(fileURLWithPath: p, isDirectory: isDirectory)
        let modDate = modificationDate
        let tags = loadTags ? FinderTagColor.readTags(for: url) : []
        return FileItem(
            url: url,
            name: name,
            path: p,
            parentPath: parentPath,
            fileExtension: ext,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            isHidden: isHidden,
            size: size,
            modificationDate: modDate,
            creationDate: modDate,
            gitStatus: gitStatus,
            grepMatch: grepMatch,
            tags: tags,
            treeDepth: treeDepth,
            searchScore: score
        )
    }
}

/// High-speed macOS kernel `getattrlistbulk` directory reader (same underlying syscall used by noahdunnagan/fsearch)
public enum BulkCrawler {
    public static let defaultSkippedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Pods", ".Trash",
        "Caches", "CloudKit", "CoreSimulator", ".swiftpm", "target", "__pycache__",
        ".venv", "venv", ".next", ".nuxt", ".cache", ".cargo", ".rustup"
    ]

    public struct DirectoryReadResult: Sendable {
        public let entries: [IndexedFileEntry]
        public let isComplete: Bool
        public let errorCode: Int32?
    }

    public struct CrawlResult: Sendable {
        public let entries: [IndexedFileEntry]
        public let isComplete: Bool
        public let skippedDirectoryCount: Int
        public let unreadableDirectoryCount: Int
        public let wasCancelled: Bool
        public let reachedEntryLimit: Bool
    }

    /// Compatibility listing; callers needing completeness use readDirectoryResult.
    public static func readDirectoryFast(at path: String, includeHidden: Bool = true) -> [IndexedFileEntry] {
        readDirectoryResult(at: path, includeHidden: includeHidden).entries
    }

    /// Bounded bulk listing. Failure and truncation are never reported as an empty,
    /// complete directory. The budget bounds retained entries even for huge folders.
    public static func readDirectoryResult(
        at path: String,
        includeHidden: Bool = true,
        maxEntries: Int = Int.max,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> DirectoryReadResult {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return DirectoryReadResult(entries: [], isComplete: false, errorCode: errno) }
        defer { Darwin.close(fd) }
        var attrList = attrlist()
        attrList.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) |
            attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
        attrList.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE)
        let bufSize = 128 * 1024
        let rawBuf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { rawBuf.deallocate() }
        var results: [IndexedFileEntry] = []
        results.reserveCapacity(min(max(0, maxEntries), 128))
        let parent = URL(fileURLWithPath: path).standardizedFileURL.path

        while !isCancelled() {
            let count = getattrlistbulk(fd, &attrList, rawBuf, bufSize, 0)
            if count == 0 { return DirectoryReadResult(entries: results, isComplete: true, errorCode: nil) }
            if count < 0 {
                if errno == EINTR { continue }
                return DirectoryReadResult(entries: results, isComplete: false, errorCode: errno)
            }
            var entryOffset = 0
            for _ in 0..<count {
                if isCancelled() { return DirectoryReadResult(entries: results, isComplete: false, errorCode: nil) }
                guard entryOffset + 4 <= bufSize else {
                    return DirectoryReadResult(entries: results, isComplete: false, errorCode: EIO)
                }
                let entryPtr = rawBuf.advanced(by: entryOffset)
                let entryLength = Int(entryPtr.loadUnaligned(as: UInt32.self))
                guard entryLength >= 4 + MemoryLayout<attribute_set_t>.size,
                      entryLength <= bufSize - entryOffset else {
                    return DirectoryReadResult(entries: results, isComplete: false, errorCode: EIO)
                }
                let returned = entryPtr.advanced(by: 4).loadUnaligned(as: attribute_set_t.self)
                var offset = 4 + MemoryLayout<attribute_set_t>.size
                var name: String?
                if (returned.commonattr & attrgroup_t(ATTR_CMN_NAME)) != 0 {
                    guard offset + MemoryLayout<attrreference_t>.size <= entryLength else {
                        return DirectoryReadResult(entries: results, isComplete: false, errorCode: EIO)
                    }
                    let ref = entryPtr.advanced(by: offset).loadUnaligned(as: attrreference_t.self)
                    let nameOffset = offset + Int(ref.attr_dataoffset)
                    let nameLength = Int(ref.attr_length)
                    guard nameOffset >= 0, nameLength > 0, nameOffset <= entryLength,
                          nameLength <= entryLength - nameOffset else {
                        return DirectoryReadResult(entries: results, isComplete: false, errorCode: EIO)
                    }
                    let bytes = UnsafeBufferPointer(start: entryPtr.advanced(by: nameOffset).assumingMemoryBound(to: UInt8.self), count: nameLength)
                    guard bytes.last == 0 else {
                        return DirectoryReadResult(entries: results, isComplete: false, errorCode: EIO)
                    }
                    name = String(bytes: bytes.dropLast(), encoding: .utf8)
                    offset += MemoryLayout<attrreference_t>.size
                }
                var objType: UInt32 = 0
                if (returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE)) != 0 {
                    guard offset + 4 <= entryLength else { return DirectoryReadResult(entries: results, isComplete: false, errorCode: EIO) }
                    objType = entryPtr.advanced(by: offset).loadUnaligned(as: UInt32.self)
                    offset += 4
                }
                var mtime = timespec()
                if (returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME)) != 0 {
                    guard offset + MemoryLayout<timespec>.size <= entryLength else { return DirectoryReadResult(entries: results, isComplete: false, errorCode: EIO) }
                    mtime = entryPtr.advanced(by: offset).loadUnaligned(as: timespec.self)
                    offset += MemoryLayout<timespec>.size
                }
                var size: Int64 = 0
                if (returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE)) != 0 {
                    guard offset + 8 <= entryLength else { return DirectoryReadResult(entries: results, isComplete: false, errorCode: EIO) }
                    size = entryPtr.advanced(by: offset).loadUnaligned(as: Int64.self)
                }
                guard let name = name else { return DirectoryReadResult(entries: results, isComplete: false, errorCode: EIO) }
                if name != ".", name != "..", includeHidden || !name.hasPrefix(".") {
                    guard results.count < maxEntries else { return DirectoryReadResult(entries: results, isComplete: false, errorCode: nil) }
                    let ext = (name as NSString).pathExtension.lowercased()
                    let lower = Array(ParsedFSearchQuery.normalizedNameSearchText(name).utf8)
                    results.append(IndexedFileEntry(name: name, lowerNameUTF8: lower, parentPath: parent,
                        ext: ext, charMask: ParsedFSearchQuery.computeAsciiBitmask(lower), size: objType == 2 ? 0 : size,
                        mtimeEpoch: Int64(mtime.tv_sec), isDirectory: objType == 2, isSymlink: objType == 5,
                        isHidden: name.hasPrefix("."), mtimeNanoseconds: Int64(mtime.tv_nsec)))
                }
                entryOffset += entryLength
            }
        }
        return DirectoryReadResult(entries: results, isComplete: false, errorCode: nil)
    }

    /// Breadth-first crawl with a strict retained-entry budget and explicit coverage.
    /// Each directory read is bounded by the remaining budget, not a 64-folder batch.
    public static func crawlTreeResult(
        roots: [String],
        skipHeavyDevDirs: Bool = true,
        customSkippedDirs: Set<String>? = nil,
        maxEntries: Int = 600_000,
        includeHidden: Bool = true,
        isCancelled: @Sendable () -> Bool = { false },
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> CrawlResult {
        let skipped = customSkippedDirs ?? defaultSkippedDirectoryNames
        let normalized = Set(roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        // An ancestor root already visits descendants; overlapping roots must not
        // duplicate entries or spend the work budget on the same tree twice.
        var queue = normalized.filter { root in
            !normalized.contains { other in other != root && (other == "/" || root.hasPrefix(other + "/")) }
        }.sorted()
        var visited = Set<String>()
        var visitedIdentities = Set<String>()
        var entries: [IndexedFileEntry] = []
        entries.reserveCapacity(min(max(0, maxEntries), 150_000))
        var head = 0
        var skippedCount = 0
        var unreadableCount = 0
        var reachedLimit = false
        while head < queue.count && !isCancelled() {
            guard entries.count < maxEntries else { reachedLimit = true; break }
            let path = queue[head]
            head += 1
            guard visited.insert(path).inserted else { continue }
            var info = stat()
            if stat(path, &info) == 0 {
                let identity = "\(info.st_dev):\(info.st_ino)"
                guard visitedIdentities.insert(identity).inserted else { continue }
            }
            let read = readDirectoryResult(at: path, includeHidden: includeHidden,
                maxEntries: maxEntries - entries.count, isCancelled: isCancelled)
            entries.append(contentsOf: read.entries)
            if read.errorCode != nil { unreadableCount += 1 }
            if !read.isComplete && read.errorCode == nil && !isCancelled() { reachedLimit = true }
            for item in read.entries where item.isDirectory && !item.isSymlink {
                if skipHeavyDevDirs && (skipped.contains(item.name) || (item.name == "Library" && item.parentPath == NSHomeDirectory())) {
                    skippedCount += 1
                } else {
                    queue.append(item.fullPath)
                }
            }
            progress?(entries.count)
            if reachedLimit { break }
        }
        let cancelled = isCancelled()
        return CrawlResult(entries: entries,
            isComplete: !cancelled && !reachedLimit && unreadableCount == 0 && skippedCount == 0,
            skippedDirectoryCount: skippedCount, unreadableDirectoryCount: unreadableCount,
            wasCancelled: cancelled, reachedEntryLimit: reachedLimit)
    }

    public static func crawlTree(
        roots: [String],
        skipHeavyDevDirs: Bool = true,
        customSkippedDirs: Set<String>? = nil,
        maxEntries: Int = 600_000,
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [IndexedFileEntry] {
        crawlTreeResult(roots: roots, skipHeavyDevDirs: skipHeavyDevDirs,
            customSkippedDirs: customSkippedDirs, maxEntries: maxEntries, progress: progress).entries
    }
}
