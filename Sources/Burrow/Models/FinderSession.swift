import Foundation
import Darwin

/// Versioned, local-only view state. Decoding never checks paths or starts work.
struct FinderPaneSession: Codable, Equatable, Sendable {
    var path: String
    var view: String = "list"
    var sort: String = "name"
    var ascending = true
    var foldersOnTop = true
    var hidden = false
    var fuzzy = true
    var query = ""
    var scope = "wholeIndex"

    var isValid: Bool {
        path.hasPrefix("/") && !path.utf8.contains(0) && path.utf8.count <= 16_384
            && query.utf8.count <= 16_384
            && ["list", "icons", "columns", "wiztree"].contains(view)
            && ["name", "size", "modified", "kind"].contains(sort)
            && ["currentFolder", "recursiveFolder", "wholeIndex"].contains(scope)
    }

    @MainActor init(pane: PaneTabState) {
        path = pane.currentURL.path
        switch pane.viewMode {
        case .list: view = "list"
        case .icons: view = "icons"
        case .columns: view = "columns"
        case .wiztree: view = "wiztree"
        }
        switch pane.sortField {
        case .name: sort = "name"
        case .size: sort = "size"
        case .dateModified: sort = "modified"
        case .kind: sort = "kind"
        }
        ascending = pane.sortAscending
        foldersOnTop = pane.foldersOnTop
        hidden = pane.showHiddenFiles
        fuzzy = pane.fuzzyEnabled
        query = pane.searchQuery
        switch pane.searchScope {
        case .currentFolder: scope = "currentFolder"
        case .recursiveFolder: scope = "recursiveFolder"
        case .wholeIndex: scope = "wholeIndex"
        }
    }

    init(path: String) { self.path = path }

    @MainActor func makePausedPane() -> PaneTabState {
        let pane = PaneTabState(initialURL: URL(fileURLWithPath: path, isDirectory: true), loadImmediately: false)
        pane.viewMode = ["icons": FinderViewMode.icons, "columns": .columns, "wiztree": .wiztree][view] ?? .list
        pane.sortField = ["size": SortField.size, "modified": .dateModified, "kind": .kind][sort] ?? .name
        pane.sortAscending = ascending
        pane.foldersOnTop = foldersOnTop
        pane.showHiddenFiles = hidden
        pane.fuzzyEnabled = fuzzy
        pane.searchQuery = query
        pane.searchScope = ["currentFolder": SearchScopeMode.currentFolder, "recursiveFolder": .recursiveFolder][scope] ?? .wholeIndex
        return pane
    }
}

struct FinderSessionSnapshot: Codable, Equatable, Sendable {
    let version: Int
    var tabs: [FinderPaneSession]
    var right: FinderPaneSession
    var activeIndex: Int
    var dualPane: Bool
    var activeSide: String

    init(tabs: [FinderPaneSession], right: FinderPaneSession, activeIndex: Int, dualPane: Bool, activeSide: String) {
        version = 1
        self.tabs = tabs
        self.right = right
        self.activeIndex = tabs.isEmpty ? 0 : max(0, min(activeIndex, tabs.count - 1))
        self.dualPane = dualPane
        self.activeSide = dualPane && activeSide == "right" ? "right" : "left"
    }
}

struct FinderSessionLoad {
    let snapshot: FinderSessionSnapshot?
    let canWrite: Bool
    let notice: String?
}

/// Pure codec and isolated preference store. Unknown/damaged data is retained
/// until an explicit Clear, even if some valid tabs can be recovered for display.
final class FinderSessionStore {
    static let dataKey = "bf.session.v1"
    static let enabledKey = "bf.restoreSession"
    private let defaults: UserDefaults
    private(set) var canWrite = true
    private var lastWritten: Data?

