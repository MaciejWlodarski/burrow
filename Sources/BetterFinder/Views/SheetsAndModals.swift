import SwiftUI
import AppKit
import Darwin

struct QuickSearchRequest: Sendable {
    let query: String
    let rootPath: String
    let includeHidden: Bool
    let token: AnalysisRequestToken
}

@MainActor
final class QuickSearchModel: ObservableObject {
    @Published private(set) var results: [FileItem] = []
    @Published private(set) var elapsedMs: Double = 0
    @Published private(set) var isSearching = false
    @Published private(set) var diagnostic: String?
    private var task: Task<Void, Never>?
    private var token: AnalysisRequestToken?
    private let provider: @Sendable (QuickSearchRequest) -> FSearchResultBundle

    init(provider: @escaping @Sendable (QuickSearchRequest) -> FSearchResultBundle = { request in
        FSearchIndex.shared.search(rawQuery: request.query, scope: .wholeIndex,
            scopeDirectory: request.rootPath, includeHidden: request.includeHidden, fuzzyEnabled: true,
            isCancelled: { request.token.isCancelled })
    }) { self.provider = provider }

    func cancel() {
        token?.cancel()
        task?.cancel()
        token = nil
        isSearching = false
    }

    func schedule(_ query: String, rootPath: String, includeHidden: Bool, debounceNanoseconds: UInt64 = 180_000_000) {
        cancel()
        results = []
        elapsedMs = 0
        diagnostic = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = AnalysisRequestToken(rootPath: rootPath)
        token = current
        isSearching = true
        let request = QuickSearchRequest(query: trimmed, rootPath: rootPath, includeHidden: includeHidden, token: current)
        let provider = self.provider
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do { try await Task.sleep(nanoseconds: debounceNanoseconds) } catch { return }
            guard !current.isCancelled else { return }
            let bundle = provider(request)
            guard !current.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, current.canPublish(active: self.token, rootPath: rootPath) else { return }
                self.results = bundle.items
                self.elapsedMs = bundle.elapsedMilliseconds
                self.diagnostic = bundle.diagnostic ?? (bundle.isPartial ? "Wyniki częściowe." : nil)
                self.isSearching = false
            }
        }
    }
}

// MARK: - 1. Instant Cmd+P Spotlight fsearch Modal

/// Pure selection movement shared by the quick-search keyboard callbacks and tests.
enum QuickSearchSelection {
    enum Direction { case up, down }
    static let visibleResultLimit = 100

    static func movedIndex(from index: Int, count: Int, direction: Direction) -> Int? {
        guard count > 0 else { return nil }
        let lastIndex = count - 1
        switch direction {
        case .up:
            return index <= 0 ? 0 : min(index - 1, lastIndex)
        case .down:
            return index >= lastIndex ? lastIndex : max(index + 1, 0)
        }
    }
}

@MainActor
public struct QuickFSearchSpotlightModal: View {
    @ObservedObject private var iconCache = FileIconCache.shared
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState

    @ViewState private var queryText: String = ""
    @StateObject private var search = QuickSearchModel()
    private var results: [FileItem] { search.results }
    private var elapsedMs: Double { search.elapsedMs }
    private var hasQuery: Bool { !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @ViewState private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)

                TextField("Szukaj w indeksie plików…", text: $queryText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .accessibilityLabel("Szybkie wyszukiwanie w indeksie plików")
                    .help("Wpisz nazwę lub filtr, np. ext:swift, grep:tekst, size:>10mb, tag:red")
                    .focused($isFocused)
                    .onChange(of: queryText) { _, newValue in
                        runSpotlightQuery(newValue)
                    }
                    .onSubmit {
                        activateSelectedResult(revealInFolder: false)
                    }
                    .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                        guard press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty else {
                            return .ignored
                        }
                        return moveSelection(press.key == .upArrow ? .up : .down)
                    }

