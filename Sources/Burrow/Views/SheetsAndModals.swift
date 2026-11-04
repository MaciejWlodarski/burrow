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
                self.diagnostic = bundle.diagnostic ?? (bundle.isPartial ? String(localized: "Partial results.") : nil)
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

                TextField("Search the file index…", text: $queryText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .accessibilityLabel("Quick search in the file index")
                    .help("Enter a name or filter, e.g. ext:swift, grep:text, size:>10mb, tag:red")
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
                        .accessibilityLabel("Searching")
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

                Button("Close") {
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
                    Text(emptyStateMessage)
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

                                    Button("Show in Tab") {
                                        selectedIndex = idx
                                        activateSelectedResult(revealInFolder: true)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Show \(item.name) in tab")
                                    .help("Show in tab: \(item.path)")
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
                Text(search.diagnostic ?? String(localized: "↑↓ select · Return or double-click: go · Esc: close"))
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("In index: \(appState.indexedFileCount.formatted())")
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

    private var emptyStateMessage: String {
        if search.isSearching { return String(localized: "Searching…") }
        if !hasQuery {
            return String(localized: "Type a query to search the index. Files: \(appState.indexedFileCount.formatted())")
        }
        return search.diagnostic == nil
            ? String(localized: "No matching results")
            : String(localized: "No results in the checked scope")
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
                Text("Create New File")
                    .font(FinderUI.titleFont)
                Spacer()
            }

            Picker("File Template", selection: $selectedTemplate) {
                ForEach(NewFileTemplate.allCases) { tpl in
                    Text(tpl.displayName).tag(tpl)
                }
            }
            .onChange(of: selectedTemplate) { _, newValue in
                filename = newValue.defaultFilename
                customContent = newValue.initialContent
            }

            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text("File Name")
                    .font(FinderUI.detailFont)
                TextField("File Name", text: $filename)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(createAndClose)
                    .onChange(of: filename) { _, _ in errorMessage = nil }
            }

            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text("Initial content (optional)")
                    .font(FinderUI.detailFont)
                TextEditor(text: $customContent)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Initial file content")
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: FinderUI.cornerRadius).stroke(Color(nsColor: .separatorColor)))
            }

            Text("Location: \(activeTab.currentURL.path)")
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
                Button("Cancel") {
                    appState.showNewFileSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create File", action: createAndClose)
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
            errorMessage = FileOperationsManager.shared.lastStatusMessage ?? String(localized: "Couldn't create the file.")
            isNameFocused = true
        }
    }
}

// MARK: - 3. New Folder Sheet

public struct NewFolderSheetView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState

    @ViewState private var folderName: String = String(localized: "New Folder")
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
                Text("Create New Folder")
                    .font(FinderUI.titleFont)
                Spacer()
            }

            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text("Folder Name")
                    .font(FinderUI.detailFont)
                TextField("Folder Name", text: $folderName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(createAndClose)
                    .onChange(of: folderName) { _, _ in errorMessage = nil }
            }

            Text("Location: \(activeTab.currentURL.path)")
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
                Button("Cancel") {
                    appState.showNewFolderSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
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
            errorMessage = FileOperationsManager.shared.lastStatusMessage ?? String(localized: "Couldn't create the folder.")
            isNameFocused = true
        }
    }
}

// MARK: - 4. Dual-Pane Folder Compare & Sync Sheet

public struct FolderCompareEntry: Identifiable, Sendable {
    public enum Status: Sendable {
        case onlyLeft, onlyRight, modified, identical, notCompared, typeConflict, unreadable

