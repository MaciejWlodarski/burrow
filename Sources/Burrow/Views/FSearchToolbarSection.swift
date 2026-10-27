import SwiftUI
import AppKit

/// Search stays close to the content; navigation and view actions use the window toolbar.
public struct FSearchToolbarSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState
    @ObservedObject var fileOps = FileOperationsManager.shared
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
                    Picker("Zakres wyszukiwania", selection: $activeTab.searchScope) {
                        ForEach(SearchScopeMode.allCases) { mode in
                            Label(scopeLabel(mode), systemImage: mode.iconName).tag(mode)
                        }
                    }
                    Divider()
                    Toggle("Toleruj literówki", isOn: $activeTab.fuzzyEnabled)
                } label: {
                    Label(scopeLabel(activeTab.searchScope), systemImage: activeTab.searchScope.iconName)
                        .font(FinderUI.detailFont)
                }
                .fixedSize()
                .help("Wybierz, gdzie szukać plików")
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
                    Label("Pasek boczny", systemImage: "sidebar.left")
                }
                .help("Pokaż lub ukryj pasek boczny (⌃⌘S)")
                .accessibilityValue(appState.showSidebar ? "Widoczny" : "Ukryty")
            }
            ToolbarItemGroup(placement: .navigation) {
                Button { activeTab.goBack() } label: {
                    Label("Wstecz", systemImage: "chevron.left")
                }
                .disabled(activeTab.historyBack.isEmpty)
                .help("Wstecz (⌘[)")
                Button { activeTab.goForward() } label: {
                    Label("Dalej", systemImage: "chevron.right")
                }
                .disabled(activeTab.historyForward.isEmpty)
                .help("Dalej (⌘])")
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Image(systemName: activeTab.searchQuery.isEmpty ? "folder.fill" : "magnifyingglass")
                        .foregroundStyle(activeTab.searchQuery.isEmpty ? Color.accentColor : .secondary)
                    Text(activeTab.searchQuery.isEmpty ? activeTab.title : "Wyniki wyszukiwania")
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
                Picker("Widok", selection: $activeTab.viewMode) {
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
                .help("Lista ⌘1 · Ikony ⌘2 · Kolumny ⌘3 · Mapa dysku ⌘4")
            }
            ToolbarItem {
                Menu {
                    Picker("Sortuj według", selection: $activeTab.sortField) {
                        ForEach(SortField.allCases) { field in
                            Text(field.displayName).tag(field)
                        }
                    }
                    Divider()
                    Toggle("Rosnąco", isOn: $activeTab.sortAscending)
                    Toggle("Foldery na górze", isOn: $activeTab.foldersOnTop)
                } label: {
                    Label("Sortuj", systemImage: "arrow.up.arrow.down")
                }
                .onChange(of: activeTab.sortField) { _, _ in activeTab.applySortChange() }
                .onChange(of: activeTab.sortAscending) { _, _ in activeTab.applySortChange() }
                .onChange(of: activeTab.foldersOnTop) { _, _ in activeTab.applySortChange() }
                .help("Sortowanie i kolejność folderów")
            }
            ToolbarItem {
                Button {
                    fileOps.showShareSheet(for: activeTab.selectedItems)
                } label: {
                    Label("Udostępnij", systemImage: "square.and.arrow.up")
                }
                .disabled(activeTab.selectedItems.isEmpty)
                .help("Udostępnij zaznaczone pliki")
            }
            ToolbarItem {
                Menu {
                    Button("Nowy folder…", systemImage: "folder.badge.plus") { appState.showNewFolderSheet = true }
                    Button("Nowy plik…", systemImage: "doc.badge.plus") { appState.showNewFileSheet = true }
                    Divider()
                    Button("Odśwież", systemImage: "arrow.clockwise") { activeTab.refresh() }
                    Toggle("Pokaż ukryte pliki", isOn: Binding(
                        get: { activeTab.showHiddenFiles },
                        set: { value in
                            activeTab.showHiddenFiles = value
                            activeTab.refresh()
                        }
                    ))
                    Button("Dodaj folder do ulubionych", systemImage: "star") {
                        appState.addBookmark(for: activeTab.currentURL)
                    }
                    Divider()
                    Button("Otwórz w Finderze", systemImage: "macwindow") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: activeTab.currentURL.path)
                    }
                    Toggle("Terminal", isOn: $appState.showTerminalDrawer)
                    Button("Szybkie wyszukiwanie…", systemImage: "magnifyingglass") {
                        appState.showQuickFSearchModal = true
                    }
                    Divider()
                    Button("Ustawienia…", systemImage: "gearshape") { appState.showSettingsSheet = true }
                } label: {
                    Label("Więcej czynności", systemImage: "ellipsis.circle")
                }
                .help("Nowy folder, ukryte pliki i inne czynności")
            }
            ToolbarItemGroup {
                Button { appState.showTerminalDrawer.toggle() } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .tint(appState.showTerminalDrawer ? .accentColor : .secondary)
                .help("Pokaż lub ukryj terminal (Ctrl+`)")
                .accessibilityValue(appState.showTerminalDrawer ? "Widoczny" : "Ukryty")
                Button { appState.toggleDualPane() } label: {
                    Label("Dwa panele", systemImage: "rectangle.split.2x1")
                }
                .tint(appState.isDualPane ? .accentColor : .secondary)
                .help("Widok dwupanelowy (⇧⌘D)")
                .accessibilityValue(appState.isDualPane ? "Włączony" : "Wyłączony")
                Button { appState.showInspector.toggle() } label: {
                    Label("Inspektor", systemImage: "sidebar.right")
                }
                .tint(appState.showInspector ? .accentColor : .secondary)
                .help("Pokaż lub ukryj inspektor (⌘I)")
                .accessibilityValue(appState.showInspector ? "Widoczny" : "Ukryty")
            }
        }
        .onChange(of: appState.focusSearchFieldTrigger) { _, _ in isSearchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Szukaj plików i folderów", text: $activeTab.searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onChange(of: activeTab.searchQuery) { _, _ in activeTab.triggerSearch() }
                .onExitCommand {
                    activeTab.clearSearch()
                    isSearchFocused = false
                }
                .accessibilityLabel("Szukaj plików i folderów")
            if activeTab.isSearching || activeTab.isActivatingSavedSearch {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(activeTab.isActivatingSavedSearch ? "Otwieranie zapisanego wyszukiwania" : "Wyszukiwanie plików")
            } else if !activeTab.searchQuery.isEmpty {
                Button { activeTab.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 24, height: 24)
                }
                .help("Wyczyść wyszukiwanie (Esc)")
                .accessibilityLabel("Wyczyść wyszukiwanie")
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
            Section("Rodzaj pliku") {
                filter("Foldery", "folder", "type:dir")
                filter("Dokumenty", "doc.text", "type:doc")
                filter("Obrazy", "photo", "type:image")
                filter("Wideo", "film", "type:video")
                filter("Kod źródłowy", "chevron.left.forwardslash.chevron.right", "type:code")
                filter("Archiwa", "doc.zipper", "type:archive")
            }
            Section("Szybkie filtry") {
                filter("Większe niż 10 MB", "internaldrive", "size:>10mb")
                filter("Zmienione w ostatnim tygodniu", "clock", "mtime:<7d")
                filter("Zmodyfikowane w Git", "point.3.connected.trianglepath.dotted", "git:modified")
            }
            Divider()
            Button("Składnia wyszukiwania…", systemImage: "questionmark.circle") {
                appState.showFSearchHelpPopover = true
            }
        } label: {
            Label("Filtry", systemImage: "line.3.horizontal.decrease.circle")
                .font(FinderUI.detailFont)
        }
        .fixedSize()
        .popover(isPresented: $appState.showFSearchHelpPopover) {
            FSearchSyntaxCheatsheetView(activeTab: activeTab)
        }
    }

    private func filter(_ title: String, _ icon: String, _ token: String) -> some View {
        Button {
            activeTab.appendSearchOperator(token)
        } label: {
            Label(title, systemImage: ParsedFSearchQuery.containsOperator(token, in: activeTab.searchQuery, pills: activeTab.activeFilterPills) ? "checkmark" : icon)
        }
    }

    private var activeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Filtry:").foregroundStyle(.secondary)
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
                    .help("Usuń filtr \(pill.rawToken)")
                    .accessibilityLabel("Usuń filtr \(pill.rawToken)")
                }
            }
            .font(FinderUI.captionFont)
            .padding(.horizontal, 16)
            .padding(.bottom, 9)
        }
    }

    private func scopeLabel(_ scope: SearchScopeMode) -> String {
        switch scope {
        case .currentFolder: return "Ten folder"
        case .recursiveFolder: return "Z podfolderami"
        case .wholeIndex: return "Indeks plików"
        }
    }
}

