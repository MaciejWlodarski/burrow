import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct IconFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Pointer, menu and accessibility actions must activate their owning pane before
/// changing selection or navigation, so global commands observe the same target.
@MainActor
enum FinderPaneActionRouting {
    /// A retained view action must never activate a replacement or hidden pane.
    @discardableResult
    static func performIfCurrent(appState: AppState, pane: PaneTabState, paneSide: PaneSide,
                                 action: () -> Void) -> Bool {
        switch paneSide {
        case .left:
            guard appState.activeTabId == pane.id, appState.tabs.contains(where: { $0.id == pane.id }) else { return false }
        case .right:
            guard appState.isDualPane, appState.rightPane.id == pane.id else { return false }
        }
        perform(appState: appState, paneSide: paneSide, action: action)
        return true
    }

    static func perform(appState: AppState, paneSide: PaneSide, action: () -> Void) {
        appState.activePaneSide = paneSide
        action()
    }
}

public struct FilePaneView: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @ObservedObject var appState: AppState
    @ObservedObject var pane: PaneTabState
    @ObservedObject var folderSizes = FolderSizeCache.shared
    @ObservedObject var fileOps = FileOperationsManager.shared
    @ObservedObject var iconCache = FileIconCache.shared
    @StateObject private var dropLoad = FileDropLoadController()
    public let paneSide: PaneSide
    public let isFocusedPane: Bool

    @ViewState private var dragFrames: [String: CGRect] = [:]
    @ViewState private var dropTargetFolderPath: String? = nil
    @ViewState private var isPaneDropTargeted: Bool = false

    // Rubber-band / Marquee selection state in Icon view
    @ViewState private var marqueeStart: CGPoint? = nil
    @ViewState private var marqueeCurrent: CGPoint? = nil
    @ViewState private var iconFrames: [String: CGRect] = [:]

    public init(
        appState: AppState,
        pane: PaneTabState,
        paneSide: PaneSide,
        isFocusedPane: Bool
    ) {
        self.appState = appState
        self.pane = pane
        self.paneSide = paneSide
        self.isFocusedPane = isFocusedPane
    }

    // Keep foreground/background colors paired for inactive panes and windows.
    private var emphasizesSelection: Bool {
        isFocusedPane && controlActiveState != .inactive
    }

    private var selectionBackgroundColor: Color {
        Color(nsColor: emphasizesSelection ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
    }

    private var selectionForegroundColor: Color {
        Color(nsColor: emphasizesSelection ? .alternateSelectedControlTextColor : .unemphasizedSelectedTextColor)
    }

    private var hasSearchQuery: Bool {
        !pane.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Column placeholders belong to their own column, not over the whole trail.
    private var showsPanePlaceholder: Bool {
        hasSearchQuery || (pane.viewMode != .wiztree && pane.viewMode != .columns)
    }

    public var body: some View {
        VStack(spacing: 0) {
            PathBreadcrumbBar(appState: appState, pane: pane)

            if let diagnostic = pane.navigationDiagnostic, let failureID = pane.navigationFailureID {
                HStack(alignment: .top, spacing: FinderUI.rowSpacing) {
                    Image(systemName: pane.navigationFailureIsPermissionDenied ? "lock.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
                        Text(pane.navigationFailureIsPermissionDenied ? "Brak dostępu do folderu" : "Nie można otworzyć folderu")
                            .font(FinderUI.bodyFont.weight(.semibold))
                        ScrollView(.vertical) {
                            Text(diagnostic)
                                .font(FinderUI.detailFont)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 96)
                        .accessibilityLabel("Szczegóły błędu otwierania folderu")
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: FinderUI.rowSpacing) {
                                navigationFailureButtons(failureID: failureID)
                            }
                            VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
                                navigationFailureButtons(failureID: failureID)
                            }
                        }
                        .controlSize(.regular)
                    }
                }
                .padding(.horizontal, FinderUI.panelInset)
                .padding(.vertical, FinderUI.chromeInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FinderUI.sidebarSurface)
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityElement(children: .contain)
            }

            if let diagnostic = pane.searchDiagnostic {
                searchNotice(diagnostic)
            } else if pane.searchIsPartial {
                searchNotice("Wyniki częściowe: nie przeszukano wszystkich plików.")
            }

            if pane.isSearching && !pane.displayedItems.isEmpty {
                HStack(spacing: FinderUI.rowSpacing) {
                    ProgressView().controlSize(.small)
                    Text("Aktualizowanie wyników…")
                        .font(FinderUI.captionFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, FinderUI.sectionSpacing)
                .padding(.vertical, FinderUI.compactSpacing)
                .accessibilityElement(children: .combine)
            }

            if pane.currentURL.path == "\(NSHomeDirectory())/.Trash" {
                trashActionBanner
            }

            FileDropLoadingStatusView(controller: dropLoad)

            ZStack {
                if pane.isSessionPaused {
                    restoredSessionPlaceholder
                } else {
                    switch pane.viewMode {
                    case .list:
                        listBrowserView
                    case .icons:
                        iconGridBrowserView
                    case .columns:
                        if !hasSearchQuery {
                            millerColumnsBrowserView
                        } else { listBrowserView }
                    case .wiztree:
                        if !hasSearchQuery {
                            WizTreeAnalyzerView(
                                appState: appState,
                                pane: pane,
                                paneSide: paneSide,
                                selectionBackgroundColor: selectionBackgroundColor,
                                selectionForegroundColor: selectionForegroundColor
                            )
                            .id(pane.id)
                        } else { listBrowserView }
                    }

                    if showsPanePlaceholder && pane.displayedItems.isEmpty {
                        if pane.isSearching {
                            searchLoadingPlaceholder
                        } else {
                            emptyStatePlaceholder
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isPaneDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2.5)
                    .padding(2)
                    .allowsHitTesting(false)
            )
            .onDrop(of: [.fileURL], isTargeted: $isPaneDropTargeted) { providers in
                guard !pane.isSessionBrowsingPaused else { return false }
                return handleDropProviders(providers: providers, into: pane.currentURL)
            }
            .contextMenu {
                if !pane.isSessionBrowsingPaused { paneBackgroundContextMenu }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(
                    appState.isDualPane && isFocusedPane ? Color.accentColor.opacity(0.65) : Color.clear,
                    lineWidth: 2
                )
                .allowsHitTesting(false)
        )
        .onDisappear { dropLoad.cancel() }
        .onChange(of: pane.id) { _, _ in dropLoad.cancel() }
        .onChange(of: pane.currentURL.path) { _, _ in dropLoad.cancel() }
        .coordinateSpace(name: "FilePaneSpace")
        .background(NativeFileDragSource(pane: pane, frames: dragFrames, isActive: isFocusedPane, activate: activatePane))
        .onPreferenceChange(FileDragFramesKey.self) { dragFrames = $0 }
        .onChange(of: folderSizes.results) { _, _ in
            if pane.sortField == .size { pane.applySortChange() }
        }
        .simultaneousGesture(TapGesture().onEnded { activatePane() })
        .sheet(isPresented: Binding(
            get: { pane.renamingItemPath != nil },
            set: { if !$0 { pane.renamingItemPath = nil } }
        )) {
            if let item = pane.renamingItem {
                RenameItemSheet(item: item, pane: pane)
            }
        }
    }

    private var restoredSessionPlaceholder: some View {
        VStack(spacing: FinderUI.chromeInset) {
            Image(systemName: "pause.circle").font(.largeTitle).accessibilityHidden(true)
            VStack(spacing: FinderUI.compactSpacing) {
                Text("Zapisany widok jest wstrzymany").font(FinderUI.titleFont)
                Text(pane.currentURL.path).font(FinderUI.detailFont).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3).truncationMode(.middle).help(pane.currentURL.path)
            }
            if case .unavailable(let reason) = pane.sessionAvailability {
                Text(reason).font(FinderUI.detailFont).foregroundStyle(.secondary)
            } else {
                Text("Folder nie został jeszcze odczytany. Wznowienie otworzy tę lokalizację i uruchomi zapisane wyszukiwanie lub analizę, jeśli były aktywne.")
                    .font(FinderUI.detailFont).foregroundStyle(.secondary)
            }
            if !pane.searchQuery.isEmpty {
                Text("Wyszukiwanie: \(pane.searchQuery)").font(FinderUI.detailFont).lineLimit(3)
            }
            if pane.sessionAvailability == .loading {
                ProgressView("Otwieranie zapisanego widoku…")
                Button("Anuluj") { pane.cancelSessionRestoration() }
            } else {
                Button("Wznów zapisany widok") {
                    activatePane()
                    Task {
                        guard appState.activeTab.id == pane.id else { return }
                        await pane.resumeSession()
                    }
                }.buttonStyle(.borderedProminent)
                Button("Wybierz inną lokalizację…") {
                    activatePane()
                    let context = pane.savedSearchActivationContext
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    // Do not set directoryURL to the unavailable path.
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        Task { @MainActor in
                            guard pane.savedSearchActivationContext == context,
                                  appState.tabs.contains(where: { $0.id == pane.id }) || appState.rightPane.id == pane.id else { return }
                            pane.navigate(to: url)
                        }
                    }
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(FinderUI.sheetPadding)
        .frame(maxWidth: 440)
    }

    // MARK: - 1. Native List View with Expandable Outline Tree (`▸`) & Drag/Drop

    private var listBrowserView: some View {
        GeometryReader { geometry in
            let showDate = geometry.size.width >= 480
            let showKind = geometry.size.width >= 700
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    sortableHeaderButton(title: "Nazwa", field: .name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    sortableHeaderButton(title: "Rozmiar", field: .size)
                        .frame(width: 85, alignment: .trailing)
                        .padding(.trailing, 14)
                    if showDate {
                        sortableHeaderButton(title: "Zmodyfikowano", field: .dateModified)
                            .frame(width: 145, alignment: .leading)
                    }
                    if showKind {
                        sortableHeaderButton(title: "Rodzaj", field: .kind)
                            .frame(width: 110, alignment: .leading)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(.bar)
                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(pane.displayedItems.enumerated()), id: \.element.id) { index, item in
                                fileListRow(item: item, index: index, showDate: showDate, showKind: showKind)
                                    .id(item.path)
                            }
                        }
                        .padding(5)
                    }
                    .onChange(of: pane.selectionCursorPath) { _, path in
                        if let path { proxy.scrollTo(path) }
                    }
                }
            }
        }
    }

    private func sortableHeaderButton(title: String, field: SortField) -> some View {
        Button {
            if pane.sortField == field {
                pane.sortAscending.toggle()
            } else {
                pane.sortField = field
                pane.sortAscending = (field == .name || field == .kind)
            }
            pane.applySortChange()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(FinderUI.captionFont.weight(pane.sortField == field ? .semibold : .medium))
                    .foregroundStyle(pane.sortField == field ? .primary : .secondary)
                if pane.sortField == field {
                    Image(systemName: pane.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sortuj według: \(title)")
        .accessibilityLabel("Sortuj według: \(title)")
        .accessibilityValue(pane.sortField == field ? (pane.sortAscending ? "Rosnąco" : "Malejąco") : "Nieaktywne sortowanie")
    }

    private func fileListRow(item: FileItem, index: Int, showDate: Bool, showKind: Bool) -> some View {
        let isSelected = pane.selectedPaths.contains(item.path)
        let isCutItem = fileOps.isCut(item.path)
        let isFolderDropTarget = (dropTargetFolderPath == item.path)
        let showSubpath = hasSearchQuery && pane.searchScope != .currentFolder

        return HStack(spacing: 0) {
            // Tree Indentation + Disclosure Triangle (`▸` / `▾`) + Icon + Name + Tags
            HStack(spacing: 6) {
                if item.treeDepth > 0 {
                    Spacer()
                        .frame(width: CGFloat(item.treeDepth) * 18)
                }

                // Outline disclosure triangle for folders when browsing directory
                if !hasSearchQuery {
                    if item.isDirectory && item.fileExtension.lowercased() != "app" {
                        Button {
                            performPaneAction { pane.toggleFolderExpansion(for: item) }
                        } label: {
                            Image(systemName: pane.isExpanded(item.path) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(pane.isExpanded(item.path) ? "Zwiń folder" : "Rozwiń folder")
                        .accessibilityLabel("\(pane.isExpanded(item.path) ? "Zwiń" : "Rozwiń") folder \(item.name)")
                    } else {
                        Spacer()
                            .frame(width: 14)
                    }
                }

                Image(nsImage: FileIconCache.shared.icon(for: item))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 20, height: 20)
                    .opacity(item.isHidden || isCutItem ? 0.5 : 1.0)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(FinderUI.bodyFont.weight(item.isDirectory ? .medium : .regular))
                            .foregroundStyle(isSelected ? selectionForegroundColor : (item.isHidden ? Color.secondary : Color.primary))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        // Native macOS Color Tag Dots
                        if !item.tags.isEmpty {
                            HStack(spacing: 3) {
                                ForEach(item.tags) { tag in
                                    Circle()
                                        .fill(tag.swiftUIColor)
                                        .frame(width: 8, height: 8)
                                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                                }
                            }
                        }

                        if item.isSymlink {
                            Image(systemName: "arrow.turn.up.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
                        }

                        if let git = item.gitStatus {
                            gitStatusBadge(git, isSelected: isSelected)
                        }
                    }

                    if showSubpath {
                        Text(item.parentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(FinderUI.captionFont)
                            .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
                            .lineLimit(1)
                    }

                    if let grep = item.grepMatch {
                        HStack(spacing: 5) {
                            Text("L\(grep.lineNumber):")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(isSelected ? selectionForegroundColor : Color.accentColor)
                            Text(grep.lineText)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(isSelected ? selectionForegroundColor : Color.primary.opacity(0.85))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isSelected ? Color.white.opacity(0.15) : Color.accentColor.opacity(0.09))
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Size Column
            Group {
                if item.isDirectory {
                    FolderSizeLabel(path: item.path, revision: pane.directoryRevision)
                } else {
                    Text(FormatHelpers.formatBytes(item.size))
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
            .frame(width: 85, alignment: .trailing)
            .padding(.trailing, 14)

            if showDate {
                Text(FormatHelpers.formatDate(item.modificationDate))
                    .font(FinderUI.detailFont)
                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
                    .lineLimit(1)
                    .frame(width: 145, alignment: .leading)
            }
            if showKind {
                Text(item.kindDisplayString)
                    .font(FinderUI.detailFont)
                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.secondary)
                    .lineLimit(1)
                    .frame(width: 110, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, showSubpath || item.grepMatch != nil ? 6 : 5)
        .opacity(isCutItem ? 0.5 : 1.0)
        .background(
            isSelected ? selectionBackgroundColor : (isFolderDropTarget ? Color.accentColor.opacity(0.18)
                : (index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1]))),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isFolderDropTarget ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: FileDragFramesKey.self,
                    value: [item.path: geometry.frame(in: .named("FilePaneSpace"))])
            }
        }
        .onDrop(of: [.fileURL], isTargeted: Binding(
            get: { dropTargetFolderPath == item.path },
            set: { targeted in dropTargetFolderPath = (targeted && item.isDropFolderTarget) ? item.path : nil }
        )) { providers in
            let targetDir = item.isDropFolderTarget ? item.url : pane.currentURL
            return handleDropProviders(providers: providers, into: targetDir)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                openOrEnterItem(item)
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                handleSelectionClick(item: item)
            }
        )
        .contextMenu {
            itemContextMenu(for: item)
        }
        .help(item.path)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Zaznacz")) { handleSelectionClick(item: item) }
        .accessibilityAction(named: Text("Otwórz")) { openOrEnterItem(item) }
    }

    // MARK: - 2. Native Icon Grid View with Rubber-Band Marquee Selection & Drag/Drop

    private var marqueeRect: CGRect? {
        guard let s = marqueeStart, let c = marqueeCurrent else { return nil }
        return CGRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(c.x - s.x),
            height: abs(c.y - s.y)
        )
    }

    private var iconGridBrowserView: some View {
        let iconDim = CGFloat(appState.iconGridSize)
        let cellWidth = max(96, iconDim + 44)
        let columns = [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth + 24), spacing: 14)]
        return ScrollView {
            ZStack(alignment: .topLeading) {
                LazyVGrid(columns: columns, spacing: FinderUI.sectionSpacing) {
                    ForEach(pane.displayedItems) { item in
                        let isSelected = pane.selectedPaths.contains(item.path)
                        let isCutItem = fileOps.isCut(item.path)
                        let isFolderDropTarget = (dropTargetFolderPath == item.path)

                        VStack(spacing: 6) {
                            ZStack(alignment: .bottomTrailing) {
                                Image(nsImage: iconCache.icon(for: item, preferThumbnail: true))
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: iconDim, height: iconDim)
                                    .clipShape(RoundedRectangle(cornerRadius: item.supportsRichThumbnail ? 6 : 0))
                                    .opacity(item.isHidden || isCutItem ? 0.5 : 1.0)

                                if let git = item.gitStatus {
                                    gitStatusBadge(git, isSelected: false)
                                }
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isFolderDropTarget ? Color.accentColor.opacity(0.22) : (isSelected ? selectionBackgroundColor.opacity(0.22) : Color.clear))
                            )

                            HStack(spacing: 3) {
                                if !item.tags.isEmpty {
                                    ForEach(item.tags.prefix(3)) { tag in
                                        Circle()
                                            .fill(tag.swiftUIColor)
                                            .frame(width: 7, height: 7)
                                    }
                                }
                                Text(item.name)
                                    .font(FinderUI.detailFont.weight(item.isDirectory ? .medium : .regular))
                                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isSelected ? selectionBackgroundColor : Color.clear)
                            )

                            Group {
                                if item.isDirectory {
                                    FolderSizeLabel(path: item.path, revision: pane.directoryRevision)
                                } else {
                                    Text(FormatHelpers.formatBytes(item.size))
                                }
                            }
                            .font(FinderUI.captionFont)
                            .foregroundStyle(.secondary)
                        }
                        .frame(width: cellWidth)
                        .padding(6)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: IconFramePreferenceKey.self,
                                    value: [item.path: geo.frame(in: .named("IconGridSpace"))]
                                )
                                .preference(key: FileDragFramesKey.self,
                                    value: [item.path: geo.frame(in: .named("FilePaneSpace"))])
                            }
                        )
                        .contentShape(Rectangle())
                        .onDrop(of: [.fileURL], isTargeted: Binding(
                            get: { dropTargetFolderPath == item.path },
                            set: { targeted in dropTargetFolderPath = (targeted && item.isDropFolderTarget) ? item.path : nil }
                        )) { providers in
                            let targetDir = item.isDropFolderTarget ? item.url : pane.currentURL
                            return handleDropProviders(providers: providers, into: targetDir)
                        }
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                openOrEnterItem(item)
                            }
                        )
                        .simultaneousGesture(
                            TapGesture(count: 1).onEnded {
                                handleSelectionClick(item: item)
                            }
                        )
                        .contextMenu {
                            itemContextMenu(for: item)
                        }
                        .help(item.path)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityAction(named: Text("Zaznacz")) { handleSelectionClick(item: item) }
                        .accessibilityAction(named: Text("Otwórz")) { openOrEnterItem(item) }
                    }
                }
                .padding(FinderUI.sectionSpacing)

                // Rubber-band Marquee Selection Box Overlay
                if let rect = marqueeRect {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(
                            Rectangle()
                                .stroke(Color.accentColor.opacity(0.85), lineWidth: 1)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "IconGridSpace")
            .onPreferenceChange(IconFramePreferenceKey.self) { frames in
                iconFrames = frames
            }
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named("IconGridSpace"))
                    .onChanged { value in
                        if marqueeStart == nil {
                            activatePane()
                            pane.focusFilePaneTrigger &+= 1
                            marqueeStart = value.startLocation
                        }
                        marqueeCurrent = value.location
                        if let box = marqueeRect {
                            var selected = Set<String>()
                            for (path, frame) in iconFrames where box.intersects(frame) {
                                selected.insert(path)
                            }
                            pane.selectedPaths = selected
                        }
                    }
                    .onEnded { _ in
                        marqueeStart = nil
                        marqueeCurrent = nil
                    }
            )
        }
    }

    // MARK: - 3. Miller Columns View

    private var millerColumnsBrowserView: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                ForEach(pane.columnTrailURLs, id: \.path) { colURL in
                    MillerColumnSingleListView(
                        columnURL: colURL,
                        pane: pane,
                        selectionBackgroundColor: selectionBackgroundColor,
                        selectionForegroundColor: selectionForegroundColor,
                        onSelectDirectory: { selectedDirURL in
                            performPaneAction { pane.navigate(to: selectedDirURL) }
                        },
                        onSelectFile: { fileItem in
                            performPaneAction {
                                let parent = fileItem.url.deletingLastPathComponent()
                                if pane.currentURL.path != parent.path, !pane.navigate(to: parent) { return }
                                pane.select(fileItem)
                            }
                        }
                    )
                    .frame(width: 245)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func navigationFailureButtons(failureID: UUID) -> some View {
        if !pane.navigationFailureIsPermissionDenied {
            Button("Spróbuj ponownie") {
                FinderPaneActionRouting.performIfCurrent(appState: appState, pane: pane, paneSide: paneSide) {
                    pane.retryNavigation(expectedFailureID: failureID)
                }
            }
            .fixedSize()
        } else {
            // Denied folders (Desktop, Documents, external disks) are granted in Privacy & Security.
            Button("Otwórz ustawienia prywatności…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .fixedSize()
            .help("Nadaj aplikacji BetterFinder dostęp w Ustawieniach systemowych › Prywatność i ochrona")
        }
        Button("Zamknij komunikat") {
            FinderPaneActionRouting.performIfCurrent(appState: appState, pane: pane, paneSide: paneSide) {
                pane.dismissNavigationFailure(expectedFailureID: failureID)
            }
        }
        .fixedSize()
    }

    // MARK: - Trash Banner (`~/.Trash`)

    private var trashActionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Kosz systemowy · Elementy: \(pane.displayedItems.count)")
                .font(FinderUI.detailFont.weight(.semibold))
            Spacer()
            if !pane.displayedItems.isEmpty {
                Button("Opróżnij Kosz…", role: .destructive) {
                    fileOps.emptySystemTrash()
                    pane.reloadDirectory()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.07))
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Search Status & Empty State

    private func searchNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(FinderUI.captionFont)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FinderUI.sectionSpacing)
            .padding(.vertical, FinderUI.rowSpacing)
            .accessibilityElement(children: .combine)
    }

    private var searchLoadingPlaceholder: some View {
        VStack(spacing: FinderUI.rowSpacing) {
            ProgressView()
                .controlSize(.regular)
                .accessibilityLabel("Wyszukiwanie plików")
            Text("Wyszukiwanie…")
                .font(FinderUI.titleFont)
            Text("Wyniki pojawią się po zakończeniu wyszukiwania.")
                .font(FinderUI.detailFont)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(FinderUI.sheetPadding)
        .allowsHitTesting(false)
    }

    private var emptyStatePlaceholder: some View {
        VStack(spacing: FinderUI.rowSpacing) {
            Image(systemName: hasSearchQuery ? "magnifyingglass" : "folder")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(!hasSearchQuery ? "Brak widocznych elementów" : (pane.searchDiagnostic != nil || pane.searchIsPartial ? "Brak wyników w sprawdzonym zakresie" : "Brak pasujących plików"))
                .font(FinderUI.titleFont)
            Text(!hasSearchQuery ? "Przeciągnij tutaj pliki, utwórz folder lub sprawdź ustawienie ukrytych plików."
                 : "Zmień zapytanie, usuń filtry lub poszerz zakres wyszukiwania.")
                .font(FinderUI.detailFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300)
            if !hasSearchQuery {
                Button("Nowy folder…") { activatePane(); appState.showNewFolderSheet = true }
            } else {
                Button("Wyczyść wyszukiwanie") { pane.clearSearch() }
            }
        }
        .multilineTextAlignment(.center)
        .padding(FinderUI.sheetPadding)
    }

    // MARK: - Git Badge

    private func gitStatusBadge(_ git: GitFileStatus, isSelected: Bool) -> some View {
        let color: Color = {
            switch git {
            case .modified: return .orange
            case .staged: return .green
            case .untracked: return .blue
            case .deleted: return .red
            case .renamed: return .purple
            }
        }()
        return Text(git.rawValue)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundStyle(isSelected ? selectionForegroundColor : color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isSelected ? Color.white.opacity(0.22) : color.opacity(0.15))
            )
            .help("Git: \(git.badgeDescription)")
    }

    // MARK: - Drag & Drop Handler

    private func handleDropProviders(providers: [NSItemProvider], into destinationURL: URL) -> Bool {
        guard FileDropPaneContext.accepts(providers, in: pane) else { return false }
        activatePane()
        let copyInstead = NSEvent.modifierFlags.contains(.option)
        let context = FileDropPaneContext(pane: pane)
        dropLoad.begin(providers: providers, destination: destinationURL) { urls in
            guard context.allowsCommit(in: appState, side: paneSide) else { return }
            fileOps.handleDropURLs(urls, into: destinationURL, copyInsteadOfMove: copyInstead)
        }
        return true
    }

    private func performPaneAction(_ action: () -> Void) {
        FinderPaneActionRouting.perform(appState: appState, paneSide: paneSide, action: action)
    }

    private func activatePane() {
        performPaneAction {}
    }

    private func handleSelectionClick(item: FileItem) {
        let flags = NSEvent.modifierFlags
        performPaneAction {
            pane.select(item, extending: flags.contains(.shift), toggling: flags.contains(.command))
        }
    }

    private func openOrEnterItem(_ item: FileItem) {
        guard !pane.actionItems(for: item).isEmpty else { return }
        performPaneAction {
            if item.isDirectory && item.fileExtension.lowercased() != "app" {
                pane.navigate(to: item.url)
            } else {
                pane.openFile(item.url)
            }
        }
    }

    // MARK: - Context Menus (Open With, Share, Color Tags, Extract Archive, etc.)

    @ViewBuilder
    private func itemContextMenu(for item: FileItem) -> some View {
        // Resolve inside the action, not while the menu captures an old row.
        let targetItems = { pane.actionItems(for: item) }

        Button {
            openOrEnterItem(item)
        } label: {
            Label(item.isDirectory ? "Otwórz folder" : "Otwórz", systemImage: "arrow.up.forward.app")
        }

        if !item.isDirectory {
            OpenWithApplicationsMenu(item: item)
        }

        Button {
            guard !pane.actionItems(for: item).isEmpty else { return }
            activatePane()
            pane.select(item)
            appState.toggleQuickLook()
        } label: {
            Label("Quick Look (Spacja)", systemImage: "eye")
        }

        if !pane.searchQuery.isEmpty {
            Button {
                guard !pane.actionItems(for: item).isEmpty else { return }
                performPaneAction {
                    let parentURL = URL(fileURLWithPath: item.parentPath, isDirectory: true)
                    if pane.navigate(to: parentURL, clearSearch: true) {
                        pane.selectedPaths = [item.path]
                    }
                }
            } label: {
                Label("Pokaż w folderze nadrzędnym", systemImage: "folder.fill.badge.person.crop")
            }
        }

        Divider()

        // Native macOS Color Tags Menu
        Menu("Tagi macOS") {
            ForEach(FinderTagColor.allCases) { tagColor in
                let hasTag = item.tags.contains(tagColor)
                Button {
                    fileOps.toggleTag(tagColor, for: targetItems())
                    pane.reloadDirectory()
                } label: {
                    Label(
                        hasTag ? "✓ \(tagColor.displayName)" : tagColor.displayName,
                        systemImage: hasTag ? "checkmark.circle.fill" : "circle.fill"
                    )
                }
            }
            if !item.tags.isEmpty {
                Divider()
                Button("Usuń wszystkie tagi", role: .destructive) {
                    fileOps.clearTags(for: targetItems())
                    pane.reloadDirectory()
                }
            }
        }

        Button {
            fileOps.showShareSheet(for: targetItems())
        } label: {
            Label("Udostępnij (AirDrop, Wiadomości...)", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button {
            fileOps.cutItems(targetItems())
        } label: {
            Label("Wytnij (⌘X)", systemImage: "scissors")
        }

        Button {
            fileOps.copyItems(targetItems())
        } label: {
            Label("Kopiuj (⌘C)", systemImage: "doc.on.doc")
        }

        Button {
            fileOps.paste(into: pane.currentURL)
            pane.reloadDirectory()
        } label: {
            Label("Wklej tutaj (⌘V)", systemImage: "doc.on.clipboard")
        }

        Divider()

        Button {
            activatePane()
            pane.select(item)
            guard !pane.actionItems(for: item).isEmpty else { return }
            pane.renamingItemPath = item.path
        } label: {
            Label("Zmień nazwę…", systemImage: "pencil")
        }

        Button {
            fileOps.duplicateItems(targetItems())
            pane.reloadDirectory()
        } label: {
            Label("Duplikuj (⌘D)", systemImage: "plus.square.on.square")
        }

        Button {
            fileOps.compressItems(targetItems(), in: pane.currentURL)
        } label: {
            Label("Kompresuj do ZIP", systemImage: "doc.zipper")
        }

        if item.isExtractableArchive {
            Button {
                guard !pane.actionItems(for: item).isEmpty else { return }
                fileOps.extractArchive(item)
            } label: {
                if item.fileExtension.lowercased() == "dmg" {
                    Label("Zamontuj obraz dysku", systemImage: "externaldrive.fill")
                } else {
                    Label("Rozpakuj archiwum tutaj", systemImage: "archivebox.fill")
                }
            }
        }

        Divider()

        Button {
            fileOps.copyPaths(targetItems())
        } label: {
            Label("Kopiuj pełną ścieżkę (⌥⌘C)", systemImage: "link")
        }

        Button {
            guard !pane.actionItems(for: item).isEmpty else { return }
            fileOps.openInTerminal(at: item.url)
        } label: {
            Label("Otwórz w Terminalu", systemImage: "terminal")
        }

        Button {
            guard !pane.actionItems(for: item).isEmpty else { return }
            fileOps.openInCodeEditor(at: item.url)
        } label: {
            Label("Otwórz w edytorze kodu", systemImage: "chevron.left.forwardslash.chevron.right")
        }

        if item.isDirectory {
            Button {
                guard !pane.actionItems(for: item).isEmpty else { return }
                appState.addBookmark(for: item.url)
            } label: {
                Label("Przypnij do paska bocznego", systemImage: "bookmark")
            }
        }

        Button {
            fileOps.revealInAppleFinder(targetItems())
        } label: {
            Label("Pokaż w klasycznym Finderze", systemImage: "macwindow")
        }

        Divider()

        Button(role: .destructive) {
            fileOps.moveToTrash(targetItems())
            pane.reloadDirectory()
        } label: {
            Label("Przenieś do Kosza", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var paneBackgroundContextMenu: some View {
        Button {
            activatePane()
            appState.showNewFolderSheet = true
        } label: {
            Label("Nowy folder (⇧⌘N)…", systemImage: "folder.badge.plus")
        }

        Button {
            activatePane()
            appState.showNewFileSheet = true
        } label: {
            Label("Nowy plik (⌥⌘N)…", systemImage: "doc.badge.plus")
        }

        Divider()

        Button {
            fileOps.paste(into: pane.currentURL)
            pane.reloadDirectory()
        } label: {
            Label("Wklej tutaj (⌘V)", systemImage: "doc.on.clipboard")
        }

        if fileOps.canUndo {
            Button {
                fileOps.undoLastOperation()
            } label: {
                Label("\(fileOps.undoLabel) (⌘Z)", systemImage: "arrow.uturn.backward")
            }
        }

        Button {
            pane.reloadDirectory()
        } label: {
            Label("Odśwież widok", systemImage: "arrow.clockwise")
        }

        Divider()

        Button {
            performPaneAction { appState.showTerminalDrawer.toggle() }
        } label: {
            Label("Wbudowany panel Terminala (Ctrl+`)", systemImage: "terminal.fill")
        }

        Button {
            fileOps.openInTerminal(at: pane.currentURL)
        } label: {
            Label("Otwórz bieżący folder w Terminalu", systemImage: "terminal")
        }
    }
}

private struct MillerColumnSingleListView: View {
    let columnURL: URL
    @ObservedObject var pane: PaneTabState
    @ObservedObject private var iconCache = FileIconCache.shared
    @ObservedObject private var folderSizes = FolderSizeCache.shared
    @ViewState private var folderSizeOwner = UUID()
    let selectionBackgroundColor: Color
    let selectionForegroundColor: Color
    let onSelectDirectory: (URL) -> Void
    let onSelectFile: (FileItem) -> Void

    @ViewState private var items: [FileItem] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text(columnURL.lastPathComponent.isEmpty ? "/" : columnURL.lastPathComponent)
                    .font(FinderUI.captionFont.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .help(columnURL.path)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()
            if pane.sortField == .size && items.contains(where: { $0.isDirectory && folderSizes.size(for: $0.path) == nil }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Niepełne sortowanie: nieznane i częściowe rozmiary na końcu grupy.")
                    if items.contains(where: { $0.isDirectory && folderSizes.status(for: $0.path) == .deferred }) {
                        Text("Limit aktywnych folderów. Zawęź widok lub zamknij inne widoki.")
                        Button("Ponów rozmiary") { updateFolderSizeDemand() }
                    }
                }
                .font(FinderUI.captionFont)
                .padding(FinderUI.compactSpacing)
            }

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(items) { item in
                        let isInTrail = pane.columnTrailURLs.contains(where: { $0.path == item.path }) ||
                                        pane.selectedPaths.contains(item.path)
                        HStack(spacing: 7) {
                            Image(nsImage: FileIconCache.shared.icon(for: item))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(item.name)
                                .font(FinderUI.detailFont)
                                .foregroundStyle(isInTrail ? selectionForegroundColor : Color.primary)
                                .lineLimit(1)
                            Spacer()
                            let tags = pane.cachedTags(for: item.path) ?? item.tags
                            if let firstTag = tags.first {
                                Circle()
                                    .fill(firstTag.swiftUIColor)
                                    .frame(width: 7, height: 7)
                            }
                            if item.isDirectory {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(isInTrail ? selectionForegroundColor : Color.secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isInTrail ? selectionBackgroundColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onDrag {
                            NSItemProvider(object: item.url as NSURL)
                        }
                        .onTapGesture {
                            if item.isDirectory && item.fileExtension.lowercased() != "app" {
                                onSelectDirectory(item.url)
                            } else {
                                onSelectFile(item)
                            }
                        }
                        .help(item.path)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(isInTrail ? .isSelected : [])
                        .accessibilityAction {
                            if item.isDirectory && item.fileExtension.lowercased() != "app" {
                                onSelectDirectory(item.url)
                            } else {
                                onSelectFile(item)
                            }
                        }
                    }
                }
                .padding(FinderUI.compactSpacing)
            }
            .overlay {
                if items.isEmpty {
                    VStack(spacing: FinderUI.rowSpacing) {
                        Image(systemName: "folder")
                            .font(.title2)
                            .accessibilityHidden(true)
                        Text("Brak widocznych elementów")
                            .font(FinderUI.detailFont)
                    }
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(FinderUI.sectionSpacing)
                    .allowsHitTesting(false)
                }
            }
        }
        .onAppear {
            loadColumn()
        }
        .onChange(of: pane.showHiddenFiles) { _, _ in loadColumn() }
        .onChange(of: pane.directoryRevision) { _, _ in loadColumn() }
        .onChange(of: pane.sortField) { _, _ in loadColumn() }
        .onChange(of: pane.sortAscending) { _, _ in loadColumn() }
        .onChange(of: pane.foldersOnTop) { _, _ in loadColumn() }
        .onChange(of: folderSizes.results) { _, _ in
            if pane.sortField == .size { items = pane.sortItems(items) }
        }
        .onChange(of: columnURL) { _, _ in loadColumn() }
        .onDisappear { folderSizes.release(owner: folderSizeOwner) }
    }

    private func updateFolderSizeDemand() {
        folderSizes.updateDemand(owner: folderSizeOwner,
            paths: FolderSizeCache.columnDemandPaths(items: items, sortBySize: pane.sortField == .size),
            priority: .background)
    }

    private func loadColumn() {
        let entries = BulkCrawler.readDirectoryFast(at: columnURL.path, includeHidden: pane.showHiddenFiles)
        items = pane.sortItems(entries.map { $0.toFileItem(loadTags: false) })
        updateFolderSizeDemand()
        pane.loadTagMetadataIfNeeded(for: items)
    }
}

/// Each lazily appearing row owns its demand independently of other panes and
/// the inspector. Offscreen rows release their lease instead of pinning a whole
/// directory and starving a newly visible or selected folder.
private struct FolderSizeLabel: View {
    let path: String
    let revision: UInt64
    @ObservedObject private var cache = FolderSizeCache.shared
    @ViewState private var owner = UUID()

    var body: some View {
        HStack(spacing: 0) {
            if cache.status(for: path) == .deferred {
                Button("Odroczono ↻") { request() }
                    .buttonStyle(.plain)
                    .help("Limit aktywnych folderów. Zawęź widok lub zamknij inne widoki, a następnie kliknij, aby ponowić.")
            } else {
                Text(cache.statusText(for: path))
                    .help(cache.size(for: path) == nil
                        ? "W kolejce, w trakcie skanu lub dolne oszacowanie (limit / nieodczytane katalogi)."
                        : "Pełny rozmiar folderu")
            }
        }
        .onAppear { request() }
        .onChange(of: path) { _, _ in request() }
        .onChange(of: revision) { _, _ in request() }
        .onDisappear { cache.release(owner: owner) }
    }

    private func request() { cache.updateDemand(owner: owner, paths: [path], priority: .visible) }
}