        public var displayName: String {
            switch self {
            case .onlyLeft: return String(localized: "Only in left")
            case .onlyRight: return String(localized: "Only in right")
            case .modified: return String(localized: "Different content or time")
            case .identical: return String(localized: "Same content and time")
            case .notCompared: return String(localized: "Subfolder: not compared")
            case .typeConflict: return String(localized: "Different type: check manually")
            case .unreadable: return String(localized: "Unreadable / changed")
            }
        }
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
            return ([], String(localized: "Comparison incomplete: read error or limit of \(budget) items. Copying disabled."))
        }
        let rightRead = BulkCrawler.readDirectoryResult(at: right.path, includeHidden: includeHidden,
            maxEntries: budget - leftRead.entries.count, isCancelled: { token.isCancelled })
        guard leftRead.isComplete && rightRead.isComplete else {
            return ([], String(localized: "Comparison incomplete: read error or limit of \(budget) items. Copying disabled."))
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
                Text("Compare Folder Contents")
                    .font(FinderUI.titleFont)
                Spacer()
                Toggle("Hide Identical", isOn: $hideIdentical)
                    .font(FinderUI.detailFont)
                    .fixedSize()
            }

            HStack(spacing: 12) {
                Label("Left: \(leftURL.path)", systemImage: "folder.fill")
                    .font(FinderUI.detailFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(leftURL.path)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Label("Right: \(rightURL.path)", systemImage: "folder.fill")
                    .font(FinderUI.detailFont)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rightURL.path)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)

            Divider()

