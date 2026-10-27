import Foundation

struct AnalysisScanInput: Sendable {
    let rootURL: URL
    let showHidden: Bool
    let mode: WizTreeSubMode
}
struct AnalysisScanResult: Sendable {
    let branches: [WizTreeNode]
    let files: [FileItem]
    let groups: [DuplicateFileGroup]
    let categories: [(FileKindCategory, Int64, Int)]
    let complete: Bool
    let diagnostic: String?
    let elapsed: Double
}
struct AnalysisComparisonInput: Sendable {
    let left: URL
    let right: URL
    let includeHidden: Bool
}
struct AnalysisComparisonResult: Sendable {
    let entries: [FolderCompareEntry]
    let diagnostic: String?
}
enum AnalysisVerificationResult: Sendable { case verified, failed(String) }

/// The same adapters serve views and injected-scheduler regression tests. Their
/// inputs/results are immutable; no SwiftUI or MainActor state enters IO work.
enum AnalysisWorkAdapters {
    static func scan(_ input: AnalysisScanInput, token: AnalysisRequestToken) -> AnalysisScanResult? {
        guard !token.isCancelled else { return nil }
        let rootURL = input.rootURL
        let showHidden = input.showHidden
        let mode = input.mode
        let started = DispatchTime.now().uptimeNanoseconds
        let scan = BulkCrawler.crawlTreeResult(roots: [rootURL.path], skipHeavyDevDirs: false,
            maxEntries: 60_000, includeHidden: showHidden, isCancelled: { token.isCancelled })
        guard !token.isCancelled else { return nil }
        var groups: [DuplicateFileGroup] = []
        var failedHashes = 0
        if mode == .duplicates {
            let result = DuplicateFileSafety.groups(from: scan.entries, token: token)
            groups = result.groups
            failedHashes = result.failed
        }
        let files = scan.entries.filter { !$0.isDirectory && !$0.isSymlink }.map { $0.toFileItem(loadTags: false) }
        var categoryMap: [FileKindCategory: (Int64, Int)] = [:]
        for item in files {
            let previous = categoryMap[item.kindCategory] ?? (0, 0)
            categoryMap[item.kindCategory] = (previous.0 + item.size, previous.1 + 1)
        }
        let rootPrefix = rootURL.path == "/" ? "/" : rootURL.path + "/"
        var filesByBranch: [String: [FileItem]] = [:]
        for item in files {
            let relative = item.path.dropFirst(rootPrefix.count)
            let first = String(relative.split(separator: "/", maxSplits: 1).first ?? "")
            filesByBranch[first, default: []].append(item)
        }
        var branches: [WizTreeNode] = []
        for entry in scan.entries where entry.parentPath == rootURL.path && !entry.isSymlink {
            let branchFiles = filesByBranch[entry.name] ?? []
            let item = entry.toFileItem(loadTags: false)
            let children = branchFiles.sorted { $0.size > $1.size }.prefix(32).map { leaf in
                WizTreeNode(name: leaf.name, path: leaf.path, url: leaf.url, isDirectory: false,
                    size: leaf.size, fileCount: 1, kindCategory: leaf.kindCategory,
                    modificationDate: leaf.modificationDate, children: [])
            }
            branches.append(WizTreeNode(name: entry.name, path: entry.fullPath, url: item.url,
                isDirectory: entry.isDirectory, size: entry.isDirectory ? branchFiles.reduce(0) { $0 + $1.size } : item.size,
                fileCount: entry.isDirectory ? branchFiles.count : 1, kindCategory: item.kindCategory,
                modificationDate: item.modificationDate, children: entry.isDirectory ? children : []))
        }
        let complete = scan.isComplete && failedHashes == 0
        var messages: [String] = []
        if scan.reachedEntryLimit { messages.append("Wyniki częściowe: osiągnięto limit 60 000 wpisów.") }
        if scan.skippedDirectoryCount > 0 { messages.append("Pominięte katalogi: \(scan.skippedDirectoryCount).") }
        if scan.unreadableDirectoryCount > 0 { messages.append("Nieodczytane katalogi: \(scan.unreadableDirectoryCount).") }
        if failedHashes > 0 { messages.append("Pliki zmienione lub nieodczytane: \(failedHashes).") }
        if !complete && messages.isEmpty { messages.append("Skan niepełny; suma jest dolnym oszacowaniem.") }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        guard !token.isCancelled else { return nil }
        return AnalysisScanResult(branches: branches.sorted { $0.size > $1.size },
            files: files, groups: groups,
            categories: categoryMap.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.1 > $1.1 },
            complete: complete, diagnostic: messages.isEmpty ? nil : messages.joined(separator: " "), elapsed: elapsed)
    }
    static func compare(_ input: AnalysisComparisonInput, token: AnalysisRequestToken) -> AnalysisComparisonResult {
        let result = FolderComparison.compare(left: input.left, right: input.right,
            includeHidden: input.includeHidden, token: token)
        return AnalysisComparisonResult(entries: result.entries, diagnostic: result.diagnostic)
    }
    static func verify(_ groups: [DuplicateFileGroup], token: AnalysisRequestToken) -> AnalysisVerificationResult {
        do {
            if token.isCancelled { throw DuplicateSafetyError.cancelled }
            for group in groups { try DuplicateFileSafety.validate(group, isCancelled: { token.isCancelled }) }
            if token.isCancelled { throw DuplicateSafetyError.cancelled }
            return .verified
        } catch { return .failed(error.localizedDescription) }
    }
}

