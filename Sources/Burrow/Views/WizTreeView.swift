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
    case changed, unreadable, cancelled, cloudOnly
    var errorDescription: String? {
        switch self {
        case .cloudOnly: return String(localized: "The file is stored only in the cloud. Download it to compare it.")
        case .changed: return String(localized: "A file or the original being kept has changed. Nothing more was removed; run a new scan.")
        case .unreadable: return String(localized: "The file can't be read safely. Run a new scan.")
        case .cancelled: return String(localized: "The scan was canceled.")
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
        guard !CloudFiles.isDataless(path: url.path) else { throw DuplicateSafetyError.cloudOnly }
        try hooks.beforeOpen?()
        if isCancelled() { throw DuplicateSafetyError.cancelled }
        let fd = CloudFiles.withoutDownloading { Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else { throw errno == EDEADLK ? DuplicateSafetyError.cloudOnly : DuplicateSafetyError.unreadable }
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
            // Hashing a cloud-only file would download it; such files are left out.
            for entry in sameSize.sorted(by: { $0.fullPath < $1.fullPath }) where !entry.isDataless {
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
    case treemap = "treemap"
    case largestFiles = "largestFiles"
    case duplicates = "duplicates"

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
        if tree.reachedEntryLimit { messages.append(String(localized: "Partial results: reached the limit of \(DiskScanner.defaultMaxEntries.formatted()) entries.")) }
        if tree.unreadableDirectoryCount > 0 { messages.append(String(localized: "Folders without access: \(tree.unreadableDirectoryCount.formatted()).")) }
        if tree.datalessDirectoryCount > 0 { messages.append(String(localized: "iCloud folders without local content: \(tree.datalessDirectoryCount.formatted()).")) }
        if tree.skippedMountCount > 0 { messages.append(String(localized: "Other disks and mounts skipped: \(tree.skippedMountCount.formatted()).")) }
        if tree.cloneSharedBytes > 0 { messages.append(String(localized: "APFS clones counted once: \(FormatHelpers.formatBytes(tree.cloneSharedBytes)) was not counted twice.")) }
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }
}

public struct WizTreeAnalyzerView: View {
    @Environment(\.colorScheme) private var colorScheme
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
    /// nil until the divider is dragged: then about 40% of the space, in whole rows.
    @ViewState private var treePaneHeight: CGFloat?
    @ViewState private var treePaneDrag: CGFloat = 0
    @ViewState private var mapHoverLocation: CGPoint = .zero
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

            if !categoryStats.isEmpty {
                categoryBreakdownStrip
            }
            Divider()

            if let diagnostic = scanDiagnostic {
                analysisNotice(diagnostic)
            }
            if isMapMode, let mapTree, mapTree.unreadableDirectoryCount > 0 {
                fullDiskAccessHint
            }
            if let error = duplicateActionError {
                analysisNotice(error, isError: true)
            }
            // Main Content
            if let scan = activeMapScan, mapTree == nil {
                mapScanProgress(scan)
            } else if isScanning {
                VStack(spacing: FinderUI.rowSpacing) {
                    ProgressView()
                        .controlSize(.regular)
                        .accessibilityLabel("Scanning folder")
                    Text(isScanningStatusTitle)
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
                    title: scanWorkState == .deferred ? String(localized: "Analysis deferred") : String(localized: "Analysis canceled"),
                    message: String(localized: "There is no current result. Use Refresh to start a new scan."),
                    systemImage: "pause.circle"
                )
            } else {
                switch subMode {
                case .treemap:
                    if let mapTree, !treeRows.isEmpty {
                        wizTreeSplitWorkspace(mapTree)
                    } else {
                        analysisEmptyState(
                            title: scanIsComplete ? String(localized: "No items to analyze") : String(localized: "No data in the checked scope"),
                            message: String(localized: "Check the scan scope or choose another folder."),
                            systemImage: "chart.pie"
                        )
                    }
                case .largestFiles:
                    if largestFiles.isEmpty {
                        analysisEmptyState(
                            title: scanIsComplete ? String(localized: "No files to show") : String(localized: "No files in the checked scope"),
                            message: String(localized: "The scan found no regular files. Symbolic links are not included."),
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
                // One row: the total on the left, modes and scan actions on the right.
                // The toolbar's pie button already says this is the disk analysis.
                HStack(spacing: FinderUI.sectionSpacing) {
                    HStack(alignment: .firstTextBaseline, spacing: FinderUI.rowSpacing) { analysisTelemetry }
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    analysisModePicker
                        .fixedSize()
                    wholeDiskButton
                    refreshScanButton
                }
                VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
                    HStack {
                        analysisModePicker
                            .fixedSize()
                        Spacer()
                        wholeDiskButton
                        refreshScanButton
                    }
                    HStack(alignment: .firstTextBaseline, spacing: FinderUI.rowSpacing) { analysisTelemetry }
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                }
            }
            if let scan = activeMapScan, mapTree != nil {
                HStack {
                    Text("Background scan: \(scan.rootPath) · items: \((mapStore.progress[scan.id]?.entries ?? 0).formatted())")
                        .font(FinderUI.captionFont)
                    Button("Cancel Scan") { mapStore.cancel(scan) }.controlSize(.small)
                }
            } else if isScanning {
                HStack {
                    Text(scanWorkState == .queued ? String(localized: "Scan queued…") : String(localized: "Scanning…"))
                        .font(FinderUI.captionFont)
                    Button("Cancel Scan") { cancelScan() }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, FinderUI.sectionSpacing)
        .padding(.top, 10)
        .padding(.bottom, FinderUI.rowSpacing)
        .background(Color(nsColor: .controlBackgroundColor))
    }


    private var isScanningStatusTitle: String {
        if scanWorkState == .queued { return String(localized: "Scan is waiting for a free slot…") }
        return subMode == .duplicates
            ? String(localized: "Scanning and verifying files…")
            : String(localized: "Scanning folder…")
    }

    private var scanScopeNote: String {
        if isMapMode {
            return String(localized: "Scope: all files including hidden ones, without other disks or symlink following. Size: space allocated on disk.")
        }
        return pane.showHiddenFiles
            ? String(localized: "Scope: including hidden files, without symlink following. Limit: 60,000 entries.")
            : String(localized: "Scope: excluding hidden files, without symlink following. Limit: 60,000 entries.")
    }

    private var analysisModePicker: some View {
        // A quiet tab strip in the style of the toolbar's view switcher: the
        // chosen mode gets a grey pill, not an accent fill that would outshout the total.
        HStack(spacing: 2) {
            ForEach(WizTreeSubMode.allCases) { mode in
                let isSelected = subMode == mode
                Button { subMode = mode } label: {
                    Text(analysisModeTitle(mode))
                        .font(FinderUI.detailFont.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background {
                            if isSelected {
                                Capsule().fill(Color.primary.opacity(0.1))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Disk space analysis mode")
        .help("Choose the space map, largest files, or duplicates")
    }

    private func analysisModeTitle(_ mode: WizTreeSubMode) -> String {
        switch mode {
        case .treemap: return String(localized: "Map and Tree")
        case .largestFiles: return String(localized: "Largest Files")
        case .duplicates: return String(localized: "Duplicates")
        }
    }

    @ViewBuilder
    private var analysisTelemetry: some View {
        Text(FormatHelpers.formatBytes(totalScannedBytes))
            .font(.system(size: 22, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .fixedSize()
        Text(telemetryDetails)
            .fixedSize()
            .help(scanScopeNote)
            .accessibilityHint(scanScopeNote)
    }

    /// "used · 44 files · 213 GB free · scanned 1:04 PM"
    private var telemetryDetails: String {
        var parts = [telemetryTotalTitle.lowercased(), String(localized: "\(totalScannedFiles.formatted()) files")]
        if isMapMode, let free = mapTree?.volumeFreeBytes {
            parts.append(String(localized: "\(FormatHelpers.formatBytes(free)) free on disk"))
        }
        if isMapMode, let mapTree {
            parts.append(String(localized: "scanned \(mapTree.scannedAt.formatted(date: .omitted, time: .shortened))"))
        }
        return parts.joined(separator: " · ")
    }

    private var telemetryTotalTitle: String {
        if isMapMode, let mapTree, mapTree.unaccountedBytes > 0, mapScope == DiskTree.rootID { return String(localized: "Used") }
        return scanIsComplete ? String(localized: "Total") : String(localized: "At least")
    }

    private var wholeDiskButton: some View {
        Button {
            performPaneAction { showWholeDisk() }
        } label: {
            Label("Scan Whole Disk", systemImage: "internaldrive")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Scan the whole disk that contains this folder")
    }

    private var fullDiskAccessHint: some View {
        Button("Open Full Disk Access Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(.link)
        .font(FinderUI.captionFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FinderUI.sectionSpacing)
        .help("Burrow can count more folders once Full Disk Access is granted. Folders only the system can access stay in the “Unscanned” block.")
    }

    private func mapScanProgress(_ scan: DiskMapStore.RunningScan) -> some View {
        let progress = mapStore.progress[scan.id]
        return VStack(spacing: FinderUI.rowSpacing) {
            if let used = scan.usedBytesEstimate, used > 0 {
                ProgressView(value: min(1, Double(progress?.bytes ?? 0) / Double(used)))
                    .frame(maxWidth: 360)
                    .accessibilityLabel("Disk scan progress")
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel("Scanning folder")
            }
            Text("Scanning \(scan.rootPath)…")
                .font(FinderUI.titleFont)
            Text("Items: \((progress?.entries ?? 0).formatted()) · \(FormatHelpers.formatBytes(progress?.bytes ?? 0))")
                .font(FinderUI.detailFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(progress?.currentPath ?? "")
                .font(FinderUI.captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 480)
            Button("Cancel Scan") { cancelScan() }.controlSize(.small)
            Text("The scan waits while macOS asks for access to protected folders. Once Full Disk Access is granted, these prompts no longer appear.")
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
            Label("Refresh Scan", systemImage: "arrow.clockwise")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Refresh the disk space analysis")
        .accessibilityLabel("Refresh the disk space analysis")
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
            Button("Scan Again") { performPaneAction { runActiveScan(for: pane.currentURL) } }
        }
        .multilineTextAlignment(.center)
        .padding(FinderUI.sheetPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Category Legend & Proportional Bar

    private var categoryBreakdownStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(categoryStats, id: \.0.rawValue) { cat, bytes, _ in
                        let frac = totalScannedBytes > 0 ? CGFloat(bytes) / CGFloat(totalScannedBytes) : 0
                        if frac > 0.005 {
                            Rectangle()
                                .fill(cat.treemapColor)
                                .frame(width: max(4, geo.size.width * frac))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(categoryStats.prefix(7), id: \.0.rawValue) { cat, bytes, count in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(cat.treemapColor)
                                .frame(width: 8, height: 8)
                            Text(cat.displayName)
                                .foregroundStyle(.primary)
                            Text(FormatHelpers.formatBytes(bytes))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .help(String(localized: "\(count.formatted()) files"))
                    }
                }
                .font(FinderUI.detailFont)
            }
        }
        .padding(.horizontal, FinderUI.sectionSpacing)
        .padding(.bottom, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Split Workspace: Expandable Tree + Full-Depth Treemap

    /// Header plus whole rows, so the divider never cuts through a row.
    private static let treeHeaderHeight: CGFloat = 24
    private static let treeRowHeight: CGFloat = 28
    private static let minimumMapHeight: CGFloat = 220

    private func wizTreeSplitWorkspace(_ tree: DiskTree) -> some View {
        GeometryReader { outer in
            let maximumTree = max(Self.treeHeaderHeight + Self.treeRowHeight * 2,
                                  outer.size.height - Self.minimumMapHeight)
            let defaultRows = max(3, ((outer.size.height * 0.45 - Self.treeHeaderHeight) / Self.treeRowHeight).rounded(.down))
            let baseHeight = treePaneHeight ?? Self.treeHeaderHeight + Self.treeRowHeight * defaultRows
            let treeHeight = min(maximumTree, baseHeight + treePaneDrag)
            VStack(spacing: 0) {
                treePane(tree)
                    .frame(height: treeHeight)
                splitHandle(baseHeight: baseHeight, maximumHeight: maximumTree)
                VStack(spacing: 0) {
                    if mapScope != DiskTree.rootID { treemapHudBar(tree) }
                    diskMapCanvas(tree)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(FinderUI.rowSpacing)
                        .background(Color(nsColor: .controlBackgroundColor))
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func treePane(_ tree: DiskTree) -> some View {
        // Optional detail columns collapse in narrow panes, like the file list.
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Bars are drawn against the largest visible row, so the biggest item
                // fills the track; the percentage keeps the share of the total.
                let largestRow = treeRows.lazy.filter { $0.hiddenChildren == nil }
                    .map { tree.allocatedSize($0.node) }.max() ?? 0
                diskTreeHeader(availableWidth: geometry.size.width)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(treeRows.enumerated()), id: \.element.id) { index, row in
                                diskTreeRow(row, tree: tree, index: index, availableWidth: geometry.size.width,
                                            largestRow: largestRow)
                                    .id(row.id)
                            }
                        }
                    }
                    .onChange(of: treeScrollTarget) { _, target in
                        if let target { proxy.scrollTo(target, anchor: .center) }
                    }
                }
            }
        }
    }

    /// A thin divider with a taller drag target that snaps the tree to whole rows.
    private func splitHandle(baseHeight: CGFloat, maximumHeight: CGFloat) -> some View {
        Divider()
            .frame(height: 1)
            .overlay {
                // A visible grip says the divider can be dragged.
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 36, height: 4)
                    .allowsHitTesting(false)
            }
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in treePaneDrag = value.translation.height }
                        .onEnded { value in
                            let raw = min(maximumHeight, max(Self.treeHeaderHeight + Self.treeRowHeight * 2,
                                                             baseHeight + value.translation.height))
                            let rows = ((raw - Self.treeHeaderHeight) / Self.treeRowHeight).rounded()
                            treePaneHeight = Self.treeHeaderHeight + rows * Self.treeRowHeight
                            treePaneDrag = 0
                        })
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }

    /// Name column of the analysis tree: wide enough for long names, never so wide
    /// that short ones sit far from their bars.
    /// Chevron, icon and their gaps: the header's "Name" starts where the names do.
    static let treeNameInset: CGFloat = 14 + FinderUI.rowSpacing * 2 + 18

    static var legacyScrollerWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    static func treeNameWidth(_ availableWidth: CGFloat) -> CGFloat {
        min(300, max(220, availableWidth * 0.24))
    }

    private func diskTreeHeader(availableWidth: CGFloat) -> some View {
        HStack(spacing: FinderUI.rowSpacing) {
            if availableWidth >= 650 {
                Text("Name").padding(.leading, Self.treeNameInset).frame(width: Self.treeNameWidth(availableWidth), alignment: .leading)
                Text("Share of Total").frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Name").padding(.leading, Self.treeNameInset).frame(maxWidth: .infinity, alignment: .leading)
                if availableWidth >= 480 { Text("Share of Total").frame(width: 48, alignment: .trailing) }
            }
            Text("Size").frame(width: 80, alignment: .trailing)
            if availableWidth >= 760 { Text("Files").frame(width: 64, alignment: .trailing) }
        }
        .font(FinderUI.captionFont.weight(.medium))
        .foregroundStyle(FinderUI.metadataColor)
        .padding(.leading, FinderUI.sectionSpacing)
        // Rows lose the width of an always-visible scroller; the header must too,
        // or numbers sit left of their titles.
        .padding(.trailing, FinderUI.sectionSpacing + Self.legacyScrollerWidth)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func diskTreeRow(_ row: DiskMapRow, tree: DiskTree, index: Int, availableWidth: CGFloat,
                             largestRow: Int64) -> some View {
        Group {
            if let hidden = row.hiddenChildren {
                Text("… and \(hidden.formatted()) more smaller items")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, CGFloat(row.depth + 1) * 16 + FinderUI.sectionSpacing)
                    .padding(.vertical, 5)
            } else {
                diskNodeRow(row, tree: tree, index: index, availableWidth: availableWidth, largestRow: largestRow)
            }
        }
    }

    private func diskNodeRow(_ row: DiskMapRow, tree: DiskTree, index: Int, availableWidth: CGFloat,
                             largestRow: Int64) -> some View {
        let id = row.node
        let generation = scanToken
        let size = tree.allocatedSize(id)
        let fraction = totalScannedBytes > 0 ? Double(size) / Double(totalScannedBytes) : 0
        let barFraction = largestRow > 0 ? Double(size) / Double(largestRow) : 0
        let isSelected = selectedNode == id
        let synthetic = tree.isSynthetic(id)
        let foreground = isSelected ? selectionForegroundColor : Color.primary
        let secondary = isSelected ? selectionForegroundColor : Color.secondary

        return HStack(spacing: FinderUI.rowSpacing) {
          HStack(spacing: FinderUI.rowSpacing) {
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
                    .accessibilityLabel(expandedNodes.contains(id) ? String(localized: "Collapse folder") : String(localized: "Expand folder"))
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
                Image(nsImage: iconCache.icon(for: tree.fileItem(id)))
                    .resizable()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            Text(tree.name(id))
                .font(FinderUI.detailFont)
                .foregroundStyle(foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if tree.isUnreadable(id) {
                Image(systemName: "lock.fill")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(secondary)
                    .help("No access to this folder")
                    .accessibilityLabel("No access")
            }
          }
          // A compact name column: the share bar starts right after short names
          // instead of across an empty band, and takes the remaining width.
          .frame(maxWidth: availableWidth >= 650 ? Self.treeNameWidth(availableWidth) : .infinity, alignment: .leading)

            if availableWidth >= 650 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule()
                            // Neutral: category colour belongs to the summary bar and the map,
                            // and blue means selection. Never thinner than a short pill,
                            // so small shares don't read as bullets.
                            .fill(isSelected ? selectionForegroundColor.opacity(0.85) : Color.primary.opacity(0.5))
                            .frame(width: max(10, geometry.size.width * CGFloat(barFraction)))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            if availableWidth >= 480 {
                Text(String(format: "%.1f%%", fraction * 100.0))
                    .font(FinderUI.detailFont)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? foreground : FinderUI.metadataColor)
                    .frame(width: 44, alignment: .trailing)
            }
            Text(FormatHelpers.formatBytes(size))
                .font(FinderUI.detailFont)
                .monospacedDigit()
                .foregroundStyle(isSelected ? foreground : FinderUI.metadataColor)
                .frame(width: 80, alignment: .trailing)
            if availableWidth >= 760 {
                Text(tree.isDirectory(id) ? tree.fileCount(id).formatted() : "")
                    .font(FinderUI.detailFont)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? foreground : FinderUI.metadataColor)
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.horizontal, FinderUI.sectionSpacing)
        .padding(.vertical, 5)
        .background(isSelected ? selectionBackgroundColor : (index.isMultiple(of: 2) ? Color.clear : FinderUI.stripeColor))
        .contentShape(Rectangle())
        .help(synthetic ? String(localized: "Space used by the system, APFS snapshots, purgeable data, and folders without access") : tree.path(id))
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

    /// Shown only when zoomed in: the way back up and where the map is.
    private func treemapHudBar(_ tree: DiskTree) -> some View {
        HStack(spacing: 8) {
            if let parent = tree.parent(mapScope) {
                Button {
                    openMapNode(parent, in: tree)
                } label: {
                    Label("Up", systemImage: "arrow.up")
                }
                .buttonStyle(.borderless)
                .font(FinderUI.captionFont)
                .help("Show the parent folder on the map")
            }
            Text(zoomPath(in: tree))
                .font(FinderUI.detailFont.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.head)
            Text("· \(FormatHelpers.formatBytes(tree.allocatedSize(mapScope)))")
                .font(FinderUI.detailFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, FinderUI.sectionSpacing)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func selectionStrip(_ node: DiskTree.NodeID, tree: DiskTree) -> some View {
        let size = tree.allocatedSize(node)
        let share = totalScannedBytes > 0 ? Double(size) / Double(totalScannedBytes) : 0
        return HStack(spacing: 8) {
            Circle()
                .fill(tree.category(node).treemapColor)
                .frame(width: 8, height: 8)
            Text(tree.name(node))
                .font(FinderUI.detailFont.weight(.semibold))
                .lineLimit(1)
            Text("\(FormatHelpers.formatBytes(size)) · \(share.formatted(.percent.precision(.fractionLength(1))))")
                .font(FinderUI.detailFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let parent = tree.parent(node) {
                Text(tree.path(parent))
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.regularMaterial)
        .allowsHitTesting(false)
    }

    /// A small card next to the pointer naming the tile under it.
    private func mapCallout(_ tile: DiskMapTile, tree: DiskTree) -> some View {
        let size = tile.isRemainder ? remainderSize(tile, in: tree) : tree.allocatedSize(tile.node)
        let share = totalScannedBytes > 0 ? Double(size) / Double(totalScannedBytes) : 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tree.category(tile.node).treemapColor)
                    .frame(width: 8, height: 8)
                Text(tile.isRemainder ? String(localized: "Smaller items") : tree.name(tile.node))
                    .font(FinderUI.detailFont.weight(.semibold))
                    .lineLimit(1)
            }
            Text("\(FormatHelpers.formatBytes(size)) · \(share.formatted(.percent.precision(.fractionLength(1))))")
                .font(FinderUI.captionFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let parent = tree.parent(tile.node), parent != mapScope || tile.isRemainder {
                Text("in \(tree.name(parent))")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)) }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
        .allowsHitTesting(false)
    }

    private func zoomPath(in tree: DiskTree) -> String {
        var names: [String] = []
        var node: DiskTree.NodeID? = mapScope
        while let current = node {
            names.append(tree.name(current))
            node = tree.parent(current)
        }
        return names.reversed().joined(separator: " › ")
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
                        .accessibilityLabel("Used space map")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let selected = selectedNode, let tile = mapLayout?.tile(for: selected, in: tree) {
                    mapHighlight(tile, color: .white, lineWidth: 2)
                }
                // The selected item, named in full along the bottom of the map.
                if let selected = selectedNode, hoveredTile == nil {
                    selectionStrip(selected, tree: tree)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                if let hoveredTile {
                    mapHighlight(hoveredTile, color: .white.opacity(0.85), lineWidth: 1)
                    // Beside the pointer, flipped to stay inside the map.
                    mapCallout(hoveredTile, tree: tree)
                        .alignmentGuide(.leading) { card in
                            let x = mapHoverLocation.x + 14
                            return -(x + card.width > geo.size.width ? mapHoverLocation.x - card.width - 10 : x)
                        }
                        .alignmentGuide(.top) { card in
                            let y = mapHoverLocation.y + 16
                            return -(y + card.height > geo.size.height ? mapHoverLocation.y - card.height - 8 : y)
                        }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let tile = mapTile(at: location)
                    mapHoverLocation = location
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
            .onChange(of: colorScheme) { _, _ in renderMap() }
            .help("Click an item to locate it in the tree. Double-click a folder to zoom in.")
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
                    Label("Open Folder in Analysis", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            } else if let parent = tree.parent(id) {
                Button {
                    openMapNode(parent, in: tree)
                } label: {
                    Label("Open Parent Folder in Analysis", systemImage: "arrow.down.right.and.arrow.up.left")
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
                Label("Show in File List", systemImage: "list.bullet")
            }
            Button {
                performPaneAction { QuickLookCoordinator.shared.preview(ownerID: pane.id, urls: [item.url]) }
            } label: {
                Label("Quick Look (Space)", systemImage: "eye")
            }
            Button {
                performPaneAction { FileOperationsManager.shared.openInTerminal(at: item.url) }
            } label: {
                Label("Open in Terminal", systemImage: "terminal")
            }
            Divider()
            Button(role: .destructive) {
                performPaneAction { trashAnalyzedItem(item, generation: generation) }
            } label: {
                Label("Move to Trash", systemImage: "trash")
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
            .help("Move to Trash: \(item.name)")
            .accessibilityLabel("Move to Trash: \(item.name)")
        }
        .padding(.horizontal, FinderUI.sectionSpacing)
        .padding(.vertical, 6)
        .background(isSelected ? selectionBackgroundColor : (index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025)))
        .contentShape(Rectangle())
        .help(item.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Select")) {
            selectAnalyzedItem(item, generation: generation)
        }
        .onTapGesture { selectAnalyzedItem(item, generation: generation) }
    }

    // MARK: - Duplicate Files View (SHA-256)

    private var duplicatesScannerView: some View {
        VStack(spacing: 0) {
            if duplicateGroups.isEmpty {
                analysisEmptyState(
                    title: scanIsComplete ? String(localized: "No duplicates found in the scanned scope") : String(localized: "No duplicates found in the partially checked scope"),
                    message: String(localized: "The full contents of files were compared using SHA-256, including empty and large files. Symbolic links are not followed. Hidden files depend on the view setting."),
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
            Text("Duplicate groups: \(duplicateGroups.count) · Redundant logical data: \(FormatHelpers.formatBytes(totalWasted))")
                .font(FinderUI.detailFont.weight(.semibold))
            Button("Move Redundant Copies to Trash", role: .destructive) {
                performPaneAction { trashDuplicates(groups, generation: generation) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isValidatingDuplicates || cleanupID != nil || fileOps.isBusy || !scanIsComplete)
            .help("Keep the first file in each group and verify the rest before moving them to the Trash")

            if cleanupID != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(cleanupIsCancelling ? String(localized: "Cancelling after the current operation…") : String(localized: "Moving duplicates to the Trash…"))
                        .font(FinderUI.captionFont)
                    Button("Cancel Remaining Steps") {
                        guard let id = cleanupID else { return }
                        cleanupCancelRequested = true
                        FileOperationsManager.shared.cancelDuplicateCleanup(id)
                    }
                    .disabled(cleanupIsCancelling)
                }
                Text("The current system operation may still be running. Files already moved are not restored automatically.")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
            }
            if cleanupID == nil && fileOps.isBusy {
                Text("Wait for the current file operation to finish.")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
            }
            if !scanIsComplete {
                Text("Removing duplicates is disabled for an incomplete scan. Refresh the analysis and fix the cause of the skipped items.")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.orange)
            }
            if isValidatingDuplicates {
                HStack(spacing: FinderUI.rowSpacing) {
                    ProgressView().controlSize(.small)
                    Text(verificationWorkState == .queued ? String(localized: "Verification queued…") : String(localized: "Verifying files before moving…"))
                        .font(FinderUI.captionFont)
                }
                .accessibilityElement(children: .combine)
                Button("Cancel Verification") { cancelVerification() }.controlSize(.small)
            }
            Text("In each group the designated original is kept. Logical size does not guarantee reclaimed space: hard links, APFS clones, and compression can share data.")
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
            Text("Copies: \(group.files.count) · \(FormatHelpers.formatBytes(group.fileSize)) per file")
                .font(FinderUI.detailFont.weight(.semibold))
            Text("Redundant logical data: \(FormatHelpers.formatBytes(group.wastedBytes))")
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
                Label("Original Kept", systemImage: "checkmark.shield")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
            } else {
                Button("Move to Trash", role: .destructive) {
                    performPaneAction { trashDuplicates([group], generation: generation, onlyPath: file.path) }
                }
                .disabled(isValidatingDuplicates || cleanupID != nil || fileOps.isBusy || !scanIsComplete)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Move to Trash: \(file.name)")
            }
        }
        .padding(FinderUI.compactSpacing)
        .background(isSelected ? selectionBackgroundColor : Color.clear, in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))
        .contentShape(Rectangle())
        .help(file.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(file.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Select")) {
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
                    self.scanDiagnostic = String(localized: "Deferred: analysis slots are busy. Use Refresh to try again.")
                } else if state == .cancelled {
                    self.isScanning = false
                    self.scanIsComplete = false
                    self.scanDiagnostic = String(localized: "Analysis canceled. Use Refresh to try again.")
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
        scanDiagnostic = String(localized: "Scan canceled. A system read in progress may still be finishing.")
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
        duplicateActionError = String(localized: "Verification canceled. A system read in progress may still be finishing.")
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
        let dark = colorScheme == .dark
        mapRenderTask = Task { @MainActor in
            // Coalesces live window resizing.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) { () -> DiskMapRendering? in
                tree.read {
                    guard let layout = DiskMapLayoutEngine.layout(tree: tree, scope: scope, width: width, height: height,
                                                                  scale: Double(scale), isCancelled: { Task.isCancelled }),
                          let image = DiskMapRenderer.image(layout: layout, tree: tree, scale: Double(scale), dark: dark,
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
        FileOperationsManager.shared.moveToTrash([item]) {
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
                    self.duplicateActionError = String(localized: "Verification deferred: analysis is busy. Try the operation again.")
                } else if state == .cancelled {
                    self.isValidatingDuplicates = false
                    self.duplicateActionError = String(localized: "Verification canceled.")
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
                        self.duplicateActionError = FileOperationsManager.shared.lastStatusMessage ?? String(localized: "Duplicate removal did not start.")
                    }
                case .failed(let message):
                    self.duplicateActionError = message
                }
            })
    }
}