                if search.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Wyszukiwanie")
                } else if hasQuery {
                    HStack(spacing: FinderUI.compactSpacing) {
                        Image(systemName: "bolt.fill")
                            .accessibilityHidden(true)
                        Text(FormatHelpers.formatLatency(elapsedMs))
                            .monospacedDigit()
                    }
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                }

                Button("Zamknij") {
                    appState.showQuickFSearchModal = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            }
            .padding(FinderUI.sectionSpacing)
            .background(VisualEffectBackground(material: .headerView, blendingMode: .withinWindow))

            Divider()

            if results.isEmpty {
                VStack(spacing: FinderUI.rowSpacing) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(search.isSearching ? "Wyszukiwanie…" : (!hasQuery
                         ? "Wpisz zapytanie, aby przeszukać indeks. Pliki: \(appState.indexedFileCount.formatted())"
                         : (search.diagnostic == nil ? "Brak pasujących wyników" : "Brak wyników w sprawdzonym zakresie")))
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: FinderUI.rowSpacing) {
                        quickSampleButton("ext:swift")
                        quickSampleButton("type:code grep:struct")
                        quickSampleButton("git:modified")
                        quickSampleButton("mtime:<24h")
                    }
                    .padding(.top, FinderUI.compactSpacing)
                }
                .padding(FinderUI.sheetPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.prefix(QuickSearchSelection.visibleResultLimit).enumerated()), id: \.element.id) { idx, item in
                                let isHighlighted = (idx == selectedIndex)
                                HStack(spacing: 10) {
                                    Image(nsImage: iconCache.icon(for: item))
                                        .resizable()
                                        .frame(width: 24, height: 24)
                                        .accessibilityHidden(true)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.name)
                                                .font(FinderUI.bodyFont.weight(.medium))
                                                .foregroundStyle(isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .help(item.name)
                                            if !item.tags.isEmpty {
                                                ForEach(item.tags) { tag in
                                                    Circle().fill(tag.swiftUIColor).frame(width: 7, height: 7)
                                                        .accessibilityLabel("Tag: \(tag.displayName)")
                                                }
                                            }
                                            Text(FormatHelpers.formatBytes(item.size))
                                                .font(FinderUI.captionFont.monospacedDigit())
                                                .foregroundStyle(isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                                        }
                                        Text(item.parentPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                            .font(FinderUI.captionFont)
                                            .foregroundStyle(isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .help(item.parentPath)

                                        if let grep = item.grepMatch {
                                            Text("L\(grep.lineNumber): \(grep.lineText)")
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : Color.accentColor)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()

                                    Button("Pokaż w karcie") {
                                        selectedIndex = idx
                                        activateSelectedResult(revealInFolder: true)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Pokaż \(item.name) w karcie")
                                    .help("Pokaż w karcie: \(item.path)")
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: FinderUI.cornerRadius)
                                        .fill(isHighlighted ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
                                )
                                .contentShape(Rectangle())
                                .accessibilityElement(children: .contain)
                                .accessibilityAddTraits(isHighlighted ? .isSelected : [])
                                .onTapGesture(count: 2) {
                                    selectedIndex = idx
                                    activateSelectedResult(revealInFolder: false)
                                }
                                .onTapGesture(count: 1) {
                                    selectedIndex = idx
                                    isFocused = true
                                }
                                .id(idx)
                            }
                        }
                        .padding(FinderUI.rowSpacing)
                    }
                    .onChange(of: selectedIndex) { _, index in
                        proxy.scrollTo(index)
                    }
                }
            }

            Divider()

            HStack {
                Text(search.diagnostic ?? "↑↓ wybór · Return lub dwuklik: przejdź · Esc: zamknij")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("W indeksie: \(appState.indexedFileCount.formatted())")
                    .font(FinderUI.captionFont.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, FinderUI.sectionSpacing)
            .padding(.vertical, FinderUI.rowSpacing)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 680, height: 440)
        .onAppear { isFocused = true }
        .onDisappear { search.cancel() }
        .onChange(of: activeTab.currentURL.path) { _, _ in runSpotlightQuery(queryText) }
        .onChange(of: activeTab.showHiddenFiles) { _, _ in runSpotlightQuery(queryText) }
    }

    private func quickSampleButton(_ sample: String) -> some View {
        Button(sample) {
            queryText = sample
            isFocused = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func runSpotlightQuery(_ q: String) {
        selectedIndex = 0
        search.schedule(q, rootPath: activeTab.currentURL.path, includeHidden: activeTab.showHiddenFiles)
    }

    private func moveSelection(_ direction: QuickSearchSelection.Direction) -> KeyPress.Result {
        guard isFocused, !search.isSearching,
              let index = QuickSearchSelection.movedIndex(
                from: selectedIndex,
                count: min(results.count, QuickSearchSelection.visibleResultLimit),
                direction: direction
              ) else { return .ignored }
        selectedIndex = index
        return .handled
    }

    private func activateSelectedResult(revealInFolder: Bool) {
        guard selectedIndex >= 0 && selectedIndex < results.count else { return }
        let chosen = results[selectedIndex]
        appState.showQuickFSearchModal = false
        if chosen.isDirectory && !revealInFolder {
            activeTab.navigate(to: chosen.url, clearSearch: true)
        } else {
            let parentURL = URL(fileURLWithPath: chosen.parentPath, isDirectory: true)
            if activeTab.navigate(to: parentURL, clearSearch: true) {
                activeTab.selectedPaths = [chosen.path]
            }
        }
    }
}

// MARK: - 2. New File Sheet

public struct NewFileSheetView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState

    @ViewState private var selectedTemplate: NewFileTemplate = .emptyText
    @ViewState private var filename: String = "Untitled.txt"
    @ViewState private var customContent: String = ""
    @ViewState private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: FinderUI.sectionSpacing) {
            HStack {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Utwórz nowy plik")
                    .font(FinderUI.titleFont)
                Spacer()
            }

            Picker("Szablon pliku", selection: $selectedTemplate) {
                ForEach(NewFileTemplate.allCases) { tpl in
                    Text(tpl.rawValue).tag(tpl)
                }
            }
            .onChange(of: selectedTemplate) { _, newValue in
                filename = newValue.defaultFilename
                customContent = newValue.initialContent
            }

            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text("Nazwa pliku")
                    .font(FinderUI.detailFont)
                TextField("Nazwa pliku", text: $filename)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(createAndClose)
                    .onChange(of: filename) { _, _ in errorMessage = nil }
            }

            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text("Początkowa zawartość (opcjonalnie)")
                    .font(FinderUI.detailFont)
                TextEditor(text: $customContent)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Początkowa zawartość pliku")
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: FinderUI.cornerRadius).stroke(Color(nsColor: .separatorColor)))
            }

            Text("Lokalizacja: \(activeTab.currentURL.path)")
                .font(FinderUI.captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(activeTab.currentURL.path)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(FinderUI.detailFont)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Anuluj") {
                    appState.showNewFileSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Utwórz plik", action: createAndClose)
                    .keyboardShortcut(.defaultAction)
                    .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(FinderUI.bodyFont)
        .controlSize(.regular)
        .padding(FinderUI.sheetPadding)
        .frame(width: 480)
        .onAppear { isNameFocused = true }
    }

    private func createAndClose() {
        guard !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let created = FileOperationsManager.shared.createFile(
            named: filename,
            content: customContent,
            in: activeTab.currentURL
        ) {
            activeTab.reloadDirectory()
            activeTab.selectedPaths = [created.path]
            appState.showNewFileSheet = false
        } else {
            errorMessage = FileOperationsManager.shared.lastStatusMessage ?? "Nie udało się utworzyć pliku."
            isNameFocused = true
        }
    }
}

