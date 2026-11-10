import SwiftUI
import AppKit

/// Search stays close to the content; navigation and view actions use the window toolbar.
public struct FSearchToolbarSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState
    @ObservedObject var fileOps = FileOperationsManager.shared
    @ObservedObject var folderSorts = FolderSortPreferences.shared

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    @ViewState private var isSearchPresented = false

    private var windowTitle: String {
        let query = activeTab.searchQuery.trimmingCharacters(in: .whitespaces)
        // The query is already in the field and the results header.
        return query.isEmpty ? activeTab.title : String(localized: "Search")
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !activeTab.activeFilterPills.isEmpty {
                activeFilters
                Divider()
            }
        }
        .background(.bar)
        // Observed here, so the title follows the query as it is typed.
        .navigationTitle(windowTitle)
        .sheet(isPresented: $appState.showFSearchHelpPopover) {
            VStack(spacing: 0) {
                FSearchSyntaxCheatsheetView(activeTab: activeTab)
                HStack {
                    Spacer()
                    Button("Done") { appState.showFSearchHelpPopover = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding([.horizontal, .bottom], 14)
            }
            // Trying an example closes the sheet to show its results.
            .onChange(of: activeTab.searchQuery) { _, _ in appState.showFSearchHelpPopover = false }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { activeTab.goBack() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(activeTab.historyBack.isEmpty)
                .help("Back (⌘[)")
                Button { activeTab.goForward() } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(activeTab.historyForward.isEmpty)
                .help("Forward (⌘])")
            }
            ToolbarItem {
                Picker("View", selection: Binding(
                    get: { activeTab.viewMode },
                    set: { activeTab.chooseViewMode($0) }
                )) {
                    ForEach(FinderViewMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.iconName).tag(mode)
                    }
                }
                .labelsHidden()
                .labelStyle(.iconOnly)
                .pickerStyle(.segmented)
                // Do not force four native segments into a 132 pt box. Their
                // intrinsic width follows the running macOS control metrics.
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, FinderUI.compactSpacing)
                .help("List ⌘1 · Icons ⌘2 · Columns ⌘3 · Disk Map ⌘4")
            }
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: Binding(
                        get: { activeTab.sortField },
                        set: { field in var sort = activeTab.currentSort; sort.field = field; activeTab.setSort(sort) }
                    )) {
                        ForEach(SortField.allCases) { field in
                            Text(field.displayName).tag(field)
                        }
                    }
                    Divider()
                    Toggle("Ascending", isOn: Binding(
                        get: { activeTab.sortAscending },
                        set: { value in var sort = activeTab.currentSort; sort.ascending = value; activeTab.setSort(sort) }
                    ))
                    Toggle("Folders on Top", isOn: Binding(
                        get: { activeTab.foldersOnTop },
                        set: { value in var sort = activeTab.currentSort; sort.foldersOnTop = value; activeTab.setSort(sort) }
                    ))
                    Divider()
                    Section(folderSorts.hasCustomSort(for: activeTab.currentURL)
                            ? String(localized: "This folder has its own sort order") : String(localized: "This folder uses the default sort order")) {
                        Button("Restore Default for This Folder") {
                            folderSorts.resetSort(for: activeTab.currentURL)
                        }
                        .disabled(!folderSorts.hasCustomSort(for: activeTab.currentURL))
                        Button("Set as Default for All Folders") {
                            folderSorts.setDefaultSort(activeTab.currentSort)
                            folderSorts.resetSort(for: activeTab.currentURL)
                        }
                        .disabled(activeTab.currentSort == folderSorts.defaultSort)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sorting and folder order")
            }
            ToolbarItem {
                Menu {
                    Button("New Folder…", systemImage: "folder.badge.plus") { appState.showNewFolderSheet = true }
                    Button("New File…", systemImage: "doc.badge.plus") { appState.showNewFileSheet = true }
                    Divider()
                    Button("Refresh", systemImage: "arrow.clockwise") { activeTab.refresh() }
                    Toggle("Show Hidden Files", isOn: Binding(
                        get: { activeTab.showHiddenFiles },
                        set: { value in
                            activeTab.showHiddenFiles = value
                            activeTab.refresh()
                        }
                    ))
                    Button("Add Folder to Favorites", systemImage: "star") {
                        appState.addBookmark(for: activeTab.currentURL)
                    }
                    Button("Share…", systemImage: "square.and.arrow.up") {
                        fileOps.showShareSheet(for: activeTab.selectedItems)
                    }
                    .disabled(activeTab.selectedItems.isEmpty)
                    Divider()
                    Button("Open in Finder", systemImage: "macwindow") {
                        AppleFinder.open(folder: activeTab.currentURL)
                    }
                    Toggle("Terminal", isOn: $appState.showTerminalDrawer)
                    if appState.isDualPane {
                        Divider()
                        Button("Copy Selection to Other Pane", systemImage: "doc.on.doc") {
                            let destination = appState.activePaneSide == .left ? appState.rightPane : appState.leftTab
                            fileOps.performTransfer(sourceURLs: activeTab.selectedItems.map(\.url), into: destination.currentURL, isMove: false)
                        }
                        .disabled(activeTab.selectedItems.isEmpty || fileOps.isBusy)
                        Button("Compare Folders…", systemImage: "arrow.left.arrow.right") { appState.showCompareSheet = true }
                        Divider()
                    }
                    Menu("Search Filters", systemImage: "line.3.horizontal.decrease.circle") { filterMenuItems }
                    Button("Quick Search…", systemImage: "magnifyingglass") {
                        appState.showQuickFSearchModal = true
                    }
                    Divider()
                    Button("Settings…", systemImage: "gearshape") { appState.showSettingsSheet = true }
                } label: {
                    Label("More Actions", systemImage: "ellipsis.circle")
                }
                .help("New folder, hidden files and other actions")
            }
            // A little air between "what to show" and "how the window is split".
            // ToolbarSpacer exists only in the macOS 26 SDK (Swift 6.2 toolchains).
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed)
            }
            #endif
            ToolbarItemGroup {
                // On reads as an accent-coloured glyph on the normal capsule:
                // visible, but quieter than a solid fill.
                Button { appState.toggleDualPane() } label: {
                    Label("Two Panes", systemImage: "rectangle.split.2x1")
                        .foregroundStyle(appState.isDualPane ? Color.accentColor : Color.primary)
                }
                .help("Two-pane view (⇧⌘D)")
                .accessibilityValue(appState.isDualPane ? String(localized: "On") : String(localized: "Off"))
                Button { appState.showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                        .foregroundStyle(appState.showInspector ? Color.accentColor : Color.primary)
                }
                .help("Show or hide the inspector (⌘I)")
                .accessibilityValue(appState.showInspector ? String(localized: "Visible") : String(localized: "Hidden"))
            }
        }
        // A native toolbar search field, as in Finder. Where to search is a
        // scope bar that appears only while searching.
        .searchable(text: $activeTab.searchQuery, isPresented: $isSearchPresented,
                    placement: .toolbar, prompt: Text("Search"))
        .searchScopes($activeTab.searchScope, activation: .onSearchPresentation) {
            ForEach(SearchScopeMode.allCases) { mode in
                Text(scopeLabel(mode)).tag(mode)
            }
        }
        .onChange(of: activeTab.searchQuery) { _, _ in activeTab.triggerSearch() }
        .onChange(of: activeTab.searchScope) { _, _ in activeTab.triggerSearch() }
        .onChange(of: activeTab.fuzzyEnabled) { _, _ in activeTab.triggerSearch() }
        .onChange(of: appState.focusSearchFieldTrigger) { _, _ in isSearchPresented = true }
    }

    @ViewBuilder
    private var filterMenuItems: some View {
        Section("File Kind") {
            filter("Folders", "folder", "type:dir")
            filter("Documents", "doc.text", "type:doc")
            filter("Images", "photo", "type:image")
            filter("Video", "film", "type:video")
            filter("Source Code", "chevron.left.forwardslash.chevron.right", "type:code")
            filter("Archives", "doc.zipper", "type:archive")
        }
        Section("Quick Filters") {
            filter("Larger Than 10 MB", "internaldrive", "size:>10mb")
            filter("Changed in the Last Week", "clock", "mtime:<7d")
            filter("Modified in Git", "point.3.connected.trianglepath.dotted", "git:modified")
        }
        Divider()
        Toggle("Tolerate Typos", isOn: $activeTab.fuzzyEnabled)
        Button("Search Syntax…", systemImage: "questionmark.circle") {
            appState.showFSearchHelpPopover = true
        }
    }

    private func filter(_ title: LocalizedStringKey, _ icon: String, _ token: String) -> some View {
        Button {
            activeTab.appendSearchOperator(token)
        } label: {
            Label(title, systemImage: ParsedFSearchQuery.containsOperator(token, in: activeTab.searchQuery, pills: activeTab.activeFilterPills) ? "checkmark" : icon)
        }
    }

    private var activeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Filters:").foregroundStyle(.secondary)
                ForEach(activeTab.activeFilterPills) { pill in
                    Button { activeTab.removeFilterPill(pill) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: pill.icon)
                            Text("\(pill.prefix):\(pill.value)")
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Remove filter \(pill.rawToken)")
                    .accessibilityLabel("Remove filter \(pill.rawToken)")
                }
            }
            .font(FinderUI.captionFont)
            .padding(.horizontal, 16)
            .padding(.bottom, 9)
        }
    }

    private func scopeLabel(_ scope: SearchScopeMode) -> String {
        switch scope {
        case .currentFolder: return String(localized: "This Folder")
        case .recursiveFolder: return String(localized: "With Subfolders")
        case .wholeIndex: return String(localized: "File Index")
        }
    }
}

