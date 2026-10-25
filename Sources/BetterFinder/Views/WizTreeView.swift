import SwiftUI
import AppKit
import CryptoKit
import Darwin

public struct WizTreeNode: Identifiable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let url: URL
    public let isDirectory: Bool
    public let size: Int64
    public let fileCount: Int
    public let kindCategory: FileKindCategory
    public let modificationDate: Date
    public var children: [WizTreeNode]

    public func toFileItem() -> FileItem {
        FileItem(
            url: url,
            name: name,
            path: path,
            parentPath: url.deletingLastPathComponent().path,
            fileExtension: url.pathExtension.lowercased(),
            isDirectory: isDirectory,
            isHidden: name.hasPrefix("."),
            size: size,
            modificationDate: modificationDate,
            kindCategory: kindCategory
        )
    }
}

public struct DuplicateFileGroup: Identifiable, Sendable {
    public let id: String
    public let sha256: String
    public let fileSize: Int64
    public let files: [FileItem]
    let snapshots: [String: DuplicateFileSnapshot]

    public var wastedBytes: Int64 {
        fileSize * Int64(max(0, files.count - 1))
    }
}

/// Captured input identity, checked against the currently visible owner rather
/// than an obsolete SwiftUI value's ObservedObject reference.
struct AnalysisPublicationContext: Equatable, Sendable {
    let paneID: UUID
    let side: PaneSide
    let rootPath: String
    let revision: UInt64
    let hidden: Bool
    let mode: String

    @MainActor init(pane: PaneTabState, side: PaneSide, mode: WizTreeSubMode) {
        paneID = pane.id
        self.side = side
        rootPath = pane.currentURL.path
        revision = pane.directoryRevision
        hidden = pane.showHiddenFiles
        self.mode = mode.rawValue
    }

    @MainActor func matches(appState: AppState, mode: WizTreeSubMode) -> Bool {
        let live: PaneTabState?
        switch side {
        case .left: live = appState.tabs.first { $0.id == appState.activeTabId } ?? appState.tabs.first
        case .right: live = appState.isDualPane ? appState.rightPane : nil
        }
        guard let live, live.viewMode == .wiztree, live.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return self == AnalysisPublicationContext(pane: live, side: side, mode: mode)
    }
}

// A generation is cancelled on every root/mode change, refresh and disappearance.
// The same predicate protects all publication paths, including empty results.
final class AnalysisRequestToken: @unchecked Sendable {
    let id = UUID()
    let rootPath: String
    let context: AnalysisPublicationContext?
    private let lock = NSLock()
    private var cancelled = false
    init(rootPath: String, context: AnalysisPublicationContext? = nil) {
        self.rootPath = rootPath
        self.context = context
    }
    @MainActor func canPublishAnalysis(active: AnalysisRequestToken?, appState: AppState, mode: WizTreeSubMode) -> Bool {
        active === self && !isCancelled && context?.matches(appState: appState, mode: mode) == true
    }
    func canUseAnalysisResult(active: AnalysisRequestToken?, resultReady: Bool,
                              isComplete: Bool, requiresComplete: Bool) -> Bool {
        active === self && !isCancelled && resultReady && (!requiresComplete || isComplete)
    }
    func canPublishVerification(active: AnalysisRequestToken?, scan: AnalysisRequestToken,
                                activeScan: AnalysisRequestToken?) -> Bool {
        active === self && !isCancelled && scan === activeScan && !scan.isCancelled
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func canPublish(active: AnalysisRequestToken?, rootPath: String) -> Bool {
        active === self && self.rootPath == rootPath && !isCancelled
    }
}

struct DuplicateFileSnapshot: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let generation: UInt32
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ info: stat) throws {
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw DuplicateSafetyError.changed }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        generation = UInt32(info.st_gen)
        size = Int64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }
}

enum DuplicateSafetyError: LocalizedError {
    case changed, unreadable, cancelled
    var errorDescription: String? {
        switch self {
        case .changed: return "Plik lub zachowywany oryginał zmienił się. Nic więcej nie usunięto; wykonaj nowy skan."
        case .unreadable: return "Nie można bezpiecznie odczytać pliku. Wykonaj nowy skan."
        case .cancelled: return "Skanowanie anulowano."
        }
    }
}

struct DuplicateHashHooks {
    var beforeSnapshot: (() throws -> Void)? = nil
    var beforeOpen: (() throws -> Void)? = nil
    var afterChunk: ((Int) throws -> Void)? = nil
    var readChunk: ((Int32, UnsafeMutableRawPointer, Int) -> Int)? = nil
}