            Text(compareStatusText)
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
                                .help(entry.leftItem?.path ?? String(localized: "Not in the left folder"))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(entry.status.displayName)
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
                                .help(entry.rightItem?.path ?? String(localized: "Not in the right folder"))
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
                        .accessibilityLabel("Comparing folders")
                } else if compareDiagnostic == nil && filteredEntries.isEmpty {
                    Text(entries.isEmpty ? String(localized: "No items to compare") : String(localized: "No differences in the compared files"))
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if isComparing {
                    Button("Cancel Comparison") {
                        compareToken?.cancel()
                        compareTask?.cancel()
                        isComparing = false
                        comparedContext = nil
                        compareDiagnostic = String(localized: "Canceled. A system read in progress may still be finishing.")
                    }
                } else if compareDiagnostic != nil {
                    Button("Compare Again") { computeDiff() }
                }
                Spacer()
            }
            HStack {
                Text("Copy differences:")
                    .font(FinderUI.detailFont)
                Button("Left → Right") { copyDifferences(leftToRight: true) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Copy differences from the left folder to the right")
                    .help("Copy differing items from the left folder to the right. Existing files require conflict resolution.")
                    .disabled(isComparing || compareDiagnostic != nil || comparedContext != comparisonContext || fileOps.isBusy || FolderComparison.copyCandidates(entries, leftToRight: true).isEmpty)
                Button("Right → Left") { copyDifferences(leftToRight: false) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Copy differences from the right folder to the left")
                    .help("Copy differing items from the right folder to the left. Existing files require conflict resolution.")
                    .disabled(isComparing || compareDiagnostic != nil || comparedContext != comparisonContext || fileOps.isBusy || FolderComparison.copyCandidates(entries, leftToRight: false).isEmpty)

                Spacer()

                Button("Close") {
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

    private var compareStatusText: String {
        if let compareDiagnostic { return compareDiagnostic }
        if isComparing {
            return compareWorkState == .queued
                ? String(localized: "Comparison queued…")
                : String(localized: "Comparing file contents…")
        }
        return String(localized: "Compares file contents and modification times, non-recursively. Common subfolders and type conflicts need a separate comparison. Copying doesn't delete items at the destination.")
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
                    self.compareDiagnostic = String(localized: "Deferred: analysis is busy. Compare again. Copying disabled.")
                } else if state == .cancelled {
                    self.isComparing = false
                    self.comparedContext = nil
                    self.compareDiagnostic = String(localized: "Comparison canceled. Copying disabled.")
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
                    Text("File name conflict detected (\(conflict.conflictingNames.count))")
                        .font(FinderUI.titleFont)
                    Text("The destination folder '\(conflict.destinationDirectory.lastPathComponent)' already contains files with the same names:")
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
                Button("Cancel") {
                    fileOps.cancelPendingTransferRequest(conflict.id)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Skip Existing") {
                    resolveWith(.skip)
                }
                .buttonStyle(.bordered)
                .disabled(fileOps.isBusy)

                Button("Replace Existing", role: .destructive) {
                    resolveWith(.overwrite)
                }
                .buttonStyle(.bordered)
                .disabled(fileOps.isBusy)

                Button("Keep Both") {
                    resolveWith(.keepBoth)
                }
                .keyboardShortcut(.defaultAction)
                .help("Keep existing files and append a counter to the names of copied or moved items")
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


/// The Settings window (⌘,): native toolbar tabs with grouped forms, like
/// System Settings. Choices apply at once; only the search index has an
/// explicit rebuild, because rebuilding reads every indexed folder again.
public struct FSearchSettingsSheetView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        TabView {
            GeneralSettingsPane(appState: appState)
                .frame(height: 452)
                .tabItem { Label("General", systemImage: "gearshape") }
            BrowsingSettingsPane()
                .frame(minHeight: 300, idealHeight: 300)
                .tabItem { Label("Browsing", systemImage: "folder") }
            IndexSettingsPane(appState: appState)
                .frame(minHeight: 470, idealHeight: 470)
                .tabItem { Label("Search Index", systemImage: "magnifyingglass") }
        }
        .frame(width: 560)
    }
}

/// Short explanatory text under a settings group.
private struct SettingsFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.callout)
            .lineSpacing(2)
            .foregroundStyle(FinderUI.metadataColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralSettingsPane: View {
    @ObservedObject var appState: AppState
    @ViewState private var confirmingSessionClear = false

    var body: some View {
        Form {
            LanguageSettingsSection()
            DefaultFileViewerSettingsSection()
            Section {
                // The explanation sits under the toggle it explains, not under the button.
                Toggle(isOn: Binding(
                    get: { appState.restoreSessionEnabled },
                    set: { appState.setSessionRestorationEnabled($0) }
                )) {
                    Text("Reopen tabs and panes at launch")
                    Text("Folders, views and searches reopen as you left them.")
                }
                LabeledContent("Saved session") {
                    Button("Clear…", role: .destructive) { confirmingSessionClear = true }
                }
                if let notice = appState.sessionPersistenceNotice {
                    Text(notice).font(FinderUI.captionFont).foregroundStyle(.orange)
                }
            }
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete the saved session?", isPresented: $confirmingSessionClear) {
            Button("Clear and Turn Off Restoration", role: .destructive) { appState.clearSavedSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved session can't be recovered. Open tabs will stay unchanged.")
        }
    }
}

struct BrowsingSettingsPane: View {
    @ObservedObject private var fileOps = FileOperationsManager.shared
    @ViewState private var conflictPolicy: FileConflictPolicy = FileOperationsManager.shared.defaultConflictPolicy

    var body: some View {
        Form {
            FolderSortSettingsSection()
            Section {
                Picker("When a file already exists", selection: $conflictPolicy) {
                    ForEach(FileConflictPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .onChange(of: conflictPolicy) { _, value in fileOps.defaultConflictPolicy = value }
            } footer: {
                SettingsFootnote(String(localized: "Used when copying or moving files onto items with the same name."))
            }
        }
        .formStyle(.grouped)
    }
}

struct IndexSettingsPane: View {
    @ObservedObject var appState: AppState

    @ViewState private var roots: [String] = FSearchIndex.shared.configuredRoots
    @ViewState private var skippedDirsText: String = FSearchIndex.shared.skippedDirectoryNames.sorted().joined(separator: ", ")
    @ViewState private var skipHeavyDirs: Bool = FSearchIndex.shared.skipHeavyDevDirs
    @ViewState private var useMMapCache: Bool = FSearchIndex.shared.usePersistentMMapCache
    @ViewState private var rootPathError: String?
    @ViewState private var repairIndexSettings = false
    @ViewState private var indexSettingsError: String?
    @ViewState private var savedConfiguration = IndexSettingsPane.currentConfiguration()

    private static func currentConfiguration() -> IndexingConfiguration {
        IndexingConfiguration(roots: FSearchIndex.shared.configuredRoots,
                              skippedDirectoryNames: FSearchIndex.shared.skippedDirectoryNames,
                              skipHeavyDevDirs: FSearchIndex.shared.skipHeavyDevDirs,
                              usePersistentMMapCache: FSearchIndex.shared.usePersistentMMapCache)
    }

    private var editedConfiguration: IndexingConfiguration {
        IndexingConfiguration(
            roots: roots,
            skippedDirectoryNames: Set(skippedDirsText.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }),
            skipHeavyDevDirs: skipHeavyDirs, usePersistentMMapCache: useMMapCache)
    }

    private var hasChanges: Bool {
        let edited = editedConfiguration
        return edited.roots != savedConfiguration.roots
            || edited.skippedDirectoryNames != savedConfiguration.skippedDirectoryNames
            || edited.skipHeavyDevDirs != savedConfiguration.skipHeavyDevDirs
            || edited.usePersistentMMapCache != savedConfiguration.usePersistentMMapCache
    }

    var body: some View {
        Form {
            if let notice = FSearchIndex.shared.indexingPreferencesNotice {
                Section {
                    Text(notice).foregroundStyle(.orange)
                    Toggle("Repair: replace settings with those below and keep a copy of the original", isOn: $repairIndexSettings)
                }
            }
            Section {
                if roots.isEmpty {
                    Text("Add a folder to include its files in the index.")
                        .foregroundStyle(.secondary)
                }
                ForEach(roots, id: \.self) { root in
                    HStack(spacing: FinderUI.rowSpacing) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: root))
                            .resizable()
                            .frame(width: 18, height: 18)
                            .accessibilityHidden(true)
                        Text(root.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(root)
                        Spacer()
                        Button {
                            roots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(root) from indexed folders")
                        .help("Remove from the index; files stay on disk")
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Folder…", action: chooseRoot)
                }
            } header: {
                Text("Indexed Folders")
            } footer: {
                if let rootPathError {
                    Label(rootPathError, systemImage: "exclamationmark.circle")
                        .font(FinderUI.captionFont)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Toggle("Skip developer folders and caches", isOn: $skipHeavyDirs)
                TextField("Ignored folder names", text: $skippedDirsText, prompt: Text(verbatim: "node_modules, .git, .build"))
                Toggle("Keep the index on disk for a faster launch", isOn: $useMMapCache)
            } footer: {
                SettingsFootnote(String(localized: "Separate ignored folder names with commas."))
            }

            Section {
                LabeledContent("Files in index") {
                    Text(appState.indexedFileCount.formatted()).monospacedDigit()
                }
                HStack {
                    if let indexSettingsError {
                        Text(indexSettingsError).font(FinderUI.captionFont).foregroundStyle(.red)
                    }
                    Spacer()
                    Button(hasChanges ? String(localized: "Apply and Rebuild Index") : String(localized: "Rebuild Index"), action: apply)
                        .disabled(appState.isIndexing && !hasChanges)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func apply() {
        indexSettingsError = nil
        guard hasChanges else {
            FSearchIndex.shared.startIndexing()
            return
        }
        do {
            try FSearchIndex.shared.saveConfigurationAndRebuild(editedConfiguration, explicitlyRepair: repairIndexSettings)
            savedConfiguration = editedConfiguration
        } catch {
            indexSettingsError = String(localized: "Index settings were not saved. Check the values or explicitly confirm the repair.")
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        guard !roots.contains(path) else {
            rootPathError = String(localized: "This path is already in the list of indexed folders.")
            return
        }
        roots.append(path)
        rootPathError = nil
    }
}

/// The app follows the system language unless one is chosen here. macOS reads
/// the choice at launch, so it applies after Burrow restarts.
struct LanguageSettingsSection: View {
    enum Choice: String, CaseIterable, Identifiable {
        case system, en, pl
        var id: String { rawValue }
    }

    private static let key = "AppleLanguages"
    @ViewState private var choice: Choice = {
        guard let languages = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? [String],
              let first = languages.first else { return .system }
        return Choice(rawValue: String(first.prefix(2))) ?? .system
    }()
    @ViewState private var changed = false

    var body: some View {
        Section {
            Picker("Language", selection: $choice) {
                Text("System Default").tag(Choice.system)
                Text(verbatim: "English").tag(Choice.en)
                Text(verbatim: "Polski").tag(Choice.pl)
            }
            .onChange(of: choice) { _, value in
                if value == .system {
                    UserDefaults.standard.removeObject(forKey: Self.key)
                } else {
                    UserDefaults.standard.set([value.rawValue], forKey: Self.key)
                }
                changed = true
            }
        } footer: {
            // Always present, so every section is spaced the same.
            SettingsFootnote(changed ? String(localized: "Restart Burrow to apply the new language.")
                             : String(localized: "System Default follows the language set in System Settings."))
        }
    }
}

/// Lets the user hand folder opening and "Show in Finder" over to Burrow.
struct DefaultFileViewerSettingsSection: View {
    @ViewState private var isDefault = DefaultFileViewer.isDefault
    @ViewState private var isWorking = false
    @ViewState private var errorMessage: String?

    var body: some View {
        Section {
            LabeledContent("Default file browser") {
                HStack(spacing: FinderUI.rowSpacing) {
                    Text(isDefault ? "Currently Burrow" : "Currently Finder")
                        .foregroundStyle(.secondary)
                    if isDefault {
                        Button("Restore Finder") { apply(makeDefault: false) }
                            .disabled(isWorking)
                    } else {
                        Button("Use Burrow") { apply(makeDefault: true) }
                            .disabled(isWorking)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(FinderUI.captionFont).foregroundStyle(.orange)
            }
        } footer: {
            SettingsFootnote(String(localized: "Folders opened from other apps and “Show in Finder” open in Burrow. The Desktop and the Dock’s Trash stay with Finder."))
        }
        .onAppear { isDefault = DefaultFileViewer.isDefault }
    }

    private func apply(makeDefault: Bool) {
        isWorking = true
        errorMessage = nil
        let finish: @MainActor (String?) -> Void = { error in
            isWorking = false
            errorMessage = error
            isDefault = DefaultFileViewer.isDefault
        }
        if makeDefault { DefaultFileViewer.makeDefault(completion: finish) }
        else { DefaultFileViewer.restoreFinder(completion: finish) }
    }
}

/// Default sort for every folder, plus the folders that keep their own.
/// Changes apply at once.
struct FolderSortSettingsSection: View {
    @ObservedObject private var preferences = FolderSortPreferences.shared

    private func binding<Value>(_ keyPath: WritableKeyPath<FolderSort, Value>) -> Binding<Value> {
        Binding(
            get: { preferences.defaultSort[keyPath: keyPath] },
            set: { value in
                var sort = preferences.defaultSort
                sort[keyPath: keyPath] = value
                preferences.setDefaultSort(sort)
            }
        )
    }

    var body: some View {
        Section {
            Picker("Sort folders by", selection: binding(\.field)) {
                ForEach(SortField.allCases) { field in
                    Text(field.displayName).tag(field)
                }
            }
            Picker("Order", selection: binding(\.ascending)) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            Toggle("Keep folders on top", isOn: binding(\.foldersOnTop))
        } header: {
            Text("Sorting")
        } footer: {
            SettingsFootnote(String(localized: "Sorting a folder by its columns is remembered for that folder."))
        }

        if !preferences.folderSorts.isEmpty {
            Section {
                ForEach(preferences.folderSorts.keys.sorted(), id: \.self) { path in
                    HStack {
                        Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer()
                        Text(preferences.folderSorts[path]?.summary ?? "")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button {
                            preferences.resetSort(for: URL(fileURLWithPath: path))
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Restore the default sorting for this folder")
                        .accessibilityLabel("Restore the default sorting for \(path)")
                    }
                }
                HStack {
                    Spacer()
                    Button("Restore Defaults in All Folders") { preferences.resetAllFolders() }
                }
            } header: {
                Text("Folders with custom sorting")
            }
        }
    }
}

struct UpdateSettingsSection: View {
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updates.automaticChecksEnabled },
                set: { updates.automaticChecksEnabled = $0 }
            ))
        } footer: {
            SettingsFootnote(String(localized: "Once a day Burrow asks GitHub for the latest version number. Nothing about you or your files is sent."))
        }
    }
}
