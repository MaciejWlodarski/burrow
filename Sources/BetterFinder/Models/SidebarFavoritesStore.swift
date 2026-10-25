import Foundation

/// An ordered, user-owned sidebar. Loading never probes folders or prunes offline entries.
@MainActor final class SidebarFavoritesStore {
    static let key = "bf.sidebarFavorites.v1"
    static let maximumCount = 1024
    struct Entry: Codable, Equatable {
        let path: String
        var title: String
        var iconName: String
    }
    private struct Archive: Codable { let version: Int; let items: [Entry] }
    private(set) var items: [Entry] = []
    private(set) var notice: String?
    private var observedData: Data?
    private let read: () -> Any?
    private let write: (Data) -> Void

    init(defaults: [Entry], read: @escaping () -> Any?, readLegacy: () -> Any?,
         write: @escaping (Data) -> Void) {
        self.read = read; self.write = write
        if let raw = read() {
            guard let data = raw as? Data, let entries = Self.decode(data) else { protect(); return }
            items = entries; observedData = data
            return
        }
        var seed = defaults
        if let legacy = readLegacy() {
            guard let paths = legacy as? [String], paths.count <= PinnedFolderStore.maximumCount,
                  paths.allSatisfy(PinnedFolderStore.validPath),
                  paths.reduce(0, { $0 + $1.utf8.count }) <= PinnedFolderStore.maximumPayloadBytes else {
                protect(); return
            }
            seed += paths.map { Entry(path: $0, title: Self.defaultTitle(for: $0), iconName: "bookmark.fill") }
        }
        var seen = Set<String>()
        seed = seed.filter { seen.insert(Self.membershipKey($0.path)).inserted }
        // Persist the initial order once. Keep legacy bytes intact for recovery.
        guard save(seed) else { protect(); return }
    }
    /// Trailing separators do not change a folder, but do not resolve symlinks or dot components.
    private static func membershipKey(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let minimumEnd = path.index(after: path.startIndex)
        var end = path.endIndex
        while end > minimumEnd && path[path.index(before: end)] == "/" {
            end = path.index(before: end)
        }
        return String(path[..<end])
    }
    static func defaultTitle(for path: String) -> String {
        let part = path.split(separator: "/").last.map(String.init) ?? "/"
        var result = ""
        var bytes = 0
        for scalar in part.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            let text = String(scalar)
            guard bytes + text.utf8.count <= 1024 else { break }
            result += text; bytes += text.utf8.count
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : result
    }
    private static func valid(_ entries: [Entry]) -> Bool {
        guard entries.count <= maximumCount, Set(entries.map { membershipKey($0.path) }).count == entries.count else { return false }
        return entries.allSatisfy {
            PinnedFolderStore.validPath($0.path) && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.title.utf8.count <= 1024 && !$0.title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            !$0.iconName.isEmpty && $0.iconName.utf8.count <= 128 &&
            $0.iconName.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }
        }
    }
    private static func decode(_ data: Data) -> [Entry]? {
        guard data.count <= PinnedFolderStore.maximumPayloadBytes,
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == 1, valid(archive.items) else { return nil }
        return archive.items
    }
    private func protect() {
        notice = "Nie można zmienić ulubionych: zapis jest uszkodzony, nieobsługiwany lub zmienił się poza aplikacją. Zachowano poprzednie dane."
    }
    @discardableResult private func save(_ entries: [Entry]) -> Bool {
        guard notice == nil, Self.valid(entries),
              let data = try? JSONEncoder().encode(Archive(version: 1, items: entries)),
              data.count <= PinnedFolderStore.maximumPayloadBytes else { return false }
        let current = read()
        if let observedData {
            guard let current = current as? Data, current == observedData else { protect(); return false }
        } else if current != nil { protect(); return false }
        write(data)
        guard let persisted = read() as? Data, persisted == data else { protect(); return false }
        observedData = data; items = entries
        return true
    }
    @discardableResult func add(_ path: String) -> Bool {
        guard notice == nil, PinnedFolderStore.validPath(path) else { return false }
        if items.contains(where: { Self.membershipKey($0.path) == Self.membershipKey(path) }) { return true }
        return save(items + [Entry(path: path, title: Self.defaultTitle(for: path), iconName: "bookmark.fill")])
    }
    @discardableResult func remove(_ path: String) -> Bool {
        guard notice == nil else { return false }
        guard items.contains(where: { $0.path == path }) else { return true }
        return save(items.filter { $0.path != path })
    }
    @discardableResult func rename(_ path: String, title: String) -> Bool {
        guard notice == nil, let index = items.firstIndex(where: { $0.path == path }) else { return false }
        var next = items; next[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return save(next)
    }
    @discardableResult func setIcon(_ path: String, iconName: String) -> Bool {
        guard notice == nil, let index = items.firstIndex(where: { $0.path == path }) else { return false }
        guard items[index].iconName != iconName else { return true }
        var next = items; next[index].iconName = iconName
        return save(next)
    }
    @discardableResult func move(_ path: String, by offset: Int) -> Bool {
        guard notice == nil, offset == -1 || offset == 1,
              let index = items.firstIndex(where: { $0.path == path }),
              items.indices.contains(index + offset) else { return false }
        var next = items; next.swapAt(index, index + offset)
        return save(next)
    }
    @discardableResult func move(_ path: String, before target: String?) -> Bool {
        guard notice == nil, let index = items.firstIndex(where: { $0.path == path }) else { return false }
        if target == path { return true }
        if let target, !items.contains(where: { $0.path == target }) { return false }
        var next = items; let entry = next.remove(at: index)
        let destination = target.flatMap { value in next.firstIndex(where: { $0.path == value }) } ?? next.endIndex
        next.insert(entry, at: destination)
        return next == items ? true : save(next)
    }
}
