import Foundation
import Combine
import AppKit
import QuickLookUI

public enum PaneSide: String, Sendable {
    case left
    case right
}

public struct SidebarLocationItem: Identifiable, Hashable {
    public var id: String { bookmarkPath ?? url.path }
    public var bookmarkPath: String? = nil
    public let title: String
    public let iconName: String
    public let url: URL
    public let isCustomBookmark: Bool
}

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    // A test executable must never restore or write the user's real preferences,
    // enumerate their home, or automatically start the indexer.
    static let preferences: UserDefaults = {
        #if BURROW_TESTING
        guard let suite = UserDefaults(suiteName: "com.burrow.tests.\(UUID().uuidString)") else {
            fatalError("Could not create isolated test preferences")
        }
        return suite
        #else
        return UserDefaults.standard
        #endif
    }()

    private static var homeDirectoryURL: URL {
        #if BURROW_TESTING
        guard let root = ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"],
              root.hasPrefix("/"), FileManager.default.fileExists(atPath: root) else {
            fatalError("BURROW_TEST_ROOT must identify an isolated test directory")
        }
        return URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    /// Exact special sidebar location; test builds use the isolated fixture home.
    var systemTrashURL: URL { Self.homeDirectoryURL.appendingPathComponent(".Trash", isDirectory: true) }

    let terminalWorkspace = TerminalWorkspace()

    @Published public var tabs: [PaneTabState] = [] {
        didSet { observeSessionPanes(); observeVisibleDirectories(); synchronizeQuickLookOwnership() }
    }
    @Published public var activeTabId: UUID {
        didSet {
            if oldValue != activeTabId { tabs.first { $0.id == oldValue }?.cancelSessionRestoration() }
            synchronizeQuickLookOwnership()
        }
    }

    // Dual-pane mode
    @Published public var isDualPane: Bool = false {
        didSet {
            Self.preferences.set(isDualPane, forKey: "bf.isDualPane")
            if !isDualPane { rightPane.cancelSessionRestoration() }
            synchronizeQuickLookOwnership()
        }
    }
    /// The right pane keeps its own tabs, like the left pane's `tabs`.
    @Published public var rightTabs: [PaneTabState] = [] {
        didSet { observeSessionPanes(); observeVisibleDirectories(); synchronizeQuickLookOwnership() }
    }
    @Published public var activeRightTabId: UUID {
        didSet {
            if oldValue != activeRightTabId { rightTabs.first { $0.id == oldValue }?.cancelSessionRestoration() }
            synchronizeQuickLookOwnership()
        }
    }
    /// The right pane's selected tab.
    public var rightPane: PaneTabState {
        get { rightTabs.first(where: { $0.id == activeRightTabId }) ?? rightTabs[0] }
        // Replaces the selected right-pane tab (restoration and tests).
        set {
            if let index = rightTabs.firstIndex(where: { $0.id == activeRightTabId }) {
                rightTabs[index] = newValue
            } else {
                rightTabs = [newValue]
            }
            activeRightTabId = newValue.id
        }
    }
    /// Every tab in both panes.
    public var allPanes: [PaneTabState] { tabs + rightTabs }

    public func tabs(on side: PaneSide) -> [PaneTabState] { side == .left ? tabs : rightTabs }
    public func activeTabID(on side: PaneSide) -> UUID { side == .left ? activeTabId : activeRightTabId }
    public func side(ofTab id: UUID) -> PaneSide? {
        tabs.contains { $0.id == id } ? .left : (rightTabs.contains { $0.id == id } ? .right : nil)
    }
    public func selectTab(_ id: UUID) {
        guard let side = side(ofTab: id) else { return }
        if side == .left { activeTabId = id } else { activeRightTabId = id }
        activePaneSide = side
        persistTabsState()
    }
    /// New tabs open in the pane being worked in.
    private var tabSide: PaneSide { isDualPane ? activePaneSide : .left }
    @Published public var activePaneSide: PaneSide = .left {
        didSet {
            if oldValue != activePaneSide {
                (oldValue == .left ? leftTab : rightPane).cancelSessionRestoration()
            }
            synchronizeQuickLookOwnership()
        }
    }
    @Published public private(set) var restoreSessionEnabled = true
    @Published public private(set) var sessionPersistenceNotice: String?
    private let sessionStore: FinderSessionStore
    private var sessionObservers: [AnyCancellable] = []
    private var visibleDirectoryWatcher: VisibleDirectoryWatcher?
    private var visibleDirectoryObservers: [AnyCancellable] = []
    private var visibleDirectorySyncScheduled = false
    private var pendingDirectoryChanges = Set<String>()
    private var directoryReloadScheduled = false
    private var appSessionObserver: AnyCancellable?
    private var sessionSaveTask: Task<Void, Never>?
    private var sessionObservationReady = false

    private func observeSessionPanes() {
        guard sessionObservationReady else { return }
        sessionObservers = (allPanes).map { pane in
            pane.objectWillChange.sink { [weak self] _ in self?.scheduleSessionSave() }
        }
        scheduleSessionSave()
    }

    private func scheduleSessionSave() {
        guard sessionObservationReady, restoreSessionEnabled else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSessionState()
        }
    }

    public func setSessionRestorationEnabled(_ enabled: Bool) {
        sessionSaveTask?.cancel()
        sessionStore.setEnabled(enabled)
        restoreSessionEnabled = enabled
        if enabled { flushSessionState() }
    }

    public func clearSavedSession() {
        sessionSaveTask?.cancel()
        sessionStore.clearAndDisable()
        restoreSessionEnabled = false
        sessionPersistenceNotice = nil
    }

    // UI Panels & Modals
    @Published public var showSidebar: Bool = true {
        didSet { Self.preferences.set(showSidebar, forKey: "bf.showSidebar") }
    }
    @Published public private(set) var recentlyClosedTabs: [PaneTabState] = []
    @Published public var showInspector: Bool = false {
        didSet { Self.preferences.set(showInspector, forKey: "bf.showInspector") }
    }
    @Published public var iconGridSize: Double = 104.0 {
        didSet { Self.preferences.set(iconGridSize, forKey: "bf.iconGridSize") }
    }
    @Published public var showTerminalDrawer: Bool = false
    @Published public var showQuickFSearchModal: Bool = false
    @Published public var showNewFileSheet: Bool = false
    @Published public var showNewFolderSheet: Bool = false
    @Published public var showCompareSheet: Bool = false
    @Published public var showSettingsSheet: Bool = false
    /// Offered once on first launch, and from Help at any time.
    @Published public var showFullDiskAccessSheet: Bool = false {
        didSet {
            // First launch indexes Desktop, Documents and Downloads only after
            // the user chose, so a granted access means no prompts at all.
            guard !showFullDiskAccessSheet, indexingWaitsForOnboarding else { return }
            indexingWaitsForOnboarding = false
            FSearchIndex.shared.startIndexing()
        }
    }
    private var indexingWaitsForOnboarding = false
    @Published public var showFSearchHelpPopover: Bool = false
    @Published public var focusSearchFieldTrigger: Int = 0

    // Index Status
    @Published public var indexedFileCount: Int = 0
    @Published public var indexBuildDurationMs: Double = 0
    @Published public var isIndexing: Bool = true

    // Sidebar locations
    @Published public var favorites: [SidebarLocationItem] = []
    public var customBookmarks: [SidebarLocationItem] { favorites }
    @Published public private(set) var volumeInventory = VolumeInventoryState()
    public var mountedVolumes: [VolumeInfoItem] { volumeInventory.items }
    public var localMountedVolumes: [VolumeInfoItem] { VolumeSidebarGroups.build(from: mountedVolumes).localVolumes }
    public var networkServerGroups: [NetworkVolumeGroup] { VolumeSidebarGroups.build(from: mountedVolumes).networkServers }
    private var volumeService: VolumeRefreshService?
    private lazy var sidebarFavoritesStore: SidebarFavoritesStore = {
        let store = SidebarFavoritesStore(
            defaults: Self.initialSidebarFavorites,
            read: { Self.preferences.object(forKey: SidebarFavoritesStore.key) },
            write: { Self.preferences.set($0, forKey: SidebarFavoritesStore.key) })
        Self.removeDefaultICloudFavorite(from: store)
        return store
    }()

    /// iCloud Drive moved to the Cloud section. Remove the untouched default
    /// favorite once; a renamed or re-added one is the user's and stays.
    private static func removeDefaultICloudFavorite(from store: SidebarFavoritesStore) {
        let key = "bf.sidebarFavorites.cloudSectionMigrated"
        guard !preferences.bool(forKey: key) else { return }
        let path = "\(homeDirectoryURL.path)/Library/Mobile Documents/com~apple~CloudDocs"
        if store.items.contains(where: { $0.path == path && $0.title == "iCloud Drive" && $0.iconName == "icloud.fill" }) {
            store.remove(path)
        }
        preferences.set(true, forKey: key)
    }
    @Published public private(set) var pinnedFolderNotice: String?


    public var activeTab: PaneTabState {
        if isDualPane && activePaneSide == .right {
            return rightPane
        }
        return tabs.first(where: { $0.id == activeTabId }) ?? tabs[0]
    }

    public var leftTab: PaneTabState {
        tabs.first(where: { $0.id == activeTabId }) ?? tabs[0]
    }

    private init() {
        let defaults = Self.preferences
        let store = FinderSessionStore(defaults: defaults)
        self.sessionStore = store
        let homeURL = Self.homeDirectoryURL
        // Without a restored session, start at home like Finder; personal
        // project folders belong in user-editable favorites, not in code.
        let defaultStartURL = homeURL

        let restored = store.load(defaultRightPath: homeURL.path)
        let snapshot = restored.snapshot
        let restoredTabs = snapshot?.tabs.map { $0.makePausedPane() }
            ?? [PaneTabState(initialURL: defaultStartURL)]
        self.tabs = restoredTabs
        self.activeTabId = restoredTabs[snapshot?.activeIndex ?? 0].id
        let restoredRightTabs = (snapshot?.rightTabs ?? snapshot.map { [$0.right] })?.map { $0.makePausedPane() }
            ?? [PaneTabState(initialURL: homeURL)]
        self.rightTabs = restoredRightTabs
        self.activeRightTabId = restoredRightTabs[min(snapshot?.rightActiveIndex ?? 0, restoredRightTabs.count - 1)].id
        self.restoreSessionEnabled = store.isEnabled
        self.sessionPersistenceNotice = restored.notice
        if let snapshot {
            self.isDualPane = snapshot.dualPane
            self.activePaneSide = snapshot.activeSide == "right" ? .right : .left
        }

        if defaults.object(forKey: "bf.showSidebar") != nil {
            self.showSidebar = defaults.bool(forKey: "bf.showSidebar")
        }
        if defaults.object(forKey: "bf.showInspector") != nil {
            self.showInspector = defaults.bool(forKey: "bf.showInspector")
        }
        if snapshot == nil, defaults.object(forKey: "bf.isDualPane") != nil {
            self.isDualPane = defaults.bool(forKey: "bf.isDualPane")
        }
        let savedIconSize = defaults.double(forKey: "bf.iconGridSize")
        if savedIconSize >= 40 && savedIconSize <= 140 {
            self.iconGridSize = savedIconSize
        }

        if isDualPane { rightPane.retainInitialLocation() }

        #if !BURROW_TESTING
        let offeredKey = "bf.onboarding.fullDiskAccessOffered"
        if !defaults.bool(forKey: offeredKey) {
            defaults.set(true, forKey: offeredKey)
            showFullDiskAccessSheet = !FullDiskAccess.isGranted()
        }
        UpdateChecker.shared.checkIfDue()
        #endif

        setupSidebarLocations()
        #if !BURROW_TESTING
        let volumes = VolumeRefreshService.production()
        volumeService = volumes
        volumes.start { [weak self] result in
            self?.volumeInventory.apply(result)
            // Signing in to a cloud app mounts a File Provider domain.
            CloudActivity.shared.refreshLocations()
            // Runs on activation too: Full Disk Access may have just been granted.
            FolderSizeCache.shared.refreshFullDiskAccess()
        }
        #endif
        setupIndexCallbacks()
        #if !BURROW_TESTING
        visibleDirectoryWatcher = VisibleDirectoryWatcher { changed in
            Task { @MainActor in AppState.shared.handleDirectoryChanges(changed) }
        }
        observeVisibleDirectories()
        #endif
        sessionObservationReady = true
        observeSessionPanes()
        appSessionObserver = objectWillChange.sink { [weak self] _ in self?.scheduleSessionSave() }
        // Restored folders open right away off the main thread, with the
        // resume timeout. Folders on a volume that is not mounted and saved
        // disk maps (a whole-disk scan) stay paused until the user resumes.
        if snapshot != nil {
            for pane in restoredTabs + restoredRightTabs
            where pane.wasRestoredFromSession && PaneTabState.resumesAutomatically(path: pane.currentURL.path, viewMode: pane.viewMode) {
                Task { @MainActor in await pane.resumeSession() }
            }
        }
    }

    private var indexLifecycle = IndexingLifecycleState()
    private func setupIndexCallbacks() {
        FSearchIndex.shared.onIndexingLifecycle = { event in
            Task { @MainActor in
                self.indexLifecycle.apply(event)
                self.isIndexing = self.indexLifecycle.isIndexing
            }
        }
        FSearchIndex.shared.onIndexUpdated = { count, durationMs in
            Task { @MainActor in
                self.indexedFileCount = count
                self.indexBuildDurationMs = durationMs
                for tab in self.allPanes where !tab.searchQuery.isEmpty {
                    tab.triggerSearch()
                }
            }
        }
        FSearchIndex.shared.onDirectoryChangedOnDisk = { changedDirs in
            Task { @MainActor in
                self.handleDirectoryChanges(changedDirs)
            }
        }
        #if !BURROW_TESTING
        // Indexing leaves out protected folders the user has not allowed, and
        // picks them up as soon as they are allowed.
        FSearchIndex.shared.indexPrivacy = FolderSizePrivacy.shared
        FolderSizeCache.shared.onPrivacyAccessChanged = { [weak self] in
            guard let self, !self.indexingWaitsForOnboarding else { return }
            FSearchIndex.shared.startIndexing()
        }
        if showFullDiskAccessSheet {
            indexingWaitsForOnboarding = true
        } else {
            FSearchIndex.shared.startIndexing()
        }
        #else
        isIndexing = false
        #endif
    }

    public func handleDirectoryChanges(_ changedDirs: Set<String>) {
        // Invalidate shared caches even when no current pane displays the folder.
        for path in changedDirs {
            FolderSizeCache.shared.invalidate(containing: path)
            FileIconCache.shared.invalidate(containing: path)
        }
        // Bursts (copying many files; the index and visible-folder watchers
        // reporting the same change) collapse into one reload per pane.
        pendingDirectoryChanges.formUnion(changedDirs)
        guard !directoryReloadScheduled else { return }
        directoryReloadScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            self?.flushDirectoryChanges()
        }
    }

    private func flushDirectoryChanges() {
        let changed = pendingDirectoryChanges
        pendingDirectoryChanges.removeAll()
        directoryReloadScheduled = false
        for tab in allPanes where tab.isAffectedByDirectoryChanges(changed) {
            tab.reloadDirectory(invalidateCaches: false)
        }
    }

    /// Keeps the visible-folder watcher in sync with what panes display.
    private func observeVisibleDirectories() {
        guard visibleDirectoryWatcher != nil else { return }
        visibleDirectoryObservers = (allPanes).map { pane in
            pane.objectWillChange.sink { [weak self] _ in self?.scheduleVisibleDirectorySync() }
        }
        scheduleVisibleDirectorySync()
    }

    private func scheduleVisibleDirectorySync() {
        guard !visibleDirectorySyncScheduled else { return }
        visibleDirectorySyncScheduled = true
        // objectWillChange fires before the change lands; read paths on the next turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.visibleDirectorySyncScheduled = false
                let paths = (self.allPanes).reduce(into: Set<String>()) { $0.formUnion($1.visibleDirectoryPaths) }
                self.visibleDirectoryWatcher?.update(paths: paths)
            }
        }
    }

    /// Shell commands can change tags/permissions without changing indexed
    /// size/mtime. Refresh their consumers independently of index differences.
    func reconcileTerminalCommand(at path: String) {
        FSearchIndex.shared.enqueueDirectoryRefresh(path)
        FileIconCache.shared.invalidate(containing: path)
        FolderSizeCache.shared.revalidate(containing: path)
        for tab in allPanes where tab.isAffectedByDirectoryChanges([path]) {
            tab.reloadDirectory(invalidateCaches: false)
        }
    }

    /// A cloud download or eviction changed items in these folders.
    func refreshFolders(containing paths: Set<String>) {
        for path in paths {
            FSearchIndex.shared.enqueueDirectoryRefresh(path)
            FileIconCache.shared.invalidate(containing: path)
            FolderSizeCache.shared.revalidate(containing: path)
        }
        for tab in allPanes where tab.isAffectedByDirectoryChanges(paths) {
            tab.reloadDirectory(invalidateCaches: false)
        }
    }

    private static var initialSidebarFavorites: [SidebarFavoritesStore.Entry] {
        let home = Self.homeDirectoryURL.path
        // Pure initial configuration: never probe disks/cloud roots while restoring the sidebar.
        var candidates: [(String, String, String)] = [
            (String(localized: "Home"), "house.fill", home),
            (String(localized: "Desktop"), "menubar.dock.rectangle", "\(home)/Desktop"),
            (String(localized: "Documents"), "doc.fill", "\(home)/Documents"),
            (String(localized: "Downloads"), "arrow.down.circle.fill", "\(home)/Downloads"),
            (String(localized: "Trash"), "trash.fill", "\(home)/.Trash")
        ]
        #if !BURROW_TESTING
        candidates.append((String(localized: "Applications"), "square.grid.2x2", "/Applications"))
        #endif
        return candidates.map { SidebarFavoritesStore.Entry(path: $0.2, title: $0.0, iconName: $0.1) }
    }

    public func setupSidebarLocations() { updatePinnedFolderRows() }

    // MARK: - Session persistence

    public func persistTabsState() { scheduleSessionSave() }

    /// Flush synchronously at normal termination; snapshots never include runtime actions.
    public func flushSessionState() {
        guard sessionObservationReady, restoreSessionEnabled else { return }
        let snapshot = FinderSessionSnapshot(tabs: tabs.map { FinderPaneSession(pane: $0) },
            right: FinderPaneSession(pane: rightPane),
            activeIndex: tabs.firstIndex { $0.id == activeTabId } ?? 0,
            dualPane: isDualPane, activeSide: activePaneSide.rawValue,
            rightTabs: rightTabs.map { FinderPaneSession(pane: $0) },
            rightActiveIndex: rightTabs.firstIndex { $0.id == activeRightTabId } ?? 0)
        if sessionStore.save(snapshot) {
            if sessionPersistenceNotice != nil { sessionPersistenceNotice = nil }
        } else if sessionPersistenceNotice == nil {
            sessionPersistenceNotice = String(localized: "The session was not saved. The previous save was kept.")
        }
    }

    #if BURROW_TESTING
    var hasPersistedSessionForTesting: Bool { Self.preferences.object(forKey: FinderSessionStore.dataKey) != nil }
    #endif

    private func updatePinnedFolderRows() {
        favorites = sidebarFavoritesStore.items.map { entry in
            SidebarLocationItem(bookmarkPath: entry.path, title: entry.title, iconName: entry.iconName,
                url: URL(fileURLWithPath: entry.path, isDirectory: true), isCustomBookmark: true)
        }
        pinnedFolderNotice = sidebarFavoritesStore.notice
    }

    private func finishFavoritesMutation(_ succeeded: Bool) {
        if !succeeded {
            FileOperationsManager.shared.lastStatusMessage = String(localized: "The change to Favorites could not be confirmed as saved.")
        }
        updatePinnedFolderRows()
    }

    public func addBookmark(for url: URL) {
        guard sidebarFavoritesStore.notice == nil else { updatePinnedFolderRows(); return }
        guard url.isFileURL, SidebarFavoritesStore.validPath(url.path) else { return }
        // Only a new, explicitly requested target is probed; restored favorites never are.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            FileOperationsManager.shared.lastStatusMessage = String(localized: "Favorite not added: the folder is unavailable.")
            return
        }
        finishFavoritesMutation(sidebarFavoritesStore.add(url.path))
    }

    public func removeBookmark(_ item: SidebarLocationItem) {
        finishFavoritesMutation(sidebarFavoritesStore.remove(item.id))
    }

    public func moveFavorite(_ item: SidebarLocationItem, by offset: Int) {
        finishFavoritesMutation(sidebarFavoritesStore.move(item.id, by: offset))
    }

    public func moveFavorite(id: String, beforeID: String?) {
        finishFavoritesMutation(sidebarFavoritesStore.move(id, before: beforeID))
    }

    public func renameFavorite(_ item: SidebarLocationItem, title: String) {
        finishFavoritesMutation(sidebarFavoritesStore.rename(item.id, title: title))
    }

    public func setFavoriteIcon(_ item: SidebarLocationItem, iconName: String) {
        finishFavoritesMutation(sidebarFavoritesStore.setIcon(item.id, iconName: iconName))
    }

    // MARK: - Volumes & Eject (`⏏`)

    #if BURROW_TESTING
    func installVolumeFixturesForTesting(_ volumes: [VolumeInfoItem]) {
        volumeInventory.apply(.success(VolumeSnapshot(items: volumes)))
    }
    #endif

    public func refreshMountedVolumes() { volumeService?.requestRefresh() }

    /// Volumes with an unmount in flight; a repeated click must not queue a second eject.
    @Published private(set) var ejectingVolumePaths: Set<String> = []

    public func ejectVolume(_ vol: VolumeInfoItem) {
        let path = vol.url.path
        guard ejectingVolumePaths.insert(path).inserted else { return }
        FileOperationsManager.shared.lastStatusMessage = String(localized: "Ejecting volume \(vol.name)…")
        // Unmounting a busy or unresponsive (network) volume can block for a long time; keep it off the main actor.
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure: String?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: vol.url)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await self?.finishEject(vol, path: path, failure: failure)
        }
    }

    private func finishEject(_ vol: VolumeInfoItem, path: String, failure: String?) {
        ejectingVolumePaths.remove(path)
        if let failure {
            FileOperationsManager.shared.lastStatusMessage = String(localized: "Could not eject \(vol.name): \(failure)")
        } else {
            refreshMountedVolumes()
            FileOperationsManager.shared.lastStatusMessage = String(localized: "Ejected volume \(vol.name)")
        }
    }

    // MARK: - Tab Management

    /// Opens a tab in `side` (default: the pane being worked in), copying that pane's view settings.
    public func addNewTab(at url: URL? = nil, side: PaneSide? = nil) {
        let side = isDualPane ? (side ?? tabSide) : .left
        let source = side == .left ? leftTab : rightPane
        let targetURL = url ?? source.currentURL
        let newTab = PaneTabState(initialURL: targetURL)
        newTab.viewMode = source.viewMode
        newTab.showHiddenFiles = source.showHiddenFiles
        newTab.searchScope = source.searchScope
        newTab.fuzzyEnabled = source.fuzzyEnabled
        // Apply inherited display preferences without discarding shared analysis.
        newTab.reloadDirectory(invalidateCaches: false)
        FSearchIndex.shared.ensureDirectoryIndexed(newTab.currentURL.path)
        append(newTab, on: side)
    }

    private func append(_ tab: PaneTabState, on side: PaneSide) {
        if side == .left {
            tabs.append(tab)
            activeTabId = tab.id
        } else {
            rightTabs.append(tab)
            activeRightTabId = tab.id
        }
        activePaneSide = side
        persistTabsState()
    }

    /// Opens a folder handed over by the system (Dock, `open`, "Show in Finder").
    /// Reuses a tab already showing it, otherwise opens a new tab, then selects `paths`.
    public func openExternalLocation(_ url: URL, selecting paths: [String]) {
        let target = url.standardizedFileURL
        // LaunchServices hands over resolved paths (/private/tmp for /tmp).
        let resolvedTarget = target.resolvingSymlinksInPath().path
        // Paused restored tabs keep their deliberate Resume flow; open a live tab instead.
        func shows(_ pane: PaneTabState) -> Bool {
            !pane.isSessionPaused && pane.currentURL.resolvingSymlinksInPath().path == resolvedTarget
        }
        if let existing = tabs.first(where: shows) {
            if isDualPane { activePaneSide = .left }
            activeTabId = existing.id
            existing.reloadDirectory()
        } else if isDualPane, let existing = rightTabs.first(where: shows) {
            activeRightTabId = existing.id
            activePaneSide = .right
            existing.reloadDirectory()
        } else {
            addNewTab(at: target)
        }
        if !paths.isEmpty { activeTab.selectPaths(paths) }
    }

    public func closeTab(_ id: UUID) {
        guard let side = side(ofTab: id) else { return }
        var list = tabs(on: side)
        guard list.count > 1, let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].cancelSessionRestoration()
        recentlyClosedTabs.append(list[idx])
        if recentlyClosedTabs.count > 10 { recentlyClosedTabs.removeFirst() }
        list.remove(at: idx)
        let next = list[min(idx, list.count - 1)].id
        if side == .left {
            tabs = list
            if activeTabId == id { activeTabId = next }
        } else {
            rightTabs = list
            if activeRightTabId == id { activeRightTabId = next }
        }
        persistTabsState()
    }

    public func reopenClosedTab() {
        guard let tab = recentlyClosedTabs.popLast() else { return }
        append(tab, on: tabSide)
        tab.refresh()
    }

    public func selectAdjacentTab(offset: Int) {
        let side = tabSide
        let list = tabs(on: side)
        guard let index = list.firstIndex(where: { $0.id == activeTabID(on: side) }), !list.isEmpty else { return }
        selectTab(list[(index + offset + list.count) % list.count].id)
    }

    public func closeOtherTabs(keeping id: UUID) {
        guard let side = side(ofTab: id) else { return }
        for tab in tabs(on: side) where tab.id != id { closeTab(tab.id) }
        selectTab(id)
    }

    public func reloadVisiblePanes() {
        leftTab.refresh()
        if isDualPane { rightPane.refresh() }
    }

    public func toggleDualPane() {
        if !isDualPane {
            rightPane.initializeLocationIfNeeded(matching: leftTab.currentURL)
            isDualPane = true
        } else {
            isDualPane = false
            activePaneSide = .left
        }
    }

    /// A preview remains bound to its initiating pane. Explicit context changes
    /// close it; background updates must never choose a new owner implicitly.
    private func synchronizeQuickLookOwnership() {
        let visibleOwner: UUID?
        if isDualPane && activePaneSide == .right {
            visibleOwner = rightPane.id
        } else {
            visibleOwner = tabs.first(where: { $0.id == activeTabId })?.id ?? tabs.first?.id
        }
        QuickLookCoordinator.shared.retainOwner(visibleOwner)
    }

    public func toggleQuickLook() {
        let pane = activeTab
        let selected = pane.selectedItems
        guard !selected.isEmpty else { return }
        QuickLookCoordinator.shared.preview(ownerID: pane.id, urls: selected.map(\.url))
    }
}