public struct FSearchSyntaxCheatsheetView: View {
    @ObservedObject var activeTab: PaneTabState

    private let examples: [(String, String)] = [
        ("ext:swift,rs", "Tylko pliki z rozszerzeniem .swift lub .rs"),
        ("type:code", "Kategoria pliku (code, dir, file, image, video, audio, doc, archive)"),
        ("size:>5mb", "Rozmiar pliku (>5mb, <100kb, 1mb..50mb)"),
        ("mtime:<7d", "Zmodyfikowane w ciągu 7 dni (<24h, <30m, >30d)"),
        ("grep:getattrlistbulk", "Przeszukiwanie treści z filtrem Blooma trigramów i podglądem linii"),
        ("git:modified", "Pliki zmodyfikowane w repozytorium Git (modified, staged, untracked)"),
        ("tag:red", "Pliki z kolorowym tagiem macOS (red, orange, yellow, green, blue, purple, gray)"),
        ("regex:^Package.*\\.swift$", "Wyrażenie regularne na nazwie pliku"),
        ("in:Sources", "Ścieżka nadrzędna zawiera 'Sources'"),
        ("^main", "Nazwa zaczyna się od 'main'"),
        (".json$", "Nazwa kończy się na '.json'"),
        ("!test", "Wyklucz pliki zawierające 'test'"),
        ("fserach", "Fuzzy + 1-literówka dla słów 5+ znaków (znajdzie 'fsearch')")
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Składnia wyszukiwania")
                    .font(FinderUI.titleFont)
                Spacer()
                Text("Kliknij, aby wypróbować")
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
