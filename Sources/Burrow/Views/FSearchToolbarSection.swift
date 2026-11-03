import SwiftUI
import AppKit

/// Search stays close to the content; navigation and view actions use the window toolbar.
public struct FSearchToolbarSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState
    @ObservedObject var fileOps = FileOperationsManager.shared
    @ObservedObject var folderSorts = FolderSortPreferences.shared
    @FocusState private var isSearchFocused: Bool

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                searchField

                Menu {
                    Picker("Search Scope", selection: $activeTab.searchScope) {
                        ForEach(SearchScopeMode.allCases) { mode in
                            Label(scopeLabel(mode), systemImage: mode.iconName).tag(mode)
                        }
                    }
                    Divider()
                    Toggle("Tolerate Typos", isOn: $activeTab.fuzzyEnabled)
                } label: {
                    Label(scopeLabel(activeTab.searchScope), systemImage: activeTab.searchScope.iconName)
                        .font(FinderUI.detailFont)
                }
                .fixedSize()
                .help("Choose where to search for files")
                .onChange(of: activeTab.searchScope) { _, _ in activeTab.triggerSearch() }
                .onChange(of: activeTab.fuzzyEnabled) { _, _ in activeTab.triggerSearch() }

                filterMenu
            }
            .padding(.horizontal, FinderUI.panelInset)
            .padding(.vertical, FinderUI.chromeInset)

            if !activeTab.activeFilterPills.isEmpty {
                activeFilters
            }
            Divider()
        }
        .background(.bar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    appState.showSidebar.toggle()
                } label: {
                    Label("Sidebar", systemImage: "sidebar.left")
                }
                .help("Show or hide the sidebar (⌃⌘S)")
                .accessibilityValue(appState.showSidebar ? String(localized: "Visible") : String(localized: "Hidden"))
            }
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
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(systemName: activeTab.searchQuery.isEmpty ? "folder.fill" : "magnifyingglass")
                        .foregroundStyle(activeTab.searchQuery.isEmpty ? Color.accentColor : .secondary)
                    Text(activeTab.searchQuery.isEmpty ? activeTab.title : String(localized: "Search Results"))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Native toolbar containers gained larger rounded chrome on
                // newer macOS. Give the custom title breathing room inside it.
                .padding(.horizontal, FinderUI.chromeInset)
                .padding(.vertical, 6)
                .frame(maxWidth: 260)
                .help(activeTab.currentURL.path)
            }
            ToolbarItem {
                Picker("View", selection: $activeTab.viewMode) {
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
                Button {
                    fileOps.showShareSheet(for: activeTab.selectedItems)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(activeTab.selectedItems.isEmpty)
                .help("Share the selected files")
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
                    Divider()
                    Button("Open in Finder", systemImage: "macwindow") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: activeTab.currentURL.path)
                    }
                    Toggle("Terminal", isOn: $appState.showTerminalDrawer)
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
            ToolbarItemGroup {
                Button { appState.showTerminalDrawer.toggle() } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .tint(appState.showTerminalDrawer ? .accentColor : .secondary)
                .help("Show or hide the terminal (Ctrl+`)")
                .accessibilityValue(appState.showTerminalDrawer ? String(localized: "Visible") : String(localized: "Hidden"))
                Button { appState.toggleDualPane() } label: {
                    Label("Two Panes", systemImage: "rectangle.split.2x1")
                }
                .tint(appState.isDualPane ? .accentColor : .secondary)
                .help("Two-pane view (⇧⌘D)")
                .accessibilityValue(appState.isDualPane ? String(localized: "On") : String(localized: "Off"))
                Button { appState.showInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .tint(appState.showInspector ? .accentColor : .secondary)
                .help("Show or hide the inspector (⌘I)")
                .accessibilityValue(appState.showInspector ? String(localized: "Visible") : String(localized: "Hidden"))
            }
        }
        .onChange(of: appState.focusSearchFieldTrigger) { _, _ in isSearchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search files and folders", text: $activeTab.searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onChange(of: activeTab.searchQuery) { _, _ in activeTab.triggerSearch() }
                .onExitCommand {
                    activeTab.clearSearch()
                    isSearchFocused = false
                }
                .accessibilityLabel("Search files and folders")
            if activeTab.isSearching {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Searching files")
            } else if !activeTab.searchQuery.isEmpty {
                Button { activeTab.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 24, height: 24)
                }
                .help("Clear search (Esc)")
                .accessibilityLabel("Clear search")
            } else if !isSearchFocused {
                Text("⌘F").font(FinderUI.captionFont).foregroundStyle(.tertiary)
            }
        }
        .font(FinderUI.bodyFont)
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: FinderUI.chromeHeight)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(isSearchFocused ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSearchFocused ? 2 : 1)
        }
    }

    private var filterMenu: some View {
        Menu {
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
            Button("Search Syntax…", systemImage: "questionmark.circle") {
                appState.showFSearchHelpPopover = true
            }
        } label: {
            Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                .font(FinderUI.detailFont)
        }
        .fixedSize()
        .popover(isPresented: $appState.showFSearchHelpPopover) {
            FSearchSyntaxCheatsheetView(activeTab: activeTab)
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
