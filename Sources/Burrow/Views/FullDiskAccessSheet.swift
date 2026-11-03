import SwiftUI
import AppKit

/// Offered once on first launch and from Help: one switch in System Settings
/// replaces a privacy prompt for every protected folder.
struct FullDiskAccessSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var openedSettings = false
    @ViewState private var granted = FullDiskAccess.isGranted()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: granted ? "checkmark.shield.fill" : "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(granted ? Color.green : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(granted ? "Full Disk Access is on" : "Give Burrow Full Disk Access")
                        .font(.title2.weight(.semibold))
                    Text(granted
                        ? "Burrow calculates every folder size and scans the whole disk without asking again."
                        : "Burrow can then show the size of every folder and scan the whole disk, without a permission prompt for each protected folder.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !granted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Click Open System Settings.")
                    Text("2. Turn on Burrow in the list. If it is missing, drag this icon into the list.")
                    Text("3. If System Settings offers Quit & Reopen, choose it.")
                }
                .fixedSize(horizontal: false, vertical: true)

                // Dropping the app onto the Full Disk Access list adds it, the
                // same as choosing it with +.
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable()
                        .frame(width: 48, height: 48)
                        .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                        .help("Drag Burrow into the Full Disk Access list")
                        .accessibilityLabel("Burrow app icon, drag it into the Full Disk Access list")
                    Text("Drag me")
                        .font(FinderUI.captionFont)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 18)

                if openedSettings {
                    Label("Burrow notices the change when you come back.", systemImage: "arrow.uturn.backward")
                        .font(FinderUI.captionFont)
                        .foregroundStyle(.secondary)
                }

                Text("Without it, Burrow still works: protected folders such as Desktop and Documents are searched and sized once you open them or ask, and macOS asks about each of them once.")
                    .font(FinderUI.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if granted {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Open System Settings") {
                        openedSettings = true
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            FullDiskAccess.refresh()
            granted = FullDiskAccess.isGranted()
            if granted { FolderSizeCache.shared.refreshFullDiskAccess() }
        }
    }
}
