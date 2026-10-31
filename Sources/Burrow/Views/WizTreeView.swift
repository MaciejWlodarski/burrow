import SwiftUI
import AppKit
import CryptoKit
import Darwin

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
        // A map is a snapshot of the whole tree: file changes and the hidden-files
        // toggle stay relevant only to the duplicate scan of the current listing.
        revision = mode == .duplicates ? pane.directoryRevision : 0
        hidden = mode == .duplicates ? pane.showHiddenFiles : false
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

public enum WizTreeSubMode: String, CaseIterable, Identifiable, Sendable {
    case treemap = "WizTree Treemap & Drzewo"
    case largestFiles = "Największe pliki"
    case duplicates = "Duplikaty (SHA-256)"

    public var id: String { rawValue }
}

/// Shared production projection builder: keyboard selection uses displayed rows,
/// never an arbitrary last-clicked singleton or a collapsed subtree.
enum WizTreeSelectionProjection {
    static func items(mode: WizTreeSubMode, treeRows: [FileItem], largestFiles: [FileItem],
                      duplicateGroups: [DuplicateFileGroup]) -> [FileItem] {
        let candidates: [FileItem]
        switch mode {
        case .treemap: candidates = treeRows
        case .largestFiles: candidates = largestFiles
        case .duplicates: candidates = duplicateGroups.flatMap(\.files)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.path).inserted }
    }
}

/// A row of the expandable tree. `hiddenChildren` marks the closing row of a
/// folder listing more items than a list can usefully show.
struct DiskMapRow: Identifiable, Equatable {
    let node: DiskTree.NodeID
    let depth: Int
    let hiddenChildren: Int?

    var id: Int { hiddenChildren == nil ? Self.nodeRowID(node) : -Int(node) - 1 }
    static func nodeRowID(_ node: DiskTree.NodeID) -> Int { Int(node) }
}

private struct DiskMapRendering: @unchecked Sendable {
    let layout: DiskMapLayout
    let image: CGImage
}

enum DiskMapPresentation {
    static let childRowLimit = 500

    static func rows(tree: DiskTree, scope: DiskTree.NodeID, expanded: Set<DiskTree.NodeID>) -> [DiskMapRow] {
        var rows: [DiskMapRow] = []
        func append(_ parent: DiskTree.NodeID, depth: Int) {
            let children = tree.children(of: parent)
            for child in children.prefix(childRowLimit) {
                rows.append(DiskMapRow(node: child, depth: depth, hiddenChildren: nil))
                if expanded.contains(child) { append(child, depth: depth + 1) }
            }
            if children.count > childRowLimit {
                rows.append(DiskMapRow(node: parent, depth: depth, hiddenChildren: children.count - childRowLimit))
            }
        }
        append(scope, depth: 0)
        return rows
    }

