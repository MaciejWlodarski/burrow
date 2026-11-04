import Foundation
import AppKit

/// Cloud locations for the sidebar and downloads the user started. Burrow
/// downloads cloud files only through `download(_:)`; everything else reads
/// without materializing (see `CloudFiles`).
@MainActor
public final class CloudActivity: ObservableObject {
    public static let shared = CloudActivity()

    @Published public private(set) var locations: [CloudFiles.Location] = []
    /// Paths with a download in progress, shown with a spinner.
    @Published public private(set) var downloading: Set<String> = []
    private var downloadStarted: [String: Date] = [:]
    private var poll: Task<Void, Never>?
    private var icons: [String: NSImage] = [:]
    private var symbols: [String: NSImage?] = [:]

    init() {
        #if !BURROW_TESTING
        refreshLocations()
        #endif
    }

    public func refreshLocations() {
        Task.detached(priority: .utility) {
            let found = CloudFiles.locations()
            await MainActor.run { [weak self] in
                guard let self, self.locations != found else { return }
                self.locations = found
            }
        }
    }

    /// The provider's own icon (Google Drive, OneDrive…), as Finder shows it.
    /// Nil for iCloud Drive and providers whose app is not installed; the
    /// sidebar then uses a cloud symbol.
    public func icon(for location: CloudFiles.Location) -> NSImage? {
        if let cached = icons[location.id] { return cached }
        guard let bundleID = CloudFiles.appBundleIdentifier(for: location.provider),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        icons[location.id] = icon
        return icon
    }

    /// The monochrome symbol the provider's File Provider extension declares
    /// (CFBundleSymbolName, e.g. Google Drive's triangle): what Finder's sidebar
    /// shows. A template image, so it takes the sidebar's tint. Nil when the
    /// extension declares none.
    public func sidebarSymbol(for location: CloudFiles.Location) -> NSImage? {
        if let cached = symbols[location.id] { return cached }
        var found: NSImage?
        if let bundleID = CloudFiles.appBundleIdentifier(for: location.provider),
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let plugins = try? FileManager.default.contentsOfDirectory(
               at: app.appendingPathComponent("Contents/PlugIns"), includingPropertiesForKeys: nil) {
            for appex in plugins where appex.pathExtension == "appex" {
                guard let bundle = Bundle(url: appex), let info = bundle.infoDictionary,
                      let ext = info["NSExtension"] as? [String: Any],
                      (ext["NSExtensionPointIdentifier"] as? String)?.hasPrefix("com.apple.fileprovider") == true,
                      let icons = info["CFBundleIcons"] as? [String: Any],
                      let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                      let name = primary["CFBundleSymbolName"] as? String,
                      let image = NSImage(symbolName: name, bundle: bundle, variableValue: 0) else { continue }
                image.isTemplate = true
                found = image
                break
            }
        }
        symbols[location.id] = found
        return found
    }

    public func location(containing path: String) -> CloudFiles.Location? {
        CloudFiles.location(containing: path, in: locations)
    }

    public func isInCloud(_ item: FileItem) -> Bool {
        item.isCloudOnly || location(containing: item.path) != nil
    }

    // MARK: - Actions

    public func download(_ items: [FileItem]) {
        let targets = items.filter { isInCloud($0) && !downloading.contains($0.path) }
        guard !targets.isEmpty else { return }
        for item in targets {
            downloading.insert(item.path)
            downloadStarted[item.path] = Date()
        }
        let urls = targets.map(\.url)
        Task.detached(priority: .userInitiated) {
            let result = CloudFiles.download(urls)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if result.failures.isEmpty {
                    FileOperationsManager.shared.lastStatusMessage = targets.count == 1
                        ? String(localized: "Downloading “\(targets[0].name)”…")
                        : String(localized: "Downloading \(targets.count) items…")
                } else {
                    for item in targets { self.finish(item.path) }
                    FileOperationsManager.shared.lastStatusMessage = String(localized: "Could not download: \(result.failures.joined(separator: "; "))")
                }
                self.startPolling()
            }
        }
    }

    public func removeDownload(_ items: [FileItem]) {
        let targets = items.filter { !$0.isCloudOnly && location(containing: $0.path) != nil }
        guard !targets.isEmpty else { return }
        let urls = targets.map(\.url)
        Task.detached(priority: .userInitiated) {
            let result = CloudFiles.removeDownload(urls)
            // Providers mark the item as cloud-only shortly after the call
            // returns; wait for it so the refreshed row shows the cloud badge.
            let paths = targets.filter { !$0.isDirectory }.map(\.path)
            for _ in 0..<20 where result.started > 0 {
                if paths.allSatisfy({ CloudFiles.isDataless(path: $0) }) { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            await MainActor.run {
                if result.failures.isEmpty {
                    FileOperationsManager.shared.lastStatusMessage = String(localized: "Removed the downloaded copy of \(result.started) items. They stay in the cloud.")
                } else {
                    FileOperationsManager.shared.lastStatusMessage = String(localized: "Could not remove the download: \(result.failures.joined(separator: "; "))")
                }
                AppState.shared.refreshFolders(containing: Set(targets.map(\.parentPath)))
            }
        }
    }

    // MARK: - Progress

    private func finish(_ path: String) {
        downloading.remove(path)
        downloadStarted.removeValue(forKey: path)
    }

    /// Checks the provider's status once a second and refreshes the folders
    /// whose downloads finished, so cloud badges clear without a manual reload.
    private func startPolling() {
        guard poll == nil, !downloading.isEmpty else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let paths = Array(self.downloading)
                if paths.isEmpty { break }
                let done = await Task.detached(priority: .utility) { () -> [String] in
                    paths.filter { CloudActivity.isDownloaded(path: $0) }
                }.value
                let expired = paths.filter { (self.downloadStarted[$0]?.timeIntervalSinceNow ?? 0) < -1800 }
                let finished = Set(done + expired)
                guard !finished.isEmpty else { continue }
                for path in finished { self.finish(path) }
                let parents = Set(finished.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })
                AppState.shared.refreshFolders(containing: parents.union(finished))
                if self.downloading.isEmpty {
                    FileOperationsManager.shared.lastStatusMessage = String(localized: "Download finished.")
                }
            }
            self?.poll = nil
        }
    }

    nonisolated static func isDownloaded(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey]) else {
            return !CloudFiles.isDataless(path: path)
        }
        if values.ubiquitousItemIsDownloading == true { return false }
        if let status = values.ubiquitousItemDownloadingStatus { return status == .current || status == .downloaded }
        return !CloudFiles.isDataless(path: path)
    }
}
