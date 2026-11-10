import AppKit
import CoreServices
import UniformTypeIdentifiers

/// System integration that lets Burrow stand in for Finder where macOS allows it:
/// - LaunchServices default handler for `public.folder` (`open ~/Downloads`, folders
///   opened from Dock stacks, Spotlight, other apps' "Open"),
/// - the global `NSFileViewer` preference used by `NSWorkspace` for "Show in Finder"
///   / "Reveal in Finder" requests sent from other applications.
/// The desktop, Trash icon in the Dock and Finder's own windows remain Finder's.
enum DefaultFileViewer {
    static let fileViewerKey = "NSFileViewer" as CFString
    static let finderBundleID = "com.apple.finder"

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.burrow.macos" }

    /// Current global `NSFileViewer` value (nil means Finder).
    static var configuredFileViewer: String? {
        CFPreferencesCopyValue(fileViewerKey, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    static var isFileViewer: Bool { configuredFileViewer == bundleID }

    static var isFolderHandler: Bool {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: .folder) else { return false }
        return Bundle(url: url)?.bundleIdentifier == bundleID
    }

    /// macOS 27 refuses any change of the folder handler, even back to Finder
    /// (LaunchServices answers paramErr). "Show in Finder" still follows
    /// `NSFileViewer`, so Burrow is as much the default as the system allows.
    static let folderHandlerLockKey = "bf.defaultViewer.folderHandlerLockedOn"

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }

    /// True when this macOS version refused a folder handler change. It is
    /// remembered per version, so an update that lifts the lock is retried.
    @MainActor
    static func isFolderHandlerLocked(defaults: UserDefaults? = nil) -> Bool {
        (defaults ?? AppState.preferences).string(forKey: folderHandlerLockKey) == systemVersion
    }

    static func isLockedFolderHandlerError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSOSStatusErrorDomain, error.code == paramErr { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isLockedFolderHandlerError(underlying) }
        return false
    }

    @MainActor
    static var isDefault: Bool { isFileViewer && (isFolderHandler || isFolderHandlerLocked()) }

    /// Makes Burrow the folder handler and file viewer. macOS may ask the user
    /// to confirm the handler change; the completion reports the final state.
    static func makeDefault(completion: @escaping @MainActor (String?) -> Void) {
        setFileViewer(bundleID)
        setFolderHandler(appURL: Bundle.main.bundleURL, completion: completion)
    }

    @MainActor
    static func restoreFinder(completion: @escaping @MainActor (String?) -> Void) {
        setFileViewer(nil)
        if LaunchServicesHandlers.folderHandler != nil { LaunchServicesHandlers.setFolderHandler(nil) }
        // A locked handler is still Finder: nothing else to restore.
        if isFolderHandlerLocked(), !isFolderHandler {
            Task { @MainActor in completion(nil) }
            return
        }
        guard let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderBundleID) else {
            Task { @MainActor in completion(String(localized: "The Finder application was not found.")) }
            return
        }
        setFolderHandler(appURL: finderURL, completion: completion)
    }

    private static func setFileViewer(_ value: String?) {
        CFPreferencesSetValue(fileViewerKey, value as CFString?, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func setFolderHandler(appURL: URL, completion: @escaping @MainActor (String?) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: .folder) { error in
            Task { @MainActor in
                if let error, isLockedFolderHandlerError(error) {
                    AppState.preferences.set(systemVersion, forKey: folderHandlerLockKey)
                    // The same entry the API would write, added by hand as other file
                    // managers document it. macOS reads it at the next login, if at all.
                    let target = Bundle(url: appURL)?.bundleIdentifier
                    LaunchServicesHandlers.setFolderHandler(target == finderBundleID ? nil : target)
                    completion(nil)
                } else if let error {
                    completion(String(localized: "Could not change the default application for folders: \(error.localizedDescription)"))
                } else {
                    completion(nil)
                }
            }
        }
    }
}

/// Routes folders and files handed over by the system (open documents, reveal requests).
@MainActor
enum ExternalOpenRouter {
    /// Called by the main window once it exists, so requests arriving while no window
    /// is open can bring one back.
    static var openMainWindow: (() -> Void)?

    static func open(_ urls: [URL]) {
        let fileManager = FileManager.default
        var folders: [URL] = []
        var revealed: [URL: [String]] = [:]
        var revealOrder: [URL] = []
        for url in urls where url.isFileURL {
            let standardized = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue && !NSWorkspace.shared.isFilePackage(atPath: standardized.path) {
                if !folders.contains(standardized) { folders.append(standardized) }
            } else {
                let parent = standardized.deletingLastPathComponent()
                if revealed[parent] == nil { revealOrder.append(parent) }
                revealed[parent, default: []].append(standardized.path)
            }
        }
        guard !folders.isEmpty || !revealOrder.isEmpty else { return }
        let appState = AppState.shared
        for folder in folders { appState.openExternalLocation(folder, selecting: []) }
        for parent in revealOrder { appState.openExternalLocation(parent, selecting: revealed[parent] ?? []) }
        bringWindowForward()
    }

    private static func bringWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
}

/// The user's LaunchServices handler list, written directly when the API that
/// normally edits it refuses folders (macOS 27). LaunchServices reads it at login.
enum LaunchServicesHandlers {
    static let domain = "com.apple.LaunchServices/com.apple.launchservices.secure" as CFString
    static let key = "LSHandlers" as CFString
    static let folderType = "public.folder"

    /// Drops every folder entry and, with a bundle id, adds one for it.
    static func updating(_ handlers: [[String: Any]], folderHandler bundleID: String?) -> [[String: Any]] {
        var result = handlers.filter { ($0["LSHandlerContentType"] as? String)?.lowercased() != folderType }
        if let bundleID {
            result.append([
                "LSHandlerContentType": folderType,
                "LSHandlerRoleAll": bundleID,
                "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"],
            ])
        }
        return result
    }

    static func folderHandler(in handlers: [[String: Any]]) -> String? {
        handlers.first { ($0["LSHandlerContentType"] as? String)?.lowercased() == folderType }?["LSHandlerRoleAll"] as? String
    }

    static var handlers: [[String: Any]] {
        CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [[String: Any]] ?? []
    }

    static var folderHandler: String? { folderHandler(in: handlers) }

    static func setFolderHandler(_ bundleID: String?) {
        let updated = updating(handlers, folderHandler: bundleID)
        CFPreferencesSetValue(key, updated as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