/// Full streaming SHA-256 bounded to the captured size; no symlink/special-file reads.
/// Snapshot checks detect replacement and writes during or after hashing. A filesystem
/// can still change between the final check and a path-based Trash operation; this is
/// not a transactional filesystem lock and does not claim to prevent hostile races.
enum DuplicateFileSafety {
    static func snapshot(at url: URL) throws -> DuplicateFileSnapshot {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw DuplicateSafetyError.unreadable }
        return try DuplicateFileSnapshot(info)
    }

    static func hash(at url: URL, isCancelled: () -> Bool = { false },
                     hooks: DuplicateHashHooks = DuplicateHashHooks()) throws -> (hash: String, snapshot: DuplicateFileSnapshot) {
        if isCancelled() { throw DuplicateSafetyError.cancelled }
        try hooks.beforeSnapshot?()
        let before = try snapshot(at: url)
        guard before.size >= 0 else { throw DuplicateSafetyError.changed }
        try hooks.beforeOpen?()
        if isCancelled() { throw DuplicateSafetyError.cancelled }
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DuplicateSafetyError.unreadable }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, try DuplicateFileSnapshot(info) == before else { throw DuplicateSafetyError.changed }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var remaining = before.size
        var chunks = 0
        while remaining > 0 {
            if isCancelled() { throw DuplicateSafetyError.cancelled }
            let amount = Int(min(remaining, Int64(buffer.count)))
            let count = buffer.withUnsafeMutableBytes { bytes in
                hooks.readChunk?(fd, bytes.baseAddress!, amount) ?? Darwin.read(fd, bytes.baseAddress!, amount)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw DuplicateSafetyError.unreadable
            }
            guard count > 0 else { throw DuplicateSafetyError.changed }
            remaining -= Int64(count)
            chunks += 1
            try hooks.afterChunk?(chunks)
            digest.update(data: Data(buffer.prefix(count)))
        }
        if isCancelled() { throw DuplicateSafetyError.cancelled }
        guard fstat(fd, &info) == 0, try DuplicateFileSnapshot(info) == before,
              try snapshot(at: url) == before else { throw DuplicateSafetyError.changed }
        if isCancelled() { throw DuplicateSafetyError.cancelled }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), before)
    }

    static func validate(_ group: DuplicateFileGroup, isCancelled: () -> Bool = { false }) throws {
        guard group.files.count > 1, group.snapshots.count == group.files.count else { throw DuplicateSafetyError.changed }
        var identities = Set<String>()
        for item in group.files {
            let current = try hash(at: item.url, isCancelled: isCancelled)
            guard current.hash == group.sha256, current.snapshot == group.snapshots[item.path],
                  identities.insert("\(current.snapshot.device):\(current.snapshot.inode)").inserted else {
                throw DuplicateSafetyError.changed
            }
        }
    }

    // Called immediately before each candidate enters the Trash, not just once per scan.
    static func validateBeforeTrash(_ item: FileItem, in group: DuplicateFileGroup) throws {
        guard let keeper = group.files.first, keeper.path != item.path,
              let kept = group.snapshots[keeper.path], let candidate = group.snapshots[item.path],
              try snapshot(at: keeper.url) == kept,
              try snapshot(at: item.url) == candidate else { throw DuplicateSafetyError.changed }
    }

    static func groups(from entries: [IndexedFileEntry], token: AnalysisRequestToken) -> (groups: [DuplicateFileGroup], failed: Int) {
        var bySize: [Int64: [IndexedFileEntry]] = [:]
        for entry in entries where !entry.isDirectory && !entry.isSymlink {
            bySize[entry.size, default: []].append(entry)
        }
        var groups: [DuplicateFileGroup] = []
        var failed = 0
        for sameSize in bySize.values where sameSize.count > 1 {
            var byHash: [String: [(FileItem, DuplicateFileSnapshot)]] = [:]
            var seenIdentities = Set<String>()
            for entry in sameSize.sorted(by: { $0.fullPath < $1.fullPath }) {
                if token.isCancelled { return ([], failed) }
                do {
                    let item = entry.toFileItem(loadTags: false)
                    let result = try hash(at: item.url, isCancelled: { token.isCancelled })
                    guard result.snapshot.size == entry.size else { failed += 1; continue }
                    // Hard links are one physical file, not reclaimable duplicate storage.
                    guard seenIdentities.insert("\(result.snapshot.device):\(result.snapshot.inode)").inserted else { continue }
                    byHash[result.hash, default: []].append((item, result.snapshot))
                } catch { failed += 1 }
            }
            for (hash, pairs) in byHash where pairs.count > 1 {
                groups.append(DuplicateFileGroup(id: hash, sha256: hash, fileSize: pairs[0].1.size,
                    files: pairs.map { $0.0 }, snapshots: Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.path, $0.1) })))
            }
        }
        return (groups.sorted { $0.wastedBytes > $1.wastedBytes }, failed)
    }
}

public struct TreemapPlacedBlock: Identifiable {
    public let id: String
    public let node: WizTreeNode
    public let rect: CGRect
    public let isGroupContainer: Bool
    public let parentFolderName: String?
}

/// Squarified Treemap Algorithm (Bruls, Huizing, van Wijk) for WizTree-style rectangular visualization
public enum SquarifiedTreemapLayout {
    public static func computeHierarchicalBlocks(
        nodes: [WizTreeNode],
        in bounds: CGRect,
        maxBlocks: Int = 65
    ) -> [TreemapPlacedBlock] {
        guard bounds.width > 16, bounds.height > 16, !nodes.isEmpty else { return [] }
        let positiveNodes = Array(nodes.filter { $0.size > 0 }.prefix(maxBlocks))
        guard !positiveNodes.isEmpty else { return [] }

        let topRects = squarify(nodes: positiveNodes, in: bounds.insetBy(dx: 2, dy: 2))
        var result: [TreemapPlacedBlock] = []

        for (node, rect) in topRects {
            guard rect.width >= 4 && rect.height >= 4 else { continue }
            let insetRect = rect.insetBy(dx: 1.5, dy: 1.5)
            guard insetRect.width >= 3 && insetRect.height >= 3 else { continue }

            if node.isDirectory && !node.children.isEmpty && insetRect.width > 46 && insetRect.height > 38 {
                result.append(TreemapPlacedBlock(
                    id: "group:\(node.path)",
                    node: node,
                    rect: insetRect,
                    isGroupContainer: true,
                    parentFolderName: nil
                ))
                let headerHeight: CGFloat = min(18, max(14, insetRect.height * 0.16))
                let innerRect = CGRect(
                    x: insetRect.minX + 3,
                    y: insetRect.minY + headerHeight + 2,
                    width: insetRect.width - 6,
                    height: insetRect.height - headerHeight - 5
                )
                if innerRect.width > 12 && innerRect.height > 12 {
                    let subChildren = Array(node.children.filter { $0.size > 0 }.prefix(28))
                    let childRects = squarify(nodes: subChildren, in: innerRect)
                    for (child, cRect) in childRects where cRect.width >= 4 && cRect.height >= 4 {
                        result.append(TreemapPlacedBlock(
                            id: child.path,
                            node: child,
                            rect: cRect.insetBy(dx: 1, dy: 1),
                            isGroupContainer: false,
                            parentFolderName: node.name
                        ))
                    }
                }
            } else {
                result.append(TreemapPlacedBlock(
                    id: node.path,
                    node: node,
                    rect: insetRect,
                    isGroupContainer: false,
                    parentFolderName: nil
                ))
            }
        }
        return result
    }

    private static func squarify(nodes: [WizTreeNode], in rect: CGRect) -> [(WizTreeNode, CGRect)] {
        let totalSize = nodes.reduce(0.0) { $0 + Double(max(1, $1.size)) }
        guard totalSize > 0, rect.width > 1, rect.height > 1 else { return [] }

        let totalArea = Double(rect.width * rect.height)
        let scaledAreas = nodes.map { Double(max(1, $0.size)) / totalSize * totalArea }

        var output: [(WizTreeNode, CGRect)] = []
        output.reserveCapacity(nodes.count)

        var currentRect = rect
        var rowIndices: [Int] = []
        var rowAreaSum: Double = 0

        for idx in nodes.indices {
            let area = scaledAreas[idx]
            if rowIndices.isEmpty {
                rowIndices.append(idx)
                rowAreaSum = area
                continue
            }

            let shortSide = Double(min(currentRect.width, currentRect.height))
            let currentWorst = worstAspectRatio(
                rowIndices: rowIndices,
                areas: scaledAreas,
                rowAreaSum: rowAreaSum,
                sideLength: shortSide
            )
            var candidateRow = rowIndices
            candidateRow.append(idx)
            let nextWorst = worstAspectRatio(
                rowIndices: candidateRow,
                areas: scaledAreas,
                rowAreaSum: rowAreaSum + area,
                sideLength: shortSide
            )

            if nextWorst <= currentWorst {
                rowIndices.append(idx)
                rowAreaSum += area
            } else {
                currentRect = layoutRow(
                    rowIndices: rowIndices,
                    nodes: nodes,
                    areas: scaledAreas,
                    rowAreaSum: rowAreaSum,
                    in: currentRect,
                    output: &output
                )
                rowIndices = [idx]
                rowAreaSum = area
            }
        }

        if !rowIndices.isEmpty {
            _ = layoutRow(
                rowIndices: rowIndices,
                nodes: nodes,
                areas: scaledAreas,
                rowAreaSum: rowAreaSum,
                in: currentRect,
                output: &output
            )
        }

        return output
    }