// MARK: - 3. New Folder Sheet

public struct NewFolderSheetView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState

    @ViewState private var folderName: String = "Nowy folder"
    @ViewState private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: FinderUI.sectionSpacing) {
            HStack {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Utwórz nowy folder")
                    .font(FinderUI.titleFont)
                Spacer()
            }

            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text("Nazwa folderu")
                    .font(FinderUI.detailFont)
                TextField("Nazwa folderu", text: $folderName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(createAndClose)
                    .onChange(of: folderName) { _, _ in errorMessage = nil }
            }

            Text("Lokalizacja: \(activeTab.currentURL.path)")
                .font(FinderUI.captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(activeTab.currentURL.path)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(FinderUI.detailFont)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Anuluj") {
                    appState.showNewFolderSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Utwórz") {
                    createAndClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(FinderUI.bodyFont)
        .controlSize(.regular)
        .padding(FinderUI.sheetPadding)
        .frame(width: 420)
        .onAppear { isNameFocused = true }
    }

    private func createAndClose() {
        guard !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let created = FileOperationsManager.shared.createFolder(named: folderName, in: activeTab.currentURL) {
            activeTab.reloadDirectory()
            activeTab.selectedPaths = [created.path]
            appState.showNewFolderSheet = false
        } else {
            errorMessage = FileOperationsManager.shared.lastStatusMessage ?? "Nie udało się utworzyć folderu."
            isNameFocused = true
        }
    }
}

// MARK: - 4. Dual-Pane Folder Compare & Sync Sheet

public struct FolderCompareEntry: Identifiable, Sendable {
    public enum Status: String, Sendable {
        case onlyLeft = "Tylko w lewym"
        case onlyRight = "Tylko w prawym"
        case modified = "Różna treść lub czas"
        case identical = "Zgodna treść i czas"
        case notCompared = "Podfolder: nieporównany"
        case typeConflict = "Różny typ: sprawdź ręcznie"
        case unreadable = "Nieodczytany / zmieniony"
    }
    public var id: String { name }
    public let name: String
    public let leftItem: FileItem?
    public let rightItem: FileItem?
    public let status: Status
}

/// Deliberately shallow comparison: common directories are UNKNOWN, never identical.
/// This UI copies selected top-level items; it is not a recursive mirror/synchronizer.
enum FolderComparison {
    // Combined retained listing budget, not a per-side allowance. Maps and rows are
    // bounded by this same input count. Exactly-at-budget listings remain complete.
    static let retainedEntryLimit = 60_000

