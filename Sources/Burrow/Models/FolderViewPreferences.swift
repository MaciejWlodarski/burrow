import Foundation
import Combine

/// View modes like Finder's per-folder views: one default for every folder,
/// and folders whose view was changed keep their own until reset. Only list,
/// icons and columns are remembered; the disk map is an analysis, not a view.
@MainActor
public final class FolderViewPreferences: ObservableObject {
    public static let shared = FolderViewPreferences(defaults: AppState.preferences)
    public static let rememberedModes: [FinderViewMode] = [.list, .icons, .columns]

    @Published public private(set) var defaultMode: FinderViewMode
    /// Standardized folder path to its own view mode.
    @Published public private(set) var folderModes: [String: FinderViewMode]

    private let defaults: UserDefaults
    private static let defaultKey = "folderView.default"
    private static let foldersKey = "folderView.folders"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaultMode = defaults.string(forKey: Self.defaultKey).flatMap(Self.remembered) ?? .list
        folderModes = (defaults.dictionary(forKey: Self.foldersKey) as? [String: String] ?? [:])
            .compactMapValues(Self.remembered)
    }

    private static func remembered(_ raw: String) -> FinderViewMode? {
        FinderViewMode(rawValue: raw).flatMap { rememberedModes.contains($0) ? $0 : nil }
    }

    public func mode(for url: URL) -> FinderViewMode { folderModes[FolderSortPreferences.key(for: url)] ?? defaultMode }

    public func hasCustomMode(for url: URL) -> Bool { folderModes[FolderSortPreferences.key(for: url)] != nil }

    public func setMode(_ mode: FinderViewMode, for url: URL) {
        guard Self.rememberedModes.contains(mode) else { return }
        let key = FolderSortPreferences.key(for: url)
        if mode == defaultMode {
            guard folderModes.removeValue(forKey: key) != nil else { return }
        } else {
            guard folderModes[key] != mode else { return }
            if folderModes[key] == nil && folderModes.count >= FolderSortPreferences.folderLimit { return }
            folderModes[key] = mode
        }
        saveFolders()
    }

    public func resetMode(for url: URL) {
        guard folderModes.removeValue(forKey: FolderSortPreferences.key(for: url)) != nil else { return }
        saveFolders()
    }

    public func resetAllFolders() {
        guard !folderModes.isEmpty else { return }
        folderModes = [:]
        saveFolders()
    }

    /// Folders without their own view follow at once; folders whose view
    /// equals the new default stop being exceptions.
    public func setDefaultMode(_ mode: FinderViewMode) {
        guard Self.rememberedModes.contains(mode), mode != defaultMode else { return }
        defaultMode = mode
        defaults.set(mode.rawValue, forKey: Self.defaultKey)
        let redundant = folderModes.filter { $0.value == mode }.map(\.key)
        if !redundant.isEmpty {
            for key in redundant { folderModes[key] = nil }
            saveFolders()
        }
    }

    private func saveFolders() {
        defaults.set(folderModes.mapValues(\.rawValue), forKey: Self.foldersKey)
    }
}