    static func diagnostic(for tree: DiskTree) -> String? {
        var messages: [String] = []
        if tree.reachedEntryLimit { messages.append("Wyniki częściowe: osiągnięto limit \(DiskScanner.defaultMaxEntries.formatted()) wpisów.") }
        if tree.unreadableDirectoryCount > 0 { messages.append("Foldery bez dostępu: \(tree.unreadableDirectoryCount.formatted()).") }
        if tree.datalessDirectoryCount > 0 { messages.append("Foldery iCloud bez lokalnej zawartości: \(tree.datalessDirectoryCount.formatted()).") }
        if tree.skippedMountCount > 0 { messages.append("Pominięte inne dyski i montowania: \(tree.skippedMountCount.formatted()).") }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
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
    @ObservedObject private var mapStore = DiskMapStore.shared
    @ViewState private var mapTree: DiskTree?
    @ViewState private var mapScope: DiskTree.NodeID = DiskTree.rootID
    @ViewState private var expandedNodes: Set<DiskTree.NodeID> = []
    @ViewState private var treeRows: [DiskMapRow] = []
    @ViewState private var selectedNode: DiskTree.NodeID?
    @ViewState private var treeScrollTarget: Int?
    @ViewState private var mapLayout: DiskMapLayout?
    @ViewState private var mapImage: CGImage?
    @ViewState private var mapImageScale: CGFloat = 2
    @ViewState private var mapViewport: CGSize = .zero
    @ViewState private var hoveredTile: DiskMapTile?
    @ViewState private var mapRenderTask: Task<Void, Never>?
    @ViewState private var mapSummaryTask: Task<Void, Never>?

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

    private func openMapNode(_ id: DiskTree.NodeID, in tree: DiskTree) {
        guard !tree.isSynthetic(id) else { return }
        let item = tree.fileItem(id)
        performPaneAction {
            if item.isDirectory {
                pane.navigate(to: item.url)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    private var isMapMode: Bool { subMode != .duplicates }

    private var activeMapScan: DiskMapStore.RunningScan? {
        isMapMode ? mapStore.scan(covering: pane.currentURL.path) : nil
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
            if isMapMode, let mapTree, mapTree.unreadableDirectoryCount > 0 {
                fullDiskAccessHint
            }
            if let error = duplicateActionError {
                analysisNotice(error, isError: true)
            }
            Text(isMapMode
                ? "Zakres: wszystkie pliki z ukrytymi, bez innych dysków i śledzenia dowiązań. Rozmiar: miejsce zajęte na dysku."
                : "Zakres: \(pane.showHiddenFiles ? "z ukrytymi plikami" : "bez ukrytych plików"), bez śledzenia dowiązań. Limit: 60 000 wpisów.")
                .font(FinderUI.captionFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FinderUI.sectionSpacing)
                .padding(.vertical, FinderUI.compactSpacing)
            // Main Content
            if let scan = activeMapScan, mapTree == nil {
                mapScanProgress(scan)
            } else if isScanning {
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
                    if let mapTree, !treeRows.isEmpty {
                        wizTreeSplitWorkspace(mapTree)
                    } else {
                        analysisEmptyState(
                            title: scanIsComplete ? "Brak elementów do analizy" : "Brak danych w sprawdzonym zakresie",
                            message: "Sprawdź zakres skanowania lub wybierz inny folder.",
                            systemImage: "chart.pie"
                        )
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
        .onChange(of: mapStore.trees.map(\.scannedAt)) { _, _ in
            if isMapMode { presentDiskMap(startScanIfNeeded: false) }
        }
        .onChange(of: pane.selectedPaths) { _, paths in
            guard let mapTree, paths.count == 1, let path = paths.first else { return }
            selectedNode = mapTree.node(forPath: path)
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
        .onChange(of: pane.showHiddenFiles) { _, _ in if !isMapMode { runActiveScan(for: pane.currentURL) } }
        .onChange(of: pane.directoryRevision) { _, _ in
            if isMapMode { restoreDiskMapProjection() } else { runActiveScan(for: pane.currentURL) }
        }
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
                    wholeDiskButton
                    refreshScanButton
                }
                VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
                    HStack {
                        analyzerTitle
                        Spacer()
                        wholeDiskButton
                        refreshScanButton
                    }
                    analysisModePicker
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let scan = activeMapScan, mapTree != nil {
                HStack {
                    Text("Skan w tle: \(scan.rootPath) · elementy: \((mapStore.progress[scan.id]?.entries ?? 0).formatted())")
                        .font(FinderUI.captionFont)
                    Button("Anuluj skan") { mapStore.cancel(scan) }.controlSize(.small)
                }
            } else if isScanning {
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
        Text("\(telemetryTotalTitle): \(FormatHelpers.formatBytes(totalScannedBytes))")
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .fixedSize()
        Text("Pliki: \(totalScannedFiles.formatted())")
            .fixedSize()
        if scanDurationMs > 0 {
            Text("Czas: \(scanDurationMs >= 1000 ? String(format: "%.1f s", scanDurationMs / 1000) : FormatHelpers.formatLatency(scanDurationMs))")
                .fixedSize()
        }
        if isMapMode, let free = mapTree?.volumeFreeBytes {
            Text("Wolne: \(FormatHelpers.formatBytes(free))")
                .fixedSize()
        }
        if isMapMode, let mapTree {
            Text("Skan: \(mapTree.scannedAt.formatted(date: .omitted, time: .shortened))")
                .fixedSize()
        }
    }

    private var telemetryTotalTitle: String {
        if isMapMode, let mapTree, mapTree.unaccountedBytes > 0, mapScope == DiskTree.rootID { return "Zajęte" }
        return scanIsComplete ? "Łącznie" : "Co najmniej"
    }

    private var wholeDiskButton: some View {
        Button {
            performPaneAction { showWholeDisk() }
        } label: {
            Label("Cały dysk", systemImage: "internaldrive")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Przeskanuj cały dysk zawierający ten folder")
    }

    private var fullDiskAccessHint: some View {
        Button("Otwórz ustawienia pełnego dostępu do dysku") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(.link)
        .font(FinderUI.captionFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FinderUI.sectionSpacing)
        .help("Burrow liczy więcej folderów po nadaniu pełnego dostępu do dysku. Foldery dostępne tylko dla systemu pozostają w bloku „Niezeskanowane”.")
    }

    private func mapScanProgress(_ scan: DiskMapStore.RunningScan) -> some View {
        let progress = mapStore.progress[scan.id]
        return VStack(spacing: FinderUI.rowSpacing) {
            if let used = scan.usedBytesEstimate, used > 0 {
                ProgressView(value: min(1, Double(progress?.bytes ?? 0) / Double(used)))
                    .frame(maxWidth: 360)
                    .accessibilityLabel("Postęp skanowania dysku")
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel("Skanowanie folderu")
            }
            Text("Skanowanie \(scan.rootPath)…")
                .font(FinderUI.titleFont)
            Text("Elementy: \((progress?.entries ?? 0).formatted()) · \(FormatHelpers.formatBytes(progress?.bytes ?? 0))")
                .font(FinderUI.detailFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(progress?.currentPath ?? "")
                .font(FinderUI.captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 480)
            Button("Anuluj skan") { cancelScan() }.controlSize(.small)
            Text("Skan czeka, gdy macOS pyta o dostęp do chronionych folderów. Po nadaniu pełnego dostępu do dysku pytania nie pojawiają się.")
                .font(FinderUI.captionFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
        .multilineTextAlignment(.center)
        .padding(FinderUI.sheetPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var refreshScanButton: some View {
        Button {
            performPaneAction { isMapMode ? presentDiskMap(rescan: true) : runActiveScan(for: pane.currentURL) }
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

    // MARK: - Split Workspace: Expandable Tree + Full-Depth Treemap

    private func wizTreeSplitWorkspace(_ tree: DiskTree) -> some View {
        VSplitView {
            // Optional detail columns collapse in narrow panes, like the file list.
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(treeRows.enumerated()), id: \.element.id) { index, row in
                                diskTreeRow(row, tree: tree, index: index, availableWidth: geometry.size.width)
                                    .id(row.id)
                            }
                        }
                    }
                    .onChange(of: treeScrollTarget) { _, target in
                        if let target { proxy.scrollTo(target, anchor: .center) }
                    }
                }
            }
            .frame(minHeight: 120, idealHeight: 240)

            VStack(spacing: 0) {
                // Live Hover / Selection HUD Bar
                treemapHudBar(tree)
                diskMapCanvas(tree)
                    .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
            }
            .frame(minHeight: 220, idealHeight: 420)
        }
    }

    private func diskTreeRow(_ row: DiskMapRow, tree: DiskTree, index: Int, availableWidth: CGFloat) -> some View {
        Group {
            if let hidden = row.hiddenChildren {
                Text("… i jeszcze \(hidden.formatted()) mniejszych elementów")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, CGFloat(row.depth + 1) * 16 + FinderUI.sectionSpacing)
                    .padding(.vertical, 5)
            } else {
                diskNodeRow(row, tree: tree, index: index, availableWidth: availableWidth)
            }
        }
    }

    private func diskNodeRow(_ row: DiskMapRow, tree: DiskTree, index: Int, availableWidth: CGFloat) -> some View {
        let id = row.node
        let generation = scanToken
        let size = tree.allocatedSize(id)
        let fraction = totalScannedBytes > 0 ? Double(size) / Double(totalScannedBytes) : 0
        let isSelected = selectedNode == id
        let synthetic = tree.isSynthetic(id)
        let foreground = isSelected ? selectionForegroundColor : Color.primary
        let secondary = isSelected ? selectionForegroundColor : Color.secondary

        return HStack(spacing: FinderUI.rowSpacing) {
            Group {
                if tree.isDirectory(id), tree.childCount(id) > 0 {
                    Button { toggleExpansion(id) } label: {
                        Image(systemName: expandedNodes.contains(id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expandedNodes.contains(id) ? "Zwiń folder" : "Rozwiń folder")
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }
            .padding(.leading, CGFloat(row.depth) * 16)
            if synthetic {
                Image(systemName: "questionmark.square.dashed")
                    .frame(width: 18, height: 18)
                    .foregroundStyle(secondary)
                    .accessibilityHidden(true)
            } else {
                Image(nsImage: iconCache.icon(for: tree.fileItem(id), preferThumbnail: false))
                    .resizable()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            Text(tree.name(id))
                .font(FinderUI.detailFont.weight(tree.isDirectory(id) ? .semibold : .regular))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if tree.isUnreadable(id) {
                Image(systemName: "lock.fill")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(secondary)
                    .help("Brak dostępu do tego folderu")
                    .accessibilityLabel("Brak dostępu")
            }

            if availableWidth >= 650 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.07))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(tree.category(id).treemapColor.gradient)
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
                    .foregroundStyle(secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            Text(FormatHelpers.formatBytes(size))
                .font(FinderUI.captionFont.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(foreground)
                .frame(width: 90, alignment: .trailing)
            if availableWidth >= 760 {
                Text("Pliki: \(tree.fileCount(id).formatted())")
                    .font(FinderUI.captionFont)
                    .monospacedDigit()
                    .foregroundStyle(secondary)
                    .frame(width: 100, alignment: .trailing)
            }
        }
        .padding(.horizontal, FinderUI.sectionSpacing)
        .padding(.vertical, 5)
        .background(isSelected ? selectionBackgroundColor : (index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025)))
        .contentShape(Rectangle())
        .help(synthetic ? "Miejsce zajęte przez system, migawki APFS, dane usuwalne i foldery bez dostępu" : tree.path(id))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction { selectMapNode(id, in: tree, generation: generation) }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                openMapNode(id, in: tree)
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                selectMapNode(id, in: tree, generation: generation)
            }
        )
        .contextMenu { mapNodeMenu(id, tree: tree, generation: generation) }
    }

    private func treemapHudBar(_ tree: DiskTree) -> some View {
        HStack(spacing: 8) {
            if mapScope != DiskTree.rootID, let parent = tree.parent(mapScope) {
                Button {
                    openMapNode(parent, in: tree)
                } label: {
                    Label("W górę", systemImage: "arrow.up")
                }
                .buttonStyle(.borderless)
                .font(FinderUI.captionFont)
                .help("Pokaż folder nadrzędny na mapie")
            }
            if let tile = hoveredTile {
                let size = tile.isRemainder ? remainderSize(tile, in: tree) : tree.allocatedSize(tile.node)
                Circle()
                    .fill(tree.category(tile.node).treemapColor)
                    .frame(width: 9, height: 9)
                Text(tile.isRemainder ? "Mniejsze elementy" : tree.name(tile.node))
                    .font(FinderUI.detailFont.weight(.semibold))
                    .lineLimit(1)
                if let parent = tree.parent(tile.node) {
                    Text("w \(tree.name(parent))/")
                        .font(FinderUI.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("· \(FormatHelpers.formatBytes(size))")
                    .font(FinderUI.captionFont.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                if totalScannedBytes > 0 {
                    let pct = Double(size) * 100.0 / Double(totalScannedBytes)
                    Text("(\(String(format: "%.1f%%", pct)))")
                        .font(FinderUI.captionFont)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "hand.point.up.left.fill")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                Text("Kliknij element, aby wskazać go w drzewie. Kliknij dwukrotnie folder, aby go powiększyć.")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4.5)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func remainderSize(_ tile: DiskMapTile, in tree: DiskTree) -> Int64 {
        guard let parent = tree.parent(tile.node) else { return 0 }
        return tree.children(of: parent).drop { $0 != tile.node }
            .reduce(0) { $0 + tree.allocatedSize($1) }
    }

    private func mapRect(_ tile: DiskMapTile) -> CGRect {
        CGRect(x: CGFloat(tile.x0) / mapImageScale, y: CGFloat(tile.y0) / mapImageScale,
               width: CGFloat(tile.x1 - tile.x0) / mapImageScale, height: CGFloat(tile.y1 - tile.y0) / mapImageScale)
    }

    private func mapTile(at location: CGPoint) -> DiskMapTile? {
        mapLayout?.tile(atX: Int32(location.x * mapImageScale), y: Int32(location.y * mapImageScale))
    }

    /// Too-small children have no identity on the map; their folder stands in.
    private func actionNode(for tile: DiskMapTile, in tree: DiskTree) -> DiskTree.NodeID {
        tile.isRemainder ? (tree.parent(tile.node) ?? tile.node) : tile.node
    }

    private func diskMapCanvas(_ tree: DiskTree) -> some View {
        GeometryReader { geo in
            let generation = scanToken
            ZStack(alignment: .topLeading) {
                if let mapImage {
                    Image(decorative: mapImage, scale: mapImageScale)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .accessibilityLabel("Mapa zajętego miejsca")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let selected = selectedNode, let tile = mapLayout?.tile(for: selected, in: tree) {
                    mapHighlight(tile, color: .white, lineWidth: 2)
                }
                if let hoveredTile {
                    mapHighlight(hoveredTile, color: .white.opacity(0.85), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let tile = mapTile(at: location)
                    if tile != hoveredTile { hoveredTile = tile }
                case .ended:
                    hoveredTile = nil
                }
            }
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { value in
                    guard let tile = mapTile(at: value.location) else { return }
                    openMapNode(actionNode(for: tile, in: tree), in: tree)
                }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 1).onEnded { value in
                    guard let tile = mapTile(at: value.location) else { return }
                    selectMapNode(actionNode(for: tile, in: tree), in: tree, generation: generation)
                }
            )
            .contextMenu {
                if let tile = hoveredTile {
                    mapNodeMenu(actionNode(for: tile, in: tree), tree: tree, generation: generation)
                }
            }
            .onAppear {
                mapViewport = geo.size
                renderMap()
            }
            .onChange(of: geo.size) { _, size in
                mapViewport = size
                renderMap()
            }
        }
    }

    private func mapHighlight(_ tile: DiskMapTile, color: Color, lineWidth: CGFloat) -> some View {
        let rect = mapRect(tile)
        return Rectangle()
            .strokeBorder(color, lineWidth: lineWidth)
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func mapNodeMenu(_ id: DiskTree.NodeID, tree: DiskTree, generation: AnalysisRequestToken?) -> some View {
        if !tree.isSynthetic(id) {
            let item = tree.fileItem(id)
            if item.isDirectory {
                Button {
                    openMapNode(id, in: tree)
                } label: {
                    Label("Otwórz folder w analizie", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            } else if let parent = tree.parent(id) {
                Button {
                    openMapNode(parent, in: tree)
                } label: {
                    Label("Otwórz folder nadrzędny w analizie", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            }
            Button {
                performPaneAction {
                    if pane.navigate(to: item.isDirectory ? item.url : item.url.deletingLastPathComponent()) {
                        pane.viewMode = .list
                        pane.selectedPaths = [item.path]
                    }
                }
            } label: {
                Label("Pokaż na liście plików", systemImage: "list.bullet")
            }
            Button {
                performPaneAction { QuickLookCoordinator.shared.preview(ownerID: pane.id, urls: [item.url]) }
            } label: {
                Label("Quick Look (Spacja)", systemImage: "eye")
            }
            Button {
                performPaneAction { FileOperationsManager.shared.openInTerminal(at: item.url) }
            } label: {
                Label("Otwórz w Terminalu", systemImage: "terminal")
            }
            Divider()
            Button(role: .destructive) {
                performPaneAction { trashAnalyzedItem(item, generation: generation) }
            } label: {
                Label("Przenieś do Kosza", systemImage: "trash")
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
        if isMapMode {
            presentDiskMap()
            return
        }
        clearDiskMap()
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
        largestFiles = []
        duplicateGroups = []
        categoryStats = []
        totalScannedBytes = 0
        totalScannedFiles = 0
        scanDurationMs = 0
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
                self.largestFiles = Array(result.files.sorted { $0.size > $1.size }.prefix(150))
                self.duplicateGroups = result.groups
                self.categoryStats = result.categories
                self.totalScannedBytes = result.files.reduce(0) { $0 + $1.size }
                self.totalScannedFiles = result.files.count
                self.scanDurationMs = result.elapsed
                self.scanIsComplete = result.complete
                self.scanDiagnostic = result.diagnostic
                self.isScanning = false
                let visible = WizTreeSelectionProjection.items(mode: mode, treeRows: [],
                    largestFiles: self.largestFiles, duplicateGroups: duplicateGroups)
                self.pane.publishAnalysisItems(visible, rootPath: token.rootPath, generation: token.id)
            })
    }

    private func cancelScan() {
        if let scan = activeMapScan {
            mapStore.cancel(scan)
            scanWorkState = .cancelled
            return
        }
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

    // MARK: - Disk map state

    /// Shows the map from a tree covering the current folder, scanning only when
    /// none exists. Navigation inside a tree is therefore instant, and a whole-disk
    /// scan outlives this view.
    private func presentDiskMap(rescan: Bool = false, startScanIfNeeded: Bool = true) {
        cancelCleanupForOwnerChange()
        scanToken?.cancel()
        scanTask?.cancel()
        verificationTask?.cancel()
        verificationToken = nil
        isScanning = false
        isValidatingDuplicates = false
        duplicateGroups = []
        let path = pane.currentURL.path
        let context = AnalysisPublicationContext(pane: pane, side: paneSide, mode: subMode)
        guard context.matches(appState: appState, mode: subMode) else { return }
        let covered = mapStore.tree(covering: path)
        if rescan {
            mapStore.startScan(root: covered?.tree.rootPath ?? path)
        } else if covered == nil, startScanIfNeeded, mapStore.scan(covering: path) == nil {
            mapStore.startScan(root: path)
        }
        let token = AnalysisRequestToken(rootPath: path, context: context)
        scanToken = token
        scanWorkState = .finished
        pane.beginAnalysisProjection(rootPath: path, generation: token.id)
        guard let covered else {
            clearDiskMap()
            return
        }
        if covered.tree !== mapTree {
            expandedNodes = []
            selectedNode = nil
            mapImage = nil
            mapLayout = nil
        }
        mapTree = covered.tree
        if covered.node != mapScope { mapLayout = nil }
        mapScope = covered.node
        hoveredTile = nil
        refreshDiskMapContents(token: token)
    }

    private func clearDiskMap() {
        mapRenderTask?.cancel()
        mapSummaryTask?.cancel()
        mapTree = nil
        mapScope = DiskTree.rootID
        mapImage = nil
        mapLayout = nil
        hoveredTile = nil
        expandedNodes = []
        selectedNode = nil
        treeRows = []
        largestFiles = []
        categoryStats = []
        totalScannedBytes = 0
        totalScannedFiles = 0
        scanDurationMs = 0
        scanIsComplete = false
        scanDiagnostic = nil
    }

    private func refreshDiskMapContents(token: AnalysisRequestToken) {
        guard let tree = mapTree else { return }
        totalScannedBytes = tree.allocatedSize(mapScope)
        totalScannedFiles = tree.fileCount(mapScope)
        scanDurationMs = tree.elapsedMilliseconds
        scanIsComplete = tree.isComplete
        scanDiagnostic = DiskMapPresentation.diagnostic(for: tree)
        treeRows = DiskMapPresentation.rows(tree: tree, scope: mapScope, expanded: expandedNodes)
        publishDiskMapSelection(token: token)
        renderMap()
        mapSummaryTask?.cancel()
        let scope = mapScope
        mapSummaryTask = Task { @MainActor in
            let summary = await Task.detached(priority: .userInitiated) { () -> (DiskTree.Summary, [FileItem]) in
                tree.read {
                    let summary = tree.summary(of: scope, isCancelled: { Task.isCancelled })
                    return (summary, summary.largestFiles.prefix(150).map(tree.fileItem))
                }
            }.value
            guard !Task.isCancelled, scanToken === token else { return }
            categoryStats = summary.0.categories
            largestFiles = summary.1
            publishDiskMapSelection(token: token)
        }
    }

    private func publishDiskMapSelection(token: AnalysisRequestToken) {
        guard let tree = mapTree, token.canPublishAnalysis(active: scanToken, appState: appState, mode: subMode) else { return }
        let rows = subMode == .treemap ? treeRows.filter { $0.hiddenChildren == nil && !tree.isSynthetic($0.node) }.map { tree.fileItem($0.node) } : []
        let visible = WizTreeSelectionProjection.items(mode: subMode, treeRows: rows,
            largestFiles: largestFiles, duplicateGroups: [])
        pane.publishAnalysisItems(visible, rootPath: token.rootPath, generation: token.id)
    }

    /// A directory reload clears the pane's projection, and on `/` reloads never
    /// stop. The map stays a snapshot, so rows and selection are simply put back.
    private func restoreDiskMapProjection() {
        guard let tree = mapTree, let token = scanToken, !isScanning else { return }
        let selected = selectedNode
        pane.beginAnalysisProjection(rootPath: token.rootPath, generation: token.id)
        publishDiskMapSelection(token: token)
        guard let selected, !tree.isRemoved(selected) else { return }
        pane.setAnalysisSelection([tree.fileItem(selected)], rootPath: token.rootPath)
    }

    private func toggleExpansion(_ id: DiskTree.NodeID) {
        if !expandedNodes.insert(id).inserted { expandedNodes.remove(id) }
        rebuildTreeRows()
    }

    private func rebuildTreeRows() {
        guard let tree = mapTree else { return }
        treeRows = DiskMapPresentation.rows(tree: tree, scope: mapScope, expanded: expandedNodes)
        if let token = scanToken { publishDiskMapSelection(token: token) }
    }

    /// Reveals a node from either side: the tree opens down to it, and both the
    /// row and the map tile show the same selection.
    private func selectMapNode(_ id: DiskTree.NodeID, in tree: DiskTree, generation: AnalysisRequestToken?) {
        guard !tree.isSynthetic(id), canUseRenderedResult(generation, requiresComplete: false) else { return }
        var ancestor = tree.parent(id)
        while let current = ancestor, current != mapScope {
            expandedNodes.insert(current)
            ancestor = tree.parent(current)
        }
        rebuildTreeRows()
        selectedNode = id
        treeScrollTarget = DiskMapRow.nodeRowID(id)
        selectAnalyzedItem(tree.fileItem(id), generation: generation)
    }

    private func showWholeDisk() {
        let root = DiskMapStore.volumeRoot(of: pane.currentURL.path)
        if subMode == .duplicates { subMode = .treemap }
        if pane.currentURL.path == root {
            presentDiskMap(rescan: mapTree?.rootPath != root)
        } else {
            pane.navigate(to: URL(fileURLWithPath: root, isDirectory: true))
        }
    }

    private func renderMap() {
        mapRenderTask?.cancel()
        guard let tree = mapTree, subMode == .treemap, mapViewport.width >= 8, mapViewport.height >= 8 else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let width = Int(mapViewport.width * scale), height = Int(mapViewport.height * scale)
        let scope = mapScope
        mapRenderTask = Task { @MainActor in
            // Coalesces live window resizing.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { () -> DiskMapRendering? in
                tree.read {
                    guard let layout = DiskMapLayoutEngine.layout(tree: tree, scope: scope, width: width, height: height,
                                                                  scale: Double(scale), isCancelled: { Task.isCancelled }),
                          let image = DiskMapRenderer.image(layout: layout, tree: tree, scale: Double(scale),
                                                            isCancelled: { Task.isCancelled }) else { return nil }
                    return DiskMapRendering(layout: layout, image: image)
                }
            }
            let rendering = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let rendering, mapTree === tree, mapScope == scope else { return }
            mapLayout = rendering.layout
            mapImage = rendering.image
            mapImageScale = scale
        }
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
        guard isMapMode else {
            runActiveScan(for: pane.currentURL)
            return
        }
        // The map is a snapshot: drop what really left the disk instead of rescanning it.
        var info = stat()
        guard let tree = mapTree, let node = tree.node(forPath: item.path), lstat(item.path, &info) != 0,
              let token = scanToken else { return }
        tree.remove(node)
        if selectedNode == node { selectedNode = nil }
        refreshDiskMapContents(token: token)
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