    private struct LinkSnapshot: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(at url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw DuplicateSafetyError.unreadable }
            guard (info.st_mode & S_IFMT) == S_IFLNK else { throw DuplicateSafetyError.changed }
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    static func compare(
        left: URL, right: URL, includeHidden: Bool, token: AnalysisRequestToken,
        maxRetainedEntries: Int = retainedEntryLimit,
        betweenSides: (URL, URL) throws -> Void = { _, _ in }
    ) -> (entries: [FolderCompareEntry], diagnostic: String?) {
        let budget = max(0, maxRetainedEntries)
        let leftRead = BulkCrawler.readDirectoryResult(at: left.path, includeHidden: includeHidden,
            maxEntries: budget, isCancelled: { token.isCancelled })
        guard leftRead.isComplete else {
            return ([], "Porównanie niepełne: błąd odczytu lub limit \(budget) elementów. Kopiowanie wyłączone.")
        }
        let rightRead = BulkCrawler.readDirectoryResult(at: right.path, includeHidden: includeHidden,
            maxEntries: budget - leftRead.entries.count, isCancelled: { token.isCancelled })
        guard leftRead.isComplete && rightRead.isComplete else {
            return ([], "Porównanie niepełne: błąd odczytu lub limit \(budget) elementów. Kopiowanie wyłączone.")
        }
        let leftMap = Dictionary(uniqueKeysWithValues: leftRead.entries.map { ($0.name, $0.toFileItem(loadTags: false)) })
        let rightMap = Dictionary(uniqueKeysWithValues: rightRead.entries.map { ($0.name, $0.toFileItem(loadTags: false)) })
        var entries: [FolderCompareEntry] = []
        for name in Set(leftMap.keys).union(rightMap.keys).sorted() {
            if token.isCancelled { return ([], nil) }
            let l = leftMap[name], r = rightMap[name]
            let status: FolderCompareEntry.Status
            if l == nil { status = .onlyRight }
            else if r == nil { status = .onlyLeft }
            else if let l, let r {
                if l.isDirectory != r.isDirectory || l.isSymlink != r.isSymlink { status = .typeConflict }
                else if l.isDirectory { status = .notCompared }
                else {
                    do {
                        if l.isSymlink {
                            let leftSnapshot = try LinkSnapshot(at: l.url)
                            let rightSnapshot = try LinkSnapshot(at: r.url)
                            let leftTarget = try FileManager.default.destinationOfSymbolicLink(atPath: l.path)
                            try betweenSides(l.url, r.url)
                            if token.isCancelled { throw DuplicateSafetyError.cancelled }
                            let rightTarget = try FileManager.default.destinationOfSymbolicLink(atPath: r.path)
                            guard try LinkSnapshot(at: l.url) == leftSnapshot,
                                  try LinkSnapshot(at: r.url) == rightSnapshot else { throw DuplicateSafetyError.changed }
                            status = leftTarget == rightTarget
                                && leftSnapshot.modifiedSeconds == rightSnapshot.modifiedSeconds
                                && leftSnapshot.modifiedNanoseconds == rightSnapshot.modifiedNanoseconds ? .identical : .modified
                        } else {
                            let lh = try DuplicateFileSafety.hash(at: l.url, isCancelled: { token.isCancelled })
                            try betweenSides(l.url, r.url)
                            let rh = try DuplicateFileSafety.hash(at: r.url, isCancelled: { token.isCancelled })
                            // Recheck the pair after BOTH reads, closing the left-side
                            // stale-hash window. This is not an atomic filesystem snapshot.
                            guard try DuplicateFileSafety.snapshot(at: l.url) == lh.snapshot,
                                  try DuplicateFileSafety.snapshot(at: r.url) == rh.snapshot else { throw DuplicateSafetyError.changed }
                            status = lh.hash == rh.hash && lh.snapshot.size == rh.snapshot.size
                                && lh.snapshot.modifiedSeconds == rh.snapshot.modifiedSeconds
                                && lh.snapshot.modifiedNanoseconds == rh.snapshot.modifiedNanoseconds ? .identical : .modified
                        }
                    } catch { status = .unreadable }
                }
            } else { status = .unreadable }
            entries.append(FolderCompareEntry(name: name, leftItem: l, rightItem: r, status: status))
        }
        return (entries, nil)
    }

    static func copyCandidates(_ entries: [FolderCompareEntry], leftToRight: Bool) -> [URL] {
        entries.compactMap { entry in
            guard entry.status == .modified || entry.status == (leftToRight ? .onlyLeft : .onlyRight) else { return nil }
            return leftToRight ? entry.leftItem?.url : entry.rightItem?.url
        }
    }
}

/// Both nested pane objects must be observed directly. AppState does not forward
/// their objectWillChange, and a same-path refresh is a new comparison generation.
struct FolderComparisonContext: Equatable, Sendable {
    let leftID: UUID
    let rightID: UUID
    let leftPath: String
    let rightPath: String
    let leftRevision: UInt64
    let rightRevision: UInt64
    let leftHidden: Bool
    let rightHidden: Bool

    @MainActor init(left: PaneTabState, right: PaneTabState) {
        leftID = left.id
        rightID = right.id
        leftPath = left.currentURL.path
        rightPath = right.currentURL.path
        leftRevision = left.directoryRevision
        rightRevision = right.directoryRevision
        leftHidden = left.showHiddenFiles
        rightHidden = right.showHiddenFiles
    }
}

