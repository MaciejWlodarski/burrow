import SwiftUI
import AppKit

public struct PathBreadcrumbSegment: Identifiable {
    public var id: String { url.path }
    public let name: String
    public let url: URL
    public let isRoot: Bool
}

/// Retained layout regression contract for the previous breadcrumb renderer.
/// The visible address field now uses native NSTextField scrolling; these metrics
/// are not evidence of the new field's native focus or layout correctness.
struct BreadcrumbLayoutMetrics {
    let currentWidth: CGFloat
    let ancestorWidth: CGFloat
    let spacing: CGFloat

    static func finiteWidth(_ proposedWidth: CGFloat?) -> CGFloat {
        guard let width = proposedWidth, width.isFinite else { return 280 }
        return max(0, width)
    }

    init(availableWidth: CGFloat, idealCurrentWidth: CGFloat, hasAncestors: Bool) {
        let width = Self.finiteWidth(availableWidth)
        spacing = hasAncestors ? min(2, width) : 0
        let usable = max(0, width - spacing)
        currentWidth = min(Self.finiteWidth(idealCurrentWidth), 280, hasAncestors ? usable * 0.6 : usable)
        ancestorWidth = hasAncestors ? max(0, usable - currentWidth) : 0
    }
}

#if BURROW_TESTING
/// Screenshot-only presentation. This does not exercise editing, keyboard routing,
/// validation or native focus; interaction tests must leave the environment empty.
struct FolderAddressVisualFixture: Sendable {
    let draft: String
    var validationMessage: String? = nil
    var isFocused: Bool = true
}

private struct FolderAddressVisualFixturesKey: EnvironmentKey {
    static let defaultValue: [UUID: FolderAddressVisualFixture] = [:]
}

extension EnvironmentValues {
    var folderAddressVisualFixtures: [UUID: FolderAddressVisualFixture] {
        get { self[FolderAddressVisualFixturesKey.self] }
        set { self[FolderAddressVisualFixturesKey.self] = newValue }
    }
}
#endif

public struct PathBreadcrumbBar: View {
    @ObservedObject var appState: AppState
    @ObservedObject var pane: PaneTabState
    @ViewState private var editablePathText: String = ""
    @ViewState private var pathValidationMessage: String? = nil
    @ViewState private var isPathFieldFocused = false

    #if BURROW_TESTING
    @Environment(\.folderAddressVisualFixtures) private var visualFixtures
    private var visualFixture: FolderAddressVisualFixture? { visualFixtures[pane.id] }
    #endif

    private var isVisualFixture: Bool {
        #if BURROW_TESTING
        return visualFixture != nil
        #else
        return false
        #endif
    }

    private var displayedText: Binding<String> {
        #if BURROW_TESTING
        if let visualFixture { return .constant(visualFixture.draft) }
        #endif
        return $editablePathText
    }

    private var displayedValidationMessage: String? {
        #if BURROW_TESTING
        if let visualFixture { return visualFixture.validationMessage }
        #endif
        return pathValidationMessage
    }

    private var displayedFocus: Bool {
        #if BURROW_TESTING
        if let visualFixture { return visualFixture.isFocused }
        #endif
        return isPathFieldFocused
    }

    public init(appState: AppState, pane: PaneTabState) {
        self.appState = appState
        self.pane = pane
    }

    private var segments: [PathBreadcrumbSegment] {
        var result: [PathBreadcrumbSegment] = []
        var runningURL = URL(fileURLWithPath: "/", isDirectory: true)
        let rootName = appState.mountedVolumes.first { $0.url.path == "/" }?.name ?? "/"

        for (index, component) in pane.currentURL.pathComponents.enumerated() {
            if index == 0 && component == "/" {
                result.append(PathBreadcrumbSegment(name: rootName, url: runningURL, isRoot: true))
            } else {
                runningURL = runningURL.appendingPathComponent(component, isDirectory: true)
                result.append(PathBreadcrumbSegment(name: component, url: runningURL, isRoot: false))
            }
        }
        return result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                pathEditor
                pathActionButton(icon: "doc.on.doc", label: "Kopiuj ścieżkę bieżącego folderu", help: pane.currentURL.path) {
                    activatePane()
                    FileOperationsManager.shared.copyPathString(pane.currentURL.path)
                }
                .accessibilityIdentifier("folder.address.copy")
                folderActionsMenu
            }

