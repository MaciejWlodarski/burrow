import Foundation
import Darwin

/// Folders macOS guards with a privacy prompt and cloud storage. Automatic
/// folder sizes never enter them, so browsing the home folder does not open a
/// series of permission prompts. A protected folder is sized once the user
/// asks for it or opens it; that choice is remembered.
public struct FolderSizePrivacy: Sendable {
    /// Each needs consent unless the app has Full Disk Access.
    public let protectedRoots: [String]
    /// Protected roots whose listing is itself the prompt (Desktop, Documents,
    /// Downloads): opening one in a pane proves access, so it counts as consent.
    /// Listing ~/Library or /Volumes does not, because only folders inside them prompt.
    public let rootsGrantedByListing: Set<String>
    /// Media libraries (Photos, Music, TV) prompt wherever they are and whatever
    /// they are called, so they are recognised by extension.
    public let protectedBundleExtensions: Set<String>
    /// Always skipped when sizing a folder that contains them: their sizes are
    /// cloud sizes and a File Provider may ask for consent even with Full Disk Access.
    public let cloudRoots: [String]
    public let hasFullDiskAccess: @Sendable () -> Bool
    public let consent: FolderSizeConsent

    public init(protectedRoots: [String], rootsGrantedByListing: [String] = [],
                protectedBundleExtensions: Set<String> = [], cloudRoots: [String],
                hasFullDiskAccess: @escaping @Sendable () -> Bool,
                consent: FolderSizeConsent = FolderSizeConsent()) {
        self.protectedRoots = protectedRoots.map(FolderSizeCache.normalizedKey)
        self.rootsGrantedByListing = Set(rootsGrantedByListing.map(FolderSizeCache.normalizedKey))
        self.protectedBundleExtensions = Set(protectedBundleExtensions.map { $0.lowercased() })
        self.cloudRoots = cloudRoots.map(FolderSizeCache.normalizedKey)
        self.hasFullDiskAccess = hasFullDiskAccess
        self.consent = consent
    }

    public static let none = FolderSizePrivacy(protectedRoots: [], cloudRoots: [], hasFullDiskAccess: { true })

    public static func system(home: String = NSHomeDirectory()) -> FolderSizePrivacy {
        let listed = ["Desktop", "Documents", "Downloads"].map { "\(home)/\($0)" }
        return FolderSizePrivacy(
            protectedRoots: listed + ["\(home)/Library", "/Volumes"],
            rootsGrantedByListing: listed,
            protectedBundleExtensions: ["photoslibrary", "photolibrary", "aplibrary", "musiclibrary", "tvlibrary"],
            cloudRoots: ["\(home)/Library/CloudStorage", "\(home)/Library/Mobile Documents"],
            hasFullDiskAccess: FullDiskAccess.isGranted,
            consent: FolderSizeConsent(defaults: persistentDefaults))
    }

    /// A test executable never writes the user's real preferences.
    private static var persistentDefaults: UserDefaults? {
        #if BURROW_TESTING
        return nil
        #else
        return .standard
        #endif
    }

    private func isProtectedBundle(_ key: String) -> Bool {
        let name = (key as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && protectedBundleExtensions.contains(ext)
    }

    /// True for a protected folder the user has not allowed yet: sizing it
    /// would show a prompt. Folders inside one were already opened by the user.
    public func requiresConsent(_ path: String) -> Bool {
        let key = FolderSizeCache.normalizedKey(path)
        guard protectedRoots.contains(key) || isProtectedBundle(key) else { return false }
        return !hasFullDiskAccess() && !consent.contains(key)
    }

    /// The protected root a successful listing of `path` grants, if any.
    public func rootGranted(byListing path: String) -> String? {
        let key = FolderSizeCache.normalizedKey(path)
        return rootsGrantedByListing.first { key == $0 || key.hasPrefix($0 + "/") }
    }

    /// Folders skipped while sizing `path`: protected roots not yet allowed and
    /// all cloud roots, except `path` itself and its ancestors. The crawler
    /// matches them by file identity too, because firmlinks such as
    /// /System/Volumes/Data reach the same folders under other paths.
    public func skippedRoots(whileSizing path: String) -> Set<String> {
        let key = FolderSizeCache.normalizedKey(path)
        let protected = hasFullDiskAccess() ? [] : protectedRoots.filter { !consent.contains($0) }
        return Set((protected + cloudRoots).filter { root in root != key && !key.hasPrefix(root + "/") })
    }

    /// Media library bundles skipped while sizing a folder that contains them.
    public func skipsBundle(at path: String) -> Bool {
        isProtectedBundle(path) && !hasFullDiskAccess() && !consent.contains(FolderSizeCache.normalizedKey(path))
    }

    /// A protected root or media library, whether or not it is allowed.
    public func isProtected(_ path: String) -> Bool {
        let key = FolderSizeCache.normalizedKey(path)
        return protectedRoots.contains(key) || isProtectedBundle(key)
    }

    public func isCloudRoot(_ path: String) -> Bool { cloudRoots.contains(FolderSizeCache.normalizedKey(path)) }
}

/// Protected folders the user allowed Burrow to size. macOS remembers its own
/// answer, so asking again after a relaunch would only add clicks.
public final class FolderSizeConsent: @unchecked Sendable {
    private static let defaultsKey = "bf.folderSizes.allowedProtectedFolders"
    private let lock = NSLock()
    private let defaults: UserDefaults?
    private var paths: Set<String>

    /// Without `defaults` the choices live only in memory (tests).
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        paths = Set(defaults?.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    public func contains(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return paths.contains(path)
    }

    /// Returns false when the path was already allowed.
    @discardableResult
    public func insert(_ path: String) -> Bool {
        lock.lock()
        let inserted = paths.insert(path).inserted
        let snapshot = paths
        lock.unlock()
        if inserted { defaults?.set(snapshot.sorted(), forKey: Self.defaultsKey) }
        return inserted
    }
}

/// Reads the user's privacy database only to learn whether it can be opened,
/// which macOS allows only with Full Disk Access. It never shows a prompt.
enum FullDiskAccess {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (value: Bool, at: Date)?

    @Sendable static func isGranted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let cached, Date().timeIntervalSince(cached.at) < 10 { return cached.value }
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 { close(fd) }
        let value = fd >= 0
        cached = (value, Date())
        return value
    }

    /// Forget the cached answer, e.g. when the user returns from System Settings.
    static func refresh() {
        lock.lock(); cached = nil; lock.unlock()
    }
}