    private static func worstAspectRatio(
        rowIndices: [Int],
        areas: [Double],
        rowAreaSum: Double,
        sideLength: Double
    ) -> Double {
        guard sideLength > 0, rowAreaSum > 0 else { return .greatestFiniteMagnitude }
        var minArea = Double.greatestFiniteMagnitude
        var maxArea = 0.0
        for i in rowIndices {
            let a = areas[i]
            if a < minArea { minArea = a }
            if a > maxArea { maxArea = a }
        }
        guard minArea > 0 else { return .greatestFiniteMagnitude }
        let s2 = rowAreaSum * rowAreaSum
        let w2 = sideLength * sideLength
        return max((w2 * maxArea) / s2, s2 / (w2 * minArea))
    }

    private static func layoutRow(
        rowIndices: [Int],
        nodes: [WizTreeNode],
        areas: [Double],
        rowAreaSum: Double,
        in rect: CGRect,
        output: inout [(WizTreeNode, CGRect)]
    ) -> CGRect {
        guard rect.width > 0, rect.height > 0, rowAreaSum > 0 else { return rect }
        let horizontalSplit = rect.width >= rect.height

        if horizontalSplit {
            // Stack items vertically in a strip of width `stripWidth` on the left of `rect`
            let stripWidth = CGFloat(min(Double(rect.width), rowAreaSum / Double(rect.height)))
            var yCursor = rect.minY
            for i in rowIndices {
                let itemHeight = stripWidth > 0 ? CGFloat(areas[i]) / stripWidth : 0
                let itemRect = CGRect(x: rect.minX, y: yCursor, width: stripWidth, height: max(0, itemHeight))
                output.append((nodes[i], itemRect))
                yCursor += itemHeight
            }
            return CGRect(
                x: rect.minX + stripWidth,
                y: rect.minY,
                width: max(0, rect.width - stripWidth),
                height: rect.height
            )
        } else {
            // Stack items horizontally in a strip of height `stripHeight` on the top of `rect`
            let stripHeight = CGFloat(min(Double(rect.height), rowAreaSum / Double(rect.width)))
            var xCursor = rect.minX
            for i in rowIndices {
                let itemWidth = stripHeight > 0 ? CGFloat(areas[i]) / stripHeight : 0
                let itemRect = CGRect(x: xCursor, y: rect.minY, width: max(0, itemWidth), height: stripHeight)
                output.append((nodes[i], itemRect))
                xCursor += itemWidth
            }
            return CGRect(
                x: rect.minX,
                y: rect.minY + stripHeight,
                width: rect.width,
                height: max(0, rect.height - stripHeight)
            )
        }
    }
}

public enum WizTreeSubMode: String, CaseIterable, Identifiable, Sendable {
    case treemap = "WizTree Treemap & Drzewo"
    case largestFiles = "Największe pliki"
    case duplicates = "Duplikaty (SHA-256)"

    public var id: String { rawValue }
}

/// Shared production projection builder: keyboard selection uses displayed rows
/// and rendered tiles, never an arbitrary last-clicked singleton or hidden subtree.
enum WizTreeSelectionProjection {
    static func items(mode: WizTreeSubMode, branches: [WizTreeNode], largestFiles: [FileItem],
                      duplicateGroups: [DuplicateFileGroup], visibleBlocks: [TreemapPlacedBlock] = []) -> [FileItem] {
        let candidates: [FileItem]
        switch mode {
        case .treemap: candidates = branches.map { $0.toFileItem() } + visibleBlocks.map { $0.node.toFileItem() }
        case .largestFiles: candidates = largestFiles
        case .duplicates: candidates = duplicateGroups.flatMap(\.files)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.path).inserted }
    }
}

