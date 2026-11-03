import Foundation
import Darwin

/// Files from iCloud Drive and File Provider apps (Google Drive, OneDrive,
/// Dropbox, Box) can be placeholders whose content lives only in the cloud
/// ("dataless"). Opening one makes macOS download it. Burrow only downloads
/// when the user asks: background reads (indexing, content search, folder
/// sizes, checksums, previews, duplicate hashing) run without materializing.
public enum CloudFiles {
    /// A cloud storage location shown in the sidebar.
    public struct Location: Identifiable, Equatable, Sendable {
        public let url: URL
        public let provider: String
        public let account: String?
        public var id: String { url.path }
        public var title: String { provider }
    }

    // MARK: - Detection

    /// True when the item's content is not on this Mac. Reads only metadata.
    public static func isDataless(path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// iCloud Drive plus every File Provider domain in ~/Library/CloudStorage.
    /// Lists one local folder; never touches the providers' contents.
    public static func locations(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [Location] {
        var result: [Location] = []
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: iCloud.path) {
            result.append(Location(url: iCloud, provider: "iCloud Drive", account: nil))
        }
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: storage.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            let (provider, account) = describe(folderName: name)
            result.append(Location(url: storage.appendingPathComponent(name, isDirectory: true),
                                   provider: provider, account: account))
        }
        return result
    }

    /// "GoogleDrive-me@example.com" → ("Google Drive", "me@example.com").
    static func describe(folderName name: String) -> (String, String?) {
        let known: [(prefix: String, provider: String)] = [
            ("GoogleDrive", "Google Drive"), ("OneDrive", "OneDrive"), ("Dropbox", "Dropbox"),
            ("Box", "Box"), ("pCloudDrive", "pCloud Drive"), ("ProtonDrive", "Proton Drive"),
            ("SynologyDrive", "Synology Drive"), ("Nextcloud", "Nextcloud"), ("MEGA", "MEGA"),
        ]
        let parts = name.split(separator: "-", maxSplits: 1).map(String.init)
        let head = parts.first ?? name
        let account = parts.count > 1 ? parts[1] : nil
        if let match = known.first(where: { $0.prefix.caseInsensitiveCompare(head) == .orderedSame }) {
            // OneDrive uses "OneDrive-Personal" and "OneDrive-<Company>"; Box uses "Box-Box".
            let shown = account.flatMap { $0 == "Personal" || $0 == head ? nil : $0 }
            return (match.provider, shown)
        }
        return (head, account)
    }

    /// The provider's Mac app, whose icon the sidebar shows.
    static func appBundleIdentifier(for provider: String) -> String? {
        [
            "Google Drive": "com.google.drivefs", "OneDrive": "com.microsoft.OneDrive",
            "Dropbox": "com.getdropbox.dropbox", "Box": "com.box.desktop",
            "pCloud Drive": "com.pcloud.pcloud.macos", "Proton Drive": "me.proton.drive",
            "Synology Drive": "com.synology.SynologyDrive", "Nextcloud": "com.nextcloud.desktopclient",
            "MEGA": "mega.mac",
        ][provider]
    }

    /// The cloud location containing a path, following symlinks such as the
    /// "Google Drive" shortcut some apps put in the home folder.
    public static func location(containing path: String, in locations: [Location]) -> Location? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return locations.first { resolved == $0.url.path || resolved.hasPrefix($0.url.path + "/") }
    }

    // MARK: - Reading without downloading

    /// Runs `body` on the current thread with materialization of dataless
    /// files and folders turned off: opening one fails with EDEADLK instead
    /// of downloading it.
    public static func withoutDownloading<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) }
        }
        return try body()
    }

    /// The error a read reports when it refused to download a cloud file.
    public static func isNotDownloadedError(_ code: Int32) -> Bool { code == EDEADLK }

    // MARK: - Explicit actions

    public struct ActionResult: Sendable {
        public var started: Int = 0
        public var failures: [String] = []
    }

    /// Asks the provider to download items (folders download their contents).
    public static func download(_ urls: [URL]) -> ActionResult {
        var result = ActionResult()
        for url in urls {
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                result.started += 1
            } catch {
                result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Frees local space; the items stay in the cloud. Items with changes that
    /// have not been uploaded yet are refused by the provider.
    public static func removeDownload(_ urls: [URL]) -> ActionResult {
        var result = ActionResult()
        for url in urls {
            do {
                try FileManager.default.evictUbiquitousItem(at: url)
                result.started += 1
            } catch {
                result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }
}
