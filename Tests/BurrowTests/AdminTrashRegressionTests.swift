import Foundation

struct AdminTrashRegressionTests {
    static func runAll() throws {
        // Only a refused permission is worth an administrator password.
        try expect(AdminTrash.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        try expect(AdminTrash.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        try expect(AdminTrash.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])))
        try expect(!AdminTrash.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
        try expect(!AdminTrash.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))

        // A free name in the Trash, never one already there; other volumes have their own Trash.
        let trash = URL(fileURLWithPath: "/Users/someone/.Trash")
        let taken: Set<String> = ["/Users/someone/.Trash/Tool.app", "/Users/someone/.Trash/Tool 2.app", "/Users/someone/.Trash/notes"]
        func destination(_ path: String, same: Bool = true) -> String? {
            AdminTrash.destination(for: URL(fileURLWithPath: path), trash: trash,
                exists: { taken.contains($0.path) }, sameVolume: { _, _ in same })?.path
        }
        try expect(destination("/Applications/Other.app") == "/Users/someone/.Trash/Other.app")
        try expect(destination("/Applications/Tool.app") == "/Users/someone/.Trash/Tool 3.app")
        try expect(destination("/Library/notes") == "/Users/someone/.Trash/notes 2")
        try expect(destination("/Volumes/USB/Tool.app", same: false) == nil)
        try expect(destination("/Applications/Bad\nName.app") == nil)

        // Names with quotes, spaces and $ survive the shell and AppleScript quoting.
        try expect(AdminTrash.shellQuoted("it's $HOME") == "'it'\\''s $HOME'")
        try expect(AdminTrash.appleScriptQuoted("say \"hi\" \\ ok") == "\"say \\\"hi\\\" \\\\ ok\"")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-admin-trash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeTrash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let odd = root.appendingPathComponent("It's \"odd\" $USER `x`.app")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let kept = fakeTrash.appendingPathComponent("kept")
        try Data("old".utf8).write(to: kept)
        let other = root.appendingPathComponent("kept")
        try Data("new".utf8).write(to: other)
        let command = AdminTrash.shellCommand([
            (odd, fakeTrash.appendingPathComponent(odd.lastPathComponent)),
            (other, kept), // mv -n never replaces what is already in the Trash
        ])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        process.waitUntilExit()
        try expect(FileManager.default.fileExists(atPath: fakeTrash.appendingPathComponent(odd.lastPathComponent).path))
        try expect(!FileManager.default.fileExists(atPath: odd.path))
        let keptData = try Data(contentsOf: kept)
        try expect(String(decoding: keptData, as: UTF8.self) == "old")
        try expect(FileManager.default.fileExists(atPath: other.path))
        let script = AdminTrash.appleScriptSource(command: "true", prompt: "p")
        try expect(script == "do shell script \"true\" with prompt \"p\" with administrator privileges")
        try expect(NSAppleScript(source: script)?.compileAndReturnError(nil) == true)
        print("PASS Trash with an administrator password picks free names and quotes paths safely")
    }
}