    init(defaults: UserDefaults) { self.defaults = defaults }
    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey) }
    func setEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: Self.enabledKey) }

    func load(defaultRightPath: String) -> FinderSessionLoad {
        if let data = defaults.data(forKey: Self.dataKey) {
            let result = Self.decode(data)
            canWrite = result.canWrite
            lastWritten = data
            return FinderSessionLoad(snapshot: isEnabled ? result.snapshot : nil, canWrite: result.canWrite, notice: result.notice)
        }
        if defaults.object(forKey: Self.dataKey) != nil {
            canWrite = false
            return FinderSessionLoad(snapshot: nil, canWrite: false, notice: Self.protectedNotice)
        }
        guard let legacy = defaults.array(forKey: "bf.openTabPaths"), !legacy.isEmpty else {
            canWrite = defaults.object(forKey: "bf.openTabPaths") == nil || defaults.array(forKey: "bf.openTabPaths") != nil
            return FinderSessionLoad(snapshot: nil, canWrite: canWrite, notice: canWrite ? nil : Self.protectedNotice)
        }
        let originalIndex = defaults.integer(forKey: "bf.activeTabIndex")
        let candidates: [(Int, FinderPaneSession)] = legacy.prefix(128).enumerated().compactMap {
            guard let path = $0.element as? String else { return nil }
            return ($0.offset, FinderPaneSession(path: path))
        }
        let valid = candidates.filter { $0.1.isValid }
        let preserved = valid.map { $0.1 }
        let clamped = max(0, min(originalIndex, legacy.count - 1))
        let active = valid.lastIndex { $0.0 <= clamped } ?? 0
        canWrite = valid.count == legacy.count
        return FinderSessionLoad(snapshot: preserved.isEmpty || !isEnabled ? nil : FinderSessionSnapshot(
            tabs: preserved, right: FinderPaneSession(path: defaultRightPath), activeIndex: active,
            dualPane: defaults.bool(forKey: "bf.isDualPane"), activeSide: "left"), canWrite: canWrite,
            notice: canWrite ? nil : Self.protectedNotice)
    }

    static let protectedNotice = "Zapis sesji zawiera nieobsługiwane lub uszkodzone dane. Nie zostanie nadpisany. Możesz wyczyścić tylko zapis sesji w ustawieniach."

    private struct Header: Decodable {
        let version: Int
        let activeIndex: Int
        let dualPane: Bool
        let activeSide: String
    }

    static func decode(_ data: Data) -> FinderSessionLoad {
        guard data.count <= 4 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = try? JSONDecoder().decode(Header.self, from: data), header.version == 1,
              let records = object["tabs"] as? [Any], !records.isEmpty, records.count <= 128,
              let rightObject = object["right"],
              let rightData = try? JSONSerialization.data(withJSONObject: rightObject, options: [.fragmentsAllowed]),
              let right = try? JSONDecoder().decode(FinderPaneSession.self, from: rightData), right.isValid,
              ["left", "right"].contains(header.activeSide) else {
            return FinderSessionLoad(snapshot: nil, canWrite: false, notice: protectedNotice)
        }
        var tabs: [FinderPaneSession] = []
        var mappedIndex = 0
        let active = max(0, min(header.activeIndex, records.count - 1))
        var valid = true
        for (index, record) in records.enumerated() {
            if let bytes = try? JSONSerialization.data(withJSONObject: record, options: [.fragmentsAllowed]),
               let pane = try? JSONDecoder().decode(FinderPaneSession.self, from: bytes), pane.isValid {
                if index <= active { mappedIndex = tabs.count }
                tabs.append(pane)
            } else { valid = false }
        }
        guard !tabs.isEmpty else { return FinderSessionLoad(snapshot: nil, canWrite: false, notice: protectedNotice) }
        return FinderSessionLoad(snapshot: FinderSessionSnapshot(tabs: tabs, right: right,
            activeIndex: mappedIndex, dualPane: header.dualPane, activeSide: header.activeSide), canWrite: valid,
            notice: valid ? nil : protectedNotice)
    }

    @discardableResult func save(_ snapshot: FinderSessionSnapshot) -> Bool {
        guard isEnabled, canWrite, defaults.data(forKey: Self.dataKey) == lastWritten,
              defaults.object(forKey: Self.dataKey) == nil || defaults.data(forKey: Self.dataKey) != nil,
              !snapshot.tabs.isEmpty, snapshot.tabs.count <= 128,
              snapshot.tabs.allSatisfy(\.isValid), snapshot.right.isValid,
              let bytes = try? JSONEncoder().encode(snapshot), bytes.count <= 4 * 1024 * 1024 else { return false }
        if bytes != lastWritten {
            defaults.set(bytes, forKey: Self.dataKey)
            lastWritten = bytes
        }
        return true
    }

    /// Clearing also disables future saves, so observers cannot recreate it.
    /// Bookmarks, smart folders and ordinary view preferences are untouched.
    func clearAndDisable() {
        setEnabled(false)
        defaults.removeObject(forKey: Self.dataKey)
        defaults.removeObject(forKey: "bf.openTabPaths")
        defaults.removeObject(forKey: "bf.activeTabIndex")
        canWrite = true
        lastWritten = nil
    }
}

/// Errors describe observed availability, not a guessed relocation or home fallback.
enum FinderSessionReadError: LocalizedError {
    case notDirectory, permissionDenied, unavailable, incomplete
    var errorDescription: String? {
        switch self {
        case .notDirectory: return "Pod zapisaną ścieżką nie ma folderu. Nie otwarto znajdującego się tam pliku. Wybierz inną lokalizację."
        case .permissionDenied: return "Brak uprawnień do odczytu folderu. Ścieżka została zachowana; aplikacja nie zmieniła uprawnień."
        case .unavailable: return "Lokalizacja jest obecnie nieosiągalna. Folder mógł zostać przeniesiony, usunięty lub znajdować się na odłączonym dysku. Ścieżka została zachowana."
        case .incomplete: return "Nie udało się odczytać całej zawartości folderu. Widok pozostał wstrzymany; spróbuj ponownie."
        }
    }
}

enum FinderSessionPreparation {
    static func prepare(path: String, hidden: Bool, isCancelled: @Sendable () -> Bool) throws -> PreparedSavedSearch {
        if isCancelled() { throw CancellationError() }
        var info = stat()
        guard stat(path, &info) == 0 else {
            if errno == EACCES || errno == EPERM { throw FinderSessionReadError.permissionDenied }
            throw FinderSessionReadError.unavailable
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw FinderSessionReadError.notDirectory }
        if isCancelled() { throw CancellationError() }
        let result = BulkCrawler.readDirectoryResult(at: path, includeHidden: hidden, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        if result.errorCode == EACCES || result.errorCode == EPERM { throw FinderSessionReadError.permissionDenied }
        guard result.isComplete else { throw FinderSessionReadError.incomplete }
        return PreparedSavedSearch(root: URL(fileURLWithPath: path, isDirectory: true), entries: result.entries)
    }
}
