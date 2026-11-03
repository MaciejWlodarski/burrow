import Foundation
import Combine

/// How one folder's items are ordered.
public struct FolderSort: Codable, Equatable, Sendable {
    public var field: SortField
    public var ascending: Bool
    public var foldersOnTop: Bool

    public static let standard = FolderSort(field: .name, ascending: true, foldersOnTop: true)

    public init(field: SortField, ascending: Bool, foldersOnTop: Bool) {
        self.field = field
        self.ascending = ascending
        self.foldersOnTop = foldersOnTop
    }

    /// e.g. "Date Modified, descending".
    public var summary: String {
        field.displayName + (ascending ? String(localized: ", ascending") : String(localized: ", descending")) + (foldersOnTop ? "" : String(localized: ", folders mixed with files"))
    }
}

/// Sorting like Explorer's per-folder views: one default for every folder,
/// and folders whose sort was changed keep their own until reset. A folder
/// set back to exactly the default follows the default again.
@MainActor
public final class FolderSortPreferences: ObservableObject {
    public static let shared = FolderSortPreferences(defaults: AppState.preferences)

    @Published public private(set) var defaultSort: FolderSort
    /// Standardized folder path to its own sort.
    @Published public private(set) var folderSorts: [String: FolderSort]

    private let defaults: UserDefaults
    private static let defaultKey = "folderSort.default"
    private static let foldersKey = "folderSort.folders"
    static let folderLimit = 10_000

    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaultSort = defaults.data(forKey: Self.defaultKey)
            .flatMap { try? JSONDecoder().decode(FolderSort.self, from: $0) } ?? .standard
        folderSorts = defaults.data(forKey: Self.foldersKey)
            .flatMap { try? JSONDecoder().decode([String: FolderSort].self, from: $0) } ?? [:]
    }

    static func key(for url: URL) -> String { url.standardizedFileURL.path }

    public func sort(for url: URL) -> FolderSort { folderSorts[Self.key(for: url)] ?? defaultSort }

    public func hasCustomSort(for url: URL) -> Bool { folderSorts[Self.key(for: url)] != nil }

    public func setSort(_ sort: FolderSort, for url: URL) {
        let key = Self.key(for: url)
        if sort == defaultSort {
            guard folderSorts[key] != nil else { return }
            folderSorts[key] = nil
        } else {
            guard folderSorts[key] != sort else { return }
            if folderSorts[key] == nil && folderSorts.count >= Self.folderLimit { return }
            folderSorts[key] = sort
        }
        saveFolders()
    }

    public func resetSort(for url: URL) {
        guard folderSorts.removeValue(forKey: Self.key(for: url)) != nil else { return }
        saveFolders()
    }

    public func resetAllFolders() {
        guard !folderSorts.isEmpty else { return }
        folderSorts = [:]
        saveFolders()
    }

    /// Folders without their own sort change at once. Folders whose sort now
    /// equals the new default stop being exceptions.
    public func setDefaultSort(_ sort: FolderSort) {
        guard sort != defaultSort else { return }
        defaultSort = sort
        if let data = try? JSONEncoder().encode(sort) { defaults.set(data, forKey: Self.defaultKey) }
        let redundant = folderSorts.filter { $0.value == sort }.map(\.key)
        if !redundant.isEmpty {
            for key in redundant { folderSorts[key] = nil }
            saveFolders()
        }
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(folderSorts) { defaults.set(data, forKey: Self.foldersKey) }
    }
}
