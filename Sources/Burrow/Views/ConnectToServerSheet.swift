import SwiftUI
import AppKit

/// Go › Connect to Server (⌘K), as in Finder: type an address or pick a recent
/// server; the system asks for the password and the share opens in the active pane.
struct ConnectToServerSheetView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState

    @ViewState private var address = ""
    @ViewState private var recents = RecentServers().all
    @ViewState private var selectedRecent: String?
    @ViewState private var isConnecting = false
    @ViewState private var errorMessage: String?
    @ViewState private var mounter = ServerMount()
    @ViewState private var keepInSidebar = SavedNetworkShares(defaults: AppState.preferences).keepsNewShares
    @FocusState private var isAddressFocused: Bool

    private var parsedURL: URL? { ServerAddress.url(from: address) }

    var body: some View {
        VStack(alignment: .leading, spacing: FinderUI.sectionSpacing) {
            HStack {
                Image(systemName: "server.rack")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Connect to Server")
                    .font(FinderUI.titleFont)
                Spacer()
            }

            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text("Server Address")
                    .font(FinderUI.detailFont)
                TextField("smb://server/share", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .focused($isAddressFocused)
                    .disabled(isConnecting)
                    .onSubmit(connect)
                    .onChange(of: address) { _, _ in errorMessage = nil }
                Text("A server name alone uses SMB. Also afp://, nfs://, ftp:// and https:// (WebDAV).")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: FinderUI.compactSpacing) {
                Text("Recent Servers")
                    .font(FinderUI.detailFont)
                List(selection: $selectedRecent) {
                    ForEach(recents, id: \.self) { recent in
                        Label(recent, systemImage: "server.rack")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .tag(recent)
                            .contextMenu {
                                Button("Remove from Recent Servers") { remove(recent) }
                            }
                    }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
                .frame(height: 120)
                .overlay {
                    if recents.isEmpty {
                        Text("No recent servers")
                            .font(FinderUI.captionFont)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu(forSelectionType: String.self) { _ in
                } primaryAction: { selection in
                    if let recent = selection.first { address = recent; connect() }
                }
                .onChange(of: selectedRecent) { _, recent in
                    if let recent { address = recent }
                }
                .onDeleteCommand { if let selectedRecent { remove(selectedRecent) } }
                .disabled(isConnecting)
            }

            Toggle(isOn: $keepInSidebar) {
                Text("Keep in the sidebar when disconnected")
            }
            .toggleStyle(.checkbox)
            .help("The share stays under its server in the sidebar; click it there to connect again.")
            .disabled(isConnecting)
            .onChange(of: keepInSidebar) { _, keep in
                SavedNetworkShares(defaults: AppState.preferences).keepsNewShares = keep
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(FinderUI.detailFont)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isConnecting {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                        .font(FinderUI.detailFont)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    mounter.cancel()
                    appState.showConnectToServerSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsedURL == nil || isConnecting)
            }
        }
        .font(FinderUI.bodyFont)
        .controlSize(.regular)
        .padding(FinderUI.sheetPadding)
        .frame(width: 460)
        .onAppear {
            if address.isEmpty, let last = recents.first { address = last }
            isAddressFocused = true
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        guard let url = parsedURL else {
            errorMessage = String(localized: "Enter a server address, for example smb://server/share.")
            return
        }
        isConnecting = true
        errorMessage = nil
        Task { @MainActor in
            defer { isConnecting = false }
            do {
                guard let mountPoint = try await mounter.mount(url) else { return } // cancelled at sign-in
                RecentServers().add(url)
                recents = RecentServers().all
                if keepInSidebar, let share = Self.share(mountedAt: mountPoint) ?? NetworkShare(url: url) {
                    appState.saveShare(share)
                }
                appState.showConnectToServerSheet = false
                activeTab.navigate(to: mountPoint)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The share as the system names it for remounting, so the saved drive
    /// matches the mounted volume even when the address typed was a server alone.
    private static func share(mountedAt mountPoint: URL) -> NetworkShare? {
        let values = try? mountPoint.resourceValues(forKeys: [.volumeURLForRemountingKey])
        return NetworkShare(url: values?.volumeURLForRemounting)
    }

    private func remove(_ recent: String) {
        RecentServers().remove(recent)
        recents = RecentServers().all
        if selectedRecent == recent { selectedRecent = nil }
    }
}