/// Value-only ownership state shared by the native bridge and focused tests.
/// URLs may change only through an explicit preview or an update by this owner.
struct QuickLookPreviewSession {
    private(set) var ownerID: UUID?
    private(set) var urls: [URL] = []

    mutating func open(ownerID: UUID, urls: [URL]) {
        guard !urls.isEmpty else { close(); return }
        self.ownerID = ownerID
        self.urls = urls
    }

    @discardableResult
    mutating func update(ownerID: UUID, urls: [URL]) -> Bool {
        guard self.ownerID == ownerID else { return false }
        if urls.isEmpty { close() } else { self.urls = urls }
        return true
    }

    mutating func close() { ownerID = nil; urls = [] }
}

@MainActor
protocol QuickLookPanelDriving: AnyObject {
    var isVisible: Bool { get }
    func show(coordinator: QuickLookCoordinator) -> Bool
    func reload()
    func hide()
}

/// Only this adapter touches QLPreviewPanel. Ownership transitions can be tested
/// with an inert driver without presenting a native window or loading file data.
@MainActor
private final class NativeQuickLookPanelDriver: QuickLookPanelDriving {
    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible == true)
    }
    func show(coordinator: QuickLookCoordinator) -> Bool {
        guard let panel = QLPreviewPanel.shared() else { return false }
        panel.dataSource = coordinator
        panel.delegate = coordinator
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        return true
    }
    func reload() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return }
        panel.reloadData()
    }
    func hide() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared() else { return }
        panel.orderOut(nil)
    }
}

