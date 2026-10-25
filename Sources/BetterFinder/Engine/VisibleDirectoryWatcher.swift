import CoreServices
import Foundation

/// Live refresh for directories shown in panes. The index watcher only covers
/// configured index roots, so folders such as the home directory, Pictures or
/// external volumes would otherwise never refresh after external changes.
/// Only events whose parent (or the path itself) is a watched directory are
/// reported, so watching a large tree like the home directory stays cheap.
final class VisibleDirectoryWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.betterfinder.visible-directory-watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var watched: Set<String> = []
    /// Canonical (symlink-resolved) form → watched path, e.g. /private/tmp/x → /tmp/x.
    private var canonicalToWatched: [String: String] = [:]
    private let onChange: @Sendable (Set<String>) -> Void

    init(onChange: @escaping @Sendable (Set<String>) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    /// Restarts the stream only when the watched set actually changes.
    func update(paths: Set<String>) {
        let normalized = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        lock.lock()
        guard normalized != watched else { lock.unlock(); return }
        lock.unlock()
        var canonical: [String: String] = [:]
        for path in normalized { canonical[URL(fileURLWithPath: path).resolvingSymlinksInPath().path] = path }
        lock.lock()
        watched = normalized
        canonicalToWatched = canonical
        lock.unlock()
        restart(watching: normalized)
    }

    func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        if let current {
            FSEventStreamStop(current)
            FSEventStreamInvalidate(current)
            FSEventStreamRelease(current)
        }
    }

    private func restart(watching paths: Set<String>) {
        stop()
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<VisibleDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            watcher.handle(Array(paths.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, Array(paths) as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        lock.lock()
        stream = created
        lock.unlock()
    }

    private func handle(_ eventPaths: [String]) {
        lock.lock()
        let watched = self.watched
        let canonical = canonicalToWatched
        lock.unlock()
        // FSEvents may report canonical paths (/private/tmp for /tmp); compare both forms.
        var changed = Set<String>()
        for raw in eventPaths {
            let path = URL(fileURLWithPath: raw).standardizedFileURL.path
            let parent = (path as NSString).deletingLastPathComponent
            for candidate in [path, parent] {
                if watched.contains(candidate) { changed.insert(candidate) }
                if let original = canonical[candidate] { changed.insert(original) }
            }
            // A watched directory (or an ancestor) was removed or renamed.
            for dir in watched where dir.hasPrefix(path == "/" ? "/" : path + "/") { changed.insert(dir) }
        }
        if !changed.isEmpty { onChange(changed) }
    }
}
