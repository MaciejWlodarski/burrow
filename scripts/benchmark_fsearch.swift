import Foundation

@main
struct BenchmarkMain {
    static func main() {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let roots = [projectURL.path]
        let t0 = DispatchTime.now().uptimeNanoseconds
        let crawled = BulkCrawler.crawlTree(roots: roots, skipHeavyDevDirs: true, maxEntries: 300_000)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let crawlMs = Double(t1 - t0) / 1_000_000.0
        print(String(format: "[getattrlistbulk] Zaindeksowano %d plików/folderów w %.2f ms", crawled.count, crawlMs))

        for relativePath in [
            "",
            "Sources/Burrow",
            "Sources/Burrow/Models",
            "Sources/Burrow/Engine",
            "Sources/Burrow/Views"
        ] {
            FSearchIndex.shared.refreshDirectoryInIndex(projectURL.appendingPathComponent(relativePath).path)
        }

        let testQueries = [
            "fsearch",
            "fserach", // 1-literówka dla słowa 5+ znaków!
            "ext:swift",
            "type:code size:>2kb",
            "ext:swift grep:getattrlistbulk", // 1. przebieg buduje filtr Blooma trigramów
            "ext:swift grep:getattrlistbulk", // 2. przebieg używa 64-bitowego filtra Blooma trigramów w RAM!
            "^File .swift$"
        ]

        for (i, q) in testQueries.enumerated() {
            let res = FSearchIndex.shared.search(
                rawQuery: q,
                scope: .wholeIndex,
                scopeDirectory: projectURL.path,
                includeHidden: true,
                fuzzyEnabled: true
            )
            print(String(format: "[#%d] Zapytanie %-32@ -> %3d wyników w %.3f ms (trigram cache: %d)", i + 1, q as NSString, res.items.count, res.elapsedMilliseconds, FSearchIndex.shared.trigramCacheCount))
        }
    }
}
