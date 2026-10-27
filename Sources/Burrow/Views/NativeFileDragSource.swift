import SwiftUI
import AppKit

struct FileDragFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// SwiftUI's onDrag exports a single provider. An AppKit dragging session exports
/// one file URL per selected item, so Finder and our own panes receive the batch.
struct NativeFileDragSource: NSViewRepresentable {
    @ObservedObject var pane: PaneTabState
    let frames: [String: CGRect]
    let isActive: Bool
    let activate: () -> Void

    func makeNSView(context: Context) -> FileDragSourceView { FileDragSourceView() }

    func updateNSView(_ view: FileDragSourceView, context: Context) {
        view.frames = frames
        view.focusOnAttach = isActive
        if let last = view.lastFocusRequest, last != pane.focusFilePaneTrigger {
            view.window?.makeFirstResponder(view)
        }
        view.lastFocusRequest = pane.focusFilePaneTrigger
        view.itemsForDrag = { path in
            activate()
            guard let item = pane.displayedItems.first(where: { $0.path == path }) else { return [] }
            if !pane.selectedPaths.contains(path) { pane.select(item) }
            return pane.selectedItems
        }
    }
}

final class FileDragSourceView: NSView, NSDraggingSource {
    var frames: [String: CGRect] = [:]
    var itemsForDrag: ((String) -> [FileItem])?
    var focusOnAttach = false
    var lastFocusRequest: UInt64?
    private var monitor: Any?
    private var downPath: String?
    private var downPoint = NSPoint.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusOnAttach, let window = self.window,
                  window.attachedSheet == nil else { return }
            window.makeFirstResponder(self)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDown:
                self.downPath = self.bounds.contains(point)
                    ? self.frames.first(where: { $0.value.contains(point) })?.key : nil
                self.downPoint = point
                if self.downPath != nil { self.window?.makeFirstResponder(self) }
            case .leftMouseUp:
                self.downPath = nil
            case .leftMouseDragged:
                guard let path = self.downPath,
                      hypot(point.x - self.downPoint.x, point.y - self.downPoint.y) > 5 else { return event }
                self.downPath = nil
                let files = self.itemsForDrag?(path) ?? []
                guard !files.isEmpty else { return event }
                let items = files.map { file -> NSDraggingItem in
                    let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
                    let image = FileIconCache.shared.icon(for: file, preferThumbnail: false)
                    item.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 32, height: 32), contents: image)
                    return item
                }
                let session = self.beginDraggingSession(with: items, event: event, source: self)
                session.draggingFormation = .pile
                return nil
            default: break
            }
            return event
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// One request owns a bounded provider-loading phase. No transfer starts until
/// every supported provider has succeeded; a partial batch is never moved silently.
enum FileDropLoadingError: Error, LocalizedError, Sendable {
    case timedOut, cancelled, providerFailed, invalidPayload, tooManyProviders, empty
    var errorDescription: String? {
        switch self {
        case .timedOut: return "Przekroczono czas odczytu przeciąganych plików. Nie rozpoczęto operacji. Spróbuj ponownie."
        case .cancelled: return "Anulowano odczyt przeciąganych plików."
        case .providerFailed: return "Nie udało się odczytać wszystkich przeciąganych plików. Nie rozpoczęto operacji."
        case .invalidPayload: return "Źródło przeciągania nie przekazało prawidłowego adresu pliku. Nie rozpoczęto operacji."
        case .tooManyProviders: return "Jednorazowo można przeciągnąć najwyżej 256 plików. Podziel wybór na mniejsze grupy."
        case .empty: return "Źródło przeciągania nie zawiera adresów plików."
        }
    }
}

/// Injectable transport keeps deadline/cancellation tests independent of AppKit's
/// provider scheduling. Start is actor-confined; completion may arrive on any queue.
@MainActor
struct FileDropSource {
    let start: (@escaping @Sendable (Result<URL, FileDropLoadingError>) -> Void) -> Progress?
}

/// Prevent duplicate callbacks from queuing unbounded actor tasks. The lock
/// protects only the once flag; provider/user code never runs under it.
private final class FileDropCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !delivered else { return false }
        delivered = true
        return true
    }
}

