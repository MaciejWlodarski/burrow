import Foundation

@MainActor
private final class InertQuickLookPanel: QuickLookPanelDriving {
    var isVisible = false
    var reloadCount = 0
    var showCount = 0
    var hideCount = 0
    var allowsShow = true
    func show(coordinator: QuickLookCoordinator) -> Bool {
        showCount += 1
        isVisible = allowsShow
        return allowsShow
    }
    func reload() { reloadCount += 1 }
    func hide() { hideCount += 1; isVisible = false }
}

struct QuickLookOwnershipRegressionTests {
    @MainActor func runAll() async throws {
        let panel = InertQuickLookPanel()
        let coordinator = QuickLookCoordinator(panelDriver: panel)
        let previous = QuickLookCoordinator.shared
        QuickLookCoordinator.shared = coordinator
        defer { QuickLookCoordinator.shared = previous }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-quicklook-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let owner = PaneTabState(initialURL: root)
        let other = PaneTabState(initialURL: root)
        let items = owner.displayedItems
        try expect(items.count == 2)
        owner.select(items[0])
        coordinator.preview(ownerID: owner.id, urls: owner.selectedItems.map(\.url))
        let initial = coordinator.session.urls
        other.select(items[1])
        other.selectAll()
        other.refresh()
        other.searchScope = .currentFolder
        other.searchQuery = "a.txt"
        other.triggerSearch()
        for _ in 0..<250 {
            if !other.isSearching { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(!other.isSearching)
        other.clearSearch()
        other.viewMode = .wiztree
        let generation = UUID()
        other.beginAnalysisProjection(rootPath: other.currentURL.path, generation: generation)
        other.publishAnalysisItems(items, rootPath: other.currentURL.path, generation: generation)
        other.setAnalysisSelection([items[1]], rootPath: other.currentURL.path)
        other.clearAnalysisSelection()
        try expect(coordinator.session.ownerID == owner.id)
        try expect(coordinator.session.urls == initial)
        try expect(panel.isVisible && panel.reloadCount == 0 && panel.hideCount == 0)
        print("PASS inactive pane selection, refresh, search completion/clear and analysis cannot replace Quick Look")

        owner.select(items[1])
        try expect(coordinator.session.urls == [items[1].url])
        owner.selectAll()
        try expect(coordinator.session.urls == items.map(\.url))
        coordinator.preview(ownerID: other.id, urls: [items[0].url])
        try expect(coordinator.session.ownerID == other.id && panel.isVisible)
        owner.select(items[0])
        try expect(coordinator.session.ownerID == other.id && coordinator.session.urls == [items[0].url])
        coordinator.preview(ownerID: other.id, urls: [items[0].url])
        try expect(coordinator.session.ownerID == nil && !panel.isVisible)
        other.setAnalysisSelection([items[1]], rootPath: other.currentURL.path)
        coordinator.updateIfVisible(ownerID: other.id, urls: [items[1].url])
        try expect(coordinator.session.urls.isEmpty && !panel.isVisible)
        print("PASS owner selection updates, explicit transfer, toggle-close and late update rejection")

        coordinator.preview(ownerID: owner.id, urls: [items[0].url])
        owner.searchQuery = "b.txt"
        owner.triggerSearch()
        try expect(!panel.isVisible && coordinator.session.ownerID == nil)
        owner.clearSearch()
        coordinator.preview(ownerID: owner.id, urls: [items[0].url])
        panel.isVisible = false // Native Escape/dismissal, before a later callback.
        owner.select(items[1])
        try expect(coordinator.session.ownerID == nil && !panel.isVisible)
        coordinator.preview(ownerID: owner.id, urls: [items[0].url])
        try expect(panel.isVisible && coordinator.session.ownerID == owner.id)
        coordinator.retainOwner(nil)
        panel.allowsShow = false
        coordinator.preview(ownerID: owner.id, urls: [items[0].url])
        try expect(coordinator.session.ownerID == nil)
        panel.allowsShow = true
        print("PASS empty owner selection and native dismissal close without automatic reopening")
        try testAppLifecycle(root: root, coordinator: coordinator, panel: panel)
    }

    @MainActor private func testAppLifecycle(root: URL, coordinator: QuickLookCoordinator, panel: InertQuickLookPanel) throws {
        let app = AppState.shared
        let savedTabs = app.tabs, savedRight = app.rightPane
        let savedID = app.activeTabId, savedSide = app.activePaneSide, savedDual = app.isDualPane
        defer {
            app.tabs = savedTabs; app.rightPane = savedRight; app.activeTabId = savedID
            app.activePaneSide = savedSide; app.isDualPane = savedDual
        }
        let first = PaneTabState(initialURL: root), second = PaneTabState(initialURL: root)
        let right = PaneTabState(initialURL: root)
        app.tabs = [first, second]; app.activeTabId = first.id
        app.rightPane = right; app.isDualPane = true; app.activePaneSide = .left
        first.selectAll(); right.selectAll()
        app.toggleQuickLook()
        try expect(coordinator.session.ownerID == first.id)
        app.activePaneSide = .right
        try expect(!panel.isVisible && coordinator.session.ownerID == nil)
        app.toggleQuickLook()
        try expect(coordinator.session.ownerID == right.id)
        app.isDualPane = false
        try expect(!panel.isVisible)
        app.activePaneSide = .left
        app.toggleQuickLook()
        app.activeTabId = second.id
        try expect(!panel.isVisible)
        second.selectAll(); app.toggleQuickLook()
        app.closeTab(second.id)
        try expect(!panel.isVisible && coordinator.session.ownerID == nil)
        second.selectAll() // recently closed pane still alive; cannot reopen.
        try expect(!panel.isVisible)
        app.reopenClosedTab() // leave the pre-existing recently-closed history intact
        app.activeTabId = first.id
        app.toggleQuickLook()
        app.tabs = [PaneTabState(initialURL: root)] // direct restoration/replacement path
        try expect(!panel.isVisible && coordinator.session.ownerID == nil)
        print("PASS production active-pane/tab switching, hiding, closing and replacing owner dismiss Quick Look")
    }
}
