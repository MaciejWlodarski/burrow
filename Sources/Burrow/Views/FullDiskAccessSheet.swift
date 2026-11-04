import SwiftUI
import AppKit

/// Offered once on first launch and from Help: one switch in System Settings
/// replaces a privacy prompt for every protected folder.
struct FullDiskAccessSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var openedSettings = false
    @ViewState private var granted = FullDiskAccess.isGranted()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: granted ? "checkmark.shield.fill" : "lock.shield.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(granted ? Color.green : Color.accentColor)
                    .frame(width: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(granted ? "Full Disk Access is on" : "Give Burrow Full Disk Access")
                            .font(.title2.weight(.semibold))
                        Text(granted
                            ? "Burrow calculates every folder size and scans the whole disk without asking again."
                            : "Burrow can then read protected folders such as Desktop and Documents, size every folder and scan the whole disk.")
                            .lineSpacing(3)
                            .foregroundStyle(FinderUI.metadataColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !granted {
                        VStack(alignment: .leading, spacing: 8) {
                            step(1, "Click Open System Settings.")
                            step(2, "Under Privacy & Security › Full Disk Access, turn on Burrow.")
                            step(3, "If System Settings offers Quit & Reopen, choose it.")
                        }

                        // Dropping the app onto the Full Disk Access list adds it, the
                        // same as choosing it with +.
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                                .resizable()
                                .frame(width: 40, height: 40)
                                .padding(8)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                }
                                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                                .help("Drag Burrow into the Full Disk Access list")
                                .accessibilityLabel("Burrow app icon, drag it into the Full Disk Access list")
                            Text("Burrow missing from the list? Drag this icon into the Full Disk Access list.")
                                .font(FinderUI.detailFont)
                                .foregroundStyle(FinderUI.metadataColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if openedSettings {
                            Label("Burrow notices the change when you come back.", systemImage: "arrow.uturn.backward")
                                .font(FinderUI.detailFont)
                                .foregroundStyle(.secondary)
                        }

                        Text("Without it, Burrow still works; macOS asks once for each protected folder, such as Desktop.")
                            .font(.callout)
                            .foregroundStyle(FinderUI.metadataColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            FullDiskAccess.refresh()
            granted = FullDiskAccess.isGranted()
            if granted { FolderSizeCache.shared.refreshFullDiskAccess() }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(number)")
                .font(FinderUI.captionFont.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                // Grey, so the only accent fill is the primary button.
                .background(Circle().fill(Color.primary.opacity(0.08)))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
