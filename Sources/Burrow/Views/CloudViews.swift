import SwiftUI
import AppKit

/// A small badge next to a file name: a spinner while it downloads, a cloud
/// for content that is stored only online.
struct CloudStatusBadge: View {
    let item: FileItem
    var isSelected = false
    var selectionColor: Color = .white
    @ObservedObject private var cloud = CloudActivity.shared

    var body: some View {
        if cloud.downloading.contains(item.path) {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)
                .help(Text("Downloading…"))
        } else if item.isCloudOnly {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? selectionColor : Color.secondary)
                .help(helpText)
                .accessibilityLabel(Text("Stored only in the cloud"))
        }
    }

    private var helpText: String {
        if let provider = cloud.location(containing: item.path)?.provider {
            return String(localized: "Stored only in \(provider). Opening it downloads it; Download Now keeps a copy on this Mac.")
        }
        return String(localized: "Stored only in the cloud. Opening it downloads it; Download Now keeps a copy on this Mac.")
    }
}

/// "Download Now" and "Remove Download" for the item context menu. Shown only
/// for items inside a cloud location.
struct CloudContextMenuItems: View {
    let item: FileItem
    let targets: () -> [FileItem]
    @ObservedObject private var cloud = CloudActivity.shared

    var body: some View {
        if cloud.isInCloud(item) {
            Divider()
            if item.isCloudOnly || item.isDirectory {
                Button {
                    cloud.download(targets())
                } label: {
                    Label("Download Now", systemImage: "icloud.and.arrow.down")
                }
            }
            if !item.isCloudOnly {
                Button {
                    cloud.removeDownload(targets())
                } label: {
                    Label("Remove Download", systemImage: "icloud.slash")
                }
            }
        }
    }
}

/// Inspector row with the cloud status of the selected item.
struct CloudInspectorRow: View {
    let item: FileItem
    @ObservedObject private var cloud = CloudActivity.shared

    var body: some View {
        if let location = cloud.location(containing: item.path) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if let icon = cloud.icon(for: location) {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "icloud").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.provider).font(.callout.weight(.medium))
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if cloud.downloading.contains(item.path) {
                    ProgressView().controlSize(.small)
                } else if item.isCloudOnly || item.isDirectory {
                    Button("Download") { cloud.download([item]) }
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var statusText: String {
        if cloud.downloading.contains(item.path) { return String(localized: "Downloading…") }
        if item.isCloudOnly { return String(localized: "Stored only in the cloud") }
        if item.isDirectory { return String(localized: "Cloud folder") }
        return String(localized: "Downloaded to this Mac")
    }
}
