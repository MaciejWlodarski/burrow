import Foundation
import Darwin
import AppKit
import Combine

public enum FinderViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case icons = "Icons"
    case columns = "Columns"
    case wiztree = "WizTree"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .list: return String(localized: "List")
        case .icons: return String(localized: "Icons")
        case .columns: return String(localized: "Columns")
        case .wiztree: return String(localized: "Disk Map")
        }
    }

    public var iconName: String {
        switch self {
        case .list: return "list.bullet"
        case .icons: return "square.grid.2x2"
        case .columns: return "rectangle.split.3x1"
        case .wiztree: return "chart.pie"
        }
    }
}

public enum SortField: String, CaseIterable, Identifiable, Codable, Sendable {
    case name = "Name"
    case size = "Size"
    case dateModified = "Date Modified"
    case kind = "Kind"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .name: return String(localized: "Name")
        case .size: return String(localized: "Size")
        case .dateModified: return String(localized: "Date Modified")
        case .kind: return String(localized: "Kind")
        }
    }
}

@MainActor
public final class PaneTabState: ObservableObject, Identifiable {
    public let id = UUID()

    /// Synchronous navigation identity for pending operations. Unlike a view
    /// onChange callback this advances before another actor task can commit.
    public private(set) var navigationRevision: UInt64 = 0
    @Published public var currentURL: URL {
        didSet {
            if oldValue != currentURL {
                navigationRevision &+= 1
                cancelSessionRestoration()
                // Each folder opens with its own sort, or the default.
                applyFolderSort()
            }
        }
    }
    @Published public var historyBack: [URL] = []
    @Published public var historyForward: [URL] = []

    @Published public var directoryItems: [FileItem] = []
    @Published public private(set) var directoryRevision: UInt64 = 0
    @Published public var displayedItems: [FileItem] = []
    @Published public var selectedPaths: Set<String> = []
    @Published public var expandedFolderPaths: Set<String> = []

    @Published public var viewMode: FinderViewMode = .list {
        didSet {
            guard oldValue != viewMode else { return }
            cancelSessionRestoration()
            clearAnalysisSelection()
            if viewMode != .list { expandedFolderPaths.removeAll() }
            rebuildDisplayedItemsWithExpandedTree()
            reconcileSelection()
            directoryRevision &+= 1
        }
    }
    @Published public var sortField: SortField = .name
    @Published public var sortAscending: Bool = true
    @Published public var foldersOnTop: Bool = true
    private var folderSortSubscription: AnyCancellable?

    public var currentSort: FolderSort {
        FolderSort(field: sortField, ascending: sortAscending, foldersOnTop: foldersOnTop)
    }

    /// Loads the current folder's sort without re-sorting; callers that install
    /// a new listing sort it afterwards.
    func applyFolderSort() {
        let sort = FolderSortPreferences.shared.sort(for: currentURL)
        if sortField != sort.field { sortField = sort.field }
        if sortAscending != sort.ascending { sortAscending = sort.ascending }
        if foldersOnTop != sort.foldersOnTop { foldersOnTop = sort.foldersOnTop }
    }

    /// Follows changes made in Settings or in another tab showing this folder.
    private func refreshFolderSort() {
        guard FolderSortPreferences.shared.sort(for: currentURL) != currentSort else { return }
        applyFolderSort()
        applySortChange()
    }

    /// A view picked by the user is remembered for this folder; the disk map
    /// is not. Results of a whole-index search do not change the folder.
    public func chooseViewMode(_ mode: FinderViewMode) {
        viewMode = mode
        let isGlobalSearch = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchScope == .wholeIndex
        if !isGlobalSearch { FolderViewPreferences.shared.setMode(mode, for: currentURL) }
    }

    /// Opening a folder from a list or icons view shows it in its own view or
    /// the default. Columns and the disk map span folders, so browsing inside
    /// them keeps them.
    private func applyFolderViewMode() {
        guard viewMode == .list || viewMode == .icons else { return }
        let mode = FolderViewPreferences.shared.mode(for: currentURL)
        if viewMode != mode { viewMode = mode }
    }

    /// A sort chosen by the user applies to this folder only. Sorting results
    /// of a whole-index search does not change the folder behind them.
    public func setSort(_ sort: FolderSort) {
        let isGlobalSearch = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchScope == .wholeIndex
        sortField = sort.field
        sortAscending = sort.ascending
        foldersOnTop = sort.foldersOnTop
        applySortChange()
        if !isGlobalSearch { FolderSortPreferences.shared.setSort(sort, for: currentURL) }
    }
    @Published public var showHiddenFiles: Bool = false {
        didSet { if oldValue != showHiddenFiles { cancelSessionRestoration() } }
    }

    // Integrated fsearch state
    @Published public var searchQuery: String = "" {
        didSet { if oldValue != searchQuery { cancelSessionRestoration(); revokeResultsIfSessionPaused() } }
    }
    @Published public var searchScope: SearchScopeMode = .wholeIndex {
        didSet { if oldValue != searchScope { cancelSessionRestoration(); revokeResultsIfSessionPaused() } }
    }
    @Published public var fuzzyEnabled: Bool = true {
        didSet { if oldValue != fuzzyEnabled { cancelSessionRestoration() } }
    }
    @Published public var isSearching: Bool = false
    @Published public var lastSearchLatencyMs: Double = 0
    @Published public var activeFilterPills: [ActiveFilterPill] = []
    @Published public var searchBackendName: String = "fsearch-native"
    @Published public private(set) var searchDiagnostic: String?
    @Published public private(set) var searchIsPartial: Bool = false

