import SwiftUI
import AppKit

public struct PathBreadcrumbSegment: Identifiable {
    public var id: String { url.path }
    public let name: String
    public let url: URL
    public let isRoot: Bool
    public var symbol: String? = nil
}

public struct PathBreadcrumbBar: View {
    @ObservedObject var appState: AppState
    @ObservedObject var pane: PaneTabState
    @ObservedObject private var cloud = CloudActivity.shared
    @ViewState private var editablePathText: String = ""
    @ViewState private var pathValidationMessage: String? = nil
    @ViewState private var isPathFieldFocused = false

    public init(appState: AppState, pane: PaneTabState) {
        self.appState = appState
        self.pane = pane
    }

    /// Like an Explorer address bar, a path on another volume starts at that
    /// volume (`_WIZUALIZACJE › _ARCHIWUM`), not at `Macintosh HD › Volumes`.
    private var segments: [PathBreadcrumbSegment] {
        Self.segments(for: pane.currentURL, volumes: appState.mountedVolumes, clouds: cloud.locations)
    }

    static func segments(for url: URL, volumes: [VolumeInfoItem], clouds: [CloudFiles.Location] = []) -> [PathBreadcrumbSegment] {
        let path = url.standardizedFileURL.path
        // Cloud storage starts at the provider, as Finder shows it:
        // "Google Drive › My Drive", not "… › CloudStorage › GoogleDrive-me@…".
        if let cloud = clouds.first(where: { path == $0.url.path || path.hasPrefix($0.url.path + "/") }) {
            var runningURL = URL(fileURLWithPath: cloud.url.path, isDirectory: true)
            var result = [PathBreadcrumbSegment(name: cloud.provider, url: runningURL, isRoot: true,
                                                symbol: cloud.provider == "iCloud Drive" ? "icloud" : "cloud")]
            for component in path.dropFirst(cloud.url.path.count).split(separator: "/") {
                runningURL = runningURL.appendingPathComponent(String(component), isDirectory: true)
                result.append(PathBreadcrumbSegment(name: String(component), url: runningURL, isRoot: false))
            }
            return result
        }
        let volume = volumes
            .filter { $0.url.path != "/" && (path == $0.url.path || path.hasPrefix($0.url.path + "/")) }
            .max { $0.url.path.count < $1.url.path.count }
        var result: [PathBreadcrumbSegment]
        var runningURL: URL
        let remainder: Substring
        if let volume {
            let symbol = volume.isNetwork ? "network" : (volume.isRemovable ? "externaldrive" : "internaldrive")
            runningURL = URL(fileURLWithPath: volume.url.path, isDirectory: true)
            result = [PathBreadcrumbSegment(name: volume.name, url: runningURL, isRoot: true, symbol: symbol)]
            remainder = path.dropFirst(volume.url.path.count)
        } else {
            let rootName = volumes.first { $0.url.path == "/" }?.name ?? "/"
            runningURL = URL(fileURLWithPath: "/", isDirectory: true)
            result = [PathBreadcrumbSegment(name: rootName, url: runningURL, isRoot: true, symbol: "internaldrive")]
            remainder = path.dropFirst()
        }
        for component in remainder.split(separator: "/") {
            runningURL = runningURL.appendingPathComponent(String(component), isDirectory: true)
            result.append(PathBreadcrumbSegment(name: String(component), url: runningURL, isRoot: false))
        }
        return result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                pathEditor
                folderActionsMenu
            }

