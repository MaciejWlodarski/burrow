import SwiftUI
import AppKit

public struct InspectorPreviewView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState
    @ObservedObject var folderSizes = FolderSizeCache.shared
    @ViewState private var folderSizeOwner = UUID()
    @ObservedObject var fileOps = FileOperationsManager.shared
    @ObservedObject private var iconCache = FileIconCache.shared

    @ViewState private var textPreviewLines: [(Int, String)] = []
    @ViewState private var preparedPreviewImage: NSImage?
    @ViewState private var previewPixelWidth = 0
    @ViewState private var previewPixelHeight = 0
    @ViewState private var previewMessage: String?
    @ViewState private var isPreparingPreview = false
    @ViewState private var previewRequestID = UUID()
    @ViewState private var previewRequest: InspectorPreviewRequest?
    @ViewState private var posixPermissionsString: String = "—"

    /// "Shared › Burrow Demo › Studio": the nearest folders by whole name, so a
    /// shortened location never cuts a folder name in half. The tooltip has the full path.
    private var permissionsText: Text {
        guard let split = posixPermissionsString.range(of: " (") else {
            return Text(verbatim: posixPermissionsString).foregroundColor(.primary)
        }
        return Text(verbatim: String(posixPermissionsString[..<split.lowerBound])).foregroundColor(.primary)
            + Text(verbatim: String(posixPermissionsString[split.lowerBound...])).foregroundColor(FinderUI.metadataColor)
    }

    static func locationTrail(_ path: String) -> String {
        let components = (path as NSString).abbreviatingWithTildeInPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return path }
        return components.suffix(4).joined(separator: " › ")
    }
    @ViewState private var currentModeBits: UInt16 = 0
    @ViewState private var permissionSnapshot: PosixPermissionSnapshot?
    @ViewState private var permissionError: String?
    @ViewState private var permissionRequestID = UUID()
    @ViewState private var permissionReadOperation: Operation?
    private static let permissionMetadataQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.burrow.permission-metadata"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    @ViewState private var showChmodEditor: Bool = false
    @ViewState private var sha256Hash: String? = nil
    @ViewState private var md5Hash: String? = nil
    @ViewState private var isComputingHash: Bool = false
    @ViewState private var hashErrorMessage: String? = nil
    @ViewState private var hashRequestID = UUID()
    @ViewState private var hashRequest: FileChecksumRequest?

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    private var folderSizeDemandPaths: [String] {
        activeTab.selectedItems.filter(\.isDirectory).map(\.path).sorted()
    }

    private func updateFolderSizeDemand() {
        folderSizes.updateDemand(owner: folderSizeOwner, paths: folderSizeDemandPaths)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if activeTab.selectedItems.count > 1 {
                ScrollView {
                    selectionSummary
                }
            } else if let item = activeTab.primarySelectedItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: FinderUI.sectionSpacing) {
                        // Live Visual Preview (Image or Code/Text)
                        livePreviewBox(for: item)

                        // Top Identity Card
                        HStack(spacing: 12) {
                            // A previewed item already shows itself above.
                            if preparedPreviewImage == nil {
                                Image(nsImage: FileIconCache.shared.icon(for: item))
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 36, height: 36)
                                    .accessibilityHidden(true)
                            }

                            // Under a centred preview the name is centred too: one axis.
                            let centred = preparedPreviewImage != nil
                            VStack(alignment: centred ? .center : .leading, spacing: 3) {
                                Text(item.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .multilineTextAlignment(centred ? .center : .leading)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                    .help(item.name)
                                Text(preparedPreviewImage != nil && previewPixelWidth > 0
                                     ? "\(item.kindDisplayString) · \(previewPixelWidth.formatted()) × \(previewPixelHeight.formatted())"
                                     : item.kindDisplayString)
                                    .font(FinderUI.detailFont)
                                    .foregroundStyle(FinderUI.metadataColor)
                                if let git = item.gitStatus {
                                    Text("Git: \(git.badgeDescription)")
                                        .font(FinderUI.detailFont.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
                        }


                        // Frequent actions sit under the name, one click away, as one
                        // centred group of equal buttons; Trash stands apart after a hairline.
                        HStack(spacing: 8) {
                            inspectorIconButton("Quick Look", icon: "eye") { appState.toggleQuickLook() }
                            inspectorIconButton("Share", icon: "square.and.arrow.up") { fileOps.showShareSheet(for: [item]) }
                            Menu {
                                Button("Copy Path", systemImage: "doc.on.doc") { fileOps.copyPaths([item]) }
                                Button("Open in Terminal", systemImage: "terminal") { fileOps.openInTerminal(at: item.url) }
                                Button("Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right") { fileOps.openInCodeEditor(at: item.url) }
                                Divider()
                                Button("Edit Permissions…", systemImage: "lock") { showChmodEditor = true }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            // The same chip as its neighbours; a menu label drops its own background.
                            .frame(width: 32, height: 28)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                            .help("More actions")
                            .accessibilityLabel("More actions")
                            // Same size as the routine actions, behind a hairline, its icon quieter.
                            Divider().frame(height: 18).padding(.horizontal, 4)
                            Button(role: .destructive) { fileOps.moveToTrash([item]) } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(FinderUI.metadataColor)
                            }
                            .buttonStyle(InspectorChipButtonStyle())
                            .help("Move to Trash")
                            .accessibilityLabel("Move to Trash")
                        }
                        .frame(maxWidth: .infinity, alignment: preparedPreviewImage != nil ? .center : .leading)

                        Divider()

                        // Metadata + Interactive chmod Permissions
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Details")
                                .font(FinderUI.detailFont.weight(.semibold))

                            metadataRow(
                                label: "Size",
                                value: item.isDirectory
                                    ? (folderSizes.displaySize(for: item.path) ?? folderSizes.statusText(for: item.path))
                                    : FormatHelpers.formatBytes(item.size)
                            )
                            if item.isDirectory && folderSizes.status(for: item.path) == .needsConsent {
                                Text("macOS protects this folder, so its size is calculated only when you ask. macOS may ask for permission once.")
                                    .font(FinderUI.captionFont)
                                Button("Calculate Size") { folderSizes.calculateProtected(item.path) }
                                FullDiskAccessLink()
                            } else if item.isDirectory && folderSizes.status(for: item.path) == .deferred {
                                Text("Active folder limit reached. Close other views and retry.")
                                    .font(FinderUI.captionFont)
                                Button("Retry Size") { updateFolderSizeDemand() }
                            } else if item.isDirectory, let result = folderSizes.result(for: item.path), !result.isComplete {
                                let leftOut = folderSizes.protectedFoldersLeftOut(of: item.path)
                                if !leftOut.isEmpty {
                                    Text("At least this much. Not counted: \(FolderSizeNames.list(leftOut)). macOS may ask for permission once to include them.")
                                        .font(FinderUI.captionFont)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button("Include Them") { folderSizes.includeProtectedFolders(of: item.path) }
                                    FullDiskAccessLink()
                                } else {
                                    Text(result.unreadableDirectoryCount > 0
                                        ? String(localized: "Lower bound: some directories could not be read.")
                                        : folderSizes.leftOutCloudFolders(of: item.path)
                                            ? String(localized: "Lower bound: cloud storage inside is not counted.")
                                            : result.skippedDirectoryCount > 0
                                                ? String(localized: "Lower bound: protected folders inside are not counted.")
                                                : String(localized: "Lower bound: the scan reached its limit."))
                                        .font(FinderUI.captionFont)
                                }
                            }
                            metadataRow(label: "Modified", value: FormatHelpers.formatDate(item.modificationDate))
                            CloudInspectorRow(item: item)

                            // The editable value has its own line so the narrow inspector stays readable.
                            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Permissions")
                                        .font(FinderUI.detailFont)
                                        .foregroundStyle(FinderUI.metadataColor)
                                    Spacer()
                                    // One line like the other rows; editing lives in the "…" menu.
                                    // The same size and colour as the other values; the octal
                                    // form is the quieter echo.
                                    permissionsText
                                        // Regular 12 pt mono matches the cap height of the 13 pt values.
                                        .font(.system(size: 12, design: .monospaced))
                                        .textSelection(.enabled)
                                    if showChmodEditor {
                                        Button("Done") { showChmodEditor = false }
                                            .font(FinderUI.detailFont)
                                            .buttonStyle(.link)
                                            .help("Close the permissions editor")
                                    }
                                }
                                if let permissionError {
                                    Text(permissionError)
                                        .font(FinderUI.detailFont)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            if showChmodEditor {
                                chmodEditorBox(for: item)
                            }

                            // The location gets the panel's full width on its own line.
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Where")
                                    .font(FinderUI.detailFont)
                                    .foregroundStyle(FinderUI.metadataColor)
                                // The enclosing folders by whole name; the full path is in the tooltip.
                                Button {
                                    _ = appState.activeTab.navigate(to: URL(fileURLWithPath: item.parentPath))
                                } label: {
                                    Label(Self.locationTrail(item.parentPath), systemImage: "folder")
                                        .font(FinderUI.detailFont)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                .buttonStyle(.borderless)
                                .help(item.parentPath)
                            }
                        }

                        Divider()

                        // Interactive macOS Color Tags Picker
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: FinderUI.rowSpacing) {
                                Text("Tags")
                                    .font(FinderUI.detailFont.weight(.semibold))
                                    .accessibilityAddTraits(.isHeader)
                                Spacer()
                                if !item.tags.isEmpty {
                                    Button("Clear") {
                                        fileOps.clearTags(for: [item])
                                        activeTab.reloadDirectory()
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .help("Remove all tags from this item")
                                }
                                // On the header line, like the sidebar's Favorites "+".
                                Menu {
                                    ForEach(FinderTagColor.allCases) { tagColor in
                                        Toggle(tagColor.displayName, isOn: Binding(
                                            get: { item.tags.contains(tagColor) },
                                            set: { _ in
                                                fileOps.toggleTag(tagColor, for: [item])
                                                activeTab.reloadDirectory()
                                            }
                                        ))
                                    }
                                } label: {
                                    Image(systemName: "plus")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Add or remove tags")
                                .accessibilityLabel("Edit tags")
                            }
                            HStack(spacing: 6) {
                                if item.tags.isEmpty {
                                    Text("No tags")
                                        .font(FinderUI.detailFont)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(item.tags) { tag in
                                    HStack(spacing: 4) {
                                        Circle().fill(tag.swiftUIColor).frame(width: 8, height: 8)
                                        Text(tag.displayName).font(FinderUI.detailFont)
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.06), in: Capsule())
                                }
                            }
                        }


                        // Checksums (SHA-256 & MD5) for Files
                        if !item.isDirectory {
                            Divider()
                            checksumsSection(for: item)
                        }

                        if item.isExtractableArchive {
                            inspectorActionButton(title: "Extract Archive Here", icon: "archivebox.fill") {
                                fileOps.extractArchive(item)
                            }
                        }
                    }
                    .padding(FinderUI.panelInset)
                }
                .onAppear {
                    loadPreviewAndMetadata(for: item)
                }
                .onChange(of: item.path) { _, _ in
                    cancelHashes()
                    loadPreviewAndMetadata(for: item)
                }
                .onChange(of: activeTab.id) { _, _ in
                    cancelHashes()
                    loadPreviewAndMetadata(for: item)
                }
                .onChange(of: activeTab.directoryRevision) { _, _ in
                    cancelHashes()
                    loadPreviewAndMetadata(for: item)
                }
                .onDisappear {
                    cancelPreview()
                    permissionReadOperation?.cancel()
                    permissionRequestID = UUID()
                    permissionSnapshot = nil
                    cancelHashes()
                }
            } else {
                // Current Folder Summary when no file is selected
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                                .resizable()
                                .frame(width: 42, height: 42)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activeTab.currentURL.path == "/" || activeTab.currentURL.lastPathComponent.isEmpty ? "Macintosh HD" : activeTab.currentURL.lastPathComponent)
                                    .font(FinderUI.titleFont)
                                Text("\(activeTab.displayedItems.count) items in view")
                                    .font(FinderUI.detailFont)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("Select a file or folder to see its preview and details.")
                            .font(FinderUI.detailFont)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        Text("Keyboard Shortcuts")
                            .font(FinderUI.detailFont.weight(.semibold))
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
                            shortcutHintRow(keys: "Cmd + F", desc: "Search with fsearch in the bar")
                            shortcutHintRow(keys: "Cmd + P", desc: "fsearch Spotlight window")
                            shortcutHintRow(keys: "Space", desc: "Native Quick Look preview")
                            shortcutHintRow(keys: "Cmd + Z", desc: "Undo file operation")
                            shortcutHintRow(keys: "Cmd + X / V", desc: "Cut and move files")
                            shortcutHintRow(keys: "Ctrl + `", desc: "Built-in Terminal panel at the bottom")
                            shortcutHintRow(keys: "Cmd + ,", desc: "fsearch index settings")
                            shortcutHintRow(keys: "Cmd + Shift + D", desc: "Dual-pane view")
                            shortcutHintRow(keys: "Cmd + L", desc: "Edit the address bar manually")
                        }
                    }
                    .padding(FinderUI.panelInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(FinderUI.sidebarSurface)
        .onAppear { updateFolderSizeDemand() }
        .onChange(of: folderSizeDemandPaths) { _, _ in updateFolderSizeDemand() }
        .onChange(of: activeTab.id) { _, _ in updateFolderSizeDemand() }
        .onChange(of: activeTab.directoryRevision) { _, _ in updateFolderSizeDemand() }
        .onDisappear { folderSizes.release(owner: folderSizeOwner) }
    }

    private var selectionSummary: some View {
        let items = activeTab.selectedItems
        let folders = items.filter(\.isDirectory)
        let observed = items.reduce((bytes: Int64(0), overflowed: false)) { total, item in
            let bytes = max(0, item.isDirectory ? (folderSizes.result(for: item.path)?.bytes ?? 0) : item.size)
            let (sum, overflow) = total.bytes.addingReportingOverflow(bytes)
            return (overflow ? Int64.max : sum, total.overflowed || overflow)
        }
        let knownBytes = observed.bytes
        let hasUnknownSize = observed.overflowed || folders.contains { folderSizes.size(for: $0.path) == nil }
        return VStack(alignment: .leading, spacing: FinderUI.sectionSpacing) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)
                .accessibilityHidden(true)
            Text("\(items.count) items selected")
                .font(FinderUI.titleFont)
            VStack(spacing: 10) {
                metadataRow(label: "Files", value: "\(items.count - folders.count)")
                metadataRow(label: "Folders", value: "\(folders.count)")
                metadataRow(label: "Size", value: "\(hasUnknownSize ? "≥ " : "")\(FormatHelpers.formatBytes(knownBytes))")
            }
            .font(FinderUI.detailFont)
            if folders.contains(where: { folderSizes.status(for: $0.path) == .deferred }) {
                Text("Partial total: active folder limit reached. Reduce the selection or close other views, then retry.")
                    .font(FinderUI.captionFont)
                Button("Retry Sizes") { updateFolderSizeDemand() }
            } else if hasUnknownSize {
                Text("The total is a lower bound; some folders are waiting to be scanned or could not be fully read.")
                    .font(FinderUI.captionFont)
            }
            Divider()
            VStack(spacing: FinderUI.rowSpacing) {
                inspectorAction("Preview Selection", icon: "eye") { appState.toggleQuickLook() }
                inspectorAction("Share…", icon: "square.and.arrow.up") { fileOps.showShareSheet(for: items) }
                inspectorAction("Copy Paths", icon: "link") { fileOps.copyPaths(items) }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(FinderUI.panelInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func inspectorAction(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .padding(.horizontal, FinderUI.compactSpacing)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    // MARK: - Interactive chmod Box

    private func chmodEditorBox(for item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
            Text("Preset Permissions")
                .font(FinderUI.detailFont.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: FinderUI.compactSpacing) {
                Button("644") { applyChmod(.ordinaryMode(0o644), for: item) }
                    .help("rw-r--r--: owner can write, everyone can read")
                Button("755") { applyChmod(.ordinaryMode(0o755), for: item) }
                    .help("rwxr-xr-x: owner can write, everyone can read and execute")
                Button("700") { applyChmod(.ordinaryMode(0o700), for: item) }
                    .help("rwx------: owner access only")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                chmodBitGroup(label: String(localized: "Owner"), rBit: 0o400, wBit: 0o200, xBit: 0o100, item: item)
                chmodBitGroup(label: String(localized: "Group"), rBit: 0o040, wBit: 0o020, xBit: 0o010, item: item)
                chmodBitGroup(label: String(localized: "Others"), rBit: 0o004, wBit: 0o002, xBit: 0o001, item: item)
            }
        }
        .padding(FinderUI.rowSpacing)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))
        .disabled(fileOps.isBusy || permissionSnapshot == nil)
        .help("Changes the regular permissions; keeps the current sticky, setuid and setgid bits")
    }

    private func chmodBitGroup(label: String, rBit: UInt16, wBit: UInt16, xBit: UInt16, item: FileItem) -> some View {
        HStack(spacing: FinderUI.rowSpacing) {
            Text(label)
                .font(FinderUI.detailFont)
                .foregroundStyle(.secondary)
            Spacer(minLength: FinderUI.compactSpacing)
            chmodBitButton("r", permission: String(localized: "Read"), group: label, bit: rBit, item: item)
            chmodBitButton("w", permission: String(localized: "Write"), group: label, bit: wBit, item: item)
            chmodBitButton("x", permission: String(localized: "Execute"), group: label, bit: xBit, item: item)
        }
    }

    private func chmodBitButton(_ title: String, permission: String, group: String, bit: UInt16, item: FileItem) -> some View {
        let isSet = (currentModeBits & bit) != 0
        return Button {
            applyChmod(.bit(bit, enabled: !isSet), for: item)
        } label: {
            Text(title)
                .font(FinderUI.detailFont.monospaced().weight(.semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(isSet ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: FinderUI.cornerRadius)
                        .fill(isSet ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FinderUI.cornerRadius)
                        .strokeBorder(isSet ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("\(group): \(permission.lowercased())")
        .accessibilityLabel("\(group): \(permission.lowercased())")
        .accessibilityValue(isSet ? String(localized: "Enabled") : String(localized: "Disabled"))
        .accessibilityAddTraits(isSet ? .isSelected : [])
    }

    private func applyChmod(_ change: PosixPermissionChange, for item: FileItem) {
        guard !activeTab.actionItems(for: item).isEmpty, let snapshot = permissionSnapshot else { return }
        let requestID = permissionRequestID
        let tabID = activeTab.id
        let revision = activeTab.directoryRevision
        permissionError = nil
        let accepted = fileOps.updatePosixPermissions(change, for: item, expectedIdentity: snapshot.identity) { updated, error in
            guard self.permissionRequestID == requestID, self.activeTab.id == tabID,
                  self.appState.activeTab.id == tabID,
                  self.activeTab.directoryRevision == revision,
                  self.activeTab.primarySelectedItem?.path == item.path else { return }
            self.permissionError = error
            if let updated {
                self.permissionSnapshot = updated
                self.currentModeBits = updated.mode
                self.posixPermissionsString = PosixPermissionChange.format(updated.mode)
            }
        }
        if !accepted { permissionError = fileOps.lastStatusMessage ?? String(localized: "Another operation is in progress.") }
    }

    private func loadPermissions(for item: FileItem) {
        permissionReadOperation?.cancel()
        permissionRequestID = UUID()
        let requestID = permissionRequestID
        let tabID = activeTab.id
        let revision = activeTab.directoryRevision
        permissionSnapshot = nil
        permissionError = nil
        currentModeBits = 0
        posixPermissionsString = String(localized: "Reading…")
        let operation = BlockOperation {
            var snapshot: PosixPermissionSnapshot?
            var failure: String?
            do { snapshot = try PosixPermissionSnapshot.read(item.url) }
            catch { failure = error.localizedDescription }
            let result = snapshot
            let error = failure
            Task { @MainActor in
                guard self.permissionRequestID == requestID, self.activeTab.id == tabID,
                  self.appState.activeTab.id == tabID,
                      self.activeTab.directoryRevision == revision,
                      self.activeTab.primarySelectedItem?.path == item.path else { return }
                self.permissionSnapshot = result
                self.permissionError = error
                self.currentModeBits = result?.mode ?? 0
                self.posixPermissionsString = result.map { PosixPermissionChange.format($0.mode) } ?? "—"
            }
        }
        permissionReadOperation = operation
        Self.permissionMetadataQueue.addOperation(operation)
    }

    // MARK: - Checksums Section (SHA-256 / MD5)

    private func cancelHashes() {
        hashRequest?.cancel()
        hashRequest = nil
        hashRequestID = UUID()
        isComputingHash = false
        sha256Hash = nil
        md5Hash = nil
        hashErrorMessage = nil
    }

    private func startHashes(for item: FileItem) {
        cancelHashes()
        isComputingHash = true
        let context = FileChecksumPublicationContext(requestID: hashRequestID, paneID: activeTab.id,
                                                     revision: activeTab.directoryRevision, path: item.path)
        hashRequest = FileChecksumService.shared.start(for: item.url) { result in
            guard context.canPublish(currentRequestID: self.hashRequestID,
                                     activePaneID: self.appState.activeTab.id,
                                     sourceRevision: self.activeTab.directoryRevision,
                                     selectedPath: self.activeTab.primarySelectedItem?.path) else { return }
            self.hashRequest = nil
            self.isComputingHash = false
            switch result {
            case .success(let digest):
                self.sha256Hash = digest.sha256
                self.md5Hash = digest.md5
                self.hashErrorMessage = nil
            case .failure(let error):
                self.hashErrorMessage = error.localizedDescription
            }
        }
    }

    private func checksumsSection(for item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // One quiet row, like the details above: the least-used action stays the lightest.
            HStack(spacing: FinderUI.rowSpacing) {
                // A section header like Details and Tags, its action on the same line.
                Text("Checksums")
                    .font(FinderUI.detailFont.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if sha256Hash == nil {
                    if isComputingHash {
                        ProgressView().controlSize(.mini)
                        Button("Cancel") { cancelHashes() }
                            .buttonStyle(.link)
                            .font(FinderUI.detailFont)
                            .help("Cancel Calculation")
                    } else {
                        Button(hashErrorMessage == nil ? String(localized: "Calculate") : String(localized: "Try Again")) {
                            startHashes(for: item)
                        }
                        .buttonStyle(.link)
                        .font(FinderUI.detailFont)
                        .help("Calculate SHA-256 and MD5")
                        .accessibilityLabel("Calculate SHA-256 and MD5 checksums")
                    }
                }
            }

            if let message = hashErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(FinderUI.detailFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let sha = sha256Hash {
                hashDisplayRow(label: "SHA-256", value: sha)
            }
            if let md5 = md5Hash {
                hashDisplayRow(label: "MD5", value: md5)
            }
        }
    }

    private func hashDisplayRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(FinderUI.detailFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    fileOps.lastStatusMessage = String(localized: "Copied \(label): \(String(value.prefix(16)))...")
                }
                .font(FinderUI.detailFont)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Copy \(label) checksum")
                .accessibilityLabel("Copy \(label) checksum")
            }
            Text(value)
                .font(FinderUI.detailFont.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))
        }
    }

    @ViewBuilder
    private func livePreviewBox(for item: FileItem) -> some View {
        if isPreparingPreview {
            ProgressView("Preparing preview…")
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(FinderUI.rowSpacing)
        } else if let nsImg = preparedPreviewImage {
            VStack(spacing: 4) {
                // Sized to the picture itself, so the rounded edge hugs the image.
                let aspect = nsImg.size.height > 0 ? nsImg.size.width / nsImg.size.height : 1
                let height = min(180, 264 / max(aspect, 0.01))
                Image(nsImage: nsImg)
                    .resizable()
                    .scaledToFit()
                    .frame(width: height * aspect, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .accessibilityLabel("Preview: \(item.name)")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, FinderUI.compactSpacing)
        } else if !textPreviewLines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                    Text("Content Preview")
                        .font(FinderUI.detailFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    if let grep = item.grepMatch {
                        Text("Match on line \(grep.lineNumber)")
                            .font(FinderUI.detailFont.monospaced().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 1.5) {
                        ForEach(textPreviewLines, id: \.0) { lineNo, text in
                            let isMatchedLine = (item.grepMatch?.lineNumber == lineNo)
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(lineNo)")
                                    .font(FinderUI.detailFont.monospaced())
                                    .foregroundStyle(isMatchedLine ? Color.accentColor : .secondary)
                                    .frame(width: 28, alignment: .trailing)
                                Text(text.isEmpty ? " " : text)
                                    .font(FinderUI.detailFont.monospaced())
                                    .foregroundStyle(isMatchedLine ? Color.primary : Color.primary.opacity(0.85))
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isMatchedLine ? Color.accentColor.opacity(0.22) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 3)
                            )
                        }
                    }
                    .padding(6)
                }
                .frame(height: 185)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: FinderUI.cornerRadius).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            }
        } else if !item.isDirectory {
            VStack(alignment: .leading, spacing: FinderUI.rowSpacing) {
                Label(previewMessage ?? String(localized: "Content preview isn’t available. Try Quick Look."), systemImage: "doc.text.magnifyingglass")
                    .font(FinderUI.detailFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FinderUI.rowSpacing)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: FinderUI.cornerRadius))
                Button("Retry Preview") {
                    // Retry only preview preparation, never checksum or permissions.
                    let livePane = appState.activeTab
                    guard livePane.id == activeTab.id,
                          let selected = livePane.primarySelectedItem,
                          selected.path == item.path else { return }
                    startPreview(for: selected)
                }
                .font(FinderUI.detailFont)
            }
        }
    }

    private func metadataRow(label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .top, spacing: FinderUI.rowSpacing) {
            Text(label)
                .font(FinderUI.detailFont)
                .foregroundStyle(FinderUI.metadataColor)
            Spacer()
            Text(value)
                .font(FinderUI.detailFont)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func shortcutHintRow(keys: LocalizedStringKey, desc: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
            Text(keys)
                .font(FinderUI.detailFont.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            Text(desc)
                .font(FinderUI.detailFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inspectorIconButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .buttonStyle(InspectorChipButtonStyle())
        .help(title)
        .accessibilityLabel(title)
    }

    private func inspectorActionButton(
        title: LocalizedStringKey,
        icon: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            Label(title, systemImage: icon)
                .font(FinderUI.detailFont)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(title)
        .accessibilityLabel(title)
    }

    private func loadPreviewAndMetadata(for item: FileItem) {
        loadPermissions(for: item)

        startPreview(for: item)
    }

    private func cancelPreview() {
        previewRequest?.cancel()
        previewRequest = nil
        previewRequestID = UUID()
        preparedPreviewImage = nil
        textPreviewLines = []
        previewMessage = nil
        isPreparingPreview = false
    }

    private func startPreview(for item: FileItem) {
        cancelPreview()
        guard !item.isDirectory else { return }
        isPreparingPreview = true
        // Reuse the tested request/live-owner/revision/path publication fence.
        let context = FileChecksumPublicationContext(requestID: previewRequestID, paneID: activeTab.id,
                                                     revision: activeTab.directoryRevision, path: item.path)
        let input = InspectorPreviewInput(url: item.url, isImage: item.kindCategory == .image,
                                          targetLine: item.grepMatch?.lineNumber ?? 1)
        previewRequest = InspectorPreviewService.shared.start(input) { result in
            guard context.canPublish(currentRequestID: self.previewRequestID,
                                     activePaneID: self.appState.activeTab.id,
                                     sourceRevision: self.activeTab.directoryRevision,
                                     selectedPath: self.activeTab.primarySelectedItem?.path) else { return }
            self.previewRequest = nil
            self.isPreparingPreview = false
            switch result {
            case .image(let image, let width, let height):
                self.preparedPreviewImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                self.previewPixelWidth = width
                self.previewPixelHeight = height
            case .text(let lines): self.textPreviewLines = lines
            case .unavailable(let message): self.previewMessage = message
            }
        }
    }


}

/// Explains Full Disk Access, with which every folder size is automatic.
private struct FullDiskAccessLink: View {
    var body: some View {
        Button("Allow Full Disk Access…") { AppState.shared.showFullDiskAccessSheet = true }
        .buttonStyle(.link)
        .font(FinderUI.captionFont)
        .help("With Full Disk Access, Burrow calculates every folder size automatically.")
    }
}

/// Folder names as Finder shows them (“Desktop”, localized), joined for a sentence.
enum FolderSizeNames {
    static func list(_ paths: [String]) -> String {
        let names = paths.map { FileManager.default.displayName(atPath: $0) }
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return ListFormatter.localizedString(byJoining: unique)
    }
}

/// The inspector's quick actions: light square chips instead of bordered pills,
/// so they stay quieter than the preview and the name above them.
struct InspectorChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .frame(width: 32, height: 28)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
