import Foundation
import Darwin

/// Folders macOS guards with a privacy prompt (Desktop, Documents, Downloads,
/// media libraries, other apps' data, removable and network volumes) and cloud
/// storage. Automatic folder sizes never enter them, so browsing the home
/// folder does not open a series of permission prompts. A size of such a
/// folder is calculated when the user asks for it.
public struct FolderSizePrivacy: Sendable {
    /// Each needs consent unless the app has Full Disk Access.
    public let protectedRoots: [String]
    /// Always skipped when sizing a folder that contains them: their sizes are
    /// cloud sizes and a File Provider may ask for consent even with Full Disk Access.
    public let cloudRoots: [String]
    public let hasFullDiskAccess: @Sendable () -> Bool

    public init(protectedRoots: [String], cloudRoots: [String], hasFullDiskAccess: @escaping @Sendable () -> Bool) {
        self.protectedRoots = protectedRoots.map(FolderSizeCache.normalizedKey)
        self.cloudRoots = cloudRoots.map(FolderSizeCache.normalizedKey)
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    public static let none = FolderSizePrivacy(protectedRoots: [], cloudRoots: [], hasFullDiskAccess: { true })

    public static func system(home: String = NSHomeDirectory()) -> FolderSizePrivacy {
        FolderSizePrivacy(
            protectedRoots:
            // Pictures and Movies hold the Photos and TV libraries, which can
            // have any name, so the whole folders wait for a request.
            ["Desktop", "Documents", "Downloads", "Music", "Pictures", "Movies", "Library"]
                .map { "\(home)/\($0)" } + ["/Volumes"],
            cloudRoots: ["\(home)/Library/CloudStorage", "\(home)/Library/Mobile Documents"],
            hasFullDiskAccess: FullDiskAccess.isGranted)
    }

    private func activeProtectedRoots() -> [String] { hasFullDiskAccess() ? [] : protectedRoots }

    /// True for a protected folder itself: sizing it would show a prompt.
    /// Folders inside one were already opened by the user, so they are not gated.
    public func requiresConsent(_ path: String) -> Bool {
        let key = FolderSizeCache.normalizedKey(path)
        return activeProtectedRoots().contains(key)
    }

    /// Protected and cloud folders skipped while sizing `path`: all of them
    /// except `path` itself and its ancestors. The crawler matches them by file
    /// identity too, because firmlinks such as /System/Volumes/Data reach the
    /// same folders under other paths.
    public func skippedRoots(whileSizing path: String) -> Set<String> {
        let key = FolderSizeCache.normalizedKey(path)
        return Set((activeProtectedRoots() + cloudRoots).filter { root in
            root != key && !(key.hasPrefix(root + "/"))
        })
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
}
