import SwiftUI
import AppKit

public struct MainWindowView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var fileOps = FileOperationsManager.shared
    @ObservedObject var updates = UpdateChecker.shared
    @Environment(\.openWindow) private var openWindow

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
        VStack(spacing: 0) {
            tabBar
            FSearchToolbarSection(appState: appState, activeTab: activeTab)

            HSplitView {
                if appState.showSidebar {
                    SidebarView(appState: appState, activeTab: activeTab)
                        .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)
                }

                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        if appState.isDualPane {
                            HSplitView {
                                FilePaneView(appState: appState, pane: appState.leftTab, paneSide: .left,
                                             isFocusedPane: appState.activePaneSide == .left)
                                    .frame(minWidth: 260)
                                FilePaneView(appState: appState, pane: appState.rightPane, paneSide: .right,
                                             isFocusedPane: appState.activePaneSide == .right)
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

                if appState.showInspector {
                    InspectorPreviewView(appState: appState, activeTab: activeTab)
                        .frame(minWidth: 250, idealWidth: 280, maxWidth: 380)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            FinderStatusBar(appState: appState, activeTab: activeTab)
        }
        .frame(minWidth: appState.isDualPane ? 1080 : 880, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
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
        .sheet(isPresented: $appState.showSettingsSheet) { FSearchSettingsSheetView(appState: appState) }
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

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: FinderUI.compactSpacing) {
                        ForEach(appState.tabs) { tab in
                            FinderTabView(tab: tab, appState: appState)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, FinderUI.rowSpacing)
                }
                .onChange(of: appState.activeTabId) { _, id in
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
            Button { appState.addNewTab() } label: {
                Image(systemName: "plus").frame(width: 32, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("New Tab")
            .help("New Tab (⌘T)")

            if appState.isDualPane {
                Menu {
                    Button("Copy Selection to Other Pane", systemImage: "doc.on.doc") {
                        let destination = appState.activePaneSide == .left ? appState.rightPane : appState.leftTab
                        fileOps.performTransfer(sourceURLs: appState.activeTab.selectedItems.map(\.url), into: destination.currentURL, isMove: false)
                    }
                    .disabled(appState.activeTab.selectedItems.isEmpty || fileOps.isBusy)
                    Button("Compare Folders…", systemImage: "arrow.left.arrow.right") { appState.showCompareSheet = true }
                    Divider()
                    Button("Close Other Pane") { appState.toggleDualPane() }
                } label: {
                    Text(appState.activePaneSide == .left ? String(localized: "Left Pane") : String(localized: "Right Pane"))
                        .font(.system(size: 11, weight: .medium))
                }
                .fixedSize()
                .padding(.horizontal, 10)
            }
        }
        .frame(height: FinderUI.chromeHeight)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct FinderTabView: View {
    @ObservedObject var tab: PaneTabState
    @ObservedObject var appState: AppState
    @ViewState private var isHovered = false

    private var isSelected: Bool { tab.id == appState.activeTabId }

    var body: some View {
        HStack(spacing: 5) {
            Button {
                appState.activeTabId = tab.id
                appState.activePaneSide = .left
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: tab.searchQuery.isEmpty ? "folder" : "magnifyingglass")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 70, maxWidth: 190, alignment: .leading)
                .padding(.vertical, 8)
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
            .opacity(appState.tabs.count > 1 ? 1 : 0)
            .accessibilityHidden(appState.tabs.count == 1)
            .disabled(appState.tabs.count == 1)
            .accessibilityLabel("Close tab \(tab.title)")
            .help("Close tab \(tab.title)")
        }
        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
        .padding(.horizontal, 10)
        .background(isSelected ? Color(nsColor: .controlBackgroundColor) : (isHovered ? Color.primary.opacity(0.04) : .clear),
                    in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
        .onHover { isHovered = $0 }
        .help(tab.currentURL.path)
        .contextMenu {
            Button("Duplicate Tab") { appState.addNewTab(at: tab.currentURL) }
            Button("Close Tab") { appState.closeTab(tab.id) }.disabled(appState.tabs.count == 1)
            Button("Close Other Tabs") { appState.closeOtherTabs(keeping: tab.id) }.disabled(appState.tabs.count == 1)
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
    private var availableBytes: Int64? {
        let path = activeTab.currentURL.path
        return appState.mountedVolumes.filter {
            $0.url.path == "/" || path == $0.url.path || path.hasPrefix($0.url.path + "/")
        }.max(by: { $0.url.path.count < $1.url.path.count })?.freeBytes
    }

    private var selectionDescription: String {
        if activeTab.isSessionPaused { return String(localized: "Saved view · paused") }
        let items = activeTab.selectedItems
        let summary = FinderSelectionSummary(pane: activeTab)
        guard !items.isEmpty, !summary.isSearching else { return summary.countDescription }
        let knownBytes = items.reduce(Int64(0)) { $0 + ($1.isDirectory ? (folderSizes.result(for: $1.path)?.bytes ?? 0) : $1.size) }
        let unknownFolders = items.contains { $0.isDirectory && folderSizes.size(for: $0.path) == nil }
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
            if let transfer = fileOps.activeTransfer {
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
            } else if let message = fileOps.lastStatusMessage {
                Text(message).lineLimit(1).truncationMode(.middle).help(message).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let release = updates.available {
                Button("Burrow \(release.version) is available") { updates.presented = .available(release) }
                    .buttonStyle(.link)
                    .help("Show how to update")
            }
            if activeTab.viewMode == .icons {
                Image(systemName: "square.grid.2x2").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $appState.iconGridSize, in: 44...136)
                    .frame(width: 90)
                    .controlSize(.mini)
                    .accessibilityLabel("Icon size")
            }
            if appState.isIndexing {
                ProgressView().controlSize(.small).accessibilityLabel("Indexing files")
                Text("Indexing…")
            } else if !activeTab.isSearching && !activeTab.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(FormatHelpers.formatLatency(activeTab.lastSearchLatencyMs)).monospacedDigit()
                    .help("Search time · \(appState.indexedFileCount.formatted()) files in index")
            } else if let availableBytes {
                Text("\(FormatHelpers.formatBytes(availableBytes)) free").monospacedDigit()
            }
        }
        .font(FinderUI.captionFont)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(minHeight: 32)
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
