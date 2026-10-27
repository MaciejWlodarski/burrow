import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
private final class ApplicationHandlersCache: ObservableObject {
    static let shared = ApplicationHandlersCache()
    @Published private(set) var applications: [String: [URL]] = [:]
    private var pending: Set<String> = []
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.burrow.application-handlers"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    func request(for url: URL) {
        let path = url.path
        guard applications[path] == nil, !pending.contains(path), pending.count < 256 else { return }
        pending.insert(path)
        queue.addOperation { [weak self] in
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: URL(fileURLWithPath: path))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pending.remove(path)
                if self.applications.count > 512 { self.applications.removeAll() }
                self.applications[path] = apps
            }
        }
    }
}

struct OpenWithApplicationsMenu: View {
    let item: FileItem
    @ObservedObject private var cache = ApplicationHandlersCache.shared

    var body: some View {
        Menu("Otwórz w aplikacji…") {
            if let apps = cache.applications[item.path] {
                ForEach(apps, id: \.path) { application in
                    Button(application.deletingPathExtension().lastPathComponent) {
                        FileOperationsManager.shared.open(item.url, withApplication: application)
                    }
                }
            } else {
                Text("Wczytywanie aplikacji…")
            }
            Divider()
            Button("Wybierz inną aplikację…", action: chooseApplication)
        }
        .task(id: item.path) { cache.request(for: item.url) }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Otwórz „\(item.name)” w aplikacji"
        panel.prompt = "Otwórz"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            FileOperationsManager.shared.open(item.url, withApplication: url)
        }
    }
}
