import Foundation

/// `burrow mcp`: the CLI's commands as Model Context Protocol tools, served
/// over stdio as newline-delimited JSON-RPC 2.0. One session keeps its scans
/// in memory, so an agent can scan once and ask follow-up questions quickly.
final class MCPServer {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private var cli: DiskCLI

    init(cli: DiskCLI, cache: ScanCache) {
        var cli = cli
        cli.cache = cache
        cli.showsProgress = false
        self.cli = cli
    }

    /// Reads requests until stdin closes.
    func serve(input: () -> String? = { readLine(strippingNewline: true) },
               output: (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }) {
        while let line = input() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = handle(line) { output(reply) }
        }
    }

    /// One JSON-RPC message in, the reply out; notifications get none.
    func handle(_ line: String) -> String? {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let method = message["method"] as? String else {
            return message["id"] == nil ? nil : error(message["id"]!, -32600, "Invalid request")
        }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return result(id, [
                "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "burrow", "title": "Burrow disk usage", "version": Self.version],
                "instructions": """
                Disk usage of this Mac, sizes in bytes on disk. Scans stay cached for this session, so one `scan` \
                of a folder (or of / for the whole disk) answers later `top`, `junk` and `size` calls inside it \
                without rescanning; pass fresh: true after the disk changed outside these tools. `trash` only \
                reports what it would move unless dry_run is false, and moved items stay recoverable in the Trash.
                """
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name }) else {
                return error(id, -32602, "Unknown tool: \(params["name"] ?? "")")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return result(id, call(name, arguments))
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
    }

    /// Runs the matching CLI command with `--json` and returns its document.
    func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        var command = [name, "--json", "--quiet"]
        func number(_ key: String, _ flag: String) {
            if let value = arguments[key] as? NSNumber { command += [flag, value.stringValue] }
        }
        func size(_ key: String, _ flag: String) {
            if let value = arguments[key] as? String { command += [flag, value] } else { number(key, flag) }
        }
        func flag(_ key: String, _ flag: String) {
            if arguments[key] as? Bool == true { command.append(flag) }
        }
        number("depth", "--depth")
        number("top", "--top")
        number("files", "--files")
        number("limit", "--limit")
        number("older_than_days", "--older-than")
        size("min_size", "--min-size")
        flag("types", "--types")
        flag("junk", "--junk")
        flag("fresh", "--fresh")
        if let extensions = arguments["extensions"] as? [String], !extensions.isEmpty { command += ["--ext", extensions.joined(separator: ",")] }
        // Trashing is opt-in: a call without dry_run: false only reports.
        if name == "trash", arguments["dry_run"] as? Bool != false { command.append("--dry-run") }
        var paths: [String] = []
        if let path = arguments["path"] as? String { paths = [path] }
        if let list = arguments["paths"] as? [String] { paths = list }
        command += ["--"] + paths

        var stdout = "", stderr = ""
        var cli = self.cli
        cli.write = { stdout += $0 }
        cli.warn = { stderr += $0 }
        let status = cli.run(command)
        var text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = stderr.replacingOccurrences(of: "\nRun `burrow help` for usage.", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = message.isEmpty ? "burrow \(name) failed with status \(status)" : message }
        var reply: [String: Any] = ["content": [["type": "text", "text": text]], "isError": status != 0]
        if let document = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any] {
            reply["structuredContent"] = document
        }
        return reply
    }

    private static let fresh: [String: Any] = ["type": "boolean", "description": "Rescan even if this session has a recent scan"]
    private static let minSize: [String: Any] = ["type": ["string", "integer"], "description": "Hide smaller items: bytes, or e.g. \"500M\", \"2G\""]
    private static let readOnly: [String: Any] = ["readOnlyHint": true, "openWorldHint": false]

    static let tools: [[String: Any]] = [
        [
            "name": "scan",
            "title": "Scan disk usage",
            "description": "Size tree of a folder, biggest first, optionally with the largest files, totals per file type and regenerable junk in the same pass. Path / scans the whole startup disk (about 15 s); later calls inside it reuse the scan.",
            "inputSchema": ["type": "object", "properties": [
                "path": ["type": "string", "description": "Folder to scan, absolute or ~/…; default / (whole disk)"],
                "depth": ["type": "integer", "minimum": 0, "description": "Levels below path to include (default 2)"],
                "top": ["type": "integer", "minimum": 0, "description": "Children listed per folder (default 15)"],
                "min_size": minSize,
                "files": ["type": "integer", "minimum": 0, "description": "Also list the N largest files"],
                "types": ["type": "boolean", "description": "Also list totals per file type"],
                "junk": ["type": "boolean", "description": "Also list caches, build outputs and similar regenerable folders"],
                "fresh": fresh
            ] as [String: Any]],
            "annotations": readOnly
        ],
        [
            "name": "top",
            "title": "Largest files",
            "description": "Largest files under a folder, filtered by size, age and extension.",
            "inputSchema": ["type": "object", "properties": [
                "path": ["type": "string", "description": "Folder, absolute or ~/…; default / (whole disk)"],
                "limit": ["type": "integer", "minimum": 0, "description": "How many files (default 50)"],
                "min_size": minSize,
                "older_than_days": ["type": "number", "minimum": 0, "description": "Only files not modified for this many days"],
                "extensions": ["type": "array", "items": ["type": "string"], "description": "Only these extensions, e.g. [\"mov\", \"zip\"]"],
                "fresh": fresh
            ] as [String: Any]],
            "annotations": readOnly
        ],
        [
            "name": "junk",
            "title": "Regenerable clutter",
            "description": "Caches, build outputs, node_modules and similar folders that can be regenerated, each with a risk level and a hint.",
            "inputSchema": ["type": "object", "properties": [
                "path": ["type": "string", "description": "Folder, absolute or ~/…; default your home folder"],
                "min_size": minSize,
                "limit": ["type": "integer", "minimum": 0, "description": "How many items (default 100)"],
                "fresh": fresh
            ] as [String: Any]],
            "annotations": readOnly
        ],
        [
            "name": "size",
            "title": "Size of paths",
            "description": "On-disk size of each file or folder.",
            "inputSchema": ["type": "object", "properties": [
                "paths": ["type": "array", "items": ["type": "string"], "minItems": 1, "description": "Files or folders, absolute or ~/…"],
                "fresh": fresh
            ] as [String: Any], "required": ["paths"]],
            "annotations": readOnly
        ],
        [
            "name": "trash",
            "title": "Move to Trash",
            "description": "Moves items to the Trash, where they stay recoverable. Without dry_run: false it only reports what it would move. Refuses the disk root, system folders, your home and its standard folders. Space is freed when the Trash is emptied.",
            "inputSchema": ["type": "object", "properties": [
                "paths": ["type": "array", "items": ["type": "string"], "minItems": 1, "description": "Files or folders, absolute or ~/…"],
                "dry_run": ["type": "boolean", "default": true, "description": "Only report; pass false to really move the items"]
            ] as [String: Any], "required": ["paths"]],
            "annotations": ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false]
        ]
    ]

    /// The app's version when run from Burrow.app/Contents/Helpers, else "dev".
    static var version: String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    private func result(_ id: Any, _ value: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": value])
    }

    private func error(_ id: Any, _ code: Int, _ message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension DiskCLI {
    func mcpCommand(_ options: Options) throws -> Int32 {
        guard options.positional.isEmpty else { throw Failure.usage("mcp takes no PATH") }
        let cache = self.cache ?? ScanCache(directory: options.cache ? cacheDirectory : nil, maxAge: options.maxAge ?? Self.defaultCacheAge)
        // `--cache` and `--max-age` configure the session, not each tool call.
        var cli = self
        cli.cache = cache
        MCPServer(cli: cli, cache: cache).serve()
        return 0
    }
}
