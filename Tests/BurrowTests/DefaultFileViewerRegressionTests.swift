import Foundation

@MainActor
struct DefaultFileViewerRegressionTests {
    static func runAll() throws {
        // macOS 27 answers paramErr for any folder handler change, wrapped by NSWorkspace.
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: Int(paramErr))])
        try expect(DefaultFileViewer.isLockedFolderHandlerError(wrapped))
        try expect(!DefaultFileViewer.isLockedFolderHandlerError(NSError(domain: NSOSStatusErrorDomain, code: -10814)))
        try expect(!DefaultFileViewer.isLockedFolderHandlerError(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))

        // The lock is remembered for this macOS version only, so an update that lifts it is retried.
        let suite = "com.burrow.tests.default-viewer.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw RegressionFailure(description: "default viewer defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        try expect(!DefaultFileViewer.isFolderHandlerLocked(defaults: defaults))
        defaults.set(DefaultFileViewer.systemVersion, forKey: DefaultFileViewer.folderHandlerLockKey)
        try expect(DefaultFileViewer.isFolderHandlerLocked(defaults: defaults))
        defaults.set("15.0", forKey: DefaultFileViewer.folderHandlerLockKey)
        try expect(!DefaultFileViewer.isFolderHandlerLocked(defaults: defaults))

        // The hand-written handler list keeps other entries and holds one folder entry at most.
        let other: [String: Any] = ["LSHandlerContentType": "public.plain-text", "LSHandlerRoleAll": "com.apple.textedit"]
        let old: [String: Any] = ["LSHandlerContentType": "Public.Folder", "LSHandlerRoleAll": "com.example.oldviewer"]
        let set = LaunchServicesHandlers.updating([other, old], folderHandler: "com.burrow.macos")
        try expect(set.count == 2)
        try expect(LaunchServicesHandlers.folderHandler(in: set) == "com.burrow.macos")
        try expect((set.first?["LSHandlerRoleAll"] as? String) == "com.apple.textedit")
        let cleared = LaunchServicesHandlers.updating(set, folderHandler: nil)
        try expect(cleared.count == 1 && LaunchServicesHandlers.folderHandler(in: cleared) == nil)

        // Finder's window list: Recents and other non-folders have no target.
        let windows = FinderRedirectRules.parse(["12\tfile:///Users/a/Downloads/", "13\t", "x\tfile:///", "14\tfile:///Users/a/My%20Folder/"])
        try expect(windows.map(\.id) == [12, 13, 14])
        try expect(windows[0].target?.path == "/Users/a/Downloads")
        try expect(windows[1].target == nil)
        try expect(windows[2].target?.path == "/Users/a/My Folder")
        // Only new windows that show a folder move; Option or Burrow's own "Open in Finder" keep them.
        let moving = FinderRedirectRules.windowsToRedirect(windows, known: [12], optionDown: false, suppressed: false)
        try expect(moving.map(\.id) == [14])
        try expect(FinderRedirectRules.windowsToRedirect(windows, known: [], optionDown: true, suppressed: false).isEmpty)
        try expect(FinderRedirectRules.windowsToRedirect(windows, known: [], optionDown: false, suppressed: true).isEmpty)
        print("PASS Default file viewer treats the macOS folder handler lock as a limit, not an error")
    }
}