@MainActor
private final class FileDropBatch {
    let sources: [FileDropSource]
    let concurrency: Int
    let timeoutNanoseconds: UInt64
    private var continuation: CheckedContinuation<[URL], Error>?
    private var terminal: Result<[URL], Error>?
    private var next = 0
    private var pending = Set<Int>()
    private var progress: [Int: Progress] = [:]
    private var results: [URL?]
    private var deadline: Task<Void, Never>?

    init(sources: [FileDropSource], concurrency: Int, timeoutNanoseconds: UInt64) {
        self.sources = sources
        self.concurrency = max(1, min(4, concurrency))
        self.timeoutNanoseconds = timeoutNanoseconds
        self.results = Array(repeating: nil, count: sources.count)
    }

    func start(_ continuation: CheckedContinuation<[URL], Error>) {
        if let terminal { continuation.resume(with: terminal); return }
        self.continuation = continuation
        guard !sources.isEmpty else { finish(.failure(FileDropLoadingError.empty)); return }
        guard sources.count <= 256 else { finish(.failure(FileDropLoadingError.tooManyProviders)); return }
        deadline = Task { @MainActor [weak self, timeoutNanoseconds] in
            do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
            catch { return }
            self?.finish(.failure(FileDropLoadingError.timedOut))
        }
        pump()
    }

    func cancel() { finish(.failure(FileDropLoadingError.cancelled)) }

    private func pump() {
        while terminal == nil, pending.count < concurrency, next < sources.count {
            let index = next
            next += 1
            pending.insert(index)
            let gate = FileDropCallbackGate()
            let handle = sources[index].start { [weak self] result in
                guard gate.claim() else { return }
                Task { @MainActor [weak self] in self?.receive(result, index: index) }
            }
            // A provider may call completion synchronously, but receive is an
            // actor task and therefore cannot race this handle installation.
            if terminal == nil { progress[index] = handle }
            else { handle?.cancel() }
        }
    }

    private func receive(_ result: Result<URL, FileDropLoadingError>, index: Int) {
        guard terminal == nil, pending.remove(index) != nil else { return }
        progress.removeValue(forKey: index)
        switch result {
        case .failure(let error): finish(.failure(error))
        case .success(let url):
            guard FileDropLoader.isValidFileURL(url) else { finish(.failure(FileDropLoadingError.invalidPayload)); return }
            results[index] = url
            if next == sources.count && pending.isEmpty {
                var seen = Set<URL>()
                let urls = results.compactMap { $0 }.filter { seen.insert($0).inserted }
                finish(.success(urls))
            } else { pump() }
        }
    }

    private func finish(_ result: Result<[URL], Error>) {
        guard terminal == nil else { return }
        terminal = result
        deadline?.cancel()
        deadline = nil
        // Remove state before cancelling: providers may synchronously callback.
        let handles = Array(progress.values)
        progress.removeAll()
        pending.removeAll()
        let waiter = continuation
        continuation = nil
        for handle in handles { handle.cancel() }
        waiter?.resume(with: result)
    }
}

@MainActor
enum FileDropLoader {
    static func accepts(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.hasItemConformingToTypeIdentifier("public.file-url") }
    }

    nonisolated static func isValidFileURL(_ url: URL) -> Bool {
        url.isFileURL && url.path.hasPrefix("/") && !url.path.contains("\0") &&
            (url.host == nil || url.host == "" || url.host == "localhost") &&
            url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil
    }

    nonisolated static func decodeItem(_ value: Any?, failed: Bool = false) -> Result<URL, FileDropLoadingError> {
        guard !failed else { return .failure(.providerFailed) }
        let url: URL?
        if let data = value as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
        else { url = value as? URL }
        guard let url, isValidFileURL(url) else { return .failure(.invalidPayload) }
        return .success(url)
    }

    static func urls(from providers: [NSItemProvider]) async throws -> [URL] {
        let supported = Array(providers.lazy.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }.prefix(257))
        let sources = supported.map { provider in
            FileDropSource { completion in
                if provider.canLoadObject(ofClass: NSURL.self) {
                    return provider.loadObject(ofClass: NSURL.self) { value, error in
                        completion(decodeItem(value, failed: error != nil))
                    }
                }
                // Legacy file-url providers may vend Data rather than NSURL.
                // This API has no Progress handle; our deadline still terminates
                // the application request and discards every late callback.
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { value, error in
                    completion(decodeItem(value, failed: error != nil))
                }
                return nil
            }
        }
        return try await urls(from: sources)
    }

    static func urls(from sources: [FileDropSource], concurrency: Int = 4,
                     timeoutNanoseconds: UInt64 = 15_000_000_000) async throws -> [URL] {
        let batch = FileDropBatch(sources: sources, concurrency: concurrency, timeoutNanoseconds: timeoutNanoseconds)
        return try await withTaskCancellationHandler {
            if Task.isCancelled { batch.cancel() }
            return try await withCheckedThrowingContinuation { batch.start($0) }
        } onCancel: {
            Task { @MainActor in batch.cancel() }
        }
    }
}

