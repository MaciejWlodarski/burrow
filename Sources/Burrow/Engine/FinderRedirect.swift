import AppKit
import ApplicationServices
import CoreServices

/// One Finder browser window, as Finder reports it over Apple Events.
struct FinderWindowInfo: Equatable {
    let id: Int
    /// The folder the window shows; nil for Recents, AirDrop, Network and other
    /// places that are not a folder.
    let target: URL?
}

/// Pure rules of the Finder window redirect, kept apart for tests.
enum FinderRedirectRules {
    static let enabledKey = "bf.finderRedirect.enabled"

    /// Parses the listing script's lines: window id, a tab, the target's file URL.
    static func parse(_ lines: [String]) -> [FinderWindowInfo] {
        lines.compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, let id = Int(first) else { return nil }
            let text = parts.count > 1 ? String(parts[1]) : ""
            let url = URL(string: text).flatMap { $0.isFileURL ? $0.standardizedFileURL : nil }
            return FinderWindowInfo(id: id, target: url)
        }
    }

    /// New windows that show a folder move to Burrow, unless Option is held or
    /// Burrow itself has just opened Finder on purpose.
    static func windowsToRedirect(_ windows: [FinderWindowInfo], known: Set<Int>,
                                  optionDown: Bool, suppressed: Bool) -> [FinderWindowInfo] {
        guard !optionDown, !suppressed else { return [] }
        return windows.filter { !known.contains($0.id) && $0.target != nil }
    }
}

/// Finder stays the system's choice for the Desktop, the Dock's Finder icon and
/// apps that call Finder directly. When enabled, Burrow notices each new Finder
/// window (Accessibility), asks Finder which folder it shows (Apple Events),
/// closes it and opens that folder itself. Windows open before that stay.
@MainActor
final class FinderWindowRedirector {
    static let shared = FinderWindowRedirector()
    nonisolated static let finderBundleID = "com.apple.finder"

    static var isEnabled: Bool { AppState.preferences.bool(forKey: FinderRedirectRules.enabledKey) }

    static func setEnabled(_ enabled: Bool) {
        AppState.preferences.set(enabled, forKey: FinderRedirectRules.enabledKey)
        if enabled { shared.start() } else { shared.stop() }
    }

    private var observer: AXObserver?
    private var knownWindows = Set<Int>()
    private var suppressedUntil = Date.distantPast
    private var tokens: [NSObjectProtocol] = []
    private var checkTask: Task<Void, Never>?
    private(set) var isRunning = false

    var isWatching: Bool { observer != nil }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.finderBundleID else { return }
            MainActor.assumeIsolated { Self.shared.attach() }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.finderBundleID else { return }
            MainActor.assumeIsolated { Self.shared.detach() }
        })
        // Accessibility may be granted while Burrow runs; try again when it is used.
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if Self.shared.isRunning, Self.shared.observer == nil { Self.shared.attach() }
            }
        })
        attach()
    }

    func stop() {
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
        detach()
        isRunning = false
    }

    /// Called before Burrow opens Finder on purpose ("Open in Finder").
    func suppress(for seconds: TimeInterval = 3) {
        suppressedUntil = Date().addingTimeInterval(seconds)
    }

    private func attach() {
        detach()
        guard AXIsProcessTrusted(),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderBundleID).first else { return }
        let pid = finder.processIdentifier
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, _ in
            MainActor.assumeIsolated { FinderWindowRedirector.shared.windowCreated() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        guard AXObserverAddNotification(created, AXUIElementCreateApplication(pid),
                                        kAXWindowCreatedNotification as CFString, nil) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        // Windows already open (or restored by Finder at login) stay in Finder.
        knownWindows = Set((AppleFinder.listWindows() ?? []).map(\.id))
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        checkTask?.cancel()
        checkTask = nil
    }

    private func windowCreated() {
        // Read the keys now: by the time Finder has set the window up, Option may be released.
        let optionDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
        let suppressed = Date() < suppressedUntil
        checkTask?.cancel()
        checkTask = Task { @MainActor in
            // Finder creates the window before it sets its folder.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self.redirectNewWindows(optionDown: optionDown, suppressed: suppressed)
        }
    }

    private func redirectNewWindows(optionDown: Bool, suppressed: Bool) {
        guard let windows = AppleFinder.listWindows() else { return }
        let moving = FinderRedirectRules.windowsToRedirect(windows, known: knownWindows,
                                                           optionDown: optionDown, suppressed: suppressed)
        knownWindows = Set(windows.map(\.id))
        guard !moving.isEmpty else { return }
        for window in moving { AppleFinder.closeWindow(id: window.id) }
        ExternalOpenRouter.open(moving.compactMap(\.target))
    }
}

