import Foundation
import Darwin

struct TerminalPresentationRegressionTests {
    private func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw RegressionFailure(description: message) }
    }

    func testDirectoryClassification() throws {
        let base = URL(fileURLWithPath: "/fixture/root", isDirectory: true)
        let accepted: [(String, String)] = [
            ("cd", "/fixture/home"), (" cd\t ", "/fixture/home"), ("cd --", "/fixture/home"),
            ("cd ..", "/fixture"), ("cd child", "/fixture/root/child"),
            ("cd\t--\tchild", "/fixture/root/child"), ("cd /tmp", "/tmp"),
            ("cd ~/Folder", "/fixture/home/Folder"), ("cd ~", "/fixture/home"),
            ("cd 'Folder With Spaces'", "/fixture/root/Folder With Spaces"),
            (#"cd Folder\ With\ Spaces"#, "/fixture/root/Folder With Spaces"),
            (#"cd "Folder With Spaces""#, "/fixture/root/Folder With Spaces"),
            (#"cd 'cash$;literal'"#, "/fixture/root/cash$;literal"),
            (#"cd "cash\$;literal""#, "/fixture/root/cash$;literal"),
            (#"cd "back\q""#, #"/fixture/root/back\q"#),
            (#"cd "back\\q""#, #"/fixture/root/back\q"#),
            (#"cd 'it'\''s'"#, "/fixture/root/it's"),
            (#"cd '~'"#, "/fixture/root/~"), (#"cd \~"#, "/fixture/root/~"),
            ("cd -- -folder", "/fixture/root/-folder")
        ]
        for (command, path) in accepted {
            try expect(TerminalDirectoryCommand.target(for: command, directory: base, home: "/fixture/home")?.path == path,
                       "Incorrect standalone cd target for \(command)")
        }
        let rejected = [
            "cd child && pwd", "cd child; pwd", "cd child | cat", "cd child &", "cd child > out",
            "cd child\npwd", "cd child\n", "cd 'line\nbreak'", "cd $(pwd)", "cd `pwd`", "cd $HOME",
            #"cd "$HOME""#, "cd ~someone", "cd ~+", "cd ~-", "cd a*", "cd a?", "cd [ab]", "cd {a,b}",
            "cd child # comment", "cd -", "cd -- -", "cd +1", "cd -P child", "cd old new", "cd ''",
            "cd 'unclosed", "cd \"unclosed", "cd child\\", "cd child\\\n", "cd child\0tail", "pwd", "cdx child"
        ]
        for command in rejected {
            try expect(TerminalDirectoryCommand.target(for: command, directory: base) == nil,
                       "Shell syntax must pass through unchanged: \(command)")
        }
        try expect(TerminalDirectoryCommand.target(for: "cd " + String(repeating: "a", count: 20_000), directory: base) == nil,
                   "Oversized classifier input must pass to shell")
    }

    private func checkBounds(_ buffer: TerminalTranscript) throws {
        try expect(buffer.lines.count <= buffer.rowLimit, "Transcript row budget exceeded")
        try expect(buffer.retainedUTF8Bytes == buffer.lines.reduce(0) { $0 + $1.text.utf8.count }, "Byte accounting mismatch")
        try expect(buffer.retainedUTF8Bytes <= buffer.byteLimit, "Transcript byte budget exceeded")
        try expect(buffer.lines.allSatisfy { $0.text.utf8.count <= buffer.entryByteLimit }, "Entry budget exceeded")
        if buffer.hasEvicted {
            try expect(buffer.lines.first?.text == TerminalTranscript.evictionMarker, "Missing eviction marker")
        }
    }

    func testTranscriptBounds() throws {
        var buffer = TerminalTranscript()
        // Reuse one MiB, never allocate a GiB. Every completion is production code.
        let huge = String(repeating: "x", count: 1_048_576)
        for _ in 0..<40 {
            buffer.append(parts: ["[fixture] % ", "synthetic-output"], isCommand: true)
            buffer.appendOutput(huge)
            try checkBounds(buffer)
        }
        try expect(buffer.hasEvicted, "Repeated output must evict old entries")
        try expect(buffer.lines.contains { $0.text.contains(TerminalTranscript.truncationMarker) }, "Missing entry truncation marker")
        try expect(buffer.lines.last?.text == TerminalTranscript.appendMarker, "Missing per-append omission marker")
        var repeated = TerminalTranscript(byteLimit: 4_096, rowLimit: 32, entryByteLimit: 1_024)
        for _ in 0..<1_000 {
            repeated.appendOutput(huge)
            try checkBounds(repeated)
        }
        try expect(repeated.hasEvicted, "Simulated huge completions must stay bounded")
        buffer.removeAll()
        try expect(buffer.lines.isEmpty && buffer.retainedUTF8Bytes == 0 && !buffer.hasEvicted, "Clear must reset accounting")

        // Small budgets also exercise marker reservation and two-row edge case.
        for rows in [2, 3, 17] {
            var tiny = TerminalTranscript(byteLimit: 512, rowLimit: rows, entryByteLimit: 128)
            let invalid = String(decoding: [UInt8](repeating: 0xff, count: 1_024), as: UTF8.self)
            for text in [String(repeating: "🧪ż", count: 1_024), invalid, String(repeating: "\n", count: 10_000)] {
                tiny.appendOutput(text)
                try checkBounds(tiny)
            }
            for index in 0..<100 {
                tiny.append(text: "message \(index)", isError: true)
                try checkBounds(tiny)
            }
            tiny.append(text: "[Polecenie przerwane]", isError: true)
            try expect(tiny.lines.last?.isError == true, "Notice provenance must survive")
            try checkBounds(tiny)
        }
        var command = TerminalTranscript()
        command.append(parts: ["prompt ", huge], isCommand: true)
        try expect(command.lines.last?.isCommand == true, "Prompt provenance must survive")
        try checkBounds(command)
    }

    /// Fixture-only evidence: bounded UTF-8 prefixes, escaped by String(reflecting:),
    /// retain whitespace/backslashes without dumping arbitrary session output.
    private func fixtureDiagnostic(_ label: String, _ value: String) -> String {
        let bytes = Array(value.utf8.prefix(2_049))
        let prefix = String(decoding: bytes.prefix(2_048), as: UTF8.self)
        let hex = bytes.prefix(256).map { String(format: "%02x", $0) }.joined(separator: " ")
        return "\(label)=\(String(reflecting: prefix))\(bytes.count > 2_048 ? " [diagnostic truncated]" : ""); utf8=[\(hex)\(bytes.count > 256 ? " …" : "")]"
    }

    /// pwd -P uses the physical POSIX namespace. On macOS Foundation may
    /// retain /var where realpath/pwd use /private/var. Do not normalize shell
    /// output or strip arbitrary prefixes: require the exact physical path + LF.
    private func physicalDirectoryOutput(_ directory: URL) throws -> String {
        guard let physical = directory.path.withCString({ Darwin.realpath($0, nil) }) else {
            throw RegressionFailure(description: "Fixture realpath failed: errno=\(errno)")
        }
        defer { free(physical) }
        return String(cString: physical) + "\n"
    }

    func testNativeZshFixtures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bf-terminal-presentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let examples: [(String, String)] = [
            ("Folder With Spaces", "cd 'Folder With Spaces'"),
            ("Folder With Spaces", #"cd Folder\ With\ Spaces"#),
            ("Zażółć", "cd\t--\tZażółć"),
            ("cash$;literal", #"cd 'cash$;literal'"#),
            ("cash$;literal", #"cd "cash\$;literal""#),
            (#"back\q"#, #"cd "back\q""#),
            ("it's", #"cd 'it'\''s'"#),
            ("-folder", "cd -- -folder")
        ]
        for (caseIndex, example) in examples.enumerated() {
            let (name, command) = example
            let target = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let classified = TerminalDirectoryCommand.target(for: command, directory: root)
            try expect(classified?.path == target.path, "Fixture classification mismatch")
            let session = TerminalCommandSession()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { session.cancel() }
            let result = try session.run(command: command + " && /bin/pwd -P", directory: root)
            try expect(!result.wasCancelled && result.status == 0, "zsh fixture failed")
            let expectedOutput = try physicalDirectoryOutput(target)
            // Same basename, different existing directory: a name-only or overly
            // broad namespace comparison must not accept the wrong destination.
            let sibling = root.appendingPathComponent("wrong-parent", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            let siblingOutput = try physicalDirectoryOutput(sibling)
            try expect(expectedOutput != siblingOutput, "Physical oracle must distinguish same-name sibling directories")
            let evidence = [
                "case=\(caseIndex)", fixtureDiagnostic("command", command),
                fixtureDiagnostic("target", target.path),
                fixtureDiagnostic("resolvedTarget", target.resolvingSymlinksInPath().path),
                fixtureDiagnostic("expectedPhysicalOutput", expectedOutput),
                fixtureDiagnostic("rawOutput", result.output),
                "status=\(result.status) cancelled=\(result.wasCancelled) truncated=\(result.wasTruncated)"
            ].joined(separator: "; ")
            try expect(result.output == expectedOutput, "zsh and classifier disagree; " + evidence)
            try expect(result.output != siblingOutput, "Physical oracle accepted a same-name sibling; " + evidence)
        }
        for command in ["cd 'Folder With Spaces' && printf compound", "cd 'Folder With Spaces'; printf compound", "cd 'Folder With Spaces'\nprintf compound"] {
            try expect(TerminalDirectoryCommand.target(for: command, directory: root) == nil, "Compound must reach zsh")
            let session = TerminalCommandSession()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { session.cancel() }
            let result = try session.run(command: command, directory: root)
            try expect(result.status == 0 && result.output == "compound", "Compound command was swallowed")
        }
        let bad = TerminalCommandSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { bad.cancel() }
        let invalid = try bad.run(command: "cd 'unclosed", directory: root)
        try expect(invalid.status != 0, "Unmatched quote must produce shell error")
        let fresh = TerminalCommandSession()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { fresh.cancel() }
        let cwd = try fresh.run(command: "/bin/pwd -P", directory: root)
        let expectedRootOutput = try physicalDirectoryOutput(root)
        try expect(cwd.status == 0 && !cwd.wasCancelled, "Fresh-run pwd failed")
        try expect(cwd.output == expectedRootOutput,
                   "Compound cwd must not leak between runs; " + fixtureDiagnostic("expectedPhysicalOutput", expectedRootOutput)
                   + "; " + fixtureDiagnostic("rawOutput", cwd.output))
    }

    func runAll() throws {
        try testDirectoryClassification()
        try testTranscriptBounds()
        try testNativeZshFixtures()
        print("PASS 3 terminal classification, transcript-budget and native-zsh regression groups")
    }
}
