import Foundation

/// Moves items that belong to another user, usually root (apps installed by a
/// package, App Store apps), to the Trash with an administrator password, as
/// Finder does. The system asks for the password in its own dialog.
enum AdminTrash {
    /// True when the system refused the move for lack of permission, the only
    /// case an administrator password can fix.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EACCES) || error.code == Int(EPERM) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(underlying) }
        return false
    }

    /// A free name in the user's Trash. Nil when the item is on another volume:
    /// the move would turn into a copy, and that volume has its own Trash.
    static func destination(for url: URL, trash: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"),
                            exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                            sameVolume: (URL, URL) -> Bool = AdminTrash.onSameVolume) -> URL? {
        let name = url.lastPathComponent
        // A line break cannot be passed safely through the script.
        guard !name.isEmpty, !url.path.contains(where: { $0.isNewline }), sameVolume(url, trash) else { return nil }
        var candidate = trash.appendingPathComponent(name)
        var number = 2
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while exists(candidate) {
            candidate = trash.appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            number += 1
        }
        return candidate
    }

    static func onSameVolume(_ a: URL, _ b: URL) -> Bool {
        var first = stat(), second = stat()
        guard a.path.withCString({ lstat($0, &first) }) == 0, b.path.withCString({ stat($0, &second) }) == 0 else { return false }
        return first.st_dev == second.st_dev
    }

    /// The shell command for all moves, so one password covers the selection.
    /// `mv -n` never replaces an item already in the Trash.
    static func shellCommand(_ moves: [(source: URL, destination: URL)]) -> String {
        moves.map { "/bin/mv -n -- \(shellQuoted($0.source.path)) \(shellQuoted($0.destination.path))" }
            .joined(separator: "; ")
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptSource(command: String, prompt: String) -> String {
        "do shell script \(appleScriptQuoted(command)) with prompt \(appleScriptQuoted(prompt)) with administrator privileges"
    }

    static func appleScriptQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    enum Outcome: Equatable {
        case moved(Int, failed: Int)
        case cancelled
    }

    /// Runs on the main thread: NSAppleScript is not thread safe, and the
    /// password dialog belongs to the app anyway.
    @MainActor
    static func moveToTrash(_ urls: [URL]) -> Outcome {
        var moves: [(source: URL, destination: URL)] = []
        var reserved = Set<String>()
        for url in urls {
            guard let destination = destination(for: url, exists: {
                reserved.contains($0.path) || (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil
            }) else { continue }
            reserved.insert(destination.path)
            moves.append((url, destination))
        }
        guard !moves.isEmpty else { return .moved(0, failed: urls.count) }
        let prompt = moves.count == 1
            ? String(localized: "Burrow wants to move “\(moves[0].source.lastPathComponent)” to the Trash. It belongs to another user.")
            : String(localized: "Burrow wants to move \(moves.count) items that belong to another user to the Trash.")
        var error: NSDictionary?
        NSAppleScript(source: appleScriptSource(command: shellCommand(moves), prompt: prompt))?.executeAndReturnError(&error)
        if let code = error?[NSAppleScript.errorNumber] as? Int, code == -128 { return .cancelled }
        // Count what actually moved rather than trusting the script's exit status.
        let moved = moves.filter {
            (try? FileManager.default.attributesOfItem(atPath: $0.destination.path)) != nil
                && (try? FileManager.default.attributesOfItem(atPath: $0.source.path)) == nil
        }.count
        return .moved(moved, failed: urls.count - moved)
    }
}