    // Inline editing / path bar state
    @Published public var isEditingPathBar: Bool = false
    @Published public private(set) var pathEditRequest: UInt64 = 0

    public func requestPathEditing() {
        isEditingPathBar = true
        pathEditRequest &+= 1
    }
    @Published public var renamingItemPath: String? = nil
    @Published public var focusFilePaneTrigger: UInt64 = 0
    @Published public var selectionCursorPath: String?
    private var selectionAnchorPath: String?

    // Miller column trail
    @Published public var columnTrailURLs: [URL] = []

    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var searchContext: String?
    private var directoryLoadGeneration: UInt64 = 0
    @Published private var analysisItems: [FileItem] = []
    private var analysisRootPath: String?
    private var analysisGeneration: UUID?
    @Published public private(set) var tagMetadataRevision: UInt64 = 0
    private var metadataGeneration: UInt64 = 0
    private var tagCache: [String: [FinderTagColor]] = [:]
    private var pendingTagPaths: Set<String> = []
    private var tagOperations: [Operation] = []
    private static let metadataQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.burrow.tag-metadata"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    // Scroll geometry is bookkeeping, not observable UI state. Keep it per tab
    // and location without invalidating every row on each wheel event.
    let scrollHistory = PaneScrollHistory()
    var scrollContext: String { "\(currentURL.path)\u{0}\(viewMode.rawValue)\u{0}\(searchScope.rawValue)\u{0}\(searchQuery)" }

