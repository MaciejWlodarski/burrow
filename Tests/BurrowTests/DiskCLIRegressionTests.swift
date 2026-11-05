import Foundation

/// Runs the `burrow` command-line tool in-process against a fixture folder.
struct DiskCLIRegressionTests {
    private final class Output {
        var stdout = ""
        var stderr = ""
    }

    private func cli(home: String, output: Output, trashed: @escaping (URL) throws -> URL? = { _ in nil }) -> DiskCLI {
        var cli = DiskCLI()
        cli.write = { output.stdout += $0 }
        cli.warn = { output.stderr += $0 }
        cli.trash = trashed
        cli.homePath = home
        cli.currentDirectory = home
        cli.showsProgress = false
        return cli
    }

    private func json(_ text: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw RegressionFailure(description: "CLI output is not a JSON object: \(text.prefix(200))")
        }
        return object
    }

    /// `expect` for conditions that themselves throw, which an autoclosure cannot.
    private func holds(_ condition: Bool, line: UInt = #line) throws {
        try expect(condition, line: line)
    }

    private func write(_ size: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: size).write(to: url)
    }

    func runAll() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"] ?? NSTemporaryDirectory())
            .appendingPathComponent("burrow-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try write(2_000_000, to: home.appendingPathComponent("web/node_modules/pkg/index.js"))
        try write(1_000, to: home.appendingPathComponent("web/package.json"))
        try write(1_500_000, to: home.appendingPathComponent("swift/.build/debug/app"))
        try write(1_000, to: home.appendingPathComponent("swift/Package.swift"))
        // A `target` folder without Cargo.toml is user data, not a Rust build.
        try write(1_200_000, to: home.appendingPathComponent("photos/target/shot.raw"))
        try write(900_000, to: home.appendingPathComponent("Library/Caches/com.example.app/blob"))
        try write(3_000_000, to: home.appendingPathComponent("media/movie.mov"))
        try write(500_000, to: home.appendingPathComponent("media/deep/a/b/notes.txt"))
        let homePath = home.standardizedFileURL.path

        // scan: JSON tree with rolled-up sizes and depth/top limits.
        var output = Output()
        try expect(cli(home: homePath, output: output).run(["scan", "~", "--json", "--depth", "1", "--top", "2"]) == 0)
        var document = try json(output.stdout)
        let tree = document["tree"] as? [String: Any] ?? [:]
        let children = tree["children"] as? [[String: Any]] ?? []
        try expect(document["root"] as? String == homePath)
        try expect((tree["size"] as? Int64 ?? 0) >= 9_000_000)
        try expect(children.count == 2)
        try expect(children.first?["path"] as? String == homePath + "/media")
        try expect(children.first?["children"] == nil)
        try expect(tree["omittedChildren"] as? Int == 3)

        // scan text with files, types and junk in one pass.
        output = Output()
        try expect(cli(home: homePath, output: output).run(["scan", homePath, "--files", "1", "--types", "--junk"]) == 0)
        try expect(output.stdout.contains("Largest files:"))
        try expect(output.stdout.contains(homePath + "/media/movie.mov"))
        try expect(output.stdout.contains("By type:"))

        // junk: marker rules, expanded cache children and no nested matches.
        output = Output()
        try expect(cli(home: homePath, output: output).run(["junk", "--json", "--min-size", "0"]) == 0)
        document = try json(output.stdout)
        let junk = (document["junk"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        try expect(junk.first == homePath + "/web/node_modules")
        try expect(junk.contains(homePath + "/swift/.build"))
        try expect(junk.contains(homePath + "/Library/Caches/com.example.app"))
        try expect(!junk.contains { $0.contains("/photos/") || $0.hasSuffix("/pkg") })

        // top: filters by extension, size and age.
        output = Output()
        try expect(cli(home: homePath, output: output).run(["top", "--json", "--ext", "mov,.TXT", "--limit", "5", "--min-size", "100K", homePath]) == 0)
        document = try json(output.stdout)
        let largest = (document["largestFiles"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
        try expect(largest == [homePath + "/media/movie.mov", homePath + "/media/deep/a/b/notes.txt"])
        output = Output()
        try expect(cli(home: homePath, output: output).run(["top", homePath, "--older-than", "1", "--json"]) == 0)
        let recent = try json(output.stdout)["largestFiles"] as? [Any]
        try expect(recent?.isEmpty == true)

        // size: files and folders, missing paths fail with status 1.
        output = Output()
        try expect(cli(home: homePath, output: output).run(["size", "media/movie.mov", "web", "missing", "--json"]) == 1)
        let sizes = try json(output.stdout)["items"] as? [[String: Any]] ?? []
        try expect((sizes[0]["size"] as? Int64 ?? 0) >= 3_000_000)
        try expect(sizes[1]["kind"] as? String == "directory")
        try expect(sizes[2]["error"] != nil)

        // trash: dry run leaves the file; protected paths are refused; real
        // moves go through the injected trash so the user's Trash stays clean.
        let movie = homePath + "/media/movie.mov"
        output = Output()
        try expect(cli(home: homePath, output: output).run(["trash", "--dry-run", movie]) == 0)
        try expect(FileManager.default.fileExists(atPath: movie))
        try expect(output.stdout.contains("would trash"))
        output = Output()
        try expect(cli(home: homePath, output: output).run(["trash", "--json", "~", "~/Library", "/", "/System/Library", "/usr/bin/true"]) == 1)
        let refused = try json(output.stdout)["items"] as? [[String: Any]] ?? []
        try expect(refused.count == 5 && refused.allSatisfy { $0["status"] as? String == "refused" })
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        var moved: [String] = []
        output = Output()
        let mover = cli(home: homePath, output: output) { url in
            let destination = bin.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            moved.append(url.path)
            return destination
        }
        try expect(mover.run(["trash", "--json", movie, homePath + "/web/node_modules"]) == 0)
        document = try json(output.stdout)
        try expect(moved == [movie, homePath + "/web/node_modules"])
        try expect(!FileManager.default.fileExists(atPath: movie))
        try expect((document["totalSize"] as? Int64 ?? 0) >= 5_000_000)

        // Usage errors exit 2 without touching stdout.
        for arguments in [["scan", "--depth", "x"], ["frobnicate"], ["scan", "a", "b"], ["trash"], ["top", "--bogus"]] {
            output = Output()
            try expect(cli(home: homePath, output: output).run(arguments) == 2)
            try expect(output.stdout.isEmpty && output.stderr.contains("burrow help"))
        }
        output = Output()
        try expect(cli(home: homePath, output: output).run(["scan", homePath + "/media/movie.mov"]) == 1)
        try expect(DiskCLI.parseSize("1.5G") == 1_500_000_000 && DiskCLI.parseSize("20kb") == 20_000 && DiskCLI.parseSize("x") == nil)

        // Archives round-trip; damaged ones are rejected instead of trusted.
        let scanned = DiskScanner.scan(root: homePath, control: DiskScanControl())!
        let archive = scanned.archived()
        let restored = DiskTree.unarchived(archive)
        try expect(restored?.nodeCount == scanned.nodeCount && restored?.rootPath == homePath)
        try expect(restored?.allocatedSize(DiskTree.rootID) == scanned.allocatedSize(DiskTree.rootID))
        try expect(restored.flatMap { $0.node(forPath: homePath + "/media/deep/a/b/notes.txt") } != nil)
        try expect(abs((restored?.scannedAt.timeIntervalSince(scanned.scannedAt)) ?? 9) < 0.001)
        try expect(DiskTree.unarchived(archive.prefix(archive.count - 1)) == nil && DiskTree.unarchived(Data("BRWT".utf8)) == nil)
        guard let media = scanned.node(forPath: homePath + "/media").flatMap({ scanned.subtree(at: $0) }) else {
            throw RegressionFailure(description: "no subtree for media")
        }
        try expect(media.rootPath == homePath + "/media" && media.node(forPath: homePath + "/media/deep/a/b/notes.txt") != nil)
        try expect(media.allocatedSize(DiskTree.rootID) == scanned.allocatedSize(scanned.node(forPath: homePath + "/media")!))

        // --cache: a saved scan answers later commands for its folder and
        // folders inside it until --fresh, --max-age or a trash changes it.
        let cacheDirectory = root.appendingPathComponent("cache")
        func cached(_ output: Output, trashed: @escaping (URL) throws -> URL? = { _ in nil }) -> DiskCLI {
            var cli = cli(home: homePath, output: output, trashed: trashed)
            cli.cacheDirectory = cacheDirectory
            return cli
        }
        output = Output()
        try expect(cached(output).run(["scan", "~", "--cache", "--json"]) == 0)
        try holds(try json(output.stdout)["cached"] as? Bool == false)
        try write(4_000_000, to: home.appendingPathComponent("media/new.bin"))
        output = Output()
        try expect(cached(output).run(["top", "~/media", "--cache", "--json"]) == 0)
        document = try json(output.stdout)
        try expect(document["cached"] as? Bool == true && document["root"] as? String == homePath + "/media")
        try expect((document["largestFiles"] as? [[String: Any]])?.first?["path"] as? String == homePath + "/media/deep/a/b/notes.txt")
        output = Output()
        try expect(cached(output).run(["scan", "~", "--cache"]) == 0)
        try expect(output.stdout.contains("entries, cached ") && output.stdout.contains("(--fresh rescans)"))
        output = Output()
        try expect(cached(output).run(["top", "~/media", "--cache", "--fresh", "--json"]) == 0)
        document = try json(output.stdout)
        try expect(document["cached"] as? Bool == false)
        try expect((document["largestFiles"] as? [[String: Any]])?.first?["path"] as? String == homePath + "/media/new.bin")
        output = Output()
        try expect(cached(output).run(["junk", "~", "--max-age", "0", "--json"]) == 0)
        try holds(try json(output.stdout)["cached"] as? Bool == false)
        // Without --cache nothing is read or written.
        output = Output()
        try expect(cached(output).run(["top", "~/media", "--json"]) == 0)
        try holds(try json(output.stdout)["cached"] as? Bool == false)

        output = Output()
        let cachedMover = cached(output) { url in
            let destination = bin.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        try expect(cachedMover.run(["trash", "--cache", homePath + "/photos/target"]) == 0)
        output = Output()
        try expect(cached(output).run(["size", "~/photos", "--cache", "--json"]) == 0)
        let photos = (try json(output.stdout)["items"] as? [[String: Any]])?.first
        try expect((photos?["size"] as? Int64 ?? .max) < 1_000_000)
        output = Output()
        try expect(cached(output).run(["scan", "~", "--cache", "--json", "--depth", "3", "--top", "50"]) == 0)
        document = try json(output.stdout)
        try expect(document["cached"] as? Bool == true && !output.stdout.contains("/photos/target"))

        output = Output()
        try expect(cached(output).run(["cache", "--json"]) == 0)
        let saved = try json(output.stdout)["scans"] as? [[String: Any]] ?? []
        try expect(saved.contains { $0["root"] as? String == homePath })
        // A file it cannot read is never listed, loaded or treated as its own.
        try Data("BRWTgarbage".utf8).write(to: cacheDirectory.appendingPathComponent("damaged.tree"))
        output = Output()
        try expect(cached(output).run(["cache", "clear"]) == 0)
        try expect(output.stdout.hasPrefix("Removed "))
        try holds(try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).filter { $0.hasSuffix(".tree") } == ["damaged.tree"])
        try expect(cached(Output()).run(["cache", "bogus"]) == 2)

        // mcp: JSON-RPC over stdio with the scan kept for the session.
        let server = MCPServer(cli: cli(home: homePath, output: Output()), cache: ScanCache(directory: nil, maxAge: 600))
        func reply(_ line: String) throws -> [String: Any] { try json(server.handle(line) ?? "") }
        func call(_ id: Int, _ tool: String, _ arguments: String) throws -> [String: Any] {
            try reply(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#)["result"] as? [String: Any] ?? [:]
        }
        let initialized = try reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        let info = initialized["result"] as? [String: Any] ?? [:]
        try expect(initialized["id"] as? Int == 1 && info["protocolVersion"] as? String == "2025-06-18")
        try expect((info["serverInfo"] as? [String: Any])?["name"] as? String == "burrow" && info["capabilities"] != nil)
        try expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        try holds((try reply(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#))["id"] as? String == "p")
        let listed = (try reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        try expect(listed.compactMap { $0["name"] as? String } == ["scan", "top", "junk", "size", "trash"])
        try expect(listed.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
        var called = try call(3, "scan", #"{"path":"\#(homePath)","files":1,"junk":true}"#)
        try expect(called["isError"] as? Bool == false && (called["structuredContent"] as? [String: Any])?["cached"] as? Bool == false)
        try expect(((called["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("largestFiles") == true)
        called = try call(4, "top", #"{"path":"\#(homePath)/media","limit":1,"extensions":["bin"]}"#)
        var structured = called["structuredContent"] as? [String: Any] ?? [:]
        try expect(structured["cached"] as? Bool == true)
        try expect((structured["largestFiles"] as? [[String: Any]])?.first?["path"] as? String == homePath + "/media/new.bin")
        called = try call(5, "trash", #"{"paths":["\#(homePath)/media/new.bin"]}"#)
        structured = called["structuredContent"] as? [String: Any] ?? [:]
        try expect(structured["dryRun"] as? Bool == true && FileManager.default.fileExists(atPath: homePath + "/media/new.bin"))
        called = try call(6, "top", #"{"path":"\#(homePath)/media/new.bin"}"#)
        try expect(called["isError"] as? Bool == true && ((called["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("is a file") == true)
        try holds((try reply(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"rm"}}"#)["error"] as? [String: Any])?["code"] as? Int == -32602)
        try holds((try reply(#"{"jsonrpc":"2.0","id":8,"method":"resources/list"}"#)["error"] as? [String: Any])?["code"] as? Int == -32601)
        try holds((try reply("not json")["error"] as? [String: Any])?["code"] as? Int == -32700)
        var served: [String] = []
        var lines = [#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#, "", #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#]
        server.serve(input: { lines.isEmpty ? nil : lines.removeFirst() }, output: { served.append($0) })
        try expect(served.count == 1 && served[0].contains("\"id\":9"))
        print("PASS burrow CLI scan/top/junk/size/trash output, filters, protection, exit codes, scan cache and MCP server")
    }
}
