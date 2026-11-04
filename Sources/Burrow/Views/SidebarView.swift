import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct SidebarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState
    @StateObject private var dropLoad = FileDropLoadController()
    @ObservedObject private var cloud = CloudActivity.shared
    @Environment(\.controlActiveState) private var controlActiveState

    @ViewState private var dropTargetedPath: String? = nil
    @ViewState private var isPinDropTargeted = false
    @ViewState private var isFavoriteEndTargeted = false
    @ViewState private var areTagsExpanded = true
    @ViewState private var expandedServers: Set<String> = []
    @ViewState private var draggedFavoriteID: String? = nil
    @ViewState private var favoriteDragNonce: UUID? = nil
    @ViewState private var renamingFavorite: SidebarLocationItem? = nil
    @ViewState private var favoriteTitle = ""
    @ViewState private var favoriteOpenNotice: String?
    // An undeclared custom UTType is rejected at drop time; plain text plus the
    // per-drag nonce check below keeps foreign text drags from reordering.
    private let favoriteDragType = UTType.utf8PlainText

    #if BURROW_TESTING
    @Environment(\.sidebarPreviewExpandedServerIDs) private var previewExpandedServerIDs
    @Environment(\.sidebarPreviewTagsExpanded) private var previewTagsExpanded
    #endif

    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState
        self.activeTab = activeTab
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    favoritesSection
                    favoriteSectionSpacing
                    placesSection
                    cloudSection
                    tagsSection.padding(.top, FinderUI.sidebarSectionGap)
                }
                .padding(.horizontal, FinderUI.sidebarInset)
                .padding(.top, FinderUI.chromeInset)
                .padding(.bottom, FinderUI.panelInset)
            }

            FileDropLoadingStatusView(controller: dropLoad)
            Divider()
            indexFooter
        }
        .font(FinderUI.bodyFont)
        .accessibilityLabel("Sidebar")
        .onDisappear { dropLoad.cancel(); draggedFavoriteID = nil; favoriteDragNonce = nil }
        .alert("Favorite Name", isPresented: Binding(
            get: { renamingFavorite != nil },
            set: { if !$0 { renamingFavorite = nil } }
        )) {
            TextField("Name", text: $favoriteTitle)
            Button("Cancel", role: .cancel) { renamingFavorite = nil }
            Button("Save") {
                if let item = renamingFavorite { appState.renameFavorite(item, title: favoriteTitle) }
                renamingFavorite = nil
            }
            .disabled(favoriteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("This only changes the name in the sidebar, not the name of the folder on disk.")
        }
    }

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
            sidebarSectionHeader("Locations")
            if let notice = appState.volumeInventory.notice {
                Text(notice)
                    .font(FinderUI.detailFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, FinderUI.rowSpacing)
            }
            if appState.volumeInventory.canShowEmpty {
                Text("No volumes available")
                    .font(FinderUI.detailFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, FinderUI.rowSpacing)
            } else {
                ForEach(appState.localMountedVolumes) { volume in
                    volumeRow(volume)
                }
                ForEach(appState.networkServerGroups) { server in
                    if server.isServerKnown {
                        networkServerRow(server)
                    } else {
                        ForEach(server.volumes) { volume in
                            volumeRow(volume)
                                .help("Network share. The server could not be determined.")
                        }
                    }
                }
            }
        }
    }

    /// iCloud Drive and File Provider accounts (Google Drive, OneDrive,
    /// Dropbox…), found in ~/Library/CloudStorage.
    @ViewBuilder
    private var cloudSection: some View {
        if !cloud.locations.isEmpty {
            VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
                sidebarSectionHeader("Cloud")
                ForEach(cloud.locations) { location in
                    cloudRow(location)
                }
            }
            .padding(.top, FinderUI.sidebarSectionGap)
        }
    }

    private func cloudRow(_ location: CloudFiles.Location) -> some View {
        let isSelected = isLocationSelected(location.url)
        return Button {
            navigate(to: location.url)
        } label: {
            HStack(spacing: FinderUI.rowSpacing) {
                Group {
                    if let icon = cloud.icon(for: location) {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: location.provider == "iCloud Drive" ? "icloud" : "cloud")
                            .foregroundStyle(isSelected ? selectedTextColor : Color.secondary)
                    }
                }
                .frame(width: FinderUI.sidebarIconWidth)
                .accessibilityHidden(true)
                Text(location.title)
                    .lineLimit(1)
                // The account matters only when one provider has several.
                if let account = location.account,
                   cloud.locations.filter({ $0.provider == location.provider }).count > 1 {
                    Text(account)
                        .font(FinderUI.captionFont)
                        .foregroundStyle(isSelected ? selectedTextColor.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? selectedTextColor : Color.primary)
            .padding(.leading, FinderUI.sidebarRowInset)
            .frame(minHeight: FinderUI.sidebarRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(rowBackground(isSelected: isSelected))
        .help(location.account.map { "\(location.provider) – \($0)" } ?? location.provider)
        .accessibilityLabel(location.account.map { "\(location.title), \($0)" } ?? location.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var tagsAreExpanded: Bool {
        #if BURROW_TESTING
        if let previewTagsExpanded { return previewTagsExpanded }
        #endif
        return areTagsExpanded
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
            Button { areTagsExpanded.toggle() } label: {
                HStack {
                    Text("Tags").font(FinderUI.captionFont.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: tagsAreExpanded ? "chevron.down" : "chevron.right")
                        .font(FinderUI.captionFont.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, FinderUI.sidebarRowInset)
                .frame(minHeight: FinderUI.sidebarRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tags")
            .accessibilityValue(tagsAreExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            .accessibilityHint("Show or hide the seven tag colors")
            if tagsAreExpanded {
                ForEach(FinderTagColor.allCases) { tagColor in tagRow(tagColor) }
            }
        }
    }

    // The append target occupies the existing section gap, not an extra row.
    private var favoriteSectionSpacing: some View {
        ZStack {
            Color.clear
            if !appState.favorites.isEmpty {
                Rectangle()
                    .fill(isFavoriteEndTargeted ? Color.accentColor : Color.clear)
                    .frame(height: 2)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
                    .onDrop(of: [favoriteDragType], isTargeted: $isFavoriteEndTargeted) { providers in
                        reorderFavorite(providers: providers, beforeID: nil)
                    }
            }
        }
        .frame(height: FinderUI.sidebarSectionGap)
        .accessibilityHidden(true)
    }

    private func isServerExpanded(_ serverID: String) -> Bool {
        #if BURROW_TESTING
        if previewExpandedServerIDs.contains(serverID) { return true }
        #endif
        return expandedServers.contains(serverID)
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
            HStack(spacing: FinderUI.compactSpacing) {
                sidebarSectionHeader("Favorites")
                Spacer(minLength: 0)
                Menu {
                    Button("Add Current Folder", systemImage: "folder.badge.plus") {
                        appState.addBookmark(for: activeTab.currentURL)
                    }
                    .disabled(appState.favorites.contains { $0.url.path == activeTab.currentURL.path })
                    Button("Choose Folder…", systemImage: "folder") { chooseFavoriteFolder() }
                } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(appState.pinnedFolderNotice != nil)
                .help("Add folder to Favorites")
                .accessibilityLabel("Add folder to Favorites")
            }
            if let notice = appState.pinnedFolderNotice {
                Text(notice)
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, FinderUI.sidebarRowInset)
            }
            if let notice = favoriteOpenNotice {
                Text(notice)
                    .font(FinderUI.detailFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, FinderUI.sidebarRowInset)
            }
            ForEach(appState.favorites) { item in sidebarLocationRow(item) }
            if appState.favorites.isEmpty && appState.pinnedFolderNotice == nil {
                Button(action: chooseFavoriteFolder) {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, FinderUI.sidebarRowInset)
                        .frame(maxWidth: .infinity, minHeight: FinderUI.sidebarRowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(isSelected: false, isDropTarget: isPinDropTargeted))
        .onDrop(of: [.fileURL], isTargeted: $isPinDropTargeted) { providers in
            handlePinFolderDrop(providers: providers)
        }
    }

    private func reorderFavorite(providers: [NSItemProvider], beforeID: String?) -> Bool {
        guard providers.count == 1,
              providers[0].hasItemConformingToTypeIdentifier(favoriteDragType.identifier),
              let sourceID = draggedFavoriteID, let nonce = favoriteDragNonce,
              sourceID != beforeID, appState.pinnedFolderNotice == nil else { return false }
        // Consume the local drag session before asynchronous loading. A foreign
        // advertised type alone can never reorder a row left from a cancelled drag.
        draggedFavoriteID = nil
        favoriteDragNonce = nil
        let expected = Data("\(nonce.uuidString)\n\(sourceID)".utf8)
        providers[0].loadDataRepresentation(forTypeIdentifier: favoriteDragType.identifier) { data, error in
            guard error == nil, let data, data.count == expected.count, data == expected else { return }
            Task { @MainActor in
                guard appState.pinnedFolderNotice == nil,
                      appState.favorites.contains(where: { $0.id == sourceID }),
                      beforeID == nil || appState.favorites.contains(where: { $0.id == beforeID }) else { return }
                appState.moveFavorite(id: sourceID, beforeID: beforeID)
            }
        }
        return true
    }

    private func chooseFavoriteFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add to Favorites")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in appState.addBookmark(for: url) }
        }
    }

    private func tagRow(_ tagColor: FinderTagColor) -> some View {
        let query = "tag:\(tagColor.rawValue)"
        let isSelected = isSearchSelected(query)

        return Button {
            runSearch(query)
        } label: {
            HStack(spacing: FinderUI.rowSpacing) {
                Circle()
                    .fill(tagColor.swiftUIColor)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    .frame(width: 10, height: 10)
                    .frame(width: FinderUI.sidebarIconWidth)
                    .accessibilityHidden(true)
                Text(tagColor.displayName)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? selectedTextColor : Color.primary)
            .padding(.horizontal, FinderUI.sidebarRowInset)
            .frame(minHeight: FinderUI.sidebarRowHeight)
            .background(rowBackground(isSelected: isSelected))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show files with tag: \(tagColor.displayName)")
        .accessibilityLabel("Tag: \(tagColor.displayName)")
        .accessibilityHint("Searches the whole index for files with this tag")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // Keep the row's result builders and drag closures separately type-checked.
    // This preserves the native view/modifier structure without type erasure.
    private func sidebarLocationRow(_ item: SidebarLocationItem) -> some View {
        let isTrash = SystemTrashNavigation.isSystemTrash(item.url, systemTrashURL: appState.systemTrashURL)
        let isSelected = !isTrash && isLocationSelected(item.url)
        let isDropTarget = dropTargetedPath == item.url.path

        return favoriteAccessibleButton(item, isTrash: isTrash, isSelected: isSelected, isDropTarget: isDropTarget)
            .contextMenu { favoriteContextMenu(item, isTrash: isTrash) }
            .onDrag { favoriteDragProvider(for: item) }
            .onDrop(of: [.fileURL, favoriteDragType], isTargeted: favoriteDropTarget(for: item)) { providers in
                receiveFavoriteDrop(providers, item: item, isTrash: isTrash)
            }
    }

    private func favoriteAccessibleButton(_ item: SidebarLocationItem, isTrash: Bool,
                                          isSelected: Bool, isDropTarget: Bool) -> some View {
        // A Button tracks the mouse itself, so .onDrag never starts and favorites
        // could not be reordered by dragging. A tap gesture keeps both working.
        favoriteRowLabel(item, isSelected: isSelected, isDropTarget: isDropTarget)
        .onTapGesture { openFavorite(item.url) }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openFavorite(item.url) }
        .help(isTrash ? String(localized: "Open Trash in Finder") : item.url.path)
        .accessibilityLabel(item.title)
        .accessibilityValue(isSelected ? String(localized: "Current folder: \(item.url.path)") : item.url.path)
        .accessibilityHint(isTrash ? String(localized: "Opens the Trash in Finder. The context menu lets you reorder or remove it from Favorites.") : String(localized: "Opens the folder. The context menu lets you reorder or remove it from Favorites. Dragging files moves them into the folder; Option copies."))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Move Up")) { appState.moveFavorite(item, by: -1) }
        .accessibilityAction(named: Text("Move Down")) { appState.moveFavorite(item, by: 1) }
        .accessibilityAction(named: Text("Remove from Favorites")) { appState.removeBookmark(item) }
    }

    private func favoriteRowLabel(_ item: SidebarLocationItem, isSelected: Bool, isDropTarget: Bool) -> some View {
        HStack(spacing: FinderUI.rowSpacing) {
            Image(systemName: locationIcon(for: item))
                .foregroundStyle(isSelected ? selectedTextColor : Color.accentColor)
                .frame(width: FinderUI.sidebarIconWidth)
                .accessibilityHidden(true)
            Text(item.title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? selectedTextColor : Color.primary)
        .padding(.horizontal, FinderUI.sidebarRowInset)
        .frame(minHeight: FinderUI.sidebarRowHeight)
        .background(rowBackground(isSelected: isSelected, isDropTarget: isDropTarget && favoriteDragNonce == nil))
        .overlay(alignment: .top) {
            if isDropTarget && favoriteDragNonce != nil {
                Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func favoriteContextMenu(_ item: SidebarLocationItem, isTrash: Bool) -> some View {
        favoriteNavigationMenu(item, isTrash: isTrash)
        Divider()
        favoriteEditingMenu(item)
    }

    @ViewBuilder
    private func favoriteNavigationMenu(_ item: SidebarLocationItem, isTrash: Bool) -> some View {
        if !isTrash {
            Button {
                appState.addNewTab(at: item.url)
            } label: {
                Label("Open in New Tab", systemImage: "plus.square.on.square")
            }
        }
        Button {
            if isTrash { openFavorite(item.url) }
            else { NSWorkspace.shared.open(item.url) }
        } label: {
            Label(isTrash ? String(localized: "Open Trash in Finder") : String(localized: "Open in Finder"), systemImage: isTrash ? "trash" : "folder")
        }
        Button {
            FileOperationsManager.shared.copyPathString(item.url.path)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
    }

    @ViewBuilder
    private func favoriteEditingMenu(_ item: SidebarLocationItem) -> some View {
        Button("Rename in Favorites…", systemImage: "pencil") {
            favoriteTitle = item.title
            renamingFavorite = item
        }
        .disabled(appState.pinnedFolderNotice != nil)
        Menu {
            ForEach(Self.favoriteIconChoices, id: \.symbol) { choice in
                Button {
                    appState.setFavoriteIcon(item, iconName: choice.symbol)
                } label: {
                    Label(choice.title, systemImage: choice.symbol)
                }
            }
        } label: {
            Label("Change Icon", systemImage: "paintbrush")
        }
        .disabled(appState.pinnedFolderNotice != nil)
        Button("Move Up", systemImage: "arrow.up") {
            appState.moveFavorite(item, by: -1)
        }
        .disabled(appState.pinnedFolderNotice != nil || appState.favorites.first?.id == item.id)
        Button("Move Down", systemImage: "arrow.down") {
            appState.moveFavorite(item, by: 1)
        }
        .disabled(appState.pinnedFolderNotice != nil || appState.favorites.last?.id == item.id)
        Button("Remove from Favorites", systemImage: "minus.circle") {
            appState.removeBookmark(item)
        }
        .disabled(appState.pinnedFolderNotice != nil)
    }

    private func favoriteDragProvider(for item: SidebarLocationItem) -> NSItemProvider {
        let nonce = UUID()
        draggedFavoriteID = appState.pinnedFolderNotice == nil ? item.id : nil
        favoriteDragNonce = appState.pinnedFolderNotice == nil ? nonce : nil
        let data = Data("\(nonce.uuidString)\n\(item.id)".utf8)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: favoriteDragType.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func favoriteDropTarget(for item: SidebarLocationItem) -> Binding<Bool> {
        Binding(
            get: { dropTargetedPath == item.url.path },
            set: { targeted in
                if targeted {
                    dropTargetedPath = item.url.path
                } else if dropTargetedPath == item.url.path {
                    dropTargetedPath = nil
                }
            }
        )
    }

    private func receiveFavoriteDrop(_ providers: [NSItemProvider], item: SidebarLocationItem, isTrash: Bool) -> Bool {
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(favoriteDragType.identifier) }) {
            return reorderFavorite(providers: providers, beforeID: item.id)
        }
        guard !isTrash else { return false }
        return handleDropFiles(providers: providers, into: item.url)
    }

    private func networkServerRow(_ server: NetworkVolumeGroup) -> some View {
        let expanded = isServerExpanded(server.id)
        return VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
            Button {
                if expanded { expandedServers.remove(server.id) }
                else { expandedServers.insert(server.id) }
            } label: {
                HStack(spacing: FinderUI.rowSpacing) {
                    Image(systemName: "server.rack")
                        .frame(width: FinderUI.sidebarIconWidth)
                        .foregroundStyle(.secondary)
                    Text(server.title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(FinderUI.captionFont.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, FinderUI.sidebarRowInset)
                .frame(minHeight: FinderUI.sidebarRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(server.title) · mounted shares: \(server.volumes.count)")
            .accessibilityLabel("Server \(server.title), \(server.volumes.count) shares")
            .accessibilityValue(expanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
            .accessibilityHint("Show or hide the mounted shares of this server")
            if expanded {
                ForEach(server.volumes) { volume in volumeRow(volume) }
                    .padding(.leading, FinderUI.panelInset)
            }
        }
    }

    private func volumeRow(_ volume: VolumeInfoItem) -> some View {
        let isSelected = isLocationSelected(volume.url)

        return VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
            HStack(spacing: FinderUI.sidebarRowGap) {
                Button {
                    navigate(to: volume.url)
                } label: {
                    HStack(spacing: FinderUI.rowSpacing) {
                        Image(systemName: volume.isNetwork ? "folder" : (volume.isRemovable ? "externaldrive" : "internaldrive"))
                            .foregroundStyle(isSelected ? selectedTextColor : Color.secondary)
                            .frame(width: FinderUI.sidebarIconWidth)
                            .accessibilityHidden(true)
                        Text(volume.name)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(isSelected ? selectedTextColor : Color.primary)
                    .padding(.leading, FinderUI.sidebarRowInset)
                    .frame(minHeight: FinderUI.sidebarRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(volume.url.path)
                .accessibilityLabel(volume.name)
                .accessibilityValue(isSelected ? String(localized: "Current folder: \(volume.url.path)") : volume.url.path)
                .accessibilityAddTraits(isSelected ? .isSelected : [])

                if volume.isRemovable {
                    sidebarActionButton(icon: "eject", label: "Eject volume \(volume.name)") {
                        appState.ejectVolume(volume)
                    }
                    .disabled(appState.ejectingVolumePaths.contains(volume.url.path))
                    .foregroundStyle(isSelected ? selectedTextColor : Color.secondary)
                }
            }
            .padding(.trailing, 4)
            .background(rowBackground(isSelected: isSelected))

            if !volume.isNetwork, let totalBytes = volume.totalBytes, let freeBytes = volume.freeBytes,
               let usedFraction = volume.usedFraction {
                // Compact capacity line: a thin bar with the free space beside it, aligned to the name.
                HStack(spacing: 8) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.2))
                            Capsule()
                                .fill(usedFraction > 0.9 ? Color.orange : Color.accentColor.opacity(0.85))
                                .frame(width: max(3, geometry.size.width * min(1, max(0, usedFraction))))
                        }
                    }
                    .frame(height: 4)
                    .accessibilityElement()
                    .accessibilityLabel("Used space on \(volume.name)")
                    .accessibilityValue("\(Int(usedFraction * 100)) percent")
                    Text("\(FormatHelpers.formatBytes(freeBytes)) free")
                        .font(FinderUI.captionFont)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.leading, FinderUI.sidebarRowInset + FinderUI.sidebarIconWidth + FinderUI.rowSpacing)
                .padding(.trailing, FinderUI.sidebarRowInset)
                .padding(.top, -2)
                .padding(.bottom, 4)
                .help("\(FormatHelpers.formatBytes(freeBytes)) free of \(FormatHelpers.formatBytes(totalBytes))")
            }
        }
    }

    private func sidebarSectionHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(FinderUI.captionFont.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, FinderUI.sidebarRowInset)
            .frame(height: 24, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func sidebarActionButton(icon: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private var selectedTextColor: Color {
        Color(nsColor: controlActiveState == .inactive ? .unemphasizedSelectedTextColor : .alternateSelectedControlTextColor)
    }

    private func rowBackground(isSelected: Bool, isDropTarget: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: FinderUI.cornerRadius)
            .fill(isSelected
                ? Color(nsColor: controlActiveState == .inactive ? .unemphasizedSelectedContentBackgroundColor : .selectedContentBackgroundColor)
                : (isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear))
            .overlay {
                RoundedRectangle(cornerRadius: FinderUI.cornerRadius)
                    .strokeBorder(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
            }
    }

    /// Icons a user can pick for any favorite; none of them is reserved for a specific folder.
    static let favoriteIconChoices: [(title: String, symbol: String)] = [
        (String(localized: "Folder"), "folder"), (String(localized: "Home"), "house"), (String(localized: "Desktop"), "desktopcomputer"),
        (String(localized: "Documents"), "doc"), (String(localized: "Downloads"), "arrow.down.circle"), (String(localized: "Cloud"), "icloud"),
        (String(localized: "Projects"), "hammer"), (String(localized: "Code"), "chevron.left.forwardslash.chevron.right"), (String(localized: "Terminal"), "terminal"),
        (String(localized: "Images"), "photo"), (String(localized: "Music"), "music.note"), (String(localized: "Movies"), "film"),
        (String(localized: "Archive"), "archivebox"), (String(localized: "Work"), "briefcase"), (String(localized: "Books"), "book"),
        (String(localized: "Star"), "star"), (String(localized: "Heart"), "heart"), (String(localized: "Flag"), "flag"),
        (String(localized: "Disk"), "externaldrive"), (String(localized: "Network"), "network"), (String(localized: "Applications"), "app"), (String(localized: "Trash"), "trash")
    ]

    private func locationIcon(for item: SidebarLocationItem) -> String {
        switch item.iconName {
        case "menubar.dock.rectangle": return "desktopcomputer"
        case "sparkles.rectangle.stack.fill", "bookmark.fill": return "folder"
        case "app.badge.fill": return "app"
        default: return item.iconName.replacingOccurrences(of: ".fill", with: "")
        }
    }

    private func isLocationSelected(_ url: URL) -> Bool {
        activeTab.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && activeTab.currentURL.standardizedFileURL.path == url.standardizedFileURL.path
    }

    private func isSearchSelected(_ query: String) -> Bool {
        activeTab.searchScope == .wholeIndex
            && activeTab.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
    }

    private func openFavorite(_ url: URL) {
        favoriteOpenNotice = nil
        let outcome = SystemTrashNavigation.open(url, systemTrashURL: appState.systemTrashURL,
            openInFinder: { NSWorkspace.shared.open($0) }, navigate: { navigate(to: $0) })
        if outcome == .failedToOpenFinder {
            favoriteOpenNotice = String(localized: "Could not open the Trash in Finder. Open it from the Dock. The current folder was not changed.")
        }
    }

    private func navigate(to url: URL) {
        activeTab.navigate(to: url, clearSearch: true)
    }

    private func runSearch(_ query: String) {
        if activeTab.viewMode == .wiztree {
            activeTab.viewMode = .list
        }
        activeTab.searchScope = .wholeIndex
        activeTab.searchQuery = query
        activeTab.triggerSearch()
    }

    private func handleDropFiles(providers: [NSItemProvider], into destinationURL: URL) -> Bool {
        guard FileDropLoader.accepts(providers) else { return false }
        let copyInstead = NSEvent.modifierFlags.contains(.option)
        dropLoad.begin(providers: providers, destination: destinationURL) { urls in
            FileOperationsManager.shared.handleDropURLs(urls, into: destinationURL, copyInsteadOfMove: copyInstead)
        }
        return true
    }

    private func handlePinFolderDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    appState.addBookmark(for: url)
                }
            }
        }
        return true
    }

    private var indexFooter: some View {
        VStack(alignment: .leading, spacing: FinderUI.sidebarRowGap) {
            HStack(spacing: FinderUI.sidebarRowGap) {
                Text("File Index")
                    .font(FinderUI.detailFont.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                sidebarActionButton(icon: "gearshape", label: "Search and app settings") {
                    appState.showSettingsSheet = true
                }
                sidebarActionButton(icon: "arrow.clockwise", label: "Rebuild search index") {
                    FSearchIndex.shared.startIndexing()
                }
                .disabled(appState.isIndexing)
            }
            if appState.isIndexing {
                HStack(spacing: FinderUI.rowSpacing) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Indexing…")
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Indexing files")
            }
            Text("\(appState.indexedFileCount.formatted()) files in index")
                .font(FinderUI.detailFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(appState.indexBuildDurationMs > 0
                    ? String(localized: "Last indexing: \(FormatHelpers.formatLatency(appState.indexBuildDurationMs))")
                    : String(localized: "Number of files available for search"))
        }
        .padding(.leading, FinderUI.sidebarInset + FinderUI.sidebarRowInset)
        .padding(.trailing, FinderUI.sidebarInset)
        .padding(.vertical, FinderUI.chromeInset)
    }
}

#if BURROW_TESTING
// Explicit presentation fixtures only. These keys do not simulate interaction,
// mutate persistence, discover volumes, or exist in the production binary.
private struct SidebarPreviewExpandedServerIDsKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}
private struct SidebarPreviewTagsExpandedKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}
extension EnvironmentValues {
    var sidebarPreviewExpandedServerIDs: Set<String> {
        get { self[SidebarPreviewExpandedServerIDsKey.self] }
        set { self[SidebarPreviewExpandedServerIDsKey.self] = newValue }
    }
    var sidebarPreviewTagsExpanded: Bool? {
        get { self[SidebarPreviewTagsExpandedKey.self] }
        set { self[SidebarPreviewTagsExpandedKey.self] = newValue }
    }
}
#endif