/// Scheduling entry points used by the UI and the regression fixtures. Hooks
/// pause an admitted physical worker, not the UI or a mock scheduling path.
struct AnalysisWorkHooks: Sendable {
    var beforeWork: @Sendable () -> Void = {}
}
extension AnalysisWorkAdapters {
    @MainActor @discardableResult
    static func startScan(_ input: AnalysisScanInput, consumer: AnalysisWorkService.Consumer,
        token: AnalysisRequestToken, service: AnalysisWorkService,
        hooks: AnalysisWorkHooks = AnalysisWorkHooks(),
        stateChanged: @escaping @MainActor (AnalysisWorkRequest.State) -> Void = { _ in },
        completion: @escaping @MainActor @Sendable (AnalysisScanResult?) -> Void) -> AnalysisWorkRequest {
        service.submit(consumer: consumer, token: token, stateChanged: stateChanged, work: {
            hooks.beforeWork()
            return scan(input, token: token)
        }, completion: completion)
    }
    @MainActor @discardableResult
    static func startComparison(_ input: AnalysisComparisonInput, token: AnalysisRequestToken,
        service: AnalysisWorkService, hooks: AnalysisWorkHooks = AnalysisWorkHooks(),
        stateChanged: @escaping @MainActor (AnalysisWorkRequest.State) -> Void = { _ in },
        completion: @escaping @MainActor @Sendable (AnalysisComparisonResult) -> Void) -> AnalysisWorkRequest {
        service.submit(consumer: .comparison, token: token, stateChanged: stateChanged, work: {
            hooks.beforeWork()
            return compare(input, token: token)
        }, completion: completion)
    }
    @MainActor @discardableResult
    static func startVerification(_ groups: [DuplicateFileGroup], consumer: AnalysisWorkService.Consumer,
        token: AnalysisRequestToken, service: AnalysisWorkService,
        hooks: AnalysisWorkHooks = AnalysisWorkHooks(),
        stateChanged: @escaping @MainActor (AnalysisWorkRequest.State) -> Void = { _ in },
        completion: @escaping @MainActor @Sendable (AnalysisVerificationResult) -> Void) -> AnalysisWorkRequest {
        service.submit(consumer: consumer, token: token, stateChanged: stateChanged, work: {
            hooks.beforeWork()
            return verify(groups, token: token)
        }, completion: completion)
    }
}