public struct WizTreeAnalyzerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var pane: PaneTabState
    public let paneSide: PaneSide
    private let selectionBackgroundColor: Color
    private let selectionForegroundColor: Color
    @ObservedObject private var iconCache = FileIconCache.shared
    @ObservedObject private var fileOps = FileOperationsManager.shared

    @ViewState private var subMode: WizTreeSubMode = .treemap
    @ViewState private var isScanning: Bool = false
    @ViewState private var scanDurationMs: Double = 0
    @ViewState private var totalScannedBytes: Int64 = 0
    @ViewState private var totalScannedFiles: Int = 0
    @ViewState private var topBranches: [WizTreeNode] = []
    @ViewState private var largestFiles: [FileItem] = []
    @ViewState private var categoryStats: [(FileKindCategory, Int64, Int)] = []
    @ViewState private var duplicateGroups: [DuplicateFileGroup] = []
    @ViewState private var scanToken: AnalysisRequestToken?
    @ViewState private var scanTask: AnalysisWorkRequest?
    @ViewState private var verificationTask: AnalysisWorkRequest?
    @ViewState private var verificationToken: AnalysisRequestToken?
    @ViewState private var cleanupID: UUID?
    @ViewState private var cleanupCancelRequested = false
    @ViewState private var scanWorkState: AnalysisWorkRequest.State = .finished
    @ViewState private var verificationWorkState: AnalysisWorkRequest.State = .finished
    @ViewState private var scanIsComplete = false
    @ViewState private var scanDiagnostic: String?
    @ViewState private var duplicateActionError: String?
    @ViewState private var isValidatingDuplicates = false
    @ViewState private var hoveredBlock: TreemapPlacedBlock? = nil

    public init(
        appState: AppState,
        pane: PaneTabState,
        paneSide: PaneSide,
        selectionBackgroundColor: Color,
        selectionForegroundColor: Color
    ) {
        self.appState = appState
        self.pane = pane
        self.paneSide = paneSide
        self.selectionBackgroundColor = selectionBackgroundColor
        self.selectionForegroundColor = selectionForegroundColor
    }

    private var livePaneID: UUID? {
        switch paneSide {
        case .left: return (appState.tabs.first { $0.id == appState.activeTabId } ?? appState.tabs.first)?.id
        case .right: return appState.isDualPane ? appState.rightPane.id : nil
        }
    }

    private func performPaneAction(_ action: () -> Void) {
        guard livePaneID == pane.id else { return }
        FinderPaneActionRouting.perform(appState: appState, paneSide: paneSide, action: action)
    }

    private func selectAnalyzedItem(_ item: FileItem, generation: AnalysisRequestToken?) {
        guard canUseRenderedResult(generation, requiresComplete: false) else { return }
        performPaneAction {
            pane.setAnalysisSelection([item], rootPath: pane.currentURL.path)
        }
    }

    private func openAnalyzedNode(_ node: WizTreeNode) {
        performPaneAction {
            if node.isDirectory {
                pane.navigate(to: node.url)
            } else {
                NSWorkspace.shared.open(node.url)
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top WizTree Control & Telemetry Bar
            analyzerHeaderBar

            Divider()

            // Category Distribution Strip
            if !categoryStats.isEmpty {
                categoryBreakdownStrip
                Divider()
            }

            if let diagnostic = scanDiagnostic {
                analysisNotice(diagnostic)
            }
            if let error = duplicateActionError {
                analysisNotice(error, isError: true)
            }
            Text("Zakres: \(pane.showHiddenFiles ? "z ukrytymi plikami" : "bez ukrytych plików"), bez śledzenia dowiązań. Limit: 60 000 wpisów.")
                .font(FinderUI.captionFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FinderUI.sectionSpacing)
                .padding(.vertical, FinderUI.compactSpacing)
            // Main Content
            if isScanning {
                VStack(spacing: FinderUI.rowSpacing) {
                    ProgressView()
                        .controlSize(.regular)
                        .accessibilityLabel("Skanowanie folderu")
                    Text(scanWorkState == .queued ? "Skan oczekuje na wolne miejsce…" : (subMode == .duplicates ? "Skanowanie i weryfikacja plików…" : "Skanowanie folderu…"))
                        .font(FinderUI.titleFont)
                    Text(pane.currentURL.path)
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .multilineTextAlignment(.center)
                .padding(FinderUI.sheetPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if scanWorkState == .deferred || scanWorkState == .cancelled || scanWorkState == .cancelling {
                analysisEmptyState(
                    title: scanWorkState == .deferred ? "Analiza odroczona" : "Analiza anulowana",
                    message: "Brak aktualnego wyniku. Użyj odświeżania, aby rozpocząć nowy skan.",
                    systemImage: "pause.circle"
                )
            } else {
                switch subMode {
                case .treemap:
                    if topBranches.isEmpty {
                        analysisEmptyState(
                            title: scanIsComplete ? "Brak elementów do analizy" : "Brak danych w sprawdzonym zakresie",
                            message: "Sprawdź zakres skanowania lub wybierz inny folder.",
                            systemImage: "chart.pie"
                        )
                    } else {
                        wizTreeSplitWorkspace
                    }
                case .largestFiles:
                    if largestFiles.isEmpty {
                        analysisEmptyState(
                            title: scanIsComplete ? "Brak plików do wyświetlenia" : "Brak plików w sprawdzonym zakresie",
                            message: "Skan nie znalazł zwykłych plików. Dowiązania symboliczne nie są uwzględniane.",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    } else {
                        largestFilesTableView
                    }
                case .duplicates:
                    duplicatesScannerView
                }
            }
        }
        .onAppear {
            runActiveScan(for: pane.currentURL)
        }
        .onChange(of: subMode) { _, _ in
            performPaneAction { runActiveScan(for: pane.currentURL) }
        }
        .onChange(of: livePaneID) { _, _ in
            cancelCleanupForOwnerChange()
            scanToken?.cancel()
            scanTask?.cancel()
            verificationTask?.cancel()
            verificationToken = nil
            if livePaneID == pane.id { runActiveScan(for: pane.currentURL) }
        }
        .onChange(of: pane.id) { _, _ in runActiveScan(for: pane.currentURL) }
        .onChange(of: pane.currentURL.path) { _, _ in runActiveScan(for: pane.currentURL) }
        .onChange(of: pane.showHiddenFiles) { _, _ in runActiveScan(for: pane.currentURL) }
        .onChange(of: pane.directoryRevision) { _, _ in runActiveScan(for: pane.currentURL) }
        .onDisappear {
            cancelCleanupForOwnerChange()
            scanToken?.cancel()
            scanTask?.cancel()
            verificationTask?.cancel()
            verificationToken = nil
            pane.clearAnalysisSelection()
        }
    }

    // MARK: - Top Control Bar

    private var analyzerHeaderBar: some View {
        VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FinderUI.sectionSpacing) {
                    analyzerTitle
                    analysisModePicker
                        .pickerStyle(.segmented)
                        .frame(width: 420)
                    Spacer(minLength: 0)
                    refreshScanButton
                }
                VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
                    HStack {
                        analyzerTitle
                        Spacer()
                        refreshScanButton
                    }
                    analysisModePicker
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if isScanning {
                HStack {
                    Text(scanWorkState == .queued ? "Skan w kolejce…" : "Skanowanie…")
                        .font(FinderUI.captionFont)
                    Button("Anuluj skan") { cancelScan() }.controlSize(.small)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FinderUI.rowSpacing) { analysisTelemetry }
                VStack(alignment: .leading, spacing: FinderUI.compactSpacing) { analysisTelemetry }
            }
            .font(FinderUI.captionFont)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, FinderUI.sectionSpacing)
        .padding(.vertical, FinderUI.rowSpacing)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var analyzerTitle: some View {
        Label("Analiza miejsca", systemImage: "square.grid.3x1.below.line.grid.1x2.fill")
            .font(FinderUI.titleFont)
            .fixedSize()
    }

    private var analysisModePicker: some View {
        Picker("Tryb analizy", selection: $subMode) {
            ForEach(WizTreeSubMode.allCases) { mode in
                Text(analysisModeTitle(mode)).tag(mode)
            }
        }
        .labelsHidden()
        .accessibilityLabel("Tryb analizy miejsca")
        .help("Wybierz mapę miejsca, największe pliki lub duplikaty")
    }

    private func analysisModeTitle(_ mode: WizTreeSubMode) -> String {
        switch mode {
        case .treemap: return "Mapa i drzewo"
        case .largestFiles: return "Największe pliki"
        case .duplicates: return "Duplikaty"
        }
    }

    @ViewBuilder
    private var analysisTelemetry: some View {
        Text("\(scanIsComplete ? "Łącznie" : "Co najmniej"): \(FormatHelpers.formatBytes(totalScannedBytes))")
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .fixedSize()
        Text("Pliki: \(totalScannedFiles.formatted())")
            .fixedSize()
        if scanDurationMs > 0 {
            Text("Czas: \(FormatHelpers.formatLatency(scanDurationMs))")
                .fixedSize()
        }
    }

    private var refreshScanButton: some View {
        Button {
            performPaneAction { runActiveScan(for: pane.currentURL) }
        } label: {
            Label("Odśwież skan", systemImage: "arrow.clockwise")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Odśwież analizę miejsca")
        .accessibilityLabel("Odśwież analizę miejsca")
    }

    private func analysisNotice(_ message: String, isError: Bool = false) -> some View {
        Label(message, systemImage: isError ? "exclamationmark.circle" : "exclamationmark.triangle")
            .font(FinderUI.captionFont)
            .foregroundStyle(isError ? Color.red : Color.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FinderUI.sectionSpacing)
            .padding(.vertical, FinderUI.rowSpacing)
            .accessibilityElement(children: .combine)
    }

    private func analysisEmptyState(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: FinderUI.rowSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(FinderUI.titleFont)
            Text(message)
                .font(FinderUI.detailFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button("Skanuj ponownie") { performPaneAction { runActiveScan(for: pane.currentURL) } }
        }
        .multilineTextAlignment(.center)
        .padding(FinderUI.sheetPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Category Legend & Proportional Bar

    private var categoryBreakdownStrip: some View {
        VStack(spacing: 6) {
            // Proportional Multi-Color Bar
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(categoryStats, id: \.0.rawValue) { cat, bytes, _ in
                        let frac = totalScannedBytes > 0 ? CGFloat(bytes) / CGFloat(totalScannedBytes) : 0
                        if frac > 0.005 {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(cat.treemapColor.gradient)
                                .frame(width: max(4, geo.size.width * frac))
                        }
                    }
                }
            }
            .frame(height: 7)

            // Legend Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(categoryStats.prefix(7), id: \.0.rawValue) { cat, bytes, count in
                        let pct = totalScannedBytes > 0 ? Double(bytes) * 100.0 / Double(totalScannedBytes) : 0
                        HStack(spacing: 5) {
                            Circle()
                                .fill(cat.treemapColor)
                                .frame(width: 8, height: 8)
                            Text(cat.rawValue)
                                .font(FinderUI.captionFont.weight(.semibold))
                            Text("\(FormatHelpers.formatBytes(bytes)) (\(String(format: "%.1f%%", pct)))")
                                .font(FinderUI.captionFont)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text("Pliki: \(count)")
                                .font(FinderUI.captionFont)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    // MARK: - Split Workspace: Ranked Tree Table + Interactive Squarified Treemap

    private var wizTreeSplitWorkspace: some View {
        VStack(spacing: 0) {
            // Optional detail columns collapse in narrow panes, like the file list.
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(topBranches.enumerated()), id: \.element.id) { index, node in
                            rankedBranchRow(node, index: index, availableWidth: geometry.size.width)
                        }
                    }
                }
            }
            .frame(height: 175)

            Divider()

            // Interactive Squarified Treemap Canvas
            VStack(spacing: 0) {
                // Live Hover / Selection HUD Bar
                treemapHudBar

                GeometryReader { geo in
                    let blocks = SquarifiedTreemapLayout.computeHierarchicalBlocks(
                        nodes: topBranches,
                        in: CGRect(origin: .zero, size: geo.size)
                    )
                    let generation = scanToken
                    ZStack(alignment: .topLeading) {
                        if blocks.isEmpty {
                            Text(topBranches.allSatisfy { $0.size == 0 } ? "Brak zajętego miejsca do przedstawienia na mapie." : "Powiększ panel, aby wyświetlić mapę miejsca.")
                                .font(FinderUI.detailFont)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(FinderUI.sectionSpacing)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        ForEach(blocks) { block in
                            treemapBlockView(block)
                        }
                    }
                    .onAppear { publishTreemapProjection(blocks, token: generation) }
                    .onChange(of: blocks.map(\.id)) { _, _ in
                        publishTreemapProjection(blocks, token: generation)
                    }
                }
                .padding(6)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
            }
        }
    }

    private func rankedBranchRow(_ node: WizTreeNode, index: Int, availableWidth: CGFloat) -> some View {
        let generation = scanToken
        let fraction = totalScannedBytes > 0 ? Double(node.size) / Double(totalScannedBytes) : 0
        let isSelected = pane.selectedPaths.contains(node.path)

        return HStack(spacing: FinderUI.rowSpacing) {
            Image(nsImage: iconCache.icon(for: node.toFileItem(), preferThumbnail: false))
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            Text(node.name)
                .font(FinderUI.detailFont.weight(node.isDirectory ? .semibold : .regular))
                .foregroundStyle(isSelected ? selectionForegroundColor : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if availableWidth >= 650 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.07))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(node.kindCategory.treemapColor.gradient)
                            .frame(width: max(3, geometry.size.width * CGFloat(fraction)))
                    }
                }
                .frame(width: 140, height: 11)
                .accessibilityHidden(true)
            }
            if availableWidth >= 480 {
                Text(String(format: "%5.1f%%", fraction * 100.0))
                    .font(FinderUI.captionFont)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            Text(FormatHelpers.formatBytes(node.size))
                .font(FinderUI.captionFont.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isSelected ? selectionForegroundColor : Color.primary)
                .frame(width: 90, alignment: .trailing)
            if availableWidth >= 760 {
                Text("Pliki: \(node.fileCount)")
                    .font(FinderUI.captionFont)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
                    .frame(width: 85, alignment: .trailing)
            }
        }
        .padding(.horizontal, FinderUI.sectionSpacing)
        .padding(.vertical, 5)
        .background(isSelected ? selectionBackgroundColor : (index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025)))
        .contentShape(Rectangle())
        .help(node.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction {
            selectAnalyzedItem(node.toFileItem(), generation: generation)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                openAnalyzedNode(node)
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                selectAnalyzedItem(node.toFileItem(), generation: generation)
            }
        )
    }

    private var treemapHudBar: some View {
        HStack(spacing: 8) {
            if let hov = hoveredBlock {
                Circle()
                    .fill(hov.node.kindCategory.treemapColor)
                    .frame(width: 9, height: 9)
                Text(hov.node.name)
                    .font(FinderUI.detailFont.weight(.semibold))
                    .lineLimit(1)
                if let parent = hov.parentFolderName {
                    Text("w \(parent)/")
                        .font(FinderUI.captionFont)
                        .foregroundStyle(.secondary)
                }
                Text("· \(FormatHelpers.formatBytes(hov.node.size))")
                    .font(FinderUI.captionFont.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                if totalScannedBytes > 0 {
                    let pct = Double(hov.node.size) * 100.0 / Double(totalScannedBytes)
                    Text("(\(String(format: "%.1f%%", pct)))")
                        .font(FinderUI.captionFont)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "hand.point.up.left.fill")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                Text("Najedź na mapę, aby zobaczyć szczegóły. Kliknij element, aby otworzyć Inspektor, lub kliknij dwukrotnie folder, aby go otworzyć.")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4.5)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private func treemapBlockView(_ block: TreemapPlacedBlock) -> some View {
        let generation = scanToken
        let isHovered = (hoveredBlock?.id == block.id)
        let isSelected = pane.selectedPaths.contains(block.node.path)
        let baseColor = block.node.kindCategory.treemapColor

        if block.isGroupContainer {
            // Folder Group Container Frame (WizTree style)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isSelected ? Color.white : baseColor.opacity(0.55),
                        lineWidth: isSelected ? 2 : 1
                    )
                if block.rect.width > 55 {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(baseColor)
                        Text("\(block.node.name) · \(FormatHelpers.formatBytes(block.node.size))")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 5)
                    .padding(.top, 2)
                }
            }
            .frame(width: block.rect.width, height: block.rect.height)
            .offset(x: block.rect.minX, y: block.rect.minY)
            .onTapGesture(count: 2) {
                openAnalyzedNode(block.node)
            }
            .help("\(block.node.path) · \(FormatHelpers.formatBytes(block.node.size))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Folder \(block.node.name), \(FormatHelpers.formatBytes(block.node.size))")
            .accessibilityAction(named: Text("Otwórz folder")) { openAnalyzedNode(block.node) }
        } else {
            // Individual File or Leaf Folder Tile
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        LinearGradient(
                            colors: [
                                baseColor.opacity(isHovered ? 0.92 : 0.78),
                                baseColor.opacity(isHovered ? 0.72 : 0.52)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isSelected || isHovered ? Color.white : Color.white.opacity(0.22),
                        lineWidth: isSelected ? 2.0 : (isHovered ? 1.5 : 0.6)
                    )

                if block.rect.width > 42 && block.rect.height > 24 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(block.node.name)
                            .font(.system(size: block.rect.width > 90 ? 11 : 9.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 1)

                        if block.rect.height > 36 {
                            Text(FormatHelpers.formatBytes(block.node.size))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                        }
                    }
                    .padding(5)
                }
            }
            .frame(width: block.rect.width, height: block.rect.height)
            .offset(x: block.rect.minX, y: block.rect.minY)
            .help("\(block.node.path) · \(FormatHelpers.formatBytes(block.node.size))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(block.node.name), \(FormatHelpers.formatBytes(block.node.size))")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction {
                selectAnalyzedItem(block.node.toFileItem(), generation: generation)
            }
            .onHover { hovering in
                if hovering {
                    hoveredBlock = block
                } else if hoveredBlock?.id == block.id {
                    hoveredBlock = nil
                }
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    openAnalyzedNode(block.node)
                }
            )
            .simultaneousGesture(
                TapGesture(count: 1).onEnded {
                    selectAnalyzedItem(block.node.toFileItem(), generation: generation)
                }
            )
            .contextMenu {
                if block.node.isDirectory {
                    Button {
                        openAnalyzedNode(block.node)
                    } label: {
                        Label("Otwórz folder w analizie", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                }
                Button {
                    performPaneAction {
                        if pane.navigate(to: block.node.isDirectory ? block.node.url : block.node.url.deletingLastPathComponent()) {
                            pane.viewMode = .list
                            pane.selectedPaths = [block.node.path]
                        }
                    }
                } label: {
                    Label("Pokaż na liście plików", systemImage: "list.bullet")
                }
                Button {
                    performPaneAction { QuickLookCoordinator.shared.preview(ownerID: pane.id, urls: [block.node.url]) }
                } label: {
                    Label("Quick Look (Spacja)", systemImage: "eye")
                }
                Button {
                    performPaneAction { FileOperationsManager.shared.openInTerminal(at: block.node.url) }
                } label: {
                    Label("Otwórz w Terminalu", systemImage: "terminal")
                }
                Divider()
                Button(role: .destructive) {
                    performPaneAction { trashAnalyzedItem(block.node.toFileItem(), generation: generation) }
                } label: {
                    Label("Przenieś do Kosza", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Largest Files Table View

    private var largestFilesTableView: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(largestFiles.enumerated()), id: \.element.id) { index, item in
                        largestFileRow(item, index: index, availableWidth: geometry.size.width)
                    }
                }
            }
        }
    }

    private func largestFileRow(_ item: FileItem, index: Int, availableWidth: CGFloat) -> some View {
        let generation = scanToken
        let percent = totalScannedBytes > 0 ? Double(item.size) * 100.0 / Double(totalScannedBytes) : 0
        let isSelected = pane.selectedPaths.contains(item.path)

        return HStack(spacing: FinderUI.rowSpacing) {
            if availableWidth >= 540 {
                Text("#\(index + 1)")
                    .font(FinderUI.captionFont.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            Image(nsImage: iconCache.icon(for: item))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text(item.name)
                    .font(FinderUI.bodyFont.weight(.medium))
                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.parentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(FinderUI.captionFont)
                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if availableWidth >= 680 {
                Text(String(format: "%.1f%%", percent))
                    .font(FinderUI.captionFont)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
            }
            Text(FormatHelpers.formatBytes(item.size))
                .font(FinderUI.detailFont.weight(.semibold))
                .foregroundStyle(isSelected ? selectionForegroundColor : Color.primary)
                .monospacedDigit()
                .frame(width: 85, alignment: .trailing)
            Button(role: .destructive) {
                performPaneAction { trashAnalyzedItem(item, generation: generation) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.red)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Przenieś do Kosza: \(item.name)")
            .accessibilityLabel("Przenieś do Kosza: \(item.name)")
        }
        .padding(.horizontal, FinderUI.sectionSpacing)
        .padding(.vertical, 6)
        .background(isSelected ? selectionBackgroundColor : (index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025)))
        .contentShape(Rectangle())
        .help(item.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Zaznacz")) {
            selectAnalyzedItem(item, generation: generation)
        }
        .onTapGesture { selectAnalyzedItem(item, generation: generation) }
    }

    // MARK: - Duplicate Files View (SHA-256)

    private var duplicatesScannerView: some View {
        VStack(spacing: 0) {
            if duplicateGroups.isEmpty {
                analysisEmptyState(
                    title: scanIsComplete ? "Nie znaleziono duplikatów w przeskanowanym zakresie" : "Nie znaleziono duplikatów w częściowo sprawdzonym zakresie",
                    message: "Porównano pełną treść plików metodą SHA-256, także pliki puste i duże. Dowiązania symboliczne nie są śledzone. Ukryte pliki zależą od ustawienia widoku.",
                    systemImage: scanIsComplete ? "checkmark.seal" : "exclamationmark.triangle"
                )
            } else {
                duplicateSummary
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
                        ForEach(duplicateGroups) { group in
                            duplicateGroupCard(group)
                        }
                    }
                    .padding(FinderUI.sectionSpacing)
                }
            }
        }
    }

    private var duplicateSummary: some View {
        let generation = scanToken
        let groups = duplicateGroups
        let cleanupIsCancelling = cleanupCancelRequested || (cleanupID != nil
            && fileOps.activeDuplicateCleanupID == cleanupID && fileOps.activeTransfer?.isCancellable == false)
        let totalWasted = groups.reduce(Int64(0)) { $0 + $1.wastedBytes }
        return VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
            Text("Grupy duplikatów: \(duplicateGroups.count) · Nadmiarowe dane logiczne: \(FormatHelpers.formatBytes(totalWasted))")
                .font(FinderUI.detailFont.weight(.semibold))
            Button("Przenieś nadmiarowe kopie do Kosza", role: .destructive) {
                performPaneAction { trashDuplicates(groups, generation: generation) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isValidatingDuplicates || cleanupID != nil || fileOps.isBusy || !scanIsComplete)
            .help("Zachowaj pierwszy plik z każdej grupy i zweryfikuj pozostałe przed przeniesieniem do Kosza")

            if cleanupID != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(cleanupIsCancelling ? "Anulowanie po bieżącej operacji…" : "Przenoszenie duplikatów do Kosza…")
                        .font(FinderUI.captionFont)
                    Button("Anuluj dalsze kroki") {
                        guard let id = cleanupID else { return }
                        cleanupCancelRequested = true
                        FileOperationsManager.shared.cancelDuplicateCleanup(id)
                    }
                    .disabled(cleanupIsCancelling)
                }
                Text("Bieżąca operacja systemowa może jeszcze trwać. Już przeniesione pliki nie są automatycznie przywracane.")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
            }
            if cleanupID == nil && fileOps.isBusy {
                Text("Poczekaj na zakończenie bieżącej operacji plikowej.")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
            }
            if !scanIsComplete {
                Text("Usuwanie duplikatów jest wyłączone dla niepełnego skanu. Odśwież analizę i usuń przyczynę pominięć.")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.orange)
            }
            if isValidatingDuplicates {
                HStack(spacing: FinderUI.rowSpacing) {
                    ProgressView().controlSize(.small)
                    Text(verificationWorkState == .queued ? "Weryfikacja w kolejce…" : "Weryfikowanie plików przed przeniesieniem…")
                        .font(FinderUI.captionFont)
                }
                .accessibilityElement(children: .combine)
                Button("Anuluj weryfikację") { cancelVerification() }.controlSize(.small)
            }
            Text("W każdej grupie zostanie zachowany wskazany oryginał. Rozmiar logiczny nie oznacza gwarantowanego odzyskanego miejsca: dowiązania twarde, klony APFS i kompresja mogą współdzielić dane.")
                .font(FinderUI.captionFont)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FinderUI.sectionSpacing)
        .padding(.vertical, FinderUI.rowSpacing)
        .background(Color.orange.opacity(0.06))
    }

    private func duplicateGroupCard(_ group: DuplicateFileGroup) -> some View {
        VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
            Text("Kopie: \(group.files.count) · \(FormatHelpers.formatBytes(group.fileSize)) na plik")
                .font(FinderUI.detailFont.weight(.semibold))
            Text("Nadmiarowe dane logiczne: \(FormatHelpers.formatBytes(group.wastedBytes))")
                .font(FinderUI.captionFont)
                .foregroundStyle(.secondary)
            Text("SHA-256: \(group.sha256.prefix(16))…")
                .font(FinderUI.captionFont.monospaced())
                .foregroundStyle(.secondary)
                .help(group.sha256)
            Divider()
            ForEach(group.files) { file in
                duplicateFileRow(file, in: group)
            }
        }
        .padding(FinderUI.rowSpacing)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))
    }

    private func duplicateFileRow(_ file: FileItem, in group: DuplicateFileGroup) -> some View {
        let generation = scanToken
        let isKeeper = file.path == group.files.first?.path
        let isSelected = pane.selectedPaths.contains(file.path)
        return VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
            Text(file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(FinderUI.detailFont)
                .foregroundStyle(isSelected ? selectionForegroundColor : Color.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isKeeper {
                Label("Zachowywany oryginał", systemImage: "checkmark.shield")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
            } else {
                Button("Przenieś do Kosza", role: .destructive) {
                    performPaneAction { trashDuplicates([group], generation: generation, onlyPath: file.path) }
                }
                .disabled(isValidatingDuplicates || cleanupID != nil || fileOps.isBusy || !scanIsComplete)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Przenieś do Kosza: \(file.name)")
            }
        }
        .padding(FinderUI.compactSpacing)
        .background(isSelected ? selectionBackgroundColor : Color.clear, in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))
        .contentShape(Rectangle())
        .help(file.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(file.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Zaznacz")) {
            selectAnalyzedItem(file, generation: generation)
        }
        .onTapGesture { selectAnalyzedItem(file, generation: generation) }
    }

    // MARK: - Generation-bound, bounded scans

    private func runActiveScan(for rootURL: URL) {
        cancelCleanupForOwnerChange()
        // Invalidate publication immediately, but let submit replace an admitted
        // pending request in place so repeated refreshes keep their FIFO slot.
        scanToken?.cancel()
        verificationToken?.cancel()
        verificationToken = nil
        let context = AnalysisPublicationContext(pane: pane, side: paneSide, mode: subMode)
        guard context.matches(appState: appState, mode: subMode), rootURL.path == context.rootPath else {
            scanTask?.cancel()
            verificationTask?.cancel()
            // The cancelled request's callbacks are filtered by context, so nothing else clears the spinner.
            isScanning = false
            return
        }
        let token = AnalysisRequestToken(rootPath: rootURL.path, context: context)
        scanToken = token
        isValidatingDuplicates = false
        isScanning = true
        scanIsComplete = false
        scanDiagnostic = nil
        topBranches = []
        largestFiles = []
        duplicateGroups = []
        categoryStats = []
        totalScannedBytes = 0
        totalScannedFiles = 0
        scanDurationMs = 0
        hoveredBlock = nil
        pane.beginAnalysisProjection(rootPath: rootURL.path, generation: token.id)
        let showHidden = pane.showHiddenFiles
        let mode = subMode
        let input = AnalysisScanInput(rootURL: rootURL, showHidden: showHidden, mode: mode)
        scanTask = AnalysisWorkAdapters.startScan(input, consumer: .analysis(paneSide), token: token, service: .shared,
            stateChanged: { state in
                guard self.scanToken === token, context.matches(appState: self.appState, mode: self.subMode) else { return }
                self.scanWorkState = state
                if state == .deferred {
                    token.cancel() // No result exists for this generation; it must authorize no action.
                    self.isScanning = false
                    self.scanDiagnostic = "Odroczono: zajęte miejsca analizy. Użyj odświeżania, aby ponowić."
                } else if state == .cancelled {
                    self.isScanning = false
                    self.scanIsComplete = false
                    self.scanDiagnostic = "Anulowano analizę. Użyj odświeżania, aby ponowić."
                    self.pane.clearAnalysisSelection()
                }
            }, completion: { result in
                guard let result, token.canPublishAnalysis(active: self.scanToken, appState: self.appState, mode: self.subMode) else { return }
                self.topBranches = result.branches
                self.largestFiles = Array(result.files.sorted { $0.size > $1.size }.prefix(150))
                self.duplicateGroups = result.groups
                self.categoryStats = result.categories
                self.totalScannedBytes = result.files.reduce(0) { $0 + $1.size }
                self.totalScannedFiles = result.files.count
                self.scanDurationMs = result.elapsed
                self.scanIsComplete = result.complete
                self.scanDiagnostic = result.diagnostic
                self.isScanning = false
                let visible = WizTreeSelectionProjection.items(mode: mode, branches: self.topBranches,
                    largestFiles: self.largestFiles, duplicateGroups: duplicateGroups)
                self.pane.publishAnalysisItems(visible, rootPath: token.rootPath, generation: token.id)
            })
    }

    private func cancelScan() {
        cancelCleanupForOwnerChange()
        scanToken?.cancel()
        scanTask?.cancel()
        verificationTask?.cancel()
        verificationToken = nil
        isScanning = false
        scanIsComplete = false
        scanDiagnostic = "Anulowano skan. Trwający odczyt systemowy może jeszcze kończyć pracę."
        pane.clearAnalysisSelection()
    }

    private func cancelCleanupForOwnerChange() {
        DuplicateCleanupHandoff.cancelOwned(cleanupID, manager: fileOps)
        cleanupID = nil
        cleanupCancelRequested = false
    }

    private func cancelVerification() {
        verificationTask?.cancel()
        verificationToken = nil
        isValidatingDuplicates = false
        duplicateActionError = "Anulowano weryfikację. Trwający odczyt systemowy może jeszcze kończyć pracę."
    }

    private func publishTreemapProjection(_ blocks: [TreemapPlacedBlock], token: AnalysisRequestToken?) {
        guard let token, token.canPublishAnalysis(active: scanToken, appState: appState, mode: subMode),
              !isScanning, subMode == .treemap else { return }
        // Ranked rows are visible in the scrollable list. Only rendered tiles, not
        // children hidden by geometry/max-block limits, join the keyboard projection.
        let visible = WizTreeSelectionProjection.items(mode: .treemap, branches: topBranches,
            largestFiles: largestFiles, duplicateGroups: duplicateGroups, visibleBlocks: blocks)
        pane.publishAnalysisItems(visible, rootPath: token.rootPath, generation: token.id)
    }

    private func canUseRenderedResult(_ generation: AnalysisRequestToken?, requiresComplete: Bool) -> Bool {
        guard let generation else { return false }
        return generation.canUseAnalysisResult(active: scanToken,
            resultReady: !isScanning && scanWorkState == .finished,
            isComplete: scanIsComplete, requiresComplete: requiresComplete)
            && generation.canPublishAnalysis(active: scanToken, appState: appState, mode: subMode)
    }

    // Explicit generic per-item Trash remains allowed from a completed partial
    // scan; automatic duplicate cleanup below requires a complete scan.
    private func trashAnalyzedItem(_ item: FileItem, generation: AnalysisRequestToken?) {
        let root = pane.currentURL.path
        guard canUseRenderedResult(generation, requiresComplete: false),
              item.path.hasPrefix(root == "/" ? "/" : root + "/") else { return }
        FileOperationsManager.shared.moveToTrash([item])
        runActiveScan(for: pane.currentURL)
    }

    private func trashDuplicates(_ groups: [DuplicateFileGroup], generation: AnalysisRequestToken?, onlyPath: String? = nil) {
        guard let token = generation, canUseRenderedResult(generation, requiresComplete: true),
              !isValidatingDuplicates, cleanupID == nil else { return }
        isValidatingDuplicates = true
        duplicateActionError = nil
        let verification = AnalysisRequestToken(rootPath: token.rootPath)
        verificationToken = verification
        verificationTask = AnalysisWorkAdapters.startVerification(groups, consumer: .analysis(paneSide), token: verification, service: .shared,
            stateChanged: { state in
                guard self.verificationToken === verification,
                      token.canPublishAnalysis(active: self.scanToken, appState: self.appState, mode: self.subMode) else { return }
                self.verificationWorkState = state
                if state == .deferred {
                    self.isValidatingDuplicates = false
                    self.duplicateActionError = "Odroczono weryfikację: analiza jest zajęta. Ponów operację."
                } else if state == .cancelled {
                    self.isValidatingDuplicates = false
                    self.duplicateActionError = "Anulowano weryfikację."
                    self.verificationToken = nil
                }
            }, completion: { result in
                guard verification.canPublishVerification(active: self.verificationToken, scan: token, activeScan: self.scanToken),
                      token.canPublishAnalysis(active: self.scanToken, appState: self.appState, mode: self.subMode) else { return }
                self.verificationToken = nil
                self.isValidatingDuplicates = false
                switch result {
                case .verified:
                    // Last live-owner/complete-result check before handing the
                    // immutable verified selection to the manager-owned batch.
                    guard self.canUseRenderedResult(token, requiresComplete: true) else { return }
                    let id = UUID()
                    self.cleanupID = id
                    self.cleanupCancelRequested = false
                    let accepted = DuplicateCleanupHandoff.start(verified: result,
                        plan: DuplicateCleanupPlan(groups: groups, onlyPath: onlyPath),
                        scanToken: token, requestID: id, appState: self.appState, manager: self.fileOps,
                        current: {
                            DuplicateCleanupViewState(scanToken: self.scanToken,
                                resultReady: !self.isScanning && self.scanWorkState == .finished,
                                isComplete: self.scanIsComplete, mode: self.subMode, cleanupID: self.cleanupID)
                        }, didFinish: { mayRescan in
                            self.cleanupID = nil
                            self.cleanupCancelRequested = false
                            if mayRescan { self.runActiveScan(for: self.pane.currentURL) }
                        })
                    if !accepted {
                        self.cleanupID = nil
                        self.duplicateActionError = FileOperationsManager.shared.lastStatusMessage ?? "Nie rozpoczęto usuwania duplikatów."
                    }
                case .failed(let message):
                    self.duplicateActionError = message
                }
            })
    }
}