/// A view's onChange/onDisappear cleanup is deferred until rendering. Check
/// ownership again synchronously at the filesystem-operation handoff instead.
@MainActor
struct FileDropPaneContext {
    let paneID: UUID
    let browsingURL: URL
    let navigationRevision: UInt64

    init(pane: PaneTabState) {
        paneID = pane.id
        browsingURL = pane.currentURL
        navigationRevision = pane.navigationRevision
    }

    static func accepts(_ providers: [NSItemProvider], in pane: PaneTabState) -> Bool {
        // Global search results can be visible while the saved browsing root is
        // still paused. Every row/background target shares this admission rule.
        !pane.isSessionBrowsingPaused && FileDropLoader.accepts(providers)
    }

    func matches(pane: PaneTabState) -> Bool {
        !pane.isSessionBrowsingPaused && pane.id == paneID && pane.currentURL == browsingURL &&
            pane.navigationRevision == navigationRevision
    }

    func allowsCommit(in appState: AppState, side: PaneSide) -> Bool {
        switch side {
        case .left: return matches(pane: appState.leftTab)
        case .right: return appState.isDualPane && matches(pane: appState.rightPane)
        }
    }
}

@MainActor
final class FileDropLoadController: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var diagnostic: String?
    @Published private(set) var destinationPath = ""
    private var requestID: UUID?
    private var task: Task<Void, Never>?

    func begin(providers: [NSItemProvider], destination: URL, completion: @escaping @MainActor ([URL]) -> Void) {
        begin(destination: destination, load: { try await FileDropLoader.urls(from: providers) }, completion: completion)
    }

    /// Tests inject a transport, but exercise the same ownership/commit path.
    func begin(destination: URL, load: @escaping @MainActor () async throws -> [URL],
               completion: @escaping @MainActor ([URL]) -> Void) {
        cancel()
        let id = UUID()
        requestID = id
        destinationPath = destination.path
        diagnostic = nil
        isLoading = true
        task = Task { @MainActor [weak self] in
            do {
                let urls = try await load()
                guard !urls.isEmpty, urls.allSatisfy(FileDropLoader.isValidFileURL) else {
                    throw FileDropLoadingError.invalidPayload
                }
                guard !Task.isCancelled, let self, self.requestID == id else { return }
                self.requestID = nil
                self.task = nil
                self.isLoading = false
                completion(urls)
            } catch {
                guard let self, self.requestID == id else { return }
                self.requestID = nil
                self.task = nil
                self.isLoading = false
                self.diagnostic = error.localizedDescription
            }
        }
    }

    func cancel() {
        requestID = nil
        task?.cancel()
        task = nil
        isLoading = false
        diagnostic = nil
    }
}

struct FileDropLoadingStatusView: View {
    @ObservedObject var controller: FileDropLoadController
    var body: some View {
        if controller.isLoading {
            HStack(spacing: FinderUI.rowSpacing) {
                ProgressView().controlSize(.small)
                Text("Odczytywanie przeciąganych plików…").font(FinderUI.captionFont)
                Spacer(minLength: 0)
                Button("Anuluj") { controller.cancel() }.controlSize(.small)
            }
            .padding(FinderUI.rowSpacing)
            .help("Cel operacji: \(controller.destinationPath)")
            .accessibilityElement(children: .contain)
        } else if let diagnostic = controller.diagnostic {
            HStack(alignment: .top, spacing: FinderUI.rowSpacing) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(diagnostic).font(FinderUI.captionFont).textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Zamknij") { controller.cancel() }.controlSize(.small)
            }
            .padding(FinderUI.rowSpacing)
        }
    }
}
