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
            paneHeader

            if let diagnostic = pane.navigationDiagnostic, let failureID = pane.navigationFailureID {
                HStack(alignment: .top, spacing: FinderUI.rowSpacing) {
                    Image(systemName: pane.navigationFailureIsPermissionDenied ? "lock.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
                        Text(pane.navigationFailureIsPermissionDenied ? String(localized: "No access to folder") : String(localized: "Can't open folder"))
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
                        .accessibilityLabel("Folder error details")
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
                searchNotice(String(localized: "Partial results: not all files were searched."))
            }

            if pane.isSearching && !pane.displayedItems.isEmpty {
                HStack(spacing: FinderUI.rowSpacing) {
                    ProgressView().controlSize(.small)
                    Text("Updating results…")
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
                guard !pane.isSessionPaused else { return false }
                return handleDropProviders(providers: providers, into: pane.currentURL)
            }
            .contextMenu {
                if !pane.isSessionPaused { paneBackgroundContextMenu }
            }
        }
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

    /// Breadcrumbs while browsing; while searching, what was found and where,
    /// since the results no longer belong to the folder shown in the path.
    /// With two panes, an accent line marks the pane that receives commands.
    private var paneHeader: some View {
        Group {
            if hasSearchQuery {
                searchResultsHeader
            } else {
                PathBreadcrumbBar(appState: appState, pane: pane)
            }
        }
        // The inactive pane stays fully legible; tint and underline mark the active one.
        .background {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                if appState.isDualPane && isFocusedPane { FinderUI.activePaneTint }
            }
        }
        .overlay(alignment: .bottom) {
            if appState.isDualPane && isFocusedPane {
                Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
            }
        }
    }

    private var searchResultsHeader: some View {
        let count = pane.displayedItems.count
        let query = pane.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = FileManager.default.displayName(atPath: pane.currentURL.path)
        let scope: String
        switch pane.searchScope {
        case .currentFolder: scope = String(localized: "in “\(folder)”")
        case .recursiveFolder: scope = String(localized: "in “\(folder)” and its subfolders")
        case .wholeIndex: scope = String(localized: "in all indexed folders")
        }
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(pane.isSearching && count == 0 ? String(localized: "Searching for “\(query)”…")
                 : count == 1 ? String(localized: "1 result for “\(query)”") : String(localized: "\(count) results for “\(query)”"))
                .fontWeight(.semibold)
                .lineLimit(1)
            // Where to search, changeable right where the results are described.
            Menu {
                Picker("Search In", selection: Binding(get: { pane.searchScope }, set: { mode in
                    pane.searchScope = mode
                    if pane !== appState.activeTab { pane.triggerSearch() }
                })) {
                    Text("All Indexed Folders").tag(SearchScopeMode.wholeIndex)
                    Text("“\(folder)” and Subfolders").tag(SearchScopeMode.recursiveFolder)
                    Text("“\(folder)” Only").tag(SearchScopeMode.currentFolder)
                }
                .pickerStyle(.inline)
            } label: {
                Text(scope).lineLimit(1).truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Choose where to search")
            Spacer(minLength: 0)
        }
        .font(FinderUI.detailFont)
        .padding(.horizontal, FinderUI.panelInset)
        .frame(height: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    /// The folder holding a result reads first; the way to it recedes.
    private func resultLocation(_ path: String, isSelected: Bool) -> Text {
        let base = pane.searchScope == .wholeIndex
            ? FSearchIndex.shared.configuredRoots.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
            : pane.currentURL.path
        var parts: [String]
        if let base, base != "/", path == base || path.hasPrefix(base + "/") {
            parts = [FileManager.default.displayName(atPath: base)]
                + path.dropFirst(base.count).split(separator: "/").map(String.init)
        } else {
            parts = Self.shortLocation(of: path).components(separatedBy: " › ")
        }
        let folder = parts.popLast() ?? ""
        let lead = parts.isEmpty ? "" : parts.joined(separator: " › ") + " › "
        // One readable secondary colour for the whole line; the smaller size keeps it subordinate.
        let leadColor = isSelected ? selectionForegroundColor.opacity(0.85) : FinderUI.metadataColor
        let folderColor = leadColor
        return Text(verbatim: lead).foregroundColor(leadColor) + Text(verbatim: folder).foregroundColor(folderColor)
    }

    /// "Burrow Demo › Studio › Invoices": the folders nearest the result
    /// say where it is; the full path is in the tooltip.
    static func shortLocation(of path: String) -> String {
        let home = NSHomeDirectory()
        let relative = path == home ? "~" : path.hasPrefix(home + "/") ? "~/" + path.dropFirst(home.count + 1) : path
        // The whole location; the text view shortens the middle only when it overflows.
        return relative.split(separator: "/").joined(separator: " › ")
    }

    /// The name with matches in semibold on a rounded accent wash (macOS 15+),
    /// or the flat attributed wash on older systems.
    @ViewBuilder
    private func highlightedNameText(_ name: String, isSelected: Bool) -> some View {
        if #available(macOS 15.0, *) {
            matchText(name, isSelected: isSelected)
                .textRenderer(SearchMatchRenderer())
        } else {
            Text(highlightedName(name, isSelected: isSelected))
        }
    }

    @available(macOS 15.0, *)
    private func matchText(_ name: String, isSelected: Bool) -> Text {
        var result = Text(verbatim: "")
        var cursor = name.startIndex
        for range in matchRanges(in: name) {
            if cursor < range.lowerBound { result = result + Text(verbatim: String(name[cursor..<range.lowerBound])) }
            let match = Text(verbatim: String(name[range])).fontWeight(.semibold)
            result = result + (isSelected ? match : match.customAttribute(SearchMatchAttribute()))
            cursor = range.upperBound
        }
        if cursor < name.endIndex { result = result + Text(verbatim: String(name[cursor...])) }
        return result
    }

    /// Non-overlapping ranges of the typed terms inside a name, in order.
    private func matchRanges(in name: String) -> [Range<String.Index>] {
        let terms = pane.searchQuery.split(separator: " ").map(String.init)
            .filter { !$0.isEmpty && !$0.contains(":") && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." } }
        guard hasSearchQuery, !terms.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        for term in terms {
            var start = name.startIndex
            while start < name.endIndex,
                  let range = name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: start..<name.endIndex) {
                if !ranges.contains(where: { $0.overlaps(range) }) { ranges.append(range) }
                start = range.upperBound
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Search results show the typed text in bold within each name.
    private func highlightedName(_ name: String, isSelected: Bool) -> AttributedString {
        var text = AttributedString(name)
        let terms = pane.searchQuery.split(separator: " ").map(String.init)
            .filter { !$0.isEmpty && !$0.contains(":") && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." } }
        guard hasSearchQuery, !terms.isEmpty else { return text }
        for term in terms {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text[searchStart...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                text[range].font = FinderUI.bodyFont.weight(.semibold)
                // Semibold on a faint accent wash: the name keeps its colour, so the
                // match neither reads as a link nor vanishes on a selected row.
                if !isSelected { text[range].backgroundColor = FinderUI.matchHighlight }
                searchStart = range.upperBound
            }
        }
        return text
    }

    private var restoredSessionPlaceholder: some View {
        VStack(spacing: FinderUI.chromeInset) {
            Image(systemName: "pause.circle").font(.largeTitle).accessibilityHidden(true)
            VStack(spacing: FinderUI.compactSpacing) {
                Text("Saved view is paused").font(FinderUI.titleFont)
                Text(pane.currentURL.path).font(FinderUI.detailFont).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3).truncationMode(.middle).help(pane.currentURL.path)
            }
            if case .unavailable(let reason) = pane.sessionAvailability {
                Text(reason).font(FinderUI.detailFont).foregroundStyle(.secondary)
            } else {
                Text("The folder hasn't been read yet. Resuming will open this location and restart the saved search or analysis if they were active.")
                    .font(FinderUI.detailFont).foregroundStyle(.secondary)
            }
            if !pane.searchQuery.isEmpty {
                Text("Search: \(pane.searchQuery)").font(FinderUI.detailFont).lineLimit(3)
            }
            if pane.sessionAvailability == .loading {
                ProgressView("Opening saved view…")
                Button("Cancel") { pane.cancelSessionRestoration() }
            } else {
                Button("Resume Saved View") {
                    activatePane()
                    Task {
                        guard appState.activeTab.id == pane.id else { return }
                        await pane.resumeSession()
                    }
                }.buttonStyle(.borderedProminent)
                Button("Choose Another Location…") {
                    activatePane()
                    let context = pane.activationContext
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    // Do not set directoryURL to the unavailable path.
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        Task { @MainActor in
                            guard pane.activationContext == context,
                                  appState.allPanes.contains(where: { $0.id == pane.id }) else { return }
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
            // Kind stays in a half-width pane at a narrower width instead of
            // leaving an empty band after the date.
            // 144 pt holds "Numbers Spreadsheet"; Name gives way first.
            let kindWidth: CGFloat = geometry.size.width >= 760 ? 150 : (geometry.size.width >= 560 ? 144 : 0)
            let showKind = kindWidth > 0
            // No disclosure gutter in a folder without subfolders.
            let showsDisclosure = pane.displayedItems.contains { $0.isDirectory && $0.fileExtension.lowercased() != "app" }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    sortableHeaderButton(title: String(localized: "Name"), field: .name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    sortableHeaderButton(title: String(localized: "Size"), field: .size)
                        .frame(width: 80, alignment: .trailing)
                        .padding(.trailing, 20)
                    if showDate {
                        // Leading in every layout; 160 pt holds "Nov 12, 2025 at 12:58 PM".
                        sortableHeaderButton(title: String(localized: "Date Modified"), field: .dateModified)
                            .frame(width: 160, alignment: .leading)
                    }
                    if showKind {
                        sortableHeaderButton(title: String(localized: "Kind"), field: .kind)
                            .frame(width: kindWidth, alignment: .leading)
                    }
                }
                .padding(.leading, 15)
                .padding(.trailing, 19)
                .frame(height: 26)
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(pane.displayedItems.enumerated()), id: \.element.id) { index, item in
                                fileListRow(item: item, index: index, showDate: showDate, kindWidth: kindWidth,
                                            showsDisclosure: showsDisclosure)
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
            var sort = pane.currentSort
            if sort.field == field {
                sort.ascending.toggle()
            } else {
                sort.field = field
                sort.ascending = (field == .name || field == .kind)
            }
            pane.setSort(sort)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(FinderUI.captionFont.weight(pane.sortField == field ? .semibold : .medium))
                    .foregroundStyle(pane.sortField == field ? Color.primary : FinderUI.metadataColor)
                if pane.sortField == field {
                    Image(systemName: pane.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        // Grey like Finder: blue stays for selection and active state.
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by: \(title)")
        .accessibilityLabel("Sort by: \(title)")
        .accessibilityValue(pane.sortField == field ? (pane.sortAscending ? String(localized: "Ascending") : String(localized: "Descending")) : String(localized: "Not sorted"))
    }

    private func fileListRow(item: FileItem, index: Int, showDate: Bool, kindWidth: CGFloat,
                             showsDisclosure: Bool) -> some View {
        let showKind = kindWidth > 0
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
                        .help(pane.isExpanded(item.path) ? String(localized: "Collapse folder") : String(localized: "Expand folder"))
                        .accessibilityLabel(pane.isExpanded(item.path) ? String(localized: "Collapse folder \(item.name)") : String(localized: "Expand folder \(item.name)"))
                    } else if showsDisclosure {
                        Spacer()
                            .frame(width: 14)
                    }
                }

                // Two-line search rows get a larger icon to match their height.
                Image(nsImage: FileIconCache.shared.icon(for: item))
                    .resizable()
                    .interpolation(.high)
                    // System folder art fills its box more than document art; 2 pt less
                    // keeps the two-line results optically even.
                    // A 32 pt box across both lines anchors the row; folder art fills its box
                    // more than document art, so it is drawn 4 pt smaller.
                    .frame(width: showSubpath ? (item.isDirectory ? 28 : 32) : 20,
                           height: showSubpath ? (item.isDirectory ? 28 : 32) : 20)
                    .frame(width: showSubpath ? 32 : 20)
                    .opacity(item.isHidden || isCutItem ? 0.5 : 1.0)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        highlightedNameText(item.name, isSelected: isSelected)
                            .font(FinderUI.bodyFont)
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

                        CloudStatusBadge(item: item, isSelected: isSelected, selectionColor: selectionForegroundColor)
                    }

                    if showSubpath {
                        resultLocation(item.parentPath, isSelected: isSelected)
                            // Smaller and quieter than the name: the same path often repeats.
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .help(item.parentPath)
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
            .font(FinderUI.bodyFont.monospacedDigit())
            .foregroundStyle(isSelected ? selectionForegroundColor : FinderUI.metadataColor)
            .lineLimit(1)
            .frame(width: 80, alignment: .trailing)
            .padding(.trailing, 20)

            if showDate {
                Text(FormatHelpers.formatDate(item.modificationDate))
                    .font(FinderUI.bodyFont)
                    .foregroundStyle(isSelected ? selectionForegroundColor : FinderUI.metadataColor)
                    .lineLimit(1)
                    .frame(width: 160, alignment: .leading)
            }
            if showKind {
                Text(item.kindDisplayString)
                    .font(FinderUI.bodyFont)
                    .foregroundStyle(isSelected ? selectionForegroundColor : FinderUI.metadataColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: kindWidth, alignment: .leading)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, showSubpath || item.grepMatch != nil ? 6 : 5)
        .opacity(isCutItem ? 0.5 : 1.0)
        .background(
            isSelected ? selectionBackgroundColor : (isFolderDropTarget ? Color.accentColor.opacity(0.18)
                : (index.isMultiple(of: 2) ? Color.clear : FinderUI.stripeColor)),
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
        .accessibilityAction(named: Text("Select")) { handleSelectionClick(item: item) }
        .accessibilityAction(named: Text("Open")) { openOrEnterItem(item) }
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
        let cellWidth = max(110, iconDim + 60)
        // Top-aligned cells keep thumbnails, names and sizes on shared lines.
        let columns = [GridItem(.adaptive(minimum: cellWidth, maximum: cellWidth + 24), spacing: 14, alignment: .top)]
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
                                    .shadow(color: .black.opacity(item.supportsRichThumbnail ? 0.18 : 0), radius: 2, y: 1)
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
                                    .font(FinderUI.bodyFont)
                                    .foregroundStyle(isSelected ? selectionForegroundColor : Color.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                CloudStatusBadge(item: item, isSelected: isSelected, selectionColor: selectionForegroundColor)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isSelected ? selectionBackgroundColor : Color.clear)
                            )
                            // The size sits right under the name, however many lines it takes.
                            .padding(.bottom, -2)

                            Group {
                                if item.isDirectory {
                                    FolderSizeLabel(path: item.path, revision: pane.directoryRevision)
                                } else {
                                    Text(FormatHelpers.formatBytes(item.size))
                                }
                            }
                            .font(FinderUI.captionFont)
                            .foregroundStyle(FinderUI.metadataColor)
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
                        .accessibilityAction(named: Text("Select")) { handleSelectionClick(item: item) }
                        .accessibilityAction(named: Text("Open")) { openOrEnterItem(item) }
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
            Button("Try Again") {
                FinderPaneActionRouting.performIfCurrent(appState: appState, pane: pane, paneSide: paneSide) {
                    pane.retryNavigation(expectedFailureID: failureID)
                }
            }
            .fixedSize()
        } else {
            // Denied folders (Desktop, Documents, external disks) are granted in Privacy & Security.
            Button("Open Privacy Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .fixedSize()
            .help("Give Burrow access in System Settings › Privacy & Security")
        }
        Button("Dismiss") {
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
            Text("System Trash · Items: \(pane.displayedItems.count)")
                .font(FinderUI.detailFont.weight(.semibold))
            Spacer()
            if !pane.displayedItems.isEmpty {
                Button("Empty Trash…", role: .destructive) {
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
                .accessibilityLabel("Searching files")
            Text("Searching…")
                .font(FinderUI.titleFont)
            Text("Results will appear when the search finishes.")
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
            Text(!hasSearchQuery ? String(localized: "No visible items") : (pane.searchDiagnostic != nil || pane.searchIsPartial ? String(localized: "No results in the searched scope") : String(localized: "No matching files")))
                .font(FinderUI.titleFont)
            Text(!hasSearchQuery ? String(localized: "Drag files here, create a folder, or check the hidden files setting.")
                 : String(localized: "Change the query, remove filters, or widen the search scope."))
                .font(FinderUI.detailFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 300)
            if !hasSearchQuery {
                Button("New Folder…") { activatePane(); appState.showNewFolderSheet = true }
            } else {
                Button("Clear Search") { pane.clearSearch() }
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
            Label(item.isDirectory ? String(localized: "Open Folder") : String(localized: "Open"), systemImage: "arrow.up.forward.app")
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
            Label("Quick Look (Space)", systemImage: "eye")
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
                Label("Show in Enclosing Folder", systemImage: "folder.fill.badge.person.crop")
            }
        }

        CloudContextMenuItems(item: item, targets: targetItems)

        Divider()

        // Native macOS Color Tags Menu
        Menu("macOS Tags") {
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
                Button("Remove All Tags", role: .destructive) {
                    fileOps.clearTags(for: targetItems())
                    pane.reloadDirectory()
                }
            }
        }

        Button {
            fileOps.showShareSheet(for: targetItems())
        } label: {
            Label("Share (AirDrop, Messages…)", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button {
            fileOps.cutItems(targetItems())
        } label: {
            Label("Cut (⌘X)", systemImage: "scissors")
        }

        Button {
            fileOps.copyItems(targetItems())
        } label: {
            Label("Copy (⌘C)", systemImage: "doc.on.doc")
        }

        Button {
            fileOps.paste(into: pane.currentURL)
            pane.reloadDirectory()
        } label: {
            Label("Paste Here (⌘V)", systemImage: "doc.on.clipboard")
        }

        Divider()

        Button {
            activatePane()
            pane.select(item)
            guard !pane.actionItems(for: item).isEmpty else { return }
            pane.renamingItemPath = item.path
        } label: {
            Label("Rename…", systemImage: "pencil")
        }

        Button {
            fileOps.duplicateItems(targetItems())
            pane.reloadDirectory()
        } label: {
            Label("Duplicate (⌘D)", systemImage: "plus.square.on.square")
        }

        Button {
            fileOps.compressItems(targetItems(), in: pane.currentURL)
        } label: {
            Label("Compress to ZIP", systemImage: "doc.zipper")
        }

        if item.isExtractableArchive {
            Button {
                guard !pane.actionItems(for: item).isEmpty else { return }
                fileOps.extractArchive(item)
            } label: {
                if item.fileExtension.lowercased() == "dmg" {
                    Label("Mount Disk Image", systemImage: "externaldrive.fill")
                } else {
                    Label("Extract Archive Here", systemImage: "archivebox.fill")
                }
            }
        }

        Divider()

        Button {
            fileOps.copyPaths(targetItems())
        } label: {
            Label("Copy Full Path (⌥⌘C)", systemImage: "link")
        }

        Button {
            guard !pane.actionItems(for: item).isEmpty else { return }
            fileOps.openInTerminal(at: item.url)
        } label: {
            Label("Open in Terminal", systemImage: "terminal")
        }

        Button {
            guard !pane.actionItems(for: item).isEmpty else { return }
            fileOps.openInCodeEditor(at: item.url)
        } label: {
            Label("Open in Code Editor", systemImage: "chevron.left.forwardslash.chevron.right")
        }

        if item.isDirectory {
            Button {
                guard !pane.actionItems(for: item).isEmpty else { return }
                appState.addBookmark(for: item.url)
            } label: {
                Label("Pin to Sidebar", systemImage: "bookmark")
            }
        }

        Button {
            fileOps.revealInAppleFinder(targetItems())
        } label: {
            Label("Show in Classic Finder", systemImage: "macwindow")
        }

        Divider()

        Button(role: .destructive) {
            fileOps.moveToTrash(targetItems())
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var paneBackgroundContextMenu: some View {
        Button {
            activatePane()
            appState.showNewFolderSheet = true
        } label: {
            Label("New Folder (⇧⌘N)…", systemImage: "folder.badge.plus")
        }

        Button {
            activatePane()
            appState.showNewFileSheet = true
        } label: {
            Label("New File (⌥⌘N)…", systemImage: "doc.badge.plus")
        }

        Divider()

        Button {
            fileOps.paste(into: pane.currentURL)
            pane.reloadDirectory()
        } label: {
            Label("Paste Here (⌘V)", systemImage: "doc.on.clipboard")
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
            Label("Refresh View", systemImage: "arrow.clockwise")
        }

        Divider()

        Button {
            performPaneAction { appState.showTerminalDrawer.toggle() }
        } label: {
            Label("Built-in Terminal Panel (Ctrl+`)", systemImage: "terminal.fill")
        }

        Button {
            fileOps.openInTerminal(at: pane.currentURL)
        } label: {
            Label("Open Current Folder in Terminal", systemImage: "terminal")
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
                    Text("Incomplete sorting: unknown and partial sizes are at the end of the group.")
                    if items.contains(where: { $0.isDirectory && folderSizes.status(for: $0.path) == .deferred }) {
                        Text("Active folder limit reached. Narrow the view or close other views.")
                        Button("Retry Sizes") { updateFolderSizeDemand() }
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
                            CloudStatusBadge(item: item, isSelected: isInTrail, selectionColor: selectionForegroundColor)
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
                        Text("No visible items")
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
            if cache.status(for: path) == .needsConsent {
                Button("Calculate") { cache.calculateProtected(path) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("macOS protects this folder, so its size is calculated only when you ask. macOS may ask for permission once. With Full Disk Access every size is calculated automatically.")
            } else if cache.status(for: path) == .deferred {
                Button("Deferred ↻") { request() }
                    .buttonStyle(.plain)
                    .help("Active folder limit reached. Narrow the view or close other views, then click to retry.")
            } else {
                Text(cache.statusText(for: path))
                    .help(cache.size(for: path) != nil
                        ? String(localized: "Full folder size")
                        : cache.protectedFoldersLeftOut(of: path).isEmpty
                            ? String(localized: "Queued, scanning, or a lower-bound estimate (limit / unread directories).")
                            : String(localized: "At least this much. Not counted: \(FolderSizeNames.list(cache.protectedFoldersLeftOut(of: path))). Select the folder to include them."))
            }
        }
        .onAppear { request() }
        .onChange(of: path) { _, _ in request() }
        .onChange(of: revision) { _, _ in request() }
        .onDisappear { cache.release(owner: owner) }
    }

    private func request() { cache.updateDemand(owner: owner, paths: [path], priority: .visible) }
}
