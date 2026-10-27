import Foundation
import Darwin

/// Production comparison fixtures only; no global hooks, clocks, or real-user files.
struct ComparisonSnapshotRegressionTests {
    private func fixture() throws -> (root: URL, left: URL, right: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-compare-\(UUID())")
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        return (root, left, right)
    }

    private func writePair(left: URL, right: URL) throws {
        for url in [left, right] {
            try Data("same".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
        }
    }

    private func setLinkTime(_ url: URL) throws {
        let times = [timeval(tv_sec: 1_700_000_000, tv_usec: 0), timeval(tv_sec: 1_700_000_000, tv_usec: 0)]
        let result = times.withUnsafeBufferPointer { lutimes(url.path, $0.baseAddress!) }
        try expect(result == 0)
    }

    func testLeftFileMutationBetweenHashesIsUnreadable() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let left = f.left.appendingPathComponent("file"), right = f.right.appendingPathComponent("file")
        try writePair(left: left, right: right)
        let baseline = FolderComparison.compare(left: f.left, right: f.right, includeHidden: true,
            token: AnalysisRequestToken(rootPath: f.left.path))
        try expect(baseline.entries.first?.status == .identical)
        var mutated = false
        let result = FolderComparison.compare(left: f.left, right: f.right, includeHidden: true,
            token: AnalysisRequestToken(rootPath: f.left.path), betweenSides: { l, _ in
                // In-place growth must be rejected, regardless of timestamp resolution.
                let handle = try FileHandle(forWritingTo: l)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(" changed".utf8))
                mutated = true
            })
        try expect(mutated && result.diagnostic == nil && result.entries.count == 1)
        try expect(result.entries[0].status == .unreadable)
        try expect(FolderComparison.copyCandidates(result.entries, leftToRight: true).isEmpty)
        try expect(FolderComparison.copyCandidates(result.entries, leftToRight: false).isEmpty)
    }

    func testLeftFileReplacementBetweenHashesIsUnreadable() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try writePair(left: f.left.appendingPathComponent("file"), right: f.right.appendingPathComponent("file"))
        var replaced = false
        let result = FolderComparison.compare(left: f.left, right: f.right, includeHidden: true,
            token: AnalysisRequestToken(rootPath: f.left.path), betweenSides: { l, _ in
                // Keep the old inode allocated, then recreate identical bytes/time.
                try FileManager.default.moveItem(at: l, to: f.root.appendingPathComponent("old-file"))
                try Data("same".utf8).write(to: l)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: l.path)
                replaced = true
            })
        try expect(replaced && result.entries.count == 1)
        try expect(result.entries[0].status == .unreadable)
    }

    func testLinkReplacementBetweenSidesIsUnreadable() throws {
        // Test both sides: snapshots must precede both reads, and both must be
        // revalidated. Dangling links must be inspected without following targets.
        for replaceLeft in [true, false] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            for dir in [f.left, f.right] {
                let link = dir.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-target")
                try setLinkTime(link)
            }
            let baseline = FolderComparison.compare(left: f.left, right: f.right, includeHidden: true,
                token: AnalysisRequestToken(rootPath: f.left.path))
            try expect(baseline.entries.first?.status == .identical)
            var replaced = false
            let result = FolderComparison.compare(left: f.left, right: f.right, includeHidden: true,
                token: AnalysisRequestToken(rootPath: f.left.path), betweenSides: { l, r in
                    let link = replaceLeft ? l : r
                    try FileManager.default.moveItem(at: link, to: f.root.appendingPathComponent("old-link"))
                    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-target")
                    try setLinkTime(link)
                    replaced = true
                })
            try expect(replaced && result.entries.count == 1)
            try expect(result.entries[0].status == .unreadable)
            try expect(FolderComparison.copyCandidates(result.entries, leftToRight: true).isEmpty)
        }
    }

    func testComparisonEntryBudgetExactBoundary() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Zero entries at a zero budget is complete, not a truncation.
        let empty = FolderComparison.compare(left: f.left, right: f.right, includeHidden: true,
            token: AnalysisRequestToken(rootPath: f.left.path), maxRetainedEntries: 0)
        try expect(empty.diagnostic == nil && empty.entries.isEmpty)
        try Data().write(to: f.left.appendingPathComponent("left-only"))
        try Data().write(to: f.right.appendingPathComponent("right-only"))
        let exact = FolderComparison.compare(left: f.left, right: f.right, includeHidden: true,
            token: AnalysisRequestToken(rootPath: f.left.path), maxRetainedEntries: 2)
        try expect(exact.diagnostic == nil && exact.entries.count == 2)
        try expect(FolderComparison.copyCandidates(exact.entries, leftToRight: true).count == 1)
        try expect(FolderComparison.copyCandidates(exact.entries, leftToRight: false).count == 1)
        // Exhausting the allowance on the left still permits an empty right side.
        try FileManager.default.removeItem(at: f.right.appendingPathComponent("right-only"))
        let leftExact = FolderComparison.compare(left: f.left, right: f.right, includeHidden: true,
            token: AnalysisRequestToken(rootPath: f.left.path), maxRetainedEntries: 1)
        try expect(leftExact.diagnostic == nil && leftExact.entries.count == 1)
    }

    func testComparisonEntryBudgetOverflowDisablesCopy() throws {
        for overflowLeft in [true, false] {
            let f = try fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            let dir = overflowLeft ? f.left : f.right
            for name in ["one", "two", "three"] { try Data().write(to: dir.appendingPathComponent(name)) }
            let result = FolderComparison.compare(left: f.left, right: f.right, includeHidden: true,
                token: AnalysisRequestToken(rootPath: f.left.path), maxRetainedEntries: 2)
            try expect(result.diagnostic != nil && result.entries.isEmpty)
            try expect(FolderComparison.copyCandidates(result.entries, leftToRight: true).isEmpty)
            try expect(FolderComparison.copyCandidates(result.entries, leftToRight: false).isEmpty)
        }
        // Each side fits individually, but the combined retained budget does not.
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try writePair(left: f.left.appendingPathComponent("file"), right: f.right.appendingPathComponent("file"))
        let combined = FolderComparison.compare(left: f.left, right: f.right, includeHidden: true,
            token: AnalysisRequestToken(rootPath: f.left.path), maxRetainedEntries: 1)
        try expect(combined.diagnostic != nil && combined.entries.isEmpty)
    }
}
