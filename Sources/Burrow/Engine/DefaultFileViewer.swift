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

    static var isDefault: Bool { isFileViewer && isFolderHandler }

    /// Makes Burrow the folder handler and file viewer. macOS may ask the user
    /// to confirm the handler change; the completion reports the final state.
    static func makeDefault(completion: @escaping @MainActor (String?) -> Void) {
        setFileViewer(bundleID)
        setFolderHandler(appURL: Bundle.main.bundleURL, completion: completion)
    }

    static func restoreFinder(completion: @escaping @MainActor (String?) -> Void) {
        setFileViewer(nil)
        guard let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderBundleID) else {
            Task { @MainActor in completion("Nie znaleziono aplikacji Finder.") }
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
                if let error {
                    completion("Nie zmieniono domyślnej aplikacji dla folderów: \(error.localizedDescription)")
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