public struct FSearchSyntaxCheatsheetView: View {
    @ObservedObject var activeTab: PaneTabState

    private let examples: [(String, String)] = [
        ("ext:swift,rs", String(localized: "Only files with the .swift or .rs extension")),
        ("type:code", String(localized: "File category (code, dir, file, image, video, audio, doc, archive)")),
        ("size:>5mb", String(localized: "File size (>5mb, <100kb, 1mb..50mb)")),
        ("mtime:<7d", String(localized: "Modified within 7 days (<24h, <30m, >30d)")),
        ("grep:getattrlistbulk", String(localized: "Content search using a trigram Bloom filter, with line previews")),
        ("git:modified", String(localized: "Files modified in the Git repository (modified, staged, untracked)")),
        ("tag:red", String(localized: "Files with a macOS color tag (red, orange, yellow, green, blue, purple, gray)")),
        ("regex:^Package.*\\.swift$", String(localized: "Regular expression on the file name")),
        ("in:Sources", String(localized: "Parent path contains 'Sources'")),
        ("^main", String(localized: "Name starts with 'main'")),
        (".json$", String(localized: "Name ends with '.json'")),
        ("!test", String(localized: "Exclude files containing 'test'")),
        ("fserach", String(localized: "Fuzzy + 1 typo for words of 5+ characters (finds 'fsearch')"))
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Search Syntax")
                    .font(FinderUI.titleFont)
                Spacer()
                Text("Click to try")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ForEach(examples, id: \.0) { code, desc in
                Button {
                    activeTab.searchScope = .wholeIndex
                    activeTab.searchQuery = code
                    activeTab.triggerSearch()
                } label: {
                    HStack(spacing: 10) {
                        Text(code)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                            .frame(width: 175, alignment: .leading)

                        Text(desc)
                            .font(FinderUI.detailFont)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 520)
    }
}
