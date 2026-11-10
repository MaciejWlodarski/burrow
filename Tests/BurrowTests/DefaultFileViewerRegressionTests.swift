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
        print("PASS Default file viewer treats the macOS folder handler lock as a limit, not an error")
    }
}