            if pane.isEditingPathBar, let message = pathValidationMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(FinderUI.captionFont)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
        }
        .font(FinderUI.detailFont)
        .padding(.horizontal, FinderUI.rowSpacing)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
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
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
                .contentShape(Rectangle())
                .onTapGesture { beginEditingFromBreadcrumbs() }

            if pane.isEditingPathBar {
                FolderAddressTextField(
                    text: $editablePathText,
                    isEditing: pane.isEditingPathBar,
                    focusRequest: pane.pathEditRequest,
                    mayFocus: { pane.isEditingPathBar && appState.activeTab.id == pane.id },
                    beginEditing: {
                        activatePane()
                        pane.isEditingPathBar = true
                        isPathFieldFocused = true
                    },
                    endEditing: {
                        isPathFieldFocused = false
                        // Clicking elsewhere returns to the breadcrumbs, as in Explorer.
                        DispatchQueue.main.async {
                            if pane.isEditingPathBar && !isPathFieldFocused { cancelEditing() }
                        }
                    },
                    changed: { pathValidationMessage = nil },
                    submit: submitPath,
                    cancel: cancelEditing
                )
                .frame(minWidth: 40, maxWidth: .infinity, minHeight: 24)
                .help("Return opens the folder, Escape cancels. Supports ~ and file:/// addresses.")

                pathActionButton(icon: "arrow.right", label: String(localized: "Open Entered Folder"), help: String(localized: "Open Folder (Return)"), action: submitPath)
                    .accessibilityIdentifier("folder.address.go")
                pathActionButton(icon: "xmark", label: String(localized: "Cancel Path Editing"), help: String(localized: "Cancel (Escape)"), action: cancelEditing)
                    .accessibilityIdentifier("folder.address.cancel")
            } else {
                breadcrumbs
            }
        }
        .padding(.leading, pane.isEditingPathBar ? 10 : 2)
        .padding(.trailing, pane.isEditingPathBar ? 10 : 0)
        .frame(minHeight: 28)
        // The breadcrumbs sit flat in the header; only the editable path is a field.
        .background(pane.isEditingPathBar ? Color(nsColor: .textBackgroundColor) : Color.clear,
                    in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))
        .overlay {
            if pane.isEditingPathBar {
                RoundedRectangle(cornerRadius: FinderUI.cornerRadius)
                    .strokeBorder(pathValidationMessage != nil ? Color.red : (isPathFieldFocused ? Color.accentColor : Color.secondary.opacity(0.25)), lineWidth: 1)
            }
        }
    }

    /// Clickable folders with a subfolder menu after each one. When the path
    /// does not fit, the leading folders collapse into a « menu. The empty
    /// space after the last folder switches to the editable path.
    private var breadcrumbs: some View {
        let segments = self.segments
        return HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                ForEach(0..<segments.count, id: \.self) { start in
                    breadcrumbRow(segments, from: start)
                }
            }
            .layoutPriority(1)
            Color.clear
                .frame(minWidth: 28, maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Rectangle())
                .onTapGesture { beginEditingFromBreadcrumbs() }
                .help("Click to edit or copy the path (⌘L)")
                .accessibilityElement()
                .accessibilityLabel("Edit Path")
                .accessibilityValue(pane.currentURL.path)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { beginEditingFromBreadcrumbs() }
                .accessibilityIdentifier("folder.address")
        }
    }

    private func breadcrumbRow(_ segments: [PathBreadcrumbSegment], from start: Int) -> some View {
        HStack(spacing: 0) {
            if start > 0 {
                Menu {
                    ForEach(Array(segments[..<start].reversed())) { segment in
                        Button(segment.isRoot ? segment.name : segment.url.path) { navigate(to: segment.url) }
                    }
                } label: {
                    Image(systemName: "chevron.left.2")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Hidden parent folders")
                .accessibilityLabel("Hidden parent folders")
            }
            ForEach(Array(segments.enumerated()).dropFirst(start), id: \.element.id) { index, segment in
                let isCurrent = index == segments.count - 1
                Button {
                    if isCurrent { activatePane(); pane.reloadDirectory() } else { navigate(to: segment.url) }
                } label: {
                    HStack(spacing: 4) {
                        if let symbol = segment.symbol {
                            Image(systemName: symbol).foregroundStyle(.secondary)
                        }
                        Text(segment.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .fontWeight(isCurrent ? .semibold : .regular)
                    }
                    .padding(.horizontal, 5)
                    .frame(minHeight: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(BreadcrumbButtonStyle())
                .help(segment.url.path)
                .contextMenu { folderContextActions(for: segment.url) }
                .accessibilityLabel(segment.name)
                .accessibilityHint(isCurrent ? String(localized: "Refresh current folder") : String(localized: "Go to folder"))

                BreadcrumbSubfolderButton(
                    url: segment.url,
                    highlightedPath: isCurrent ? nil : segments[index + 1].url.path,
                    showsHiddenFiles: pane.showHiddenFiles,
                    open: { navigate(to: $0) }
                )
                .frame(width: 16, height: 22)
                .help("Subfolders: \(segment.name)")
            }
        }
    }

    private func beginEditingFromBreadcrumbs() {
        activatePane()
        editablePathText = pane.currentURL.path
        pathValidationMessage = nil
        pane.requestPathEditing()
    }

    private var folderActionsMenu: some View {
        Menu {
            Section("Parent Folders") {
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
                    Label("Copy Paths of Selected Items", systemImage: "doc.on.doc")
                }
            }

            Divider()

            Button {
                activatePane()
                appState.showNewFileSheet = true
            } label: {
                Label("New File…", systemImage: "doc.badge.plus")
            }
            Button {
                activatePane()
                appState.showNewFolderSheet = true
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .frame(width: FinderUI.iconButtonSize, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Actions for the current folder")
        .accessibilityLabel("Actions for the current folder")
    }

    @ViewBuilder
    private func folderContextActions(for url: URL) -> some View {
        Button {
            appState.addNewTab(at: url)
        } label: {
            Label("Open in New Tab", systemImage: "plus.square.on.square")
        }
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label("Open in Finder", systemImage: "folder")
        }
        Button {
            FileOperationsManager.shared.copyPathString(url.path)
        } label: {
            Label("Copy Folder Path", systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            FileOperationsManager.shared.openInTerminal(at: url)
        } label: {
            Label("Open in Terminal", systemImage: "terminal")
        }
        Button {
            FileOperationsManager.shared.openInCodeEditor(at: url)
        } label: {
            Label("Open in Code Editor", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        Button {
            appState.addBookmark(for: url)
        } label: {
            Label("Add Folder to Favorites", systemImage: "star")
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
                    ? String(localized: "Couldn’t open the folder.")
                    : String(localized: "Couldn’t open this path. See the message below for details.")
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

private struct BreadcrumbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HighlightedLabel(configuration: configuration)
    }

    private struct HighlightedLabel: View {
        let configuration: ButtonStyleConfiguration
        @ViewState private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (isHovered ? 0.08 : 0)))
                )
                .onHover { isHovered = $0 }
        }
    }
}

/// The › after a breadcrumb lists that folder's subfolders, read only when
/// clicked so slow network volumes are not listed on every redraw.
private struct BreadcrumbSubfolderButton: NSViewRepresentable {
    let url: URL
    let highlightedPath: String?
    let showsHiddenFiles: Bool
    let open: (URL) -> Void

    func makeNSView(context: Context) -> ChevronButton {
        let button = ChevronButton()
        button.update(from: self)
        return button
    }

    func updateNSView(_ button: ChevronButton, context: Context) {
        button.update(from: self)
    }

    final class ChevronButton: NSButton {
        private static let itemLimit = 1_000
        private var url = URL(fileURLWithPath: "/")
        private var highlightedPath: String?
        private var showsHiddenFiles = false
        private var open: (URL) -> Void = { _ in }

        init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 22))
            isBordered = false
            imagePosition = .imageOnly
            contentTintColor = .secondaryLabelColor
            setChevron(open: false)
            target = self
            action = #selector(showMenu)
            setAccessibilityLabel(String(localized: "Subfolders"))
        }

        required init?(coder: NSCoder) { nil }

        fileprivate func update(from view: BreadcrumbSubfolderButton) {
            url = view.url
            highlightedPath = view.highlightedPath
            showsHiddenFiles = view.showsHiddenFiles
            open = view.open
        }

        override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 22) }

        private func setChevron(open: Bool) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        }

        static func subfolders(of url: URL, includeHidden: Bool) -> [URL] {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
            let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)) ?? []
            return contents.filter {
                let values = try? $0.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isPackage != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }

        @objc private func showMenu() {
            let menu = NSMenu()
            menu.autoenablesItems = false
            let folders = Self.subfolders(of: url, includeHidden: showsHiddenFiles)
            let folderImage = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            for folder in folders.prefix(Self.itemLimit) {
                let item = NSMenuItem(title: folder.lastPathComponent, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = folder
                item.image = folderImage
                if folder.path == highlightedPath { item.state = .on }
                menu.addItem(item)
            }
            if folders.count > Self.itemLimit {
                let more = NSMenuItem(title: String(localized: "… and \(folders.count - Self.itemLimit) more"), action: nil, keyEquivalent: "")
                more.isEnabled = false
                menu.addItem(more)
            }
            if folders.isEmpty {
                let empty = NSMenuItem(title: String(localized: "No Subfolders"), action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            setChevron(open: true)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 2 : -2), in: self)
            setChevron(open: false)
        }

        @objc private func choose(_ item: NSMenuItem) {
            guard let folder = item.representedObject as? URL else { return }
            open(folder)
        }
    }
}