public struct FolderCompareSheetView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) { self.appState = appState }

    public var body: some View {
        FolderComparisonContentView(appState: appState, leftPane: appState.leftTab, rightPane: appState.rightPane)
            .id(appState.leftTab.id.uuidString + appState.rightPane.id.uuidString)
    }
}

private struct FolderComparisonContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var leftPane: PaneTabState
    @ObservedObject var rightPane: PaneTabState
    @ObservedObject var fileOps = FileOperationsManager.shared

    @ViewState private var entries: [FolderCompareEntry] = []
    @ViewState private var hideIdentical: Bool = true
    @ViewState private var compareTask: AnalysisWorkRequest?
    @ViewState private var compareWorkState: AnalysisWorkRequest.State = .finished
    @ViewState private var compareToken: AnalysisRequestToken?
    @ViewState private var isComparing = false
    @ViewState private var compareDiagnostic: String?
    @ViewState private var comparedContext: FolderComparisonContext?
    @ViewState private var ownedConflictID: UUID?

    init(appState: AppState, leftPane: PaneTabState, rightPane: PaneTabState) {
        self.appState = appState
        self.leftPane = leftPane
        self.rightPane = rightPane
    }

    private var comparisonContext: FolderComparisonContext {
        FolderComparisonContext(left: leftPane, right: rightPane)
    }

    private var filteredEntries: [FolderCompareEntry] {
        hideIdentical ? entries.filter { $0.status != .identical } : entries
    }

    private var ownedConflict: Binding<PendingTransferConflict?> {
        Binding(
            get: {
                guard let id = ownedConflictID, fileOps.pendingConflict?.id == id else { return nil }
                return fileOps.pendingConflict
            },
            set: { value in
                // Policy selection clears pendingConflict before continuing with
                // the same request ID. Its sheet dismissal must not cancel that
                // accepted continuation; closing this comparison still does.
                if value == nil, fileOps.pendingConflict?.id == ownedConflictID {
                    cancelOwnedConflict()
                }
            }
        )
    }

    public var body: some View {
        let leftURL = leftPane.currentURL
        let rightURL = rightPane.currentURL

        VStack(alignment: .leading, spacing: FinderUI.sectionSpacing) {
            HStack {
                Image(systemName: "arrow.left.arrow.right.square.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Porównaj zawartość katalogów")
                    .font(FinderUI.titleFont)
                Spacer()
                Toggle("Ukryj identyczne", isOn: $hideIdentical)
                    .font(FinderUI.detailFont)
                    .fixedSize()
            }

            HStack(spacing: 12) {
                Label("Lewy: \(leftURL.path)", systemImage: "folder.fill")
                    .font(FinderUI.detailFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(leftURL.path)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label("Prawy: \(rightURL.path)", systemImage: "folder.fill")
                    .font(FinderUI.detailFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rightURL.path)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)

            Divider()

            Text(compareDiagnostic ?? (isComparing ? (compareWorkState == .queued ? "Porównanie w kolejce…" : "Porównywanie treści plików…") : "Porównanie treści i czasu plików, bez rekurencji. Wspólne podfoldery i konflikty typów wymagają osobnego porównania. Kopiowanie nie usuwa pozycji docelowych."))
                .font(FinderUI.detailFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filteredEntries) { entry in
                        HStack(spacing: 10) {
                            Text(entry.leftItem?.name ?? "—")
                                .font(FinderUI.detailFont)
                                .foregroundStyle(entry.leftItem == nil ? .tertiary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry.leftItem?.path ?? "Brak w lewym katalogu")
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(entry.status.rawValue)
                                .font(FinderUI.captionFont.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(statusColor(entry.status).opacity(0.16), in: Capsule())
                                .foregroundStyle(statusColor(entry.status))

                            Text(entry.rightItem?.name ?? "—")
                                .font(FinderUI.detailFont)
                                .foregroundStyle(entry.rightItem == nil ? .tertiary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry.rightItem?.path ?? "Brak w prawym katalogu")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))
                    }
                }
            }
            .frame(height: 230)
            .overlay {
                if isComparing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Porównywanie katalogów")
                } else if compareDiagnostic == nil && filteredEntries.isEmpty {
                    Text(entries.isEmpty ? "Brak elementów do porównania" : "Brak różnic w porównanych plikach")
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if isComparing {
                    Button("Anuluj porównanie") {
                        compareToken?.cancel()
                        compareTask?.cancel()
                        isComparing = false
                        comparedContext = nil
                        compareDiagnostic = "Anulowano. Trwający odczyt systemowy może jeszcze kończyć pracę."
                    }
                } else if compareDiagnostic != nil {
                    Button("Ponów porównanie") { computeDiff() }
                }
                Spacer()
            }
            HStack {
                Text("Kopiuj różnice:")
                    .font(FinderUI.detailFont)
                Button("Lewy → Prawy") { copyDifferences(leftToRight: true) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Kopiuj różnice z lewego katalogu do prawego")
                    .help("Kopiuj różniące się elementy z lewego katalogu do prawego. Istniejące pliki wymagają rozstrzygnięcia konfliktu.")
                    .disabled(isComparing || compareDiagnostic != nil || comparedContext != comparisonContext || fileOps.isBusy || FolderComparison.copyCandidates(entries, leftToRight: true).isEmpty)
                Button("Prawy → Lewy") { copyDifferences(leftToRight: false) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Kopiuj różnice z prawego katalogu do lewego")
                    .help("Kopiuj różniące się elementy z prawego katalogu do lewego. Istniejące pliki wymagają rozstrzygnięcia konfliktu.")
                    .disabled(isComparing || compareDiagnostic != nil || comparedContext != comparisonContext || fileOps.isBusy || FolderComparison.copyCandidates(entries, leftToRight: false).isEmpty)

                Spacer()

                Button("Zamknij") {
                    cancelOwnedConflict()
                    appState.showCompareSheet = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .font(FinderUI.bodyFont)
        .controlSize(.regular)
        .padding(FinderUI.sheetPadding)
        .frame(width: 740)
        .onAppear { computeDiff() }
        .onChange(of: comparisonContext) { _, _ in computeDiff() }
        .onDisappear {
            cancelOwnedConflict()
            compareToken?.cancel()
            compareTask?.cancel()
        }
        .sheet(item: ownedConflict) { ConflictResolutionSheetView(conflict: $0) }
    }

    private func statusColor(_ status: FolderCompareEntry.Status) -> Color {
        switch status {
        case .onlyLeft: return .blue
        case .onlyRight: return .purple
        case .modified: return .orange
        case .identical: return .green
        case .notCompared: return .secondary
        case .typeConflict, .unreadable: return .red
        }
    }

    private func computeDiff() {
        cancelOwnedConflict()
        // Coalesce in place rather than removing/rejoining the FIFO on refresh.
        compareToken?.cancel()
        let context = comparisonContext
        let left = leftPane.currentURL
        let right = rightPane.currentURL
        let includeHidden = context.leftHidden || context.rightHidden
        let token = AnalysisRequestToken(rootPath: left.path)
        compareToken = token
        entries = []
        compareDiagnostic = nil
        comparedContext = nil
        isComparing = true
        let input = AnalysisComparisonInput(left: left, right: right, includeHidden: includeHidden)
        compareTask = AnalysisWorkAdapters.startComparison(input, token: token, service: .shared,
            stateChanged: { state in
                guard self.compareToken === token, context == self.comparisonContext else { return }
                self.compareWorkState = state
                if state == .deferred {
                    token.cancel()
                    self.isComparing = false
                    self.compareDiagnostic = "Odroczono: analiza jest zajęta. Ponów porównanie. Kopiowanie wyłączone."
                } else if state == .cancelled {
                    self.isComparing = false
                    self.comparedContext = nil
                    self.compareDiagnostic = "Anulowano porównanie. Kopiowanie wyłączone."
                }
            }, completion: { result in
                guard token.canPublish(active: self.compareToken, rootPath: self.leftPane.currentURL.path),
                      context == self.comparisonContext else { return }
                self.entries = result.entries
                self.compareDiagnostic = result.diagnostic
                self.comparedContext = context
                self.isComparing = false
            })
    }

    private func copyDifferences(leftToRight: Bool) {
        guard !isComparing, !fileOps.isBusy, compareDiagnostic == nil, comparedContext == comparisonContext,
              fileOps.pendingConflict == nil,
              let token = compareToken, token.canPublish(active: compareToken, rootPath: leftPane.currentURL.path) else { return }
        let candidates = FolderComparison.copyCandidates(entries, leftToRight: leftToRight)
        let destination = leftToRight ? rightPane.currentURL : leftPane.currentURL
        ownedConflictID = fileOps.performTransfer(sourceURLs: candidates, into: destination, isMove: false, explicitPolicy: .ask) { _ in
            guard token.canPublish(active: self.compareToken, rootPath: self.leftPane.currentURL.path) else { return }
            self.leftPane.reloadDirectory()
            self.rightPane.reloadDirectory()
            self.computeDiff()
        }
        // Retain ownership before asynchronous filesystem preflight can publish.
    }

    private func cancelOwnedConflict() {
        if let id = ownedConflictID { fileOps.cancelPendingTransferRequest(id) }
        ownedConflictID = nil
    }

}

// MARK: - 5. File Conflict Resolution Sheet

public struct ConflictResolutionSheetView: View {
    public let conflict: PendingTransferConflict
    @ObservedObject var fileOps = FileOperationsManager.shared

    public init(conflict: PendingTransferConflict) {
        self.conflict = conflict
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: FinderUI.sectionSpacing) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                    Text("Wykryto konflikt nazw plików (\(conflict.conflictingNames.count))")
                        .font(FinderUI.titleFont)
                    Text("W folderze docelowym '\(conflict.destinationDirectory.lastPathComponent)' istnieją już pliki o tych samych nazwach:")
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(conflict.destinationDirectory.path)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(conflict.conflictingNames, id: \.self) { name in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(name)
                                .font(FinderUI.detailFont)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(name)
                            Spacer()
                        }
                    }
                }
                .padding(FinderUI.rowSpacing)
            }
            .frame(maxHeight: 110)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))

            HStack(spacing: 10) {
                Button("Anuluj") {
                    fileOps.cancelPendingTransferRequest(conflict.id)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Pomiń istniejące") {
                    resolveWith(.skip)
                }
                .buttonStyle(.bordered)
                .disabled(fileOps.isBusy)

                Button("Zastąp istniejące", role: .destructive) {
                    resolveWith(.overwrite)
                }
                .buttonStyle(.bordered)
                .disabled(fileOps.isBusy)

                Button("Zachowaj oba") {
                    resolveWith(.keepBoth)
                }
                .keyboardShortcut(.defaultAction)
                .help("Zachowaj istniejące pliki i dopisz licznik do nazw kopiowanych lub przenoszonych elementów")
                .disabled(fileOps.isBusy)
            }
        }
        .font(FinderUI.bodyFont)
        .controlSize(.regular)
        .padding(FinderUI.sheetPadding)
        .frame(width: 560)
    }

    private func resolveWith(_ policy: FileConflictPolicy) {
        guard fileOps.pendingConflict?.id == conflict.id, !fileOps.isBusy else { return }
        let c = conflict
        fileOps.pendingConflict = nil
        fileOps.performTransfer(
            sourceURLs: c.sourceURLs,
            into: c.destinationDirectory,
            isMove: c.isMove,
            explicitPolicy: policy,
            copyAcrossVolumes: c.copyAcrossVolumes,
            requestID: c.id,
            completion: c.completion
        )
        // The manager and completion refresh panes after mutation, not here.
    }
}

