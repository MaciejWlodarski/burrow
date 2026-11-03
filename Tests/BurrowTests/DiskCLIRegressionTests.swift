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
        print("PASS burrow CLI scan/top/junk/size/trash output, filters, protection and exit codes")
    }
}