    public var title: String {
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return searchQuery
        }
        let name = currentURL.lastPathComponent
        if currentURL.deletingLastPathComponent().path.hasSuffix("/Library/CloudStorage") {
            return CloudFiles.describe(folderName: name).0
        }
        return name.isEmpty || name == "/" ? "Macintosh HD" : name
    }

    /// The only projection eligible for keyboard commands and file operations.
    public var selectableItems: [FileItem] {
        if isSessionPaused { return [] }
        if viewMode == .wiztree && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return analysisRootPath == currentURL.path ? analysisItems : []
        }
        return displayedItems
    }

    public var selectedItems: [FileItem] {
        selectableItems.filter { selectedPaths.contains($0.path) }
    }

    public var primarySelectedItem: FileItem? {
        if let cursor = selectionCursorPath, selectedPaths.contains(cursor),
           let item = selectableItems.first(where: { $0.path == cursor }) {
            return item
        }
        return selectableItems.first(where: { selectedPaths.contains($0.path) })
    }

    public var renamingItem: FileItem? {
        guard let path = renamingItemPath else { return nil }
        return selectableItems.first { $0.path == path }
    }

    public func beginAnalysisProjection(rootPath: String, generation: UUID) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        guard viewMode == .wiztree, root == currentURL.path,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearAnalysisSelection()
        analysisRootPath = root
        analysisGeneration = generation
    }

    public func publishAnalysisItems(_ items: [FileItem], rootPath: String, generation: UUID) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        guard viewMode == .wiztree, root == currentURL.path,
              root == analysisRootPath, generation == analysisGeneration,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var seen = Set<String>()
        analysisItems = items.filter {
            ($0.path == root || $0.path.hasPrefix(root == "/" ? "/" : root + "/")) && seen.insert($0.path).inserted
        }
        reconcileSelection()
    }

    public func setAnalysisSelection(_ items: [FileItem], rootPath: String) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        guard viewMode == .wiztree, root == currentURL.path, root == analysisRootPath,
              searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let visible = Set(analysisItems.map(\.path))
        let selected = items.filter { visible.contains($0.path) }
        selectedPaths = Set(selected.map(\.path))
        selectionCursorPath = selected.last?.path
        selectionAnchorPath = selected.first?.path
        QuickLookCoordinator.shared.updateIfVisible(ownerID: id, urls: selectedItems.map(\.url))
    }

    public func clearAnalysisSelection() {
        if analysisRootPath != nil {
            renamingItemPath = nil
            selectedPaths.removeAll()
            selectionCursorPath = nil
            selectionAnchorPath = nil
            QuickLookCoordinator.shared.updateIfVisible(ownerID: id, urls: [])
        }
        analysisRootPath = nil
        analysisGeneration = nil
        analysisItems.removeAll()
    }

    /// Context-menu actions re-resolve their targets at invocation time.
    public func actionItems(for item: FileItem) -> [FileItem] {
        guard let current = selectableItems.first(where: { $0.path == item.path }) else { return [] }
        return selectedPaths.contains(item.path) ? selectedItems : [current]
    }

    private func reconcileSelection() {
        let visible = Set(selectableItems.map(\.path))
        if let renamingItemPath, !visible.contains(renamingItemPath) { self.renamingItemPath = nil }
        selectedPaths.formIntersection(visible)
        if let cursor = selectionCursorPath, !visible.contains(cursor) { selectionCursorPath = nil }
        if let anchor = selectionAnchorPath, !visible.contains(anchor) { selectionAnchorPath = nil }
        QuickLookCoordinator.shared.updateIfVisible(ownerID: id, urls: selectedItems.map(\.url))
    }

    enum SessionAvailability: Equatable {
        case ready, paused, loading, unavailable(String)
    }
    let wasRestoredFromSession: Bool
    @Published private(set) var sessionAvailability: SessionAvailability = .ready
    private var sessionWork: BackgroundWork<PreparedFolder>?
    var isSessionPaused: Bool { sessionAvailability != .ready }

    func cancelSessionRestoration() {
        sessionWork?.cancel()
        sessionWork = nil
        if sessionAvailability == .loading { sessionAvailability = .paused }
    }

    /// Whether a restored pane may open without the user pressing Resume.
    /// Reading the mount table does no I/O on the folder itself.
    nonisolated static func resumesAutomatically(path: String, viewMode: FinderViewMode,
                                                 volumeRoot: (String) -> String = DiskScanBoundary.volumeRoot(of:)) -> Bool {
        guard viewMode != .wiztree else { return false }
        if path.hasPrefix("/Volumes/") && volumeRoot(path) == "/" { return false }
        return true
    }

    /// Opened by the user or automatically at launch. Runs on the background folder queue (two bounded workers),
    /// never adds roots to the index, and commits only the captured view context.
    @discardableResult
    func resumeSession(timeoutNanoseconds: UInt64 = 8_000_000_000,
                       prepare: (@Sendable (String, Bool) throws -> PreparedFolder)? = nil) async -> Bool {
        guard isSessionPaused else { return true }
        cancelSessionRestoration()
        let context = activationContext
        let path = currentURL.path
        let hidden = showHiddenFiles
        let request = BackgroundWork<PreparedFolder>()
        sessionWork = request
        sessionAvailability = .loading
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled, let self, self.sessionWork === request else { return }
            request.cancel()
            self.sessionAvailability = .unavailable(String(localized: "The folder did not respond in time. The path was kept; this does not mean the folder does not exist."))
        }
        defer {
            timeout.cancel()
            if sessionWork === request { sessionWork = nil }
        }
        do {
            let prepared = try await BackgroundFolderQueue.run({
                if let prepare { return try prepare(path, hidden) }
                return try FinderSessionPreparation.prepare(path: path, hidden: hidden, isCancelled: { request.isCancelled })
            }, request: request)
            guard !Task.isCancelled, !request.isCancelled, sessionWork === request,
                  context == activationContext else { return false }
            sessionWork = nil
            clearNavigationFailure()
            sessionAvailability = .ready
            directoryLoadGeneration &+= 1
            directoryItems = sortItems(prepared.entries.map { $0.toFileItem(treeDepth: 0, loadTags: false) })
            directoryRevision &+= 1
            // Resuming re-runs the search the pane was saved with.
            triggerSearch()
            return true
        } catch {
            guard sessionWork === request, context == activationContext else { return false }
            if sessionAvailability == .loading {
                sessionAvailability = request.isCancelled ? .paused : .unavailable((error as? FinderSessionReadError)?.errorDescription
                    ?? String(localized: "The folder is unavailable or its contents cannot be read. The path and settings were kept."))
            }
            return false
        }
    }

    public init(initialURL: URL, loadImmediately: Bool = true) {
        self.wasRestoredFromSession = !loadImmediately
        self.initialLocationEstablished = !loadImmediately
        self.currentURL = initialURL.standardizedFileURL
        self.columnTrailURLs = [initialURL.standardizedFileURL]
        scrollHistory.contextProvider = { [weak self] in self?.scrollContext }
        applyFolderSort()
        folderSortSubscription = FolderSortPreferences.shared.objectWillChange.sink { [weak self] _ in
            // objectWillChange precedes the new values; read them on the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshFolderSort() } }
        }
        if loadImmediately {
            // Restored panes keep their saved view; new ones open in the folder's.
            viewMode = FolderViewPreferences.shared.mode(for: currentURL)
            // A new pane is a snapshot consumer, not an explicit filesystem refresh.
            reloadDirectory(invalidateCaches: false)
        } else { sessionAvailability = .paused }
    }

    // Directory-only navigation. The injectable reader/opener keep failure tests
    // deterministic and ensure that history never becomes a file-open gesture.
    var navigationDirectoryReader: (String, Bool) -> BulkCrawler.DirectoryReadResult = {
        BulkCrawler.readDirectoryResult(at: $0, includeHidden: $1)
    } { didSet { readsDirectoriesInBackground = false } }
    /// The real reader runs off the main thread; injected test readers stay synchronous.
    private var readsDirectoriesInBackground = true
    /// A folder still being read after the short synchronous wait (a slow or
    /// network disk). The window stays responsive and shows it as opening.
    @Published private(set) var openingLocation: URL?
    private var pendingNavigationID: UUID?
    private var pendingReloadID: UUID?
    /// How long the main thread waits for a folder listing before showing
    /// it as opening. Tests wait long so slow CI machines stay deterministic.
    #if BURROW_TESTING
    nonisolated(unsafe) static var directoryReadWait: Double = 10
    #else
    static let directoryReadWait: Double = 0.15
    #endif
    var fileOpener: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    @Published private(set) var navigationDiagnostic: String?
    @Published private(set) var navigationFailureIsPermissionDenied = false
    private enum NavigationTransition { case direct(Bool, Bool), back, forward }
    @Published private(set) var navigationFailureID: UUID?
    private var failedNavigation: (URL, NavigationTransition, String)?
    private var navigationRetryContext: String {
        "\(navigationRevision)\u{0}\(directoryLoadGeneration)\u{0}\(currentURL.path)\u{0}\(searchQuery)\u{0}\(searchScope.rawValue)\u{0}\(showHiddenFiles)\u{0}\(viewMode.rawValue)"
    }

    /// System error descriptions often lack final punctuation; diagnostics append further sentences.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?…".contains(last) else { return text }
        return text + "."
    }

    private func clearNavigationFailure() {
        failedNavigation = nil
        navigationFailureID = nil
        navigationDiagnostic = nil
        navigationFailureIsPermissionDenied = false
    }

    func dismissNavigationFailure(expectedFailureID: UUID) {
        guard navigationFailureID == expectedFailureID else { return }
        clearNavigationFailure()
    }
    private var initialLocationEstablished = false

    func retainInitialLocation() { initialLocationEstablished = true }

    func openFile(_ url: URL) { fileOpener(url) }

    func openItems(_ items: [FileItem]) {
        let visible = Set(selectableItems.map(\.path))
        let targets = items.filter { visible.contains($0.path) }
        if targets.count == 1, let item = targets.first,
           item.isDirectory && item.fileExtension.lowercased() != "app" {
            navigate(to: item.url)
        } else {
            // Capture the batch before any external application gains focus.
            for item in targets { openFile(item.url) }
        }
    }

    func openSelectedItems() { openItems(selectedItems) }

    /// Only the first presentation may synchronize a pristine, fresh right pane.
    /// Session provenance never controls subsequent visibility changes.
    func initializeLocationIfNeeded(matching url: URL) {
        guard !initialLocationEstablished else { return }
        initialLocationEstablished = true
        navigate(to: url, recordHistory: false)
    }

    @discardableResult
    public func navigate(to url: URL, recordHistory: Bool = true, clearSearch: Bool = false) -> Bool {
        navigateDirectory(to: url, transition: .direct(recordHistory, clearSearch))
    }

    func retryNavigation(expectedFailureID: UUID? = nil) {
        if let expectedFailureID, expectedFailureID != navigationFailureID { return }
        guard let (url, transition, context) = failedNavigation else { return }
        guard context == navigationRetryContext else {
            clearNavigationFailure()
            return
        }
        _ = navigateDirectory(to: url, transition: transition)
    }

    @discardableResult
    private func navigateDirectory(to url: URL, transition: NavigationTransition) -> Bool {
        // Invalidate a Resume even when this attempt fails: its late completion
        // must not publish over the user's newer intent. Browsing state is retained.
        cancelSessionRestoration()
        // A newer request replaces one still waiting for a slow disk.
        pendingNavigationID = nil
        openingLocation = nil
        let standardized = url.standardizedFileURL
        let showHidden = showHiddenFiles
        let outcome: Result<[IndexedFileEntry], Error>
        if readsDirectoriesInBackground {
            let read = DirectoryReadHandoff()
            DispatchQueue.global(qos: .userInitiated).async {
                read.finish(Self.readNavigationTarget(standardized.path, includeHidden: showHidden,
                    reader: { BulkCrawler.readDirectoryResult(at: $0, includeHidden: $1) }))
            }
            // Local folders answer well within this; only slow disks go async.
            if let result = read.wait(seconds: Self.directoryReadWait) {
                outcome = result
            } else {
                let id = UUID()
                pendingNavigationID = id
                openingLocation = standardized
                read.whenFinished { result in
                    Task { @MainActor [weak self] in
                        guard let self, self.pendingNavigationID == id else { return }
                        self.pendingNavigationID = nil
                        self.openingLocation = nil
                        self.commitNavigation(to: standardized, transition: transition, outcome: result)
                    }
                }
                return true
            }
        } else {
            outcome = Self.readNavigationTarget(standardized.path, includeHidden: showHidden, reader: navigationDirectoryReader)
        }
        return commitNavigation(to: standardized, transition: transition, outcome: outcome)
    }

    nonisolated private static func readNavigationTarget(_ path: String, includeHidden: Bool,
        reader: (String, Bool) -> BulkCrawler.DirectoryReadResult) -> Result<[IndexedFileEntry], Error> {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)))
        }
        let result = reader(path, includeHidden)
        guard result.isComplete, result.errorCode == nil else {
            return .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(result.errorCode ?? EIO)))
        }
        return .success(result.entries)
    }

    @discardableResult
    private func commitNavigation(to standardized: URL, transition: NavigationTransition,
                                  outcome: Result<[IndexedFileEntry], Error>) -> Bool {
        let entries: [IndexedFileEntry]
        do {
            entries = try outcome.get()
        } catch {
            failedNavigation = (standardized, transition, navigationRetryContext)
            navigationFailureID = UUID()
            navigationFailureIsPermissionDenied = DirectoryNavigationFailure.isPermissionDenied(error)
            if navigationFailureIsPermissionDenied {
                navigationDiagnostic = String(localized: "macOS denied access to the folder “\(standardized.path)”. The current location and its contents were kept. Choose another location or check the permissions of this folder.")
            } else {
                navigationDiagnostic = String(localized: "Could not open the folder “\(standardized.path)”: \(Self.sentence(error.localizedDescription)) The current location and its contents were kept.")
            }
            return false
        }

        let clearSearch: Bool
        switch transition {
        case let .direct(recordHistory, clear):
            clearSearch = clear
            if recordHistory && standardized.path != currentURL.path {
                historyBack.append(currentURL)
                historyForward.removeAll()
            }
        case .back:
            guard historyBack.last == standardized else { return false }
            clearSearch = false
            historyBack.removeLast()
            historyForward.append(currentURL)
        case .forward:
            guard historyForward.last == standardized else { return false }
            clearSearch = false
            historyForward.removeLast()
            historyBack.append(currentURL)
        }
        scrollHistory.recordExpandedFolders(expandedFolderPaths, for: scrollContext)
        clearNavigationFailure()
        initialLocationEstablished = true
        sessionAvailability = .ready
        searchTask?.cancel()
        searchGeneration &+= 1
        isSearching = false
        clearAnalysisSelection()
        displayedItems.removeAll()
        searchContext = nil
        currentURL = standardized
        selectionCursorPath = nil
        selectionAnchorPath = nil
        selectedPaths.removeAll()
        expandedFolderPaths.removeAll()
        renamingItemPath = nil
        applyFolderViewMode()

        if clearSearch || (!searchQuery.isEmpty && searchScope == .wholeIndex) {
            searchQuery = ""
            activeFilterPills = []
        }
        // Rebuild the remembered outline before the view restores pixel geometry.
        if viewMode == .list { expandedFolderPaths = scrollHistory.expandedFolders(for: scrollContext) }
        // Install exactly the validated snapshot, never a second filesystem read.
        installDirectoryEntries(entries)
        FolderSizeCache.shared.noteListed(standardized.path)
        updateColumnTrail(for: standardized)
        FolderSizeCache.shared.revalidate(containing: standardized.path)
        FSearchIndex.shared.ensureDirectoryIndexed(standardized.path)
        AppState.shared.persistTabsState()
        return true
    }

    /// Everything a late background result must still match before it may
    /// commit: navigation, a new query or a view change makes it stale.
    var activationContext: String {
        "\(currentURL.path)\u{0}\(searchQuery)\u{0}\(searchScope.rawValue)\u{0}\(showHiddenFiles)\u{0}\(fuzzyEnabled)\u{0}\(viewMode.rawValue)\u{0}\(directoryLoadGeneration)"
    }

    public func goBack() {
        guard let prev = historyBack.last else { return }
        navigateDirectory(to: prev, transition: .back)
    }

    public func goForward() {
        guard let next = historyForward.last else { return }
        navigateDirectory(to: next, transition: .forward)
    }

    public func goUp() {
        let parent = currentURL.deletingLastPathComponent()
        guard parent.path != currentURL.path else { return }
        navigate(to: parent)
    }

    // MARK: - Outline Tree Disclosure (`▸`) in List View

    public func isExpanded(_ folderPath: String) -> Bool {
        expandedFolderPaths.contains(folderPath)
    }

    public func toggleFolderExpansion(for item: FileItem) {
        guard viewMode == .list, item.isDirectory, selectableItems.contains(where: { $0.path == item.path }) else { return }
        if expandedFolderPaths.contains(item.path) {
            expandedFolderPaths.remove(item.path)
            // Also collapse any nested subfolders under this folder
            let prefix = item.path + "/"
            expandedFolderPaths = expandedFolderPaths.filter { !$0.hasPrefix(prefix) }
        } else {
            expandedFolderPaths.insert(item.path)
        }
        rebuildDisplayedItemsWithExpandedTree()
    }

    public func reloadDirectory(invalidateCaches: Bool = true) {
        guard !isSessionPaused else {
            // Never re-read the paused root; the search shows nothing until Resume.
            triggerSearch()
            return
        }
        cancelSessionRestoration()
        let path = currentURL.path
        let showHidden = showHiddenFiles
        let read = DirectoryReadHandoff()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = BulkCrawler.readDirectoryResult(at: path, includeHidden: showHidden)
            read.finishRead(result)
        }
        // Local folders answer within the wait; a slow disk keeps the current
        // items on screen until its listing arrives.
        if let result = read.waitForRead(seconds: Self.directoryReadWait) {
            applyReload(result, invalidateCaches: invalidateCaches)
            return
        }
        let id = UUID()
        pendingReloadID = id
        let generation = directoryLoadGeneration
        read.whenReadFinished { result in
            Task { @MainActor [weak self] in
                guard let self, self.pendingReloadID == id, self.currentURL.path == path,
                      self.directoryLoadGeneration == generation, self.pendingNavigationID == nil else { return }
                self.pendingReloadID = nil
                self.applyReload(result, invalidateCaches: invalidateCaches)
            }
        }
    }

    private func applyReload(_ result: BulkCrawler.DirectoryReadResult, invalidateCaches: Bool) {
        guard result.isComplete, result.errorCode == nil else {
            // A failed refresh (deleted folder, dropped share) must not look like
            // a genuinely empty folder: clear the stale items and explain why.
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(result.errorCode ?? EIO))
            installDirectoryEntries([], invalidateCaches: invalidateCaches)
            failedNavigation = (currentURL, .direct(false, false), navigationRetryContext)
            navigationFailureID = UUID()
            navigationFailureIsPermissionDenied = DirectoryNavigationFailure.isPermissionDenied(error)
            navigationDiagnostic = String(localized: "Could not refresh the folder “\(currentURL.path)”: \(Self.sentence(error.localizedDescription)) Choose another location or try again.")
            return
        }
        if failedNavigation?.0 == currentURL { clearNavigationFailure() }
        installDirectoryEntries(result.entries, invalidateCaches: invalidateCaches)
        FolderSizeCache.shared.noteListed(currentURL.path)
    }

    private func installDirectoryEntries(_ entries: [IndexedFileEntry], invalidateCaches: Bool = false) {
        let targetPath = currentURL.path
        directoryLoadGeneration &+= 1
        let loadGeneration = directoryLoadGeneration
        // Invalidate consumers of this directory snapshot before a local query
        // starts asynchronous work. Its eventual result commit has its own revision.
        directoryRevision &+= 1
        if invalidateCaches {
            FileIconCache.shared.invalidate(containing: targetPath)
            FolderSizeCache.shared.invalidate(containing: targetPath)
        }
        clearAnalysisSelection()

        metadataGeneration &+= 1
        for operation in tagOperations { operation.cancel() }
        tagOperations.removeAll()
        tagCache.removeAll()
        pendingTagPaths.removeAll()
        let items = sortItems(entries.map { $0.toFileItem(treeDepth: 0, loadTags: false) })
        self.directoryItems = items
        triggerSearch()

        // A successful empty snapshot clears formerly dirty badges. Ignore
        // late responses even when the user has returned to the same folder.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let snapshot = FileOperationsManager.fetchGitStatusSnapshot(for: targetPath) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.currentURL.path == targetPath,
                      self.directoryLoadGeneration == loadGeneration else { return }
                FSearchIndex.shared.recordGitStatuses(snapshot.statuses, repositoryRoot: snapshot.repositoryRoot)
                var items = self.directoryItems
                var changed = false
                for idx in items.indices {
                    let status = snapshot.statuses[items[idx].path]
                    if items[idx].gitStatus != status { items[idx].gitStatus = status; changed = true }
                }
                if changed {
                    self.directoryItems = items
                    if self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.rebuildDisplayedItemsWithExpandedTree()
                    }
                }
            }
        }
    }

    private func rebuildDisplayedItemsWithExpandedTree() {
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if viewMode != .list || expandedFolderPaths.isEmpty {
            displayedItems = directoryItems
            reconcileSelection()
            loadTagMetadataIfNeeded(for: displayedItems)
            return
        }
        var flat: [FileItem] = []
        flat.reserveCapacity(directoryItems.count + expandedFolderPaths.count * 10)
        appendTreeItems(from: directoryItems, into: &flat)
        displayedItems = flat
        reconcileSelection()
        loadTagMetadataIfNeeded(for: flat)
    }

    private func appendTreeItems(from items: [FileItem], into output: inout [FileItem]) {
        for item in items {
            output.append(item)
            if item.isDirectory && expandedFolderPaths.contains(item.path) && item.treeDepth < 8 {
                let childEntries = BulkCrawler.readDirectoryFast(at: item.path, includeHidden: showHiddenFiles)
                let childItems = sortItems(childEntries.map {
                    var child = $0.toFileItem(treeDepth: item.treeDepth + 1, loadTags: false)
                    child.tags = tagCache[child.path] ?? []
                    return child
                })
                appendTreeItems(from: childItems, into: &output)
            }
        }
    }

    private func revokeResultsIfSessionPaused() {
        guard isSessionPaused else { return }
        searchTask?.cancel()
        searchGeneration &+= 1
        isSearching = false
        displayedItems.removeAll()
        selectedPaths.removeAll()
        selectionCursorPath = nil
        selectionAnchorPath = nil
        reconcileSelection()
    }

    public func triggerSearch() {
        guard !isSessionPaused else {
            revokeResultsIfSessionPaused()
            return
        }
        cancelSessionRestoration()
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = ParsedFSearchQuery.parse(searchQuery, fuzzyEnabled: fuzzyEnabled)
        activeFilterPills = parsed.pills
        searchDiagnostic = parsed.validationError
        searchIsPartial = false
        let context = "\(currentURL.path)\u{0}\(searchScope.rawValue)\u{0}\(q)\u{0}\(showHiddenFiles)\u{0}\(fuzzyEnabled)"
        if context != searchContext {
            selectedPaths.removeAll()
            selectionCursorPath = nil
            selectionAnchorPath = nil
            clearAnalysisSelection()
        }
        searchContext = context

        guard !q.isEmpty else {
            isSearching = false
            lastSearchLatencyMs = 0
            directoryItems = sortItems(directoryItems)
            rebuildDisplayedItemsWithExpandedTree()
            return
        }

        // Never leave results from a previous query or directory actionable.
        // Same-context refreshes may restore selection only after fresh results commit.
        displayedItems.removeAll()
        QuickLookCoordinator.shared.updateIfVisible(ownerID: id, urls: [])
        if parsed.validationError != nil {
            isSearching = false
            reconcileSelection()
            directoryRevision &+= 1
            return
        }
        isSearching = true
        let scope = searchScope
        let dirPath = currentURL.path
        let showHidden = showHiddenFiles
        let fuzzy = fuzzyEnabled

        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let bundle = FSearchIndex.shared.search(
                rawQuery: q,
                scope: scope,
                scopeDirectory: dirPath,
                includeHidden: showHidden,
                fuzzyEnabled: fuzzy,
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self = self, self.searchGeneration == generation else { return }
                self.displayedItems = self.sortItems(bundle.items)
                self.reconcileSelection()
                self.lastSearchLatencyMs = bundle.elapsedMilliseconds
                self.searchBackendName = bundle.backendName
                self.searchIsPartial = bundle.isPartial
                self.searchDiagnostic = bundle.diagnostic
                self.isSearching = false
                self.directoryRevision &+= 1
            }
        }
    }

    public func cachedTags(for path: String) -> [FinderTagColor]? { tagCache[path] }

    /// Native tag providers can block on cloud/network metadata. Never query them
    /// while building a view or initializing a tab on the main actor.
    public func loadTagMetadataIfNeeded(for items: [FileItem]) {
        guard !isSessionPaused else { return }
        let pending = items.filter { tagCache[$0.path] == nil && !pendingTagPaths.contains($0.path) }
        guard !pending.isEmpty else { return }
        pendingTagPaths.formUnion(pending.map(\.path))
        let generation = metadataGeneration
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            var batch: [String: [FinderTagColor]] = [:]
            var lastPublish = ContinuousClock.now
            for item in pending {
                guard let operation, !operation.isCancelled, self != nil else { return }
                batch[item.path] = FinderTagColor.readTags(for: item.url)
                if operation.isCancelled { return }
                if batch.count >= 256 || lastPublish.duration(to: .now) >= .milliseconds(100) {
                    let completed = batch
                    batch.removeAll(keepingCapacity: true)
                    lastPublish = .now
                    Task { @MainActor [weak self] in self?.installTagMetadata(completed, generation: generation) }
                }
            }
            let completed = batch
            Task { @MainActor [weak self] in self?.installTagMetadata(completed, generation: generation) }
        }
        tagOperations.removeAll { $0.isFinished || $0.isCancelled }
        tagOperations.append(operation)
        Self.metadataQueue.addOperation(operation)
    }

    private func installTagMetadata(_ batch: [String: [FinderTagColor]], generation: UInt64) {
        guard metadataGeneration == generation, !batch.isEmpty else { return }
        let changedTags = batch.filter { (tagCache[$0.key] ?? []) != $0.value }
        tagCache.merge(batch, uniquingKeysWith: { _, new in new })
        pendingTagPaths.subtract(batch.keys)
        guard !changedTags.isEmpty else { return }
        // Most files have no tags: cache that negative result without publishing
        // identical arrays. Tagged rows are installed once per batch, in O(n).
        func updated(_ items: [FileItem]) -> [FileItem]? {
            var copy = items
            var changed = false
            for index in copy.indices {
                if let tags = changedTags[copy[index].path], tags != copy[index].tags {
                    copy[index].tags = tags
                    changed = true
                }
            }
            return changed ? copy : nil
        }
        if let items = updated(directoryItems) { directoryItems = items }
        if let items = updated(displayedItems) { displayedItems = items }
        tagMetadataRevision &+= 1
    }

    public var visibleDirectoryPaths: Set<String> {
        var paths: Set<String> = [currentURL.path]
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return paths }
        if viewMode == .list { paths.formUnion(expandedFolderPaths) }
        if viewMode == .columns { paths.formUnion(columnTrailURLs.map(\.path)) }
        return paths
    }

    public func isAffectedByDirectoryChanges(_ changedDirectories: Set<String>) -> Bool {
        let changed = Set(changedDirectories.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let path = currentURL.path
        // Changes to a displayed directory, or its ancestor (removed/renamed
        // directory), invalidate its snapshot. Component boundaries are required.
        if visibleDirectoryPaths.contains(where: { visible in
            changed.contains { dir in visible == dir || visible.hasPrefix(dir == "/" ? "/" : dir + "/") }
        }) { return true }
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Disk-analysis views also depend on descendants of the root.
            return viewMode == .wiztree && changed.contains { $0.hasPrefix(path == "/" ? "/" : path + "/") }
        }
        switch searchScope {
        case .wholeIndex: return !changed.isEmpty
        case .currentFolder: return false
        case .recursiveFolder:
            return changed.contains { $0.hasPrefix(path == "/" ? "/" : path + "/") }
        }
    }

    public func refresh() {
        reloadDirectory()
    }

    public func clearSearch() {
        searchQuery = ""
        reloadDirectory()
    }

    /// Selects the listed paths that are visible; the cursor moves to the first one.
    public func selectPaths(_ paths: [String]) {
        let visible = Set(selectableItems.map(\.path))
        // Callers may pass symlink-resolved paths (/private/tmp/x/a for /tmp/x/a).
        let resolvedCurrent = currentURL.resolvingSymlinksInPath().path
        let matched = paths.compactMap { path -> String? in
            if visible.contains(path) { return path }
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == resolvedCurrent else { return nil }
            let local = currentURL.appendingPathComponent(url.lastPathComponent).path
            return visible.contains(local) ? local : nil
        }
        guard let first = matched.first else { return }
        selectedPaths = Set(matched)
        selectionAnchorPath = first
        selectionCursorPath = first
        QuickLookCoordinator.shared.updateIfVisible(ownerID: id, urls: selectedItems.map(\.url))
    }

    public func select(_ item: FileItem, extending: Bool = false, toggling: Bool = false) {
        let items = selectableItems
        guard items.contains(where: { $0.path == item.path }) else { return }
        if extending,
           let anchor = selectionAnchorPath ?? primarySelectedItem?.path,
           let start = items.firstIndex(where: { $0.path == anchor }),
           let end = items.firstIndex(where: { $0.path == item.path }) {
            selectionAnchorPath = anchor
            selectedPaths = Set(items[min(start, end)...max(start, end)].map(\.path))
        } else if toggling {
            if selectedPaths.contains(item.path) { selectedPaths.remove(item.path) }
            else { selectedPaths.insert(item.path) }
            selectionAnchorPath = item.path
        } else {
            selectedPaths = [item.path]
            selectionAnchorPath = item.path
        }
        selectionCursorPath = item.path
        QuickLookCoordinator.shared.updateIfVisible(ownerID: id, urls: selectedItems.map(\.url))
    }

    public func moveSelection(by delta: Int, extending: Bool = false) {
        let items = selectableItems
        guard !items.isEmpty else { return }
        let current = selectionCursorPath.flatMap { path in items.firstIndex(where: { $0.path == path }) }
            ?? primarySelectedItem.flatMap { item in items.firstIndex(where: { $0.path == item.path }) }
        let next = current.map { max(0, min(items.count - 1, $0 + delta)) }
            ?? (delta > 0 ? 0 : items.count - 1)
        select(items[next], extending: extending)
    }

    /// Finder-style type-to-select: keystrokes within a short pause extend the
    /// typed prefix; the first visible item whose name starts with it is selected.
    private var typeSelectBuffer = ""
    private var typeSelectLastInput = Date.distantPast

    @discardableResult
    public func typeSelect(_ characters: String, now: Date = Date()) -> Bool {
        if now.timeIntervalSince(typeSelectLastInput) > 1.0 { typeSelectBuffer = "" }
        typeSelectLastInput = now
        typeSelectBuffer += characters
        let prefix = typeSelectBuffer
        let items = selectableItems
        guard let match = items.first(where: {
            $0.name.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }) ?? items.first(where: {
            // No exact prefix: fall back to the first name sorting after the prefix, like Finder.
            $0.name.localizedStandardCompare(prefix) == .orderedDescending
        }) else { return false }
        select(match)
        return true
    }

    public func selectBoundary(last: Bool, extending: Bool = false) {
        let items = selectableItems
        guard let target = last ? items.last : items.first else { return }
        select(target, extending: extending)
    }

    public func selectAll() {
        let items = selectableItems
        selectedPaths = Set(items.map(\.path))
        selectionAnchorPath = items.first?.path
        selectionCursorPath = items.last?.path
        QuickLookCoordinator.shared.updateIfVisible(ownerID: id, urls: selectedItems.map(\.url))
    }

    public func removeFilterPill(_ pill: ActiveFilterPill) {
        searchQuery = ParsedFSearchQuery.removing(pill, from: searchQuery)
        triggerSearch()
    }

    public func appendSearchOperator(_ token: String) {
        searchQuery = ParsedFSearchQuery.togglingOperator(token, in: searchQuery)
        triggerSearch()
    }

    public func applySortChange() {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            directoryItems = sortItems(directoryItems)
            rebuildDisplayedItemsWithExpandedTree()
        } else {
            displayedItems = sortItems(displayedItems)
        }
    }

    public func sortItems(_ list: [FileItem]) -> [FileItem] {
        list.sorted { a, b in
            if foldersOnTop && a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            let cmp: Bool
            switch sortField {
            case .name:
                cmp = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size:
                let exactA = a.isDirectory ? FolderSizeCache.shared.size(for: a.path) : a.size
                let exactB = b.isDirectory ? FolderSizeCache.shared.size(for: b.path) : b.size
                if (exactA == nil) != (exactB == nil) { return exactA != nil }
                let sizeA = exactA ?? FolderSizeCache.shared.result(for: a.path)?.bytes
                let sizeB = exactB ?? FolderSizeCache.shared.result(for: b.path)?.bytes
                if (sizeA == nil) != (sizeB == nil) { return sizeA != nil }
                if let sizeA, let sizeB, sizeA != sizeB {
                    cmp = sizeA < sizeB
                } else {
                    cmp = a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            case .dateModified:
                if a.modificationDate != b.modificationDate {
                    cmp = a.modificationDate < b.modificationDate
                } else {
                    cmp = a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            case .kind:
                if a.kindDisplayString != b.kindDisplayString {
                    cmp = a.kindDisplayString < b.kindDisplayString
                } else {
                    cmp = a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            if a.path == b.path { return false }
            let equal: Bool
            switch sortField {
            case .name: equal = a.name.localizedStandardCompare(b.name) == .orderedSame
            case .size:
                let sizeA = a.isDirectory ? FolderSizeCache.shared.result(for: a.path)?.bytes : a.size
                let sizeB = b.isDirectory ? FolderSizeCache.shared.result(for: b.path)?.bytes : b.size
                equal = sizeA == sizeB && a.name.localizedStandardCompare(b.name) == .orderedSame
            case .dateModified: equal = a.modificationDate == b.modificationDate && a.name.localizedStandardCompare(b.name) == .orderedSame
            case .kind: equal = a.kindDisplayString == b.kindDisplayString && a.name.localizedStandardCompare(b.name) == .orderedSame
            }
            if equal { return a.path < b.path }
            return sortAscending ? cmp : !cmp
        }
    }

    private func updateColumnTrail(for url: URL) {
        if let idx = columnTrailURLs.firstIndex(of: url) {
            columnTrailURLs = Array(columnTrailURLs.prefix(through: idx))
        } else if let last = columnTrailURLs.last, url.deletingLastPathComponent().path == last.path {
            columnTrailURLs.append(url)
            if columnTrailURLs.count > 4 {
                columnTrailURLs.removeFirst(columnTrailURLs.count - 4)
            }
        } else {
            let parent = url.deletingLastPathComponent()
            if parent.path != url.path {
                columnTrailURLs = [parent, url]
            } else {
                columnTrailURLs = [url]
            }
        }
    }
}

/// Hands a directory read from a worker to the main thread: either within a
/// short synchronous wait, or later through a callback.
private final class DirectoryReadHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<[IndexedFileEntry], Error>?
    private var callback: (@Sendable (Result<[IndexedFileEntry], Error>) -> Void)?
    private var readResult: BulkCrawler.DirectoryReadResult?
    private var readCallback: (@Sendable (BulkCrawler.DirectoryReadResult) -> Void)?

    func finishRead(_ value: BulkCrawler.DirectoryReadResult) {
        lock.lock()
        readResult = value
        let waiting = readCallback
        lock.unlock()
        done.signal()
        waiting?(value)
    }

    func waitForRead(seconds: Double) -> BulkCrawler.DirectoryReadResult? {
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return readResult
    }

    func whenReadFinished(_ handler: @escaping @Sendable (BulkCrawler.DirectoryReadResult) -> Void) {
        lock.lock()
        if let readResult {
            lock.unlock()
            handler(readResult)
        } else {
            readCallback = handler
            lock.unlock()
        }
    }

    func finish(_ value: Result<[IndexedFileEntry], Error>) {
        lock.lock()
        result = value
        let waiting = callback
        lock.unlock()
        done.signal()
        waiting?(value)
    }

    func wait(seconds: Double) -> Result<[IndexedFileEntry], Error>? {
        guard done.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return result
    }

    func whenFinished(_ handler: @escaping @Sendable (Result<[IndexedFileEntry], Error>) -> Void) {
        lock.lock()
        if let result {
            lock.unlock()
            handler(result)
        } else {
            callback = handler
            lock.unlock()
        }
    }
}