// MARK: - 6. Settings & fsearch Engine Configuration Sheet (Cmd+,)

public struct FSearchSettingsSheetView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var fileOps = FileOperationsManager.shared

    @ViewState private var roots: [String] = FSearchIndex.shared.configuredRoots
    @ViewState private var skippedDirsText: String = FSearchIndex.shared.skippedDirectoryNames.sorted().joined(separator: ", ")
    @ViewState private var skipHeavyDirs: Bool = FSearchIndex.shared.skipHeavyDevDirs
    @ViewState private var useMMapCache: Bool = FSearchIndex.shared.usePersistentMMapCache
    @ViewState private var conflictPolicy: FileConflictPolicy = FileOperationsManager.shared.defaultConflictPolicy
    @ViewState private var newRootPath: String = ""
    @ViewState private var rootPathError: String?
    @ViewState private var repairIndexSettings = false
    @ViewState private var confirmingSessionClear = false
    @ViewState private var indexSettingsError: String?

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
        ScrollView {
        VStack(alignment: .leading, spacing: FinderUI.sectionSpacing) {
            HStack {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Ustawienia BetterFinder")
                    .font(FinderUI.titleFont)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Toggle("Zapisuj i przywracaj sesję", isOn: Binding(
                    get: { appState.restoreSessionEnabled },
                    set: { appState.setSessionRestorationEnabled($0) }
                ))
                Text("Zmiany sesji obowiązują od razu, niezależnie od przycisków na dole. Lokalnie zapisywane są ścieżki, kolejność kart, oba panele, widoki i tekst wyszukiwania. Zaznaczenia, schowek, cofanie i operacje nie są przywracane. Foldery wracają wstrzymane do chwili wybrania „Wznów”.")
                    .font(FinderUI.captionFont).foregroundStyle(.secondary)
                Text("Wyłączenie zatrzymuje zapis i przywracanie, ale zachowuje poprzedni zapis. Włączenie zapisuje bieżącą sesję. Wyczyszczenie usuwa zapis i wyłącza tę opcję; otwarte karty i inteligentne foldery pozostają bez zmian.")
                    .font(FinderUI.captionFont).foregroundStyle(.secondary)
                if let notice = appState.sessionPersistenceNotice {
                    Text(notice).font(FinderUI.captionFont).foregroundStyle(.orange)
                }
                Button("Wyczyść zapis sesji i wyłącz przywracanie", role: .destructive) {
                    confirmingSessionClear = true
                }.buttonStyle(.bordered)
                .confirmationDialog("Usunąć zapis sesji?", isPresented: $confirmingSessionClear) {
                    Button("Wyczyść i wyłącz przywracanie", role: .destructive) { appState.clearSavedSession() }
                    Button("Anuluj", role: .cancel) {}
                } message: {
                    Text("Zapisanej sesji nie będzie można odzyskać. Otwarte karty pozostaną bez zmian.")
                }
            }
            Divider()

            if let notice = FSearchIndex.shared.indexingPreferencesNotice {
                Text(notice).font(FinderUI.detailFont).foregroundStyle(.orange)
                Toggle("Napraw: zastąp ustawienia poniższymi i zachowaj kopię oryginału", isOn: $repairIndexSettings)
            }
            if let indexSettingsError {
                Text(indexSettingsError).font(FinderUI.detailFont).foregroundStyle(.red)
            }
            // Indexed Roots
            VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
                Text("Indeksowane katalogi")
                    .font(FinderUI.bodyFont.weight(.medium))

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(roots, id: \.self) { root in
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                                Text(root)
                                    .font(FinderUI.detailFont)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(root)
                                Spacer()
                                Button(role: .destructive) {
                                    roots.removeAll { $0 == root }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Usuń \(root) z indeksowanych katalogów")
                                .help("Usuń z indeksu; pliki pozostaną na dysku")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))
                        }
                    }
                }
                .frame(height: 115)
                .overlay {
                    if roots.isEmpty {
                        Text("Dodaj katalog, aby uwzględnić jego pliki w indeksie.")
                            .font(FinderUI.detailFont)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: FinderUI.rowSpacing) {
                    TextField("Ścieżka folderu, np. ~/Work", text: $newRootPath)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Nowy indeksowany katalog")
                        .onSubmit(addRoot)
                        .onChange(of: newRootPath) { _, _ in rootPathError = nil }
                    Button("Dodaj", action: addRoot)
                        .buttonStyle(.bordered)
                        .disabled(newRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let rootPathError {
                    Label(rootPathError, systemImage: "exclamationmark.circle")
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // Exclusions & MMap Cache
            Toggle("Pomijaj ciężkie katalogi deweloperskie i pamięć podręczną", isOn: $skipHeavyDirs)
                .font(FinderUI.bodyFont)

            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text("Ignorowane nazwy katalogów (oddzielone przecinkami)")
                    .font(FinderUI.detailFont)
                    .foregroundStyle(.secondary)
                TextField("node_modules, .git, .build...", text: $skippedDirsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Ignorowane nazwy katalogów")
            }

            Toggle("Zapisuj indeks na dysku, aby przyspieszyć uruchamianie", isOn: $useMMapCache)
                .font(FinderUI.bodyFont)
                .help("Korzystaj z trwałej pamięci podręcznej indeksu mmap")

            Picker("Domyślna akcja przy konflikcie plików", selection: $conflictPolicy) {
                ForEach(FileConflictPolicy.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .font(FinderUI.bodyFont)

            // Engine Diagnostics Footer
            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text("Plików w indeksie: \(appState.indexedFileCount.formatted()) · Filtry Blooma: \(FSearchIndex.shared.trigramCacheCount)")
                Text("Pamięć podręczna: \((FSearchIndex.shared.cacheFilePath as NSString).lastPathComponent)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(FSearchIndex.shared.cacheFilePath)
            }
            .font(FinderUI.captionFont.monospacedDigit())
            .foregroundStyle(.secondary)


        }
        .font(FinderUI.bodyFont)
        .controlSize(.regular)
        .padding(FinderUI.sheetPadding)
        }
        Divider()
        settingsActions
            .controlSize(.regular)
            .padding(.horizontal, FinderUI.sheetPadding)
            .padding(.vertical, FinderUI.panelInset)
            .background(FinderUI.sidebarSurface)
        }
        .frame(width: 580)
        .frame(maxHeight: 760)
    }

    private var settingsActions: some View {
            HStack {
                Spacer()
                Button("Anuluj") {
                    appState.showSettingsSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Zapisz i przebuduj indeks") {
                    let parsedSkip = Set(
                        skippedDirsText
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    )
                    do {
                        try FSearchIndex.shared.saveConfigurationAndRebuild(IndexingConfiguration(
                            roots: roots, skippedDirectoryNames: parsedSkip,
                            skipHeavyDevDirs: skipHeavyDirs, usePersistentMMapCache: useMMapCache),
                            explicitlyRepair: repairIndexSettings)
                        fileOps.defaultConflictPolicy = conflictPolicy
                        appState.showSettingsSheet = false
                    } catch {
                        indexSettingsError = "Nie zapisano ustawień indeksu. Sprawdź wartości lub jawnie potwierdź naprawę."
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
    }

    private func addRoot() {
        guard !newRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let expandedPath = (newRootPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            rootPathError = "Nie znaleziono folderu pod podaną ścieżką."
            return
        }
        guard !roots.contains(expandedPath) else {
            rootPathError = "Ta ścieżka jest już na liście indeksowanych katalogów."
            return
        }
        roots.append(expandedPath)
        newRootPath = ""
        rootPathError = nil
    }
}
