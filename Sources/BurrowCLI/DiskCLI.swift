import Foundation
import Darwin

/// `burrow`: the disk map's scanner for scripts and AI agents. Every command
/// prints readable text or, with `--json`, one JSON document on stdout. The
/// only change it can make is moving items to the Trash, which is recoverable.
struct DiskCLI {
    typealias NodeID = DiskTree.NodeID

    var write: (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) }
    var warn: (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    var trash: (URL) throws -> URL? = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
    var homePath = NSHomeDirectory()
    var currentDirectory = FileManager.default.currentDirectoryPath
    var showsProgress = isatty(STDERR_FILENO) != 0

    enum Failure: Error {
        case usage(String)
        case failed(String)
    }

    struct Options {
        var positional: [String] = []
        var json = false
        var quiet = false
        var types = false
        var junk = false
        var dryRun = false
        var help = false
        var depth = 2
        var top = 15
        var files = 0
        var limit: Int?
        var minSize: Int64?
        var olderThanDays: Double?
        var extensions: Set<String> = []
    }

    static let usage = """
    burrow: WizTree-style disk usage for the terminal and AI agents.

    USAGE
      burrow <command> [PATH...] [options]

    COMMANDS
      scan [PATH]       Size tree, biggest first (default PATH: / = whole startup disk)
                          --depth N      levels below PATH to show (default 2)
                          --top N        children shown per folder (default 15)
                          --min-size S   hide smaller items, e.g. 500M, 2G
                          --files N      also list the N largest files
                          --types        also list totals per file type
                          --junk         also list regenerable clutter (see junk)
      top [PATH]        Largest files (default PATH: /)
                          --limit N (default 50)  --min-size S
                          --older-than DAYS       --ext mov,zip,dmg
      junk [PATH]       Caches, build outputs, node_modules and similar folders that
                        can be regenerated, with a risk level and a hint for each
                        (default PATH: your home folder)
                          --min-size S (default 10M)  --limit N (default 100)
      size PATH...      On-disk size of each path
      trash PATH...     Move items to the Trash (recoverable). Refuses the disk root,
                        system folders, your home and its standard folders.
                          --dry-run      only report what would be moved
      help              This text

    GLOBAL OPTIONS
      --json            One JSON document on stdout (sizes in bytes)
      --quiet           No progress line on stderr

    NOTES
      Sizes are on-disk (allocated) bytes. Hard links count once, other disks and
      iCloud-only files are skipped. Every command scans fresh: a whole disk takes
      about 15 s, a single folder much less, so prefer one `scan` with --files,
      --types and --junk over several commands. Without Full Disk Access for the
      app that runs burrow, some folders are unreadable; their space is reported
      as "unscanned". Trashed items free space only after the Trash is emptied.

    EXIT STATUS
      0 success, 1 a scan or trash operation failed, 2 invalid usage
    """

    func run(_ arguments: [String]) -> Int32 {
        do {
            guard let command = arguments.first else {
                write(Self.usage + "\n")
                return 0
            }
            let options = try parse(Array(arguments.dropFirst()))
            if options.help || ["help", "-h", "--help"].contains(command) {
                write(Self.usage + "\n")
                return 0
            }
            switch command {
            case "scan": return try scanCommand(options)
            case "top": return try topCommand(options)
            case "junk": return try junkCommand(options)
            case "size": return try sizeCommand(options)
            case "trash": return try trashCommand(options)
            default: throw Failure.usage("unknown command '\(command)'")
            }
        } catch Failure.usage(let message) {
            warn("burrow: \(message)\nRun `burrow help` for usage.\n")
            return 2
        } catch Failure.failed(let message) {
            warn("burrow: \(message)\n")
            return 1
        } catch {
            warn("burrow: \(error.localizedDescription)\n")
            return 1
        }
    }

    // MARK: Arguments

    func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value(_ name: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw Failure.usage("\(name) needs a value") }
            return arguments[index]
        }
        func count(_ name: String) throws -> Int {
            let raw = try value(name)
            guard let number = Int(raw), number >= 0 else { throw Failure.usage("\(name) needs a whole number, got '\(raw)'") }
            return number
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json": options.json = true
            case "--quiet", "-q": options.quiet = true
            case "--types": options.types = true
            case "--junk": options.junk = true
            case "--dry-run", "-n": options.dryRun = true
            case "--help", "-h": options.help = true
            case "--depth": options.depth = try count(argument)
            case "--top": options.top = try count(argument)
            case "--files": options.files = try count(argument)
            case "--limit": options.limit = try count(argument)
            case "--min-size":
                let raw = try value(argument)
                guard let bytes = Self.parseSize(raw) else { throw Failure.usage("invalid size '\(raw)', use e.g. 500M or 2G") }
                options.minSize = bytes
            case "--older-than":
                let raw = try value(argument)
                guard let days = Double(raw), days >= 0 else { throw Failure.usage("--older-than needs days, got '\(raw)'") }
                options.olderThanDays = days
            case "--ext":
                let raw = try value(argument)
                options.extensions = Set(raw.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                }.filter { !$0.isEmpty })
            case "--":
                options.positional.append(contentsOf: arguments[(index + 1)...])
                index = arguments.count
            default:
                if argument.hasPrefix("-") && argument.count > 1 { throw Failure.usage("unknown option '\(argument)'") }
                options.positional.append(argument)
            }
            index += 1
        }
        return options
    }

    /// Decimal units like Finder: `1.5G`, `500M`, `20KB`, `123`.
    static func parseSize(_ raw: String) -> Int64? {
        var text = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if text.hasSuffix("B") { text.removeLast() }
        let units: [Character: Double] = ["K": 1e3, "M": 1e6, "G": 1e9, "T": 1e12]
        var multiplier = 1.0
        if let last = text.last, let unit = units[last] {
            multiplier = unit
            text.removeLast()
        }
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number >= 0 else { return nil }
        return Int64(number * multiplier)
    }

    func resolve(_ raw: String) -> String {
        var path = raw
        if path == "~" { path = homePath } else if path.hasPrefix("~/") { path = homePath + path.dropFirst() }
        if !path.hasPrefix("/") { path = currentDirectory + "/" + path }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: Scanning

    private func scannedTree(_ rawPath: String, options: Options) throws -> DiskTree {
        let path = resolve(rawPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { throw Failure.failed("\(path): no such file or folder") }
        guard isDirectory.boolValue else { throw Failure.failed("\(path) is a file; use `burrow size` for files") }
        return scan(path, quiet: options.quiet)
    }

    private func scan(_ path: String, quiet: Bool) -> DiskTree {
        let control = DiskScanControl()
        var ticker: DispatchSourceTimer?
        if showsProgress && !quiet {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            let warn = self.warn
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler {
                let progress = control.progress
                warn("\r\u{1B}[KScanning \(path): \(Self.grouped(progress.entries)) entries, \(Self.human(progress.bytes))")
            }
            timer.resume()
            ticker = timer
        }
        // Without cancellation the scanner always returns a tree.
        let tree = DiskScanner.scan(root: path, control: control)!
        if let ticker {
            ticker.cancel()
            warn("\r\u{1B}[K")
        }
        return tree
    }

    // MARK: scan

    private func scanCommand(_ options: Options) throws -> Int32 {
        guard options.positional.count <= 1 else { throw Failure.usage("scan takes one PATH") }
        let tree = try scannedTree(options.positional.first ?? "/", options: options)
        let minSize = options.minSize ?? 0
        let junk = options.junk ? junkItems(tree, minSize: max(minSize, 10_000_000), limit: options.limit ?? 100) : []
        let summary = options.types || options.files > 0 ? tree.summary(of: DiskTree.rootID, largestLimit: max(options.files, 1)) : nil
        if options.json {
            var document = header(tree)
            document["tree"] = nodeJSON(tree, DiskTree.rootID, depth: 0, options: options)
            if let summary, options.files > 0 { document["largestFiles"] = summary.largestFiles.prefix(options.files).map { fileJSON(tree, $0) } }
            if let summary, options.types { document["types"] = typesJSON(summary) }
            if options.junk { document["junk"] = junk.map { junkJSON(tree, $0) } }
            try emit(document)
            return 0
        }
        var lines = headerLines(tree)
        lines.append("")
        appendTree(tree, DiskTree.rootID, depth: 0, options: options, total: tree.allocatedSize(DiskTree.rootID), into: &lines)
        if let summary, options.files > 0 {
            lines.append("")
            lines.append("Largest files:")
            lines += summary.largestFiles.prefix(options.files).map { fileLine(tree, $0) }
        }
        if let summary, options.types {
            lines.append("")
            lines.append("By type:")
            lines += typeLines(summary)
        }
        if options.junk {
            lines.append("")
            lines += junkLines(tree, junk)
        }
        write(lines.joined(separator: "\n") + "\n")
        return 0
    }

    private func header(_ tree: DiskTree) -> [String: Any] {
        var document: [String: Any] = [
            "root": tree.rootPath,
            "scannedAt": ISO8601DateFormatter().string(from: tree.scannedAt),
            "elapsedMilliseconds": Int(tree.elapsedMilliseconds.rounded()),
            "entries": tree.nodeCount,
            "totalSize": tree.allocatedSize(DiskTree.rootID),
            "complete": tree.isComplete,
            "unreadableFolders": tree.unreadableDirectoryCount,
            "cloudOnlyFolders": tree.datalessDirectoryCount,
            "skippedMounts": tree.skippedMountCount,
            "unscannedSize": tree.unaccountedBytes,
            "sizeUnit": "bytes on disk"
        ]
        if let free = tree.volumeFreeBytes { document["volumeFreeSize"] = free }
        if tree.reachedEntryLimit { document["reachedEntryLimit"] = true }
        return document
    }

    private func headerLines(_ tree: DiskTree) -> [String] {
        let seconds = String(format: "%.1f", tree.elapsedMilliseconds / 1000)
        var lines = ["Scanned \(tree.rootPath): \(Self.grouped(tree.nodeCount)) entries in \(seconds) s"]
        var disk = "Total \(Self.human(tree.allocatedSize(DiskTree.rootID)))"
        if let free = tree.volumeFreeBytes { disk += ", free \(Self.human(free))" }
        if tree.unaccountedBytes > 0 { disk += ", unscanned (system/protected) \(Self.human(tree.unaccountedBytes))" }
        lines.append(disk)
        if tree.unreadableDirectoryCount > 0 {
            lines.append("\(Self.grouped(tree.unreadableDirectoryCount)) folders unreadable: give the app running burrow Full Disk Access for a complete scan")
        }
        if tree.reachedEntryLimit { lines.append("Entry limit reached: the tree is incomplete") }
        return lines
    }

    private func visibleChildren(_ tree: DiskTree, _ id: NodeID, options: Options) -> (shown: [NodeID], hiddenCount: Int, hiddenSize: Int64) {
        let children = tree.children(of: id)
        let minSize = options.minSize ?? 0
        let shown = Array(children.lazy.filter { tree.allocatedSize($0) >= minSize }.prefix(options.top))
        let shownSet = Set(shown)
        let hidden = children.filter { !shownSet.contains($0) }
        return (shown, hidden.count, hidden.reduce(0) { $0 + tree.allocatedSize($1) })
    }

    private func nodeJSON(_ tree: DiskTree, _ id: NodeID, depth: Int, options: Options) -> [String: Any] {
        var node: [String: Any] = ["size": tree.allocatedSize(id), "logicalSize": tree.logicalSize(id)]
        if tree.isSynthetic(id) {
            node["kind"] = "unscanned"
            node["name"] = "unscanned space (system, protected or unreadable)"
            return node
        }
        node["path"] = tree.path(id)
        node["name"] = tree.name(id)
        if tree.isDirectory(id) {
            node["kind"] = "directory"
            node["files"] = tree.fileCount(id)
            if tree.isUnreadable(id) { node["unreadable"] = true }
            if depth < options.depth {
                let children = visibleChildren(tree, id, options: options)
                node["children"] = children.shown.map { nodeJSON(tree, $0, depth: depth + 1, options: options) }
                if children.hiddenCount > 0 {
                    node["omittedChildren"] = children.hiddenCount
                    node["omittedSize"] = children.hiddenSize
                }
            }
        } else {
            node["kind"] = tree.isSymlink(id) ? "symlink" : "file"
            node["modified"] = ISO8601DateFormatter().string(from: tree.modificationDate(id))
        }
        return node
    }

    private func appendTree(_ tree: DiskTree, _ id: NodeID, depth: Int, options: Options, total: Int64, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        let size = tree.allocatedSize(id)
        let share = total > 0 ? Double(size) / Double(total) * 100 : 0
        let prefix = Self.pad(Self.human(size), 9) + Self.pad(String(format: "%.0f%%", share), 6) + "  " + indent
        if tree.isSynthetic(id) {
            lines.append(prefix + "[unscanned: system, protected or unreadable]")
            return
        }
        var label = tree.path(id)
        if tree.isDirectory(id) {
            if label != "/" { label += "/" }
            label += "  (\(Self.files(tree.fileCount(id))))"
            if tree.isUnreadable(id) { label += " [unreadable]" }
        } else if tree.isSymlink(id) {
            label += " -> symlink"
        }
        lines.append(prefix + label)
        guard tree.isDirectory(id), depth < options.depth else { return }
        let children = visibleChildren(tree, id, options: options)
        for child in children.shown {
            appendTree(tree, child, depth: depth + 1, options: options, total: total, into: &lines)
        }
        if children.hiddenCount > 0 {
            lines.append(Self.pad(Self.human(children.hiddenSize), 9) + String(repeating: " ", count: 8)
                + indent + "  … \(Self.grouped(children.hiddenCount)) more items")
        }
    }

    // MARK: top

    private func topCommand(_ options: Options) throws -> Int32 {
        guard options.positional.count <= 1 else { throw Failure.usage("top takes one PATH") }
        let tree = try scannedTree(options.positional.first ?? "/", options: options)
        let files = largestFiles(tree, options: options)
        if options.json {
            var document = header(tree)
            document["largestFiles"] = files.map { fileJSON(tree, $0) }
            try emit(document)
        } else {
            let lines = headerLines(tree) + [""] + (files.isEmpty ? ["No matching files."] : files.map { fileLine(tree, $0) })
            write(lines.joined(separator: "\n") + "\n")
        }
        return 0
    }

    func largestFiles(_ tree: DiskTree, options: Options) -> [NodeID] {
        let limit = options.limit ?? 50
        let minSize = options.minSize ?? 0
        let cutoff = options.olderThanDays.map { Date().addingTimeInterval(-$0 * 86_400) }
        var candidates: [(size: Int64, id: NodeID)] = []
        var stack: [NodeID] = [DiskTree.rootID]
        while let id = stack.popLast() {
            if tree.isDirectory(id) {
                stack.append(contentsOf: tree.children(of: id))
                continue
            }
            guard !tree.isSynthetic(id), !tree.isSymlink(id) else { continue }
            let size = tree.allocatedSize(id)
            guard size >= minSize else { continue }
            if let cutoff, tree.modificationDate(id) >= cutoff { continue }
            if !options.extensions.isEmpty {
                let ext = (tree.name(id) as NSString).pathExtension.lowercased()
                guard options.extensions.contains(ext) else { continue }
            }
            candidates.append((size, id))
        }
        candidates.sort { $0.size > $1.size }
        return candidates.prefix(limit).map(\.id)
    }

    private func fileJSON(_ tree: DiskTree, _ id: NodeID) -> [String: Any] {
        ["path": tree.path(id), "size": tree.allocatedSize(id), "logicalSize": tree.logicalSize(id),
         "type": tree.category(id).rawValue.lowercased(),
         "modified": ISO8601DateFormatter().string(from: tree.modificationDate(id))]
    }

    private func fileLine(_ tree: DiskTree, _ id: NodeID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return Self.pad(Self.human(tree.allocatedSize(id)), 9) + "  " + formatter.string(from: tree.modificationDate(id)) + "  " + tree.path(id)
    }

    private func typesJSON(_ summary: DiskTree.Summary) -> [[String: Any]] {
        summary.categories.map { ["type": $0.0.rawValue.lowercased(), "size": $0.1, "files": $0.2] }
    }

    private func typeLines(_ summary: DiskTree.Summary) -> [String] {
        summary.categories.map {
            Self.pad(Self.human($0.1), 9) + "  " + $0.0.rawValue.lowercased().padding(toLength: 11, withPad: " ", startingAt: 0)
                + Self.files($0.2)
        }
    }

    // MARK: junk

    struct JunkRule {
        let kind: String
        /// "safe": rebuilt or redownloaded on demand. "review": check before removing.
        let risk: String
        let hint: String
    }

    struct JunkItem {
        let node: NodeID
        let rule: JunkRule
    }

    private static let pythonCache = JunkRule(kind: "Python cache", risk: "safe", hint: "Recreated automatically")
    private static let webBuild = JunkRule(kind: "JavaScript build cache", risk: "safe", hint: "Rebuilt by the next build")

    /// Folder names that are clutter wherever they appear. A marker, when set,
    /// must exist next to (`sibling`) or inside (`child`) the folder.
    private static let namedRules: [String: (marker: String?, inside: Bool, rule: JunkRule)] = [
        "node_modules": (nil, false, JunkRule(kind: "node_modules", risk: "safe", hint: "Reinstalled by npm/pnpm/yarn install")),
        "DerivedData": (nil, false, JunkRule(kind: "Xcode DerivedData", risk: "safe", hint: "Rebuilt by Xcode")),
        "__pycache__": (nil, false, pythonCache),
        ".pytest_cache": (nil, false, pythonCache),
        ".mypy_cache": (nil, false, pythonCache),
        ".ruff_cache": (nil, false, pythonCache),
        ".next": (nil, false, webBuild),
        ".nuxt": (nil, false, webBuild),
        ".turbo": (nil, false, webBuild),
        ".parcel-cache": (nil, false, webBuild),
        ".svelte-kit": (nil, false, webBuild),
        ".gradle": (nil, false, JunkRule(kind: "Gradle cache", risk: "safe", hint: "Redownloaded by Gradle")),
        ".build": ("Package.swift", false, JunkRule(kind: "SwiftPM build", risk: "safe", hint: "Rebuilt by swift build")),
        "target": ("Cargo.toml", false, JunkRule(kind: "Rust build", risk: "safe", hint: "Rebuilt by cargo build")),
        "Pods": ("Podfile", false, JunkRule(kind: "CocoaPods", risk: "safe", hint: "Reinstalled by pod install")),
        ".venv": ("pyvenv.cfg", true, JunkRule(kind: "Python virtualenv", risk: "review", hint: "Recreate the environment and reinstall its packages")),
        "venv": ("pyvenv.cfg", true, JunkRule(kind: "Python virtualenv", risk: "review", hint: "Recreate the environment and reinstall its packages"))
    ]

    /// Home-relative folders. `expand` reports each child separately so they
    /// can be trashed one by one.
    private static let homeRules: [(path: String, expand: Bool, rule: JunkRule)] = [
        ("Library/Caches", true, JunkRule(kind: "App cache", risk: "safe", hint: "Recreated by its app; quit the app first")),
        ("Library/Logs", false, JunkRule(kind: "Logs", risk: "safe", hint: "Old diagnostic logs")),
        ("Library/Developer/Xcode/iOS DeviceSupport", false, JunkRule(kind: "Xcode device support", risk: "safe", hint: "Recreated when a device connects")),
        ("Library/Developer/Xcode/watchOS DeviceSupport", false, JunkRule(kind: "Xcode device support", risk: "safe", hint: "Recreated when a device connects")),
        ("Library/Developer/Xcode/tvOS DeviceSupport", false, JunkRule(kind: "Xcode device support", risk: "safe", hint: "Recreated when a device connects")),
        ("Library/Developer/Xcode/visionOS DeviceSupport", false, JunkRule(kind: "Xcode device support", risk: "safe", hint: "Recreated when a device connects")),
        ("Library/Developer/CoreSimulator/Caches", false, JunkRule(kind: "Simulator cache", risk: "safe", hint: "Recreated by Xcode")),
        ("Library/Developer/Xcode/Archives", false, JunkRule(kind: "Xcode archives", risk: "review", hint: "Archives of shipped builds are needed to symbolicate their crashes")),
        ("Library/Developer/CoreSimulator/Devices", false, JunkRule(kind: "Simulator devices", risk: "review", hint: "Prefer `xcrun simctl delete unavailable` over trashing")),
        ("Library/Application Support/MobileSync/Backup", false, JunkRule(kind: "iPhone/iPad backups", risk: "review", hint: "Manage them in Finder under the device's Manage Backups")),
        ("Library/Containers/com.docker.docker/Data/vms", false, JunkRule(kind: "Docker disk image", risk: "review", hint: "Use `docker system prune` instead of trashing the image")),
        (".npm/_cacache", false, JunkRule(kind: "npm cache", risk: "safe", hint: "Redownloaded; or run `npm cache clean --force`")),
        (".bun/install/cache", false, JunkRule(kind: "Bun cache", risk: "safe", hint: "Redownloaded by bun install")),
        (".cache", true, JunkRule(kind: "Tool cache", risk: "review", hint: "CLI tool caches; some hold large downloaded models")),
        (".Trash", false, JunkRule(kind: "Trash", risk: "review", hint: "Empty the Trash in Finder to free this space"))
    ]

    func junkItems(_ tree: DiskTree, minSize: Int64, limit: Int) -> [JunkItem] {
        var special: [NodeID: (expand: Bool, rule: JunkRule)] = [:]
        for entry in Self.homeRules {
            if let node = tree.node(forPath: homePath + "/" + entry.path) { special[node] = (entry.expand, entry.rule) }
        }
        var items: [JunkItem] = []
        var stack: [NodeID] = [DiskTree.rootID]
        while let id = stack.popLast() {
            guard tree.isDirectory(id), tree.allocatedSize(id) >= minSize else { continue }
            if let match = special[id] {
                if match.expand {
                    items += tree.children(of: id).filter { tree.allocatedSize($0) >= minSize }.map { JunkItem(node: $0, rule: match.rule) }
                } else {
                    items.append(JunkItem(node: id, rule: match.rule))
                }
                continue
            }
            if id != DiskTree.rootID, let named = Self.namedRules[tree.name(id)] {
                let markerOwner = named.inside ? id : tree.parent(id)
                let hasMarker = named.marker.map { marker in
                    markerOwner.map { tree.children(of: $0).contains { tree.name($0) == marker } } ?? false
                } ?? true
                if hasMarker {
                    items.append(JunkItem(node: id, rule: named.rule))
                    continue
                }
            }
            stack.append(contentsOf: tree.children(of: id))
        }
        items.sort { tree.allocatedSize($0.node) > tree.allocatedSize($1.node) }
        return Array(items.prefix(limit))
    }

    private func junkCommand(_ options: Options) throws -> Int32 {
        guard options.positional.count <= 1 else { throw Failure.usage("junk takes one PATH") }
        let tree = try scannedTree(options.positional.first ?? "~", options: options)
        let items = junkItems(tree, minSize: options.minSize ?? 10_000_000, limit: options.limit ?? 100)
        if options.json {
            var document = header(tree)
            document["junk"] = items.map { junkJSON(tree, $0) }
            document["junkTotalSize"] = items.reduce(0) { $0 + tree.allocatedSize($1.node) }
            try emit(document)
        } else {
            write((headerLines(tree) + [""] + junkLines(tree, items)).joined(separator: "\n") + "\n")
        }
        return 0
    }

    private func junkJSON(_ tree: DiskTree, _ item: JunkItem) -> [String: Any] {
        ["path": tree.path(item.node), "size": tree.allocatedSize(item.node), "kind": item.rule.kind,
         "risk": item.rule.risk, "hint": item.rule.hint]
    }

    private func junkLines(_ tree: DiskTree, _ items: [JunkItem]) -> [String] {
        guard !items.isEmpty else { return ["No regenerable clutter found."] }
        let total = items.reduce(0) { $0 + tree.allocatedSize($1.node) }
        return ["Regenerable clutter (\(Self.human(total)) in \(items.count) items; risk safe = rebuilt on demand, review = check first):"]
            + items.map {
                Self.pad(Self.human(tree.allocatedSize($0.node)), 9) + "  " + $0.rule.risk.padding(toLength: 7, withPad: " ", startingAt: 0)
                    + tree.path($0.node) + "  [\($0.rule.kind): \($0.rule.hint)]"
            }
    }

    // MARK: size

    private struct Measured {
        let path: String
        let size: Int64
        let logicalSize: Int64
        let files: Int
        let isDirectory: Bool
    }

    private func measure(_ path: String, quiet: Bool) -> Measured? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if info.st_mode & S_IFMT == S_IFDIR {
            let tree = scan(path, quiet: quiet)
            return Measured(path: path, size: tree.allocatedSize(DiskTree.rootID), logicalSize: tree.logicalSize(DiskTree.rootID),
                files: tree.fileCount(DiskTree.rootID), isDirectory: true)
        }
        return Measured(path: path, size: Int64(info.st_blocks) * 512, logicalSize: Int64(info.st_size), files: 1, isDirectory: false)
    }

    private func sizeCommand(_ options: Options) throws -> Int32 {
        guard !options.positional.isEmpty else { throw Failure.usage("size needs at least one PATH") }
        var results: [[String: Any]] = []
        var lines: [String] = []
        var status: Int32 = 0
        for raw in options.positional {
            let path = resolve(raw)
            guard let measured = measure(path, quiet: options.quiet) else {
                status = 1
                results.append(["path": path, "error": "no such file or folder"])
                lines.append("        ?  \(path): no such file or folder")
                continue
            }
            results.append(["path": path, "size": measured.size, "logicalSize": measured.logicalSize,
                            "files": measured.files, "kind": measured.isDirectory ? "directory" : "file"])
            lines.append(Self.pad(Self.human(measured.size), 9) + "  " + path + (measured.isDirectory ? "/  (\(Self.files(measured.files)))" : ""))
        }
        if options.json { try emit(["items": results]) } else { write(lines.joined(separator: "\n") + "\n") }
        return status
    }

    // MARK: trash

    /// Why a path must never be trashed by an automated cleanup, or nil.
    func protectionReason(_ path: String) -> String? {
        if path == "/" { return "the root of the disk" }
        let home = homePath
        let homeFolders = ["", "/Library", "/Desktop", "/Documents", "/Downloads", "/Pictures", "/Movies", "/Music",
                           "/Public", "/Applications", "/.Trash", "/Library/Application Support", "/Library/Containers",
                           "/Library/Group Containers", "/Library/Preferences", "/Library/Mobile Documents", "/Library/Caches",
                           "/Library/Developer", "/.ssh", "/.config"]
        if homeFolders.contains(where: { path == home + $0 }) { return "a standard folder of your home" }
        let systemFolders = ["/Applications", "/Library", "/Users", "/Volumes", "/opt", "/opt/homebrew", "/usr/local", "/private",
                             "/private/var", "/private/tmp", "/tmp", "/var", "/etc", "/cores", "/Network", "/System"]
        if systemFolders.contains(path) { return "a system folder" }
        let systemTrees = ["/System/", "/bin/", "/sbin/", "/usr/", "/private/etc/", "/private/var/db/", "/etc/", "/dev/",
                           "/Library/Apple/", home + "/Library/Keychains/"]
        if systemTrees.contains(where: { path.hasPrefix($0) || path + "/" == $0 }), !path.hasPrefix("/usr/local/") {
            return "inside a protected system location"
        }
        if DiskScanBoundary.volumeRoot(of: path) == path { return "a mounted volume" }
        return nil
    }

    private func trashCommand(_ options: Options) throws -> Int32 {
        guard !options.positional.isEmpty else { throw Failure.usage("trash needs at least one PATH") }
        var results: [[String: Any]] = []
        var lines: [String] = []
        var status: Int32 = 0
        var total: Int64 = 0
        for raw in options.positional {
            let path = resolve(raw)
            var result: [String: Any] = ["path": path]
            defer { results.append(result) }
            if let reason = protectionReason(path) {
                status = 1
                result["status"] = "refused"
                result["reason"] = "protected: \(reason)"
                lines.append("refused     \(path): protected, \(reason)")
                continue
            }
            guard let measured = measure(path, quiet: options.quiet) else {
                status = 1
                result["status"] = "failed"
                result["reason"] = "no such file or folder"
                lines.append("failed      \(path): no such file or folder")
                continue
            }
            result["size"] = measured.size
            if options.dryRun {
                result["status"] = "would-trash"
                total += measured.size
                lines.append("would trash " + Self.pad(Self.human(measured.size), 9) + "  " + path)
                continue
            }
            do {
                let destination = try trash(URL(fileURLWithPath: path))
                result["status"] = "trashed"
                if let destination { result["trashedTo"] = destination.path }
                total += measured.size
                lines.append("trashed     " + Self.pad(Self.human(measured.size), 9) + "  " + path)
            } catch {
                status = 1
                result["status"] = "failed"
                result["reason"] = error.localizedDescription
                lines.append("failed      \(path): \(error.localizedDescription)")
            }
        }
        let verb = options.dryRun ? "Would move" : "Moved"
        let note = "\(verb) \(Self.human(total)) to the Trash. Space is freed when the Trash is emptied."
        if options.json {
            try emit(["items": results, "totalSize": total, "dryRun": options.dryRun, "note": note])
        } else {
            write((lines + [note]).joined(separator: "\n") + "\n")
        }
        return status
    }

    // MARK: Formatting

    private func emit(_ document: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        write(String(decoding: data, as: UTF8.self) + "\n")
    }

    static func human(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while abs(value) >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: abs(value) >= 100 ? "%.0f" : "%.1f", value) + " " + units[unit]
    }

    static func grouped(_ number: Int) -> String {
        let digits = String(abs(number))
        var result = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0 && (digits.count - offset) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return number < 0 ? "-" + result : result
    }

    static func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(grouped(count)) files" }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
}