/// Talking to Finder itself, for the redirect and for Burrow's own "Open in
/// Finder", which must reach Finder even when Burrow is the file viewer.
@MainActor
enum AppleFinder {
    static var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: FinderWindowRedirector.finderBundleID)
    }

    private static let listingSource = """
        with timeout of 3 seconds
            tell application "Finder"
                set output to {}
                -- A list taken once: looping over "every Finder window" directly
                -- yields references that fail to coerce.
                set windowIDs to id of every Finder window
                repeat with i from 1 to count of windowIDs
                    set windowID to item i of windowIDs
                    set targetURL to ""
                    try
                        set targetURL to URL of (target of (Finder window id windowID))
                    end try
                    set end of output to (windowID as text) & tab & targetURL
                end repeat
                return output
            end tell
        end timeout
        """
    private static let listingScript: NSAppleScript? = NSAppleScript(source: listingSource)

    /// Nil when Finder does not answer or Burrow may not control it.
    static func listWindows() -> [FinderWindowInfo]? {
        var error: NSDictionary?
        guard let result = listingScript?.executeAndReturnError(&error), error == nil else { return nil }
        var lines: [String] = []
        if result.numberOfItems > 0 {
            for index in 1...result.numberOfItems {
                if let line = result.atIndex(index)?.stringValue { lines.append(line) }
            }
        }
        return FinderRedirectRules.parse(lines)
    }

    static func closeWindow(id: Int) {
        // "whose id is" fails on macOS 27; an id that is already gone is ignored.
        let source = "with timeout of 3 seconds\ntell application \"Finder\"\ntry\nclose Finder window id \(id)\nend try\nend tell\nend timeout"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    /// Opens a folder in a Finder window.
    static func open(folder: URL) {
        guard let finder = applicationURL else { return }
        FinderWindowRedirector.shared.suppress()
        NSWorkspace.shared.open([folder], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Shows items selected in Finder. While Burrow is the file viewer the
    /// system route leads back to Burrow, so Finder is asked directly, and
    /// without permission to control it, their folders open instead.
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        FinderWindowRedirector.shared.suppress()
        guard DefaultFileViewer.isFileViewer else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return
        }
        let files = urls.map { "POSIX file \(AdminTrash.appleScriptQuoted($0.path))" }.joined(separator: ", ")
        let source = "with timeout of 5 seconds\ntell application \"Finder\"\nreveal {\(files)}\nactivate\nend tell\nend timeout"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil {
            var seen = Set<URL>()
            for parent in urls.map({ $0.deletingLastPathComponent() }) where seen.insert(parent).inserted {
                open(folder: parent)
            }
        }
    }

    enum Automation: Equatable { case allowed, denied, notAsked, finderNotRunning }

    /// Whether Burrow may send Apple Events to Finder. With `ask`, macOS shows
    /// its consent dialog the first time. Blocks, so run it off the main thread.
    nonisolated static func automationPermission(ask: Bool) -> Automation {
        let target = NSAppleEventDescriptor(bundleIdentifier: FinderWindowRedirector.finderBundleID)
        guard let desc = target.aeDesc else { return .finderNotRunning }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch Int(status) {
        case Int(noErr): return .allowed
        case Int(errAEEventNotPermitted): return .denied
        case Int(procNotFound): return .finderNotRunning
        default: return .notAsked
        }
    }
}
