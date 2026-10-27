import Foundation

/// Membership only: intentionally has no filesystem/availability dependency.
@MainActor final class PinnedFolderStore {
    static let key = "bf.customBookmarks"
    static let maximumCount = 512
    static let maximumPathBytes = 16_384
    static let maximumPayloadBytes = 1_048_576
    enum State { case missing, valid, protected }
    private(set) var state: State = .missing
    private(set) var paths: [String] = []
    private let read: () -> Any?
    private let write: ([String]) -> Void
    var notice: String? {
        state == .protected ? "Nie można zmienić przypiętych folderów: zapis jest uszkodzony, nieobsługiwany lub nie udało się go potwierdzić. Kolejne zmiany zablokowano." : nil
    }
    init(read: @escaping () -> Any?, write: @escaping ([String]) -> Void) {
        self.read = read; self.write = write
        load()
    }
    static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= maximumPathBytes && !path.utf8.contains(0)
    }
    private static func valid(_ paths: [String]) -> Bool {
        guard paths.count <= maximumCount else { return false }
        var bytes = 0
        for path in paths {
            guard validPath(path) else { return false }
            bytes += path.utf8.count
            guard bytes <= maximumPayloadBytes else { return false }
        }
        return true
    }
    private func load() {
        guard let raw = read() else { state = .missing; paths = []; return }
        guard let values = raw as? [String], Self.valid(values) else {
            state = .protected; paths = []; return
        }
        state = .valid
        // Preserve exact stored membership, including duplicates, on later writes.
        paths = values
    }
    var displayedPaths: [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
    @discardableResult func add(_ path: String) -> Bool {
        guard state != .protected, Self.validPath(path) else { return false }
        guard !paths.contains(path) else { return true }
        return save(paths + [path])
    }
    @discardableResult func remove(_ path: String) -> Bool {
        guard state != .protected else { return false }
        guard paths.contains(path) else { return true }
        return save(paths.filter { $0 != path })
    }
    private func save(_ values: [String]) -> Bool {
        // Recheck the raw record at mutation time: never overwrite later corruption.
        if let raw = read() {
            guard let stored = raw as? [String], Self.valid(stored), stored == paths else {
                state = .protected; return false
            }
        } else if state != .missing {
            state = .protected; return false
        }
        guard Self.valid(values) else { return false }
        write(values)
        guard let persisted = read() as? [String], persisted == values else {
            // A refused/dropped write is not success. Keep prior membership visible.
            state = .protected
            return false
        }
        paths = values; state = .valid
        return true
    }
}
