import SwiftUI
import AppKit

public struct MainWindowView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var fileOps = FileOperationsManager.shared
    @ObservedObject var updates = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow
    // OpenSettingsAction ships with the macOS 15 SDK (it back-deploys to macOS 14).
    #if compiler(>=6.0)
    @Environment(\.openSettings) private var openSettings
    #endif

    @ViewState private var terminalHeight = TerminalDrawerLayout.defaultHeight
    @ViewState private var terminalDragStart: CGFloat?
    @GestureState private var isResizingTerminal = false

    #if BURROW_TESTING
    @Environment(\.terminalPreviewRequestedHeight) private var previewRequestedHeight
    #endif

    private var requestedTerminalHeight: CGFloat {
        #if BURROW_TESTING
        if let previewRequestedHeight, previewRequestedHeight.isFinite {
            return previewRequestedHeight
        }
        #endif
        return terminalHeight
    }

    public init() {}

    public var body: some View {
        let activeTab = appState.activeTab
        // A native split view gives the sidebar the full-height system
        // material and its standard toggle, as in Finder.
        NavigationSplitView(columnVisibility: Binding(
            get: { appState.showSidebar ? .all : .detailOnly },
            set: { appState.showSidebar = $0 != .detailOnly }
        )) {
            SidebarView(appState: appState, activeTab: activeTab)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            browserColumn(activeTab: activeTab)
        }
        .frame(minWidth: appState.isDualPane ? 1080 : 880, minHeight: 560)
        .onChange(of: appState.activeTabId) { _, _ in appState.persistTabsState() }
        .onAppear {
            let open = openWindow
            ExternalOpenRouter.openMainWindow = { open(id: "main") }
        }
        .sheet(isPresented: $appState.showQuickFSearchModal) {
            QuickFSearchSpotlightModal(appState: appState, activeTab: activeTab)
        }
        .sheet(isPresented: $appState.showNewFileSheet) {
            NewFileSheetView(appState: appState, activeTab: activeTab)
        }
        .sheet(isPresented: $appState.showNewFolderSheet) {
            NewFolderSheetView(appState: appState, activeTab: activeTab)
        }
        .sheet(isPresented: $appState.showCompareSheet) { FolderCompareSheetView(appState: appState) }
        .onChange(of: appState.showSettingsSheet) { _, show in
            guard show else { return }
            appState.showSettingsSheet = false
            #if compiler(>=6.0)
            openSettings()
            #else
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            #endif
        }
        .sheet(isPresented: $appState.showFullDiskAccessSheet) { FullDiskAccessSheetView() }
        .alert(updateAlertTitle, isPresented: Binding(
            get: { updates.presented != nil },
            set: { if !$0 { updates.presented = nil } }
        ), presenting: updates.presented) { outcome in
            switch outcome {
            case .available(let release):
                Button("Download") { NSWorkspace.shared.open(release.pageURL) }
                Button("Copy Homebrew Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(UpdateChecker.homebrewCommand, forType: .string)
                }
                Button("Later", role: .cancel) {}
            case .upToDate:
                Button("OK", role: .cancel) {}
            case .failed:
                Button("Open Releases Page") { NSWorkspace.shared.open(UpdateChecker.releasesPage) }
                Button("OK", role: .cancel) {}
            }
        } message: { outcome in
            switch outcome {
            case .available(let release):
                Text("Burrow \(release.version) is available. With Homebrew, run “\(UpdateChecker.homebrewCommand)”; otherwise download it from GitHub.")
            case .upToDate(let version):
                Text("Version \(version) is the latest.")
            case .failed:
                Text("Check your internet connection, or open the releases page.")
            }
        }
        .sheet(item: windowConflict) { ConflictResolutionSheetView(conflict: $0) }
    }

    private func browserColumn(activeTab: PaneTabState) -> some View {
        VStack(spacing: 0) {
            // Like Finder, the tab bar appears once there is a second tab. In two
            // panes each pane has its own tabs, so each shows its own bar.
            if !appState.isDualPane && appState.tabs.count > 1 { tabBar(side: .left) }
            FSearchToolbarSection(appState: appState, activeTab: activeTab)

            Group {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        if appState.isDualPane {
                            // Each pane keeps its own footer, so both counts are visible.
                            HSplitView {
                                VStack(spacing: 0) {
                                    if showsPaneTabBars { tabBar(side: .left) }
                                    FilePaneView(appState: appState, pane: appState.leftTab, paneSide: .left,
                                                 isFocusedPane: appState.activePaneSide == .left)
                                    Divider()
                                    FinderStatusBar(appState: appState, activeTab: appState.leftTab,
                                                    showsFreeSpace: FinderStatusBar.volume(for: appState.leftTab.currentURL.path, in: appState.mountedVolumes)?.id
                                                        != FinderStatusBar.volume(for: appState.rightPane.currentURL.path, in: appState.mountedVolumes)?.id)
                                }
                                .frame(minWidth: 260)
                                VStack(spacing: 0) {
                                    if showsPaneTabBars { tabBar(side: .right) }
                                    FilePaneView(appState: appState, pane: appState.rightPane, paneSide: .right,
                                                 isFocusedPane: appState.activePaneSide == .right)
                                    Divider()
                                    FinderStatusBar(appState: appState, activeTab: appState.rightPane, showsActivity: false)
                                }
                                .frame(minWidth: 260)
                            }
                        } else {
                            FilePaneView(appState: appState, pane: appState.leftTab, paneSide: .left, isFocusedPane: true)
                        }
                        if appState.showTerminalDrawer {
                            terminalDivider(availableHeight: geometry.size.height)
                            EmbeddedTerminalDrawerView(appState: appState, activeTab: activeTab)
                                .frame(height: TerminalDrawerLayout.height(
                                    requested: requestedTerminalHeight, availableHeight: geometry.size.height))
                        }
                    }
                    .coordinateSpace(name: "terminalSplit")
                    .onChange(of: appState.showTerminalDrawer) { _, _ in terminalDragStart = nil }
                    .onChange(of: isResizingTerminal) { _, dragging in
                        if !dragging { terminalDragStart = nil }
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !appState.isDualPane {
                Divider()
                FinderStatusBar(appState: appState, activeTab: activeTab)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        // The native inspector column: the toolbar runs across it unbroken.
        .inspector(isPresented: $appState.showInspector) {
            InspectorPreviewView(appState: appState, activeTab: activeTab)
                // A hairline from below the toolbar down, like the sidebar's edge in
                // Finder; the toolbar itself stays one continuous bar.
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).allowsHitTesting(false)
                }
                .inspectorColumnWidth(min: 300, ideal: 320, max: 400)
        }
    }

    private func terminalDivider(availableHeight: CGFloat) -> some View {
        let actualHeight = TerminalDrawerLayout.height(requested: requestedTerminalHeight, availableHeight: availableHeight)
        return TerminalResizeHandle(
            height: actualHeight,
            onIncrease: { terminalHeight = TerminalDrawerLayout.height(requested: actualHeight + TerminalDrawerLayout.keyboardStep, availableHeight: availableHeight) },
            onDecrease: { terminalHeight = TerminalDrawerLayout.height(requested: actualHeight - TerminalDrawerLayout.keyboardStep, availableHeight: availableHeight) },
            onReset: { terminalHeight = TerminalDrawerLayout.defaultHeight }
        )
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("terminalSplit"))
            .updating($isResizingTerminal) { _, dragging, _ in dragging = true }
            .onChanged { value in
                if terminalDragStart == nil { terminalDragStart = actualHeight }
                terminalHeight = TerminalDrawerLayout.draggedHeight(
                    start: terminalDragStart ?? actualHeight,
                    translation: value.translation.height,
                    availableHeight: availableHeight)
            }
            .onEnded { _ in terminalDragStart = nil })
    }

    private var updateAlertTitle: String {
        switch updates.presented {
        case .available: return String(localized: "A new version of Burrow is available")
        case .upToDate: return String(localized: "Burrow is up to date")
        case .failed: return String(localized: "Could not check for updates")
        case nil: return ""
        }
    }

    // A conflict requested from comparison belongs to that sheet, not its window.
    private var windowConflict: Binding<PendingTransferConflict?> {
        Binding(
            get: { appState.showCompareSheet ? nil : fileOps.pendingConflict },
            set: { value in
                guard !appState.showCompareSheet else { return }
                fileOps.pendingConflict = value
            }
        )
    }

    /// Both panes show their bars together, so the two path bars stay level.
    private var showsPaneTabBars: Bool {
        appState.tabs.count > 1 || appState.rightTabs.count > 1
    }

    private func tabBar(side: PaneSide) -> some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: FinderUI.compactSpacing) {
                        ForEach(appState.tabs(on: side)) { tab in
                            FinderTabView(tab: tab, appState: appState, side: side)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, FinderUI.rowSpacing)
                }
                .onChange(of: appState.activeTabID(on: side)) { _, id in
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
            Button { appState.addNewTab(side: side) } label: {
                Image(systemName: "plus").frame(width: 32, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("New Tab")
            .help("New Tab (⌘T)")

        }
        .frame(height: FinderUI.chromeHeight)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct FinderTabView: View {
    @ObservedObject var tab: PaneTabState
    @ObservedObject var appState: AppState
    let side: PaneSide
    @ViewState private var isHovered = false

    private var isSelected: Bool { tab.id == appState.activeTabID(on: side) }
    private var isOnlyTab: Bool { appState.tabs(on: side).count == 1 }

    var body: some View {
        HStack(spacing: 5) {
            Button {
                appState.selectTab(tab.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tab.searchQuery.isEmpty ? "folder" : "magnifyingglass")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 70, maxWidth: 190, alignment: .leading)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button { appState.closeTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // Like Safari: the close button on the selected tab and under the pointer only.
            .opacity(isOnlyTab ? 0 : (isSelected || isHovered ? 1 : 0))
            .accessibilityHidden(isOnlyTab)
            .disabled(isOnlyTab)
            .accessibilityLabel("Close tab \(tab.title)")
            .help("Close tab \(tab.title)")
        }
        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
        .padding(.horizontal, 10)
        // Each pane's selected tab is a filled chip whether or not that pane has focus;
        // focus itself is the path bar's tint and underline.
        .background(isSelected ? Color.primary.opacity(0.10) : (isHovered ? Color.primary.opacity(0.04) : .clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 4)
        .onHover { isHovered = $0 }
        .help(tab.currentURL.path)
        .contextMenu {
            Button("Duplicate Tab") { appState.addNewTab(at: tab.currentURL, side: side) }
            Button("Close Tab") { appState.closeTab(tab.id) }.disabled(isOnlyTab)
            Button("Close Other Tabs") { appState.closeOtherTabs(keeping: tab.id) }.disabled(isOnlyTab)
            Divider()
            Button("Reopen Closed Tab") { appState.reopenClosedTab() }
                .disabled(appState.recentlyClosedTabs.isEmpty)
        }
    }
}

private struct FinderStatusBar: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState
    @ObservedObject var fileOps = FileOperationsManager.shared
    @ObservedObject var folderSizes = FolderSizeCache.shared
    @ObservedObject var updates = UpdateChecker.shared
    /// Transfers, updates and indexing are app-wide; in two panes only one footer shows them.
    var showsActivity = true
    /// Off for the left of two panes on the same disk: the right footer says it once.
    var showsFreeSpace = true
    static func volume(for path: String, in volumes: [VolumeInfoItem]) -> VolumeInfoItem? {
        volumes.filter {
            $0.url.path == "/" || path == $0.url.path || path.hasPrefix($0.url.path + "/")
        }.max(by: { $0.url.path.count < $1.url.path.count })
    }
    private var availableBytes: Int64? {
        guard showsFreeSpace else { return nil }
        return Self.volume(for: activeTab.currentURL.path, in: appState.mountedVolumes)?.freeBytes
    }

    private var selectionDescription: String {
        if activeTab.isSessionPaused { return String(localized: "Saved view · paused") }
        let items = activeTab.selectedItems
        let summary = FinderSelectionSummary(pane: activeTab)
        guard !items.isEmpty, !summary.isSearching else { return summary.countDescription }
        let knownBytes = FinderSelectionSummary.knownBytes(of: items) { folderSizes.result(for: $0)?.bytes }
        let unknownFolders = FinderSelectionSummary.countedItems(items).contains { $0.isDirectory && folderSizes.size(for: $0.path) == nil }
        let count = summary.countDescription
        let size = FormatHelpers.formatBytes(knownBytes)
        return unknownFolders ? String(localized: "\(count) · at least \(size)") : String(localized: "\(count) · \(size)")
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(selectionDescription).lineLimit(1).layoutPriority(1).help(selectionDescription)
            if let opening = activeTab.openingLocation {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Opening “\(FileManager.default.displayName(atPath: opening.path))”…")
                    .lineLimit(1).truncationMode(.middle).help(opening.path)
            }
            if showsActivity, let transfer = fileOps.activeTransfer {
                ProgressView(value: transfer.fraction).frame(width: 70)
                    .accessibilityLabel("File operation progress")
                Text(transfer.currentFile).lineLimit(1).truncationMode(.middle).help(transfer.currentFile)
                if transfer.isCancellable {
                    Button { fileOps.cancelActiveTransfer() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 24, height: 24)
                    }
                        .buttonStyle(.plain)
                        .help("Stop after the current file")
                        .accessibilityLabel("Cancel file operation")
                }
            } else if showsActivity, let message = fileOps.lastStatusMessage {
                Text(message).lineLimit(1).truncationMode(.middle).help(message).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if showsActivity, let release = updates.available {
                Button("Burrow \(release.version) is available") { updates.presented = .available(release) }
                    .buttonStyle(.link)
                    .help("Show how to update")
            }
            if activeTab.viewMode == .icons {
                // Small and large glyphs at either end, set apart from the free space.
                HStack(spacing: 6) {
                    Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(FinderUI.metadataColor).accessibilityHidden(true)
                    Slider(value: $appState.iconGridSize, in: 44...136)
                        .frame(width: 90)
                        .controlSize(.mini)
                        .accessibilityLabel("Icon size")
                    Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(FinderUI.metadataColor).accessibilityHidden(true)
                }
                .padding(.trailing, 10)
            }
            if showsActivity && appState.isIndexing {
                ProgressView().controlSize(.small).accessibilityLabel("Indexing files")
                Text("Indexing…")
            } else if let availableBytes {
                // Same wording as the sidebar's disk row.
                Text("\(FormatHelpers.formatBytes(availableBytes)) free").monospacedDigit()
            }
        }
        .font(FinderUI.detailFont)
        .foregroundStyle(FinderUI.metadataColor)
        .padding(.horizontal, 16)
        .frame(minHeight: 30)
        .background(.bar)
    }
}

#if BURROW_TESTING
// Visual fixture input only; production sizing/clamping remains authoritative.
private struct TerminalPreviewRequestedHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}
extension EnvironmentValues {
    var terminalPreviewRequestedHeight: CGFloat? {
        get { self[TerminalPreviewRequestedHeightKey.self] }
        set { self[TerminalPreviewRequestedHeightKey.self] = newValue }
    }
}
#endif
