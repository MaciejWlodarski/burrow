import Foundation

/// Exercises the real parser, pane edit/cancellation entry points and native engine.
struct SearchQuerySafetyRegressionTests {
    @MainActor static func runAll() async throws {
        try parserValues()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bf-query-safety-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["report.pdf", "report.pdfx", "report.txt", "photo.png", "source.swift"] {
            try Data("ext:pdf say \"ext:pdf\"".utf8).write(to: root.appendingPathComponent(name))
        }
        let index = FSearchIndex(roots: [root.path], enableMonitoring: false)
        index.usePersistentMMapCache = false
        index.skipHeavyDevDirs = false
        index.startIndexing(roots: [root.path])
        for _ in 0..<1000 where index.isIndexing { try await Task.sleep(for: .milliseconds(10)) }
        try expect(!index.isIndexing)
        for scope in SearchScopeMode.allCases {
            let result = index.search(rawQuery: "type:swift", scope: scope, scopeDirectory: root.path, includeHidden: true, fuzzyEnabled: false)
            try expect(Set(result.items.map(\.name)) == ["source.swift"])
        }
        let unicodeQuery = #""żółty 📄"  ext:pdf grep:"say \"ext:pdf\"""#
        let unicodePill = ParsedFSearchQuery.parse(unicodeQuery).pills[0]
        try expect(ParsedFSearchQuery.removing(unicodePill, from: unicodeQuery) == #""żółty 📄"   grep:"say \"ext:pdf\"""#)
        let pane = PaneTabState(initialURL: root)
        pane.searchScope = .currentFolder
        pane.fuzzyEnabled = false
        let edits: [(String, Int, String, Set<String>)] = [
            (#"ext:pdf grep:"ext:pdf""#, 0, #" grep:"ext:pdf""#, ["report.pdf", "report.pdfx", "report.txt", "photo.png", "source.swift"]),
            ("ext:pdf ext:pdfx", 0, " ext:pdfx", ["report.pdfx"]),
            ("ext:pdf !ext:pdf", 0, " !ext:pdf", ["report.pdfx", "report.txt", "photo.png", "source.swift"]),
            ("ext:pdf ext:pdf", 1, "ext:pdf ", ["report.pdf"]),
            (#"ext:pdf grep:"say \"ext:pdf\"""#, 0, #" grep:"say \"ext:pdf\"""#, ["report.pdf", "report.pdfx", "report.txt", "photo.png", "source.swift"]),
            ("ext:pdf EXT:PDF", 0, " EXT:PDF", ["report.pdf"]),
            (#"ext:pdf "ext:pdf""#, 0, #" "ext:pdf""#, []),
            (" \text:pdf\n\t ext:pdfx  ", 0, " \t\n\t ext:pdfx  ", ["report.pdfx"])
        ]
        for (raw, occurrence, expected, names) in edits {
            pane.searchQuery = raw
            pane.triggerSearch()
            let pill = pane.activeFilterPills[occurrence]
            pane.removeFilterPill(pill)
            try expect(pane.searchQuery == expected)
            try expect(ParsedFSearchQuery.parse(expected).validationError == nil)
            for scope in SearchScopeMode.allCases {
                let result = index.search(rawQuery: expected, scope: scope, scopeDirectory: root.path, includeHidden: true, fuzzyEnabled: false)
                try expect(result.diagnostic == nil)
                try expect(Set(result.items.map(\.name)) == names)
            }
        }
        pane.searchQuery = #"grep:"ext:pdf""#
        pane.appendSearchOperator("ext:pdf")
        try expect(pane.searchQuery == #"grep:"ext:pdf" ext:pdf"#)
        pane.searchQuery = #" EXT:PDF ext:pdf ext:pdfx !ext:pdf grep:"ext:pdf" "ext:pdf""#
        pane.triggerSearch()
        try expect(ParsedFSearchQuery.containsOperator("ext:pdf", in: pane.searchQuery, pills: pane.activeFilterPills))
        pane.appendSearchOperator("ext:pdf")
        try expect(pane.searchQuery == #"   ext:pdfx !ext:pdf grep:"ext:pdf" "ext:pdf""#)
        try expect(!ParsedFSearchQuery.containsOperator("ext:pdf", in: pane.searchQuery, pills: pane.activeFilterPills))
        // Foundation-bridged storage plus Unicode before/between/after duplicate
        // tokens must preserve every retained source span without index reuse.
        let bridged = NSString(string: "\"żółty 📄\"\tEXT:PDF  \"家族 👨‍👩‍👧‍👦\" ext:pdf\n\"e\u{301}\" Ext:Pdf\tgrep:\"ext:pdf\"") as String
        let bridgedExpected = "\"żółty 📄\"\t  \"家族 👨‍👩‍👧‍👦\" \n\"e\u{301}\" \tgrep:\"ext:pdf\""
        pane.searchQuery = bridged
        pane.triggerSearch()
        let previousPills = pane.activeFilterPills
        try expect(ParsedFSearchQuery.containsOperator("ext:pdf", in: bridged, pills: previousPills))
        try expect(!ParsedFSearchQuery.containsOperator("ext:pdf", in: bridged + " changed", pills: previousPills))
        pane.appendSearchOperator("ext:pdf")
        try expect(pane.searchQuery == bridgedExpected)
        try expect(!ParsedFSearchQuery.containsOperator("ext:pdf", in: pane.searchQuery, pills: pane.activeFilterPills))
        try expect(ParsedFSearchQuery.parse(pane.searchQuery).grepPattern == "ext:pdf")
        let stale = ParsedFSearchQuery.parse("ext:pdf").pills[0]
        try expect(ParsedFSearchQuery.removing(stale, from: "ext:pdf ext:txt") == "ext:pdf ext:txt")
        for raw in invalidQueries {
            pane.searchQuery = "report"
            pane.triggerSearch()
            pane.searchQuery = raw
            pane.triggerSearch()
            try expect(pane.searchDiagnostic != nil)
            try expect(pane.displayedItems.isEmpty && pane.selectedItems.isEmpty)
            for scope in SearchScopeMode.allCases {
                let result = index.search(rawQuery: raw, scope: scope, scopeDirectory: root.path, includeHidden: true)
                try expect(result.items.isEmpty && result.diagnostic != nil)
            }
        }
        // The real edit entry point cancels pending work; clearing the last token
        // restores directory browsing and late results cannot replace it.
        pane.searchQuery = "ext:pdf"
        pane.triggerSearch()
        pane.removeFilterPill(pane.activeFilterPills[0])
        try await Task.sleep(for: .milliseconds(250))
        try expect(pane.searchQuery.isEmpty && !pane.isSearching)
        try expect(Set(pane.displayedItems.map(\.name)) == ["report.pdf", "report.pdfx", "report.txt", "photo.png", "source.swift"])
        for toggle in [false, true] {
            pane.searchQuery = "\next:pdf\n"
            pane.triggerSearch()
            if toggle { pane.appendSearchOperator("ext:pdf") }
            else { pane.removeFilterPill(pane.activeFilterPills[0]) }
            try expect(pane.searchQuery == "\n\n")
            try await Task.sleep(for: .milliseconds(250))
            try expect(!pane.isSearching && pane.searchDiagnostic == nil)
            try expect(Set(pane.displayedItems.map(\.name)) == ["report.pdf", "report.pdfx", "report.txt", "photo.png", "source.swift"])
        }
        print("PASS search query safety: token edits, diagnostics, exact bytes and native scopes")
    }

    private static var invalidQueries: [String] {
        let aliases = ["type", "kind", "t", "tag", "tags", "color", "kolor", "size", "s", "mtime", "modified", "age", "dm", "in", "path", "dir", "folder", "grep", "content", "g", "regex", "re", "sym", "symlink", "git", "limit", "max"]
        return aliases.flatMap { ["!\($0):image", "-\($0):image"] } +
            ["report ext:,,,", "report type:,,,", "ext:pdf,", "type:,swift", "ext:.", "sym:yees", "sym:garbage", "git:modifed", "git:clean", "tag:red,garbage", "limit:zero"]
    }

    private static func parserValues() throws {
        for raw in invalidQueries { try expect(ParsedFSearchQuery.parse(raw).validationError != nil) }
        for (value, expected) in [("true", true), ("TRUE", true), ("1", true), ("yes", true), ("false", false), ("FALSE", false), ("0", false), ("no", false)] {
            let parsed = ParsedFSearchQuery.parse("sym:\(value)")
            try expect(parsed.validationError == nil && parsed.symlinkOnly == expected)
        }
        for value in ["m", "mod", "modified", "a", "staged", "added", "?", "u", "untracked", "any", "*", "MODIFIED"] {
            try expect(ParsedFSearchQuery.parse("git:\(value)").validationError == nil)
        }
        for key in ["ext", "e"] {
            for prefix in ["!", "-"] {
                let parsed = ParsedFSearchQuery.parse("\(prefix)\(key):PDF")
                try expect(parsed.validationError == nil && parsed.excludedExtensions == ["pdf"] && parsed.extensions.isEmpty)
            }
        }
        try expect(ParsedFSearchQuery.parse("!draft -private").terms == [.excluded("draft"), .excluded("private")])
        try expect(ParsedFSearchQuery.parse(#""!type:image" "ext:pdf" "file:colon""#).terms == [.exact("!type:image"), .exact("ext:pdf"), .exact("file:colon")])
        try expect(ParsedFSearchQuery.parse(#"-"old draft" ^"my file""#).terms == [.excluded("old draft"), .prefix("my file")])
        try expect(ParsedFSearchQuery.parse(#"!"a b" "c d"$"#).terms == [.excluded("a b"), .suffix("c d")])
        try expect(FormatHelpers.formatBytes(1_048_500) == "1.00 MB" && FormatHelpers.formatBytes(1023) == "1023 B")
        try expect(ParsedFSearchQuery.parse("type:swift").typeFilters == ["swift"])
        try expect(ParsedFSearchQuery.parse("unknown:value ext:").validationError == nil)
        for (value, bytes) in [("9007199254740993.0b", Int64(9007199254740993)), ("9223372036854775807.0b", Int64.max), ("1.5kb", 1536), (".5b", 0), ("0.999999999999999999999999b", 0), ("1.b", 1)] {
            let parsed = ParsedFSearchQuery.parse("size:=\(value)")
            try expect(parsed.validationError == nil && parsed.sizeFilters.first?.bytes == bytes)
        }
        for value in ["9223372036854775808.0b", "9007199254740993gb", ".b", "1.2.3b"] {
            try expect(ParsedFSearchQuery.parse("size:\(value)").validationError != nil)
        }
        let range = ParsedFSearchQuery.parse("size:1.5kb..2kb").sizeFilters[0]
        try expect(range.matches(1536) && range.matches(2048) && !range.matches(2049))
    }
}