/// Native macOS QuickLook (`QLPreviewPanel`) bridge with explicit pane ownership.
@MainActor
public final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    #if BURROW_TESTING
    public static var shared = QuickLookCoordinator()
    #else
    public static let shared = QuickLookCoordinator()
    #endif
    private let panelDriver: any QuickLookPanelDriving
    private(set) var session = QuickLookPreviewSession()

    override init() {
        panelDriver = NativeQuickLookPanelDriver()
        super.init()
    }
    init(panelDriver: any QuickLookPanelDriving) {
        self.panelDriver = panelDriver
        super.init()
    }

    public func preview(ownerID: UUID, urls: [URL]) {
        guard !urls.isEmpty else { return }
        if !panelDriver.isVisible { session.close() }
        if session.ownerID == ownerID {
            close()
            return
        }
        // A new explicit preview may transfer a visible session to another pane;
        // background selection reconciliation cannot do so.
        session.open(ownerID: ownerID, urls: urls)
        if panelDriver.isVisible {
            panelDriver.reload()
        } else if !panelDriver.show(coordinator: self) {
            session.close()
        }
    }

    public func updateIfVisible(ownerID: UUID, urls: [URL]) {
        guard panelDriver.isVisible else { session.close(); return }
        guard session.update(ownerID: ownerID, urls: urls) else { return }
        if session.ownerID == nil { panelDriver.hide() } else { panelDriver.reload() }
    }

    /// Switching context or removing/hiding the owner closes instead of rebinding.
    public func retainOwner(_ visibleOwner: UUID?) {
        guard let owner = session.ownerID, owner != visibleOwner else { return }
        close()
    }

    private func close() {
        session.close()
        panelDriver.hide()
    }

    nonisolated public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { session.urls.count }
    }

    nonisolated public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            guard index >= 0 && index < session.urls.count else { return nil }
            return session.urls[index] as NSURL
        }
    }
}