            if pane.isEditingPathBar || isVisualFixture, let message = displayedValidationMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(FinderUI.captionFont)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
        }
        .font(FinderUI.bodyFont)
        .padding(.horizontal, FinderUI.chromeInset)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .allowsHitTesting(!isVisualFixture)
        .onAppear { editablePathText = pane.currentURL.path }
        .onChange(of: pane.isEditingPathBar) { _, editing in
            if !editing { resetEditor() }
        }
        .onChange(of: pane.pathEditRequest) { _, _ in
            activatePane()
            editablePathText = pane.currentURL.path
            pathValidationMessage = nil
        }
        .onChange(of: pane.currentURL) { _, _ in
            // A newer navigation wins over the old draft, even when another
            // control initiated it. Ordinary listing refreshes do not erase text.
            cancelEditing()
        }
        .onChange(of: appState.activePaneSide) { _, _ in
            if appState.isDualPane && appState.activeTab.id != pane.id { cancelEditing() }
        }
    }

    private var pathEditor: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            FolderAddressTextField(
                text: displayedText,
                isEditing: !isVisualFixture && pane.isEditingPathBar,
                focusRequest: pane.pathEditRequest,
                mayFocus: { !isVisualFixture && pane.isEditingPathBar && appState.activeTab.id == pane.id },
                beginEditing: {
                    activatePane()
                    pane.isEditingPathBar = true
                    isPathFieldFocused = true
                },
                endEditing: { isPathFieldFocused = false },
                changed: { pathValidationMessage = nil },
                submit: submitPath,
                cancel: cancelEditing
            )
            .frame(minWidth: 40, maxWidth: .infinity, minHeight: 24)
            .help("Kliknij, aby edytować lub skopiować ścieżkę (⌘L). Return otwiera folder, Escape anuluje. Obsługuje ~ i adresy file:///.")

            if pane.isEditingPathBar || isVisualFixture {
                pathActionButton(icon: "arrow.right", label: "Otwórz wpisany folder", help: "Otwórz folder (Return)", action: submitPath)
                    .accessibilityIdentifier("folder.address.go")
                pathActionButton(icon: "xmark", label: "Anuluj edycję ścieżki", help: "Anuluj (Escape)", action: cancelEditing)
                    .accessibilityIdentifier("folder.address.cancel")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: FinderUI.cornerRadius)
                .strokeBorder(displayedValidationMessage != nil ? Color.red : (displayedFocus ? Color.accentColor : Color.secondary.opacity(0.25)), lineWidth: 1)
        }
    }

    private var folderActionsMenu: some View {
        Menu {
            Section("Foldery nadrzędne") {
                ForEach(Array(segments.dropLast().reversed())) { segment in
                    Button(segment.isRoot ? segment.name : segment.url.path) { navigate(to: segment.url) }
                }
            }
            Divider()
            folderContextActions(for: pane.currentURL)

            if !pane.selectedItems.isEmpty {
                Button {
                    FileOperationsManager.shared.copyPaths(pane.selectedItems)
                } label: {
                    Label("Kopiuj ścieżki zaznaczonych elementów", systemImage: "doc.on.doc")
                }
            }

            Divider()

            Button {
                activatePane()
                appState.showNewFileSheet = true
            } label: {
                Label("Nowy plik…", systemImage: "doc.badge.plus")
            }
            Button {
                activatePane()
                appState.showNewFolderSheet = true
            } label: {
                Label("Nowy folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: FinderUI.iconButtonSize, height: FinderUI.iconButtonSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Działania dla bieżącego folderu")
        .accessibilityLabel("Działania dla bieżącego folderu")
    }

    @ViewBuilder
    private func folderContextActions(for url: URL) -> some View {
        Button {
            appState.addNewTab(at: url)
        } label: {
            Label("Otwórz w nowej karcie", systemImage: "plus.square.on.square")
        }
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label("Otwórz w Finderze", systemImage: "folder")
        }
        Button {
            FileOperationsManager.shared.copyPathString(url.path)
        } label: {
            Label("Kopiuj ścieżkę folderu", systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            FileOperationsManager.shared.openInTerminal(at: url)
        } label: {
            Label("Otwórz w Terminalu", systemImage: "terminal")
        }
        Button {
            FileOperationsManager.shared.openInCodeEditor(at: url)
        } label: {
            Label("Otwórz w edytorze kodu", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        Button {
            appState.addBookmark(for: url)
        } label: {
            Label("Dodaj folder do Ulubionych", systemImage: "star")
        }
        .disabled(appState.customBookmarks.contains { $0.url.path == url.path })
    }

    private func pathActionButton(icon: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: FinderUI.iconButtonSize, height: FinderUI.iconButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
    }

    private func resetEditor() {
        editablePathText = pane.currentURL.path
        isPathFieldFocused = false
        pathValidationMessage = nil
    }

    private func cancelEditing() {
        pane.isEditingPathBar = false
        resetEditor()
    }

    private func submitPath() {
        activatePane()
        do {
            let target = try FolderAddress.resolve(editablePathText, relativeTo: pane.currentURL,
                                                   home: FileManager.default.homeDirectoryForCurrentUser)
            // Do not preflight fileExists here. Navigation validates and commits
            // once; failure must retain the draft as well as the pane snapshot.
            guard pane.navigate(to: target, clearSearch: true) else {
                // The pane banner carries the full diagnostic; don't repeat it here.
                pathValidationMessage = pane.navigationDiagnostic == nil
                    ? "Nie udało się otworzyć folderu."
                    : "Nie udało się otworzyć tej ścieżki. Szczegóły są w komunikacie poniżej."
                return
            }
            cancelEditing()
        } catch {
            pathValidationMessage = error.localizedDescription
        }
    }

    private func navigate(to url: URL) {
        activatePane()
        if pane.navigate(to: url, clearSearch: true) { cancelEditing() }
    }

    private func activatePane() {
        if appState.isDualPane {
            appState.activePaneSide = pane.id == appState.rightPane.id ? .right : .left
        }
    }
}
