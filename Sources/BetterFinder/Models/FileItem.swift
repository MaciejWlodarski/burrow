import Foundation
import AppKit
import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

public enum FinderTagColor: String, CaseIterable, Identifiable, Sendable {
    case red = "red"
    case orange = "orange"
    case yellow = "yellow"
    case green = "green"
    case blue = "blue"
    case purple = "purple"
    case gray = "gray"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .red: return "Czerwony"
        case .orange: return "Pomarańczowy"
        case .yellow: return "Żółty"
        case .green: return "Zielony"
        case .blue: return "Niebieski"
        case .purple: return "Fioletowy"
        case .gray: return "Szary"
        }
    }

    public var systemTagName: String {
        switch self {
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .gray: return "Gray"
        }
    }

    public var swiftUIColor: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .gray: return .gray
        }
    }

    public static func from(rawTagName: String) -> FinderTagColor? {
        let lower = rawTagName.lowercased()
        switch lower {
        case "red", "czerwony": return .red
        case "orange", "pomarańczowy", "pomaranczowy": return .orange
        case "yellow", "żółty", "zolty": return .yellow
        case "green", "zielony": return .green
        case "blue", "niebieski": return .blue
        case "purple", "fioletowy": return .purple
        case "gray", "grey", "szary": return .gray
        default: return nil
        }
    }

    public static func readTags(for url: URL) -> [FinderTagColor] {
        guard let rawNames = try? readTagNames(for: url) else { return [] }
        return rawNames.compactMap { from(rawTagName: $0) }
    }

    public static func readTagNames(for url: URL) throws -> [String] {
        try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    /// Change the built-in colors while preserving custom tags and existing localized names.
    static func tagNames(replacingColorsWith tags: [FinderTagColor], in original: [String]) -> [String] {
        var names = original.filter { name in
            guard let color = from(rawTagName: name) else { return true }
            return tags.contains(color)
        }
        for color in tags where !names.contains(where: { from(rawTagName: $0) == color }) {
            names.append(color.systemTagName)
        }
        return names
    }

    public static func writeTags(_ tags: [FinderTagColor], to url: URL) throws {
        let names = tagNames(replacingColorsWith: tags, in: try readTagNames(for: url))
        try (url as NSURL).setResourceValue(names, forKey: .tagNamesKey)
    }

    public static func clearAllTags(for url: URL) throws {
        try (url as NSURL).setResourceValue([String](), forKey: .tagNamesKey)
    }
}

public enum FileKindCategory: String, CaseIterable, Sendable {
    case folder = "Folder"
    case code = "Code"
    case document = "Document"
    case image = "Image"
    case audio = "Audio"
    case video = "Video"
    case archive = "Archive"
    case executable = "Executable"
    case other = "File"

    public var symbolName: String {
        switch self {
        case .folder: return "folder.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .document: return "doc.text.fill"
        case .image: return "photo.fill"
        case .audio: return "waveform"
        case .video: return "film.fill"
        case .archive: return "doc.zipper"
        case .executable: return "terminal.fill"
        case .other: return "doc.fill"
        }
    }

    public var treemapColor: Color {
        switch self {
        case .folder: return .blue
        case .code: return .indigo
        case .document: return .teal
        case .image: return .pink
        case .audio: return .mint
        case .video: return .orange
        case .archive: return .yellow
        case .executable: return .red
        case .other: return .cyan
        }
    }

    public static func detect(extension ext: String, isDirectory: Bool) -> FileKindCategory {
        if isDirectory { return .folder }
        switch ext.lowercased() {
        case "swift", "rs", "py", "js", "ts", "tsx", "jsx", "c", "cpp", "h", "hpp", "m", "mm",
             "go", "java", "kt", "rb", "php", "cs", "sh", "zsh", "bash", "fish", "sql", "html",
             "css", "scss", "json", "yaml", "yml", "toml", "xml", "zig", "lua", "vue", "svelte":
            return .code
        case "md", "txt", "rtf", "pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers",
             "ppt", "pptx", "key", "csv", "log", "org", "tex":
            return .document
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tiff", "bmp", "ico", "icns", "psd", "raw":
            return .image
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "aiff":
            return .audio
        case "mp4", "mov", "mkv", "avi", "webm", "m4v":
            return .video
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg":
            return .archive
        case "app", "bin", "out", "dylib", "so", "wasm":
            return .executable
        default:
            return .other
        }
    }
}

public enum GitFileStatus: String, Sendable {
    case modified = "M"
    case staged = "A"
    case untracked = "?"
    case deleted = "D"
    case renamed = "R"

    public var badgeDescription: String {
        switch self {
        case .modified: return "Modified"
        case .staged: return "Staged"
        case .untracked: return "Untracked"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        }
    }
}

public struct GrepMatchSnippet: Sendable, Hashable {
    public let lineNumber: Int
    public let lineText: String
    public let matchRangeLower: Int
    public let matchRangeUpper: Int

    public init(lineNumber: Int, lineText: String, matchRangeLower: Int = 0, matchRangeUpper: Int = 0) {
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.matchRangeLower = matchRangeLower
        self.matchRangeUpper = matchRangeUpper
    }
}

public struct FileItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let url: URL
    public let name: String
    public let path: String
    public let parentPath: String
    public let fileExtension: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isHidden: Bool
    public let size: Int64
    public let modificationDate: Date
    public let creationDate: Date
    public let kindCategory: FileKindCategory
    public var gitStatus: GitFileStatus?
    public var grepMatch: GrepMatchSnippet?
    public var tags: [FinderTagColor]
    public var treeDepth: Int
    public var searchScore: Int

    public init(
        url: URL,
        name: String,
        path: String,
        parentPath: String,
        fileExtension: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        isHidden: Bool,
        size: Int64,
        modificationDate: Date,
        creationDate: Date = .distantPast,
        kindCategory: FileKindCategory? = nil,
        gitStatus: GitFileStatus? = nil,
        grepMatch: GrepMatchSnippet? = nil,
        tags: [FinderTagColor] = [],
        treeDepth: Int = 0,
        searchScore: Int = 0
    ) {
        self.url = url
        self.name = name
        self.path = path
        self.parentPath = parentPath
        self.fileExtension = fileExtension
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.kindCategory = kindCategory ?? FileKindCategory.detect(extension: fileExtension, isDirectory: isDirectory)
        self.gitStatus = gitStatus
        self.grepMatch = grepMatch
        self.tags = tags
        self.treeDepth = treeDepth
        self.searchScore = searchScore
    }

    /// Application bundles are directories on disk but must never receive drops as folders.
    public var isDropFolderTarget: Bool {
        isDirectory && fileExtension.lowercased() != "app"
    }

    public var isExtractableArchive: Bool {
        guard !isDirectory else { return false }
        let ext = fileExtension.lowercased()
        return ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "dmg"].contains(ext)
    }

    public var supportsRichThumbnail: Bool {
        guard !isDirectory else { return false }
        switch kindCategory {
        case .image, .video:
            return true
        case .document:
            return ["pdf", "pages", "key", "numbers", "doc", "docx", "rtf"].contains(fileExtension.lowercased())
        default:
            return false
        }
    }

    public var kindDisplayString: String {
        if isSymlink { return "Dowiązanie" }
        if isDirectory {
            return fileExtension.lowercased() == "app" ? "Aplikacja" : "Folder"
        }
        let category: String
        switch kindCategory {
        case .folder: category = "Folder"
        case .code: category = "Kod źródłowy"
        case .document: category = "Dokument"
        case .image: category = "Obraz"
        case .audio: category = "Dźwięk"
        case .video: category = "Wideo"
        case .archive: category = "Archiwum"
        case .executable: category = "Plik wykonywalny"
        case .other: category = "Plik"
        }
        return fileExtension.isEmpty ? category : "\(category) \(fileExtension.uppercased())"
    }

    public static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.path == rhs.path &&
        lhs.modificationDate == rhs.modificationDate &&
        lhs.size == rhs.size &&
        lhs.gitStatus == rhs.gitStatus &&
        lhs.grepMatch == rhs.grepMatch &&
        lhs.tags == rhs.tags &&
        lhs.treeDepth == rhs.treeDepth
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }
}

/// Fast thread-safe icon & QuickLook thumbnail cache (`QLThumbnailGenerator`) for native macOS previews
@MainActor
public final class FileIconCache: ObservableObject {
    public static let shared = FileIconCache()
    @Published private var cache: [String: NSImage] = [:]
    private var genericIcons: [String: NSImage] = [:]
    private var pendingIcons: Set<String> = []
    private let iconQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.betterfinder.file-icons"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    @Published public private(set) var thumbnails: [String: NSImage] = [:]
    // Work and result budgets are independent. Rejected demand is not retained;
    // observers retry it when a completion/cancellation publishes capacity.
    @Published private(set) var thumbnailCapacityRevision: UInt64 = 0
    struct ThumbnailLimits {
        var active = 4
        var queued = 64
        var cached = 800
        var timeout: Duration = .seconds(10)
        var maxQueueAge: Duration = .seconds(10)
        var retryDelay: Duration = .seconds(2)
        var retries = 2
    }
    private struct ThumbnailVersion: Equatable {
        let size: Int64
        let modified: Date
        let created: Date
    }
    private struct ThumbnailWork {
        let id: UUID
        let item: FileItem
        let version: ThumbnailVersion
        let attempt: Int
        let admittedAt = ContinuousClock.now
        var cancel: (() -> Void)?
        var deadline: Task<Void, Never>?
    }
    private let thumbnailLimits: ThumbnailLimits
    private var capacityNotificationPending = false
    private var activeThumbnails: [String: ThumbnailWork] = [:]
    private var queuedThumbnails: [ThumbnailWork] = []
    private var thumbnailVersions: [String: ThumbnailVersion] = [:]
    // Includes negative results: a failed provider must not create a redraw loop.
    private var completedThumbnailPaths: [String] = []
    private struct ThumbnailFailure {
        let attempt: Int
        let retryAt: ContinuousClock.Instant?
    }
    private var thumbnailFailures: [String: ThumbnailFailure] = [:]
    private var retryWake: Task<Void, Never>?
    typealias ThumbnailGenerator = @MainActor (FileItem, @escaping (NSImage?) -> Void) -> (() -> Void)
    private let thumbnailGenerator: ThumbnailGenerator

    init(thumbnailLimits: ThumbnailLimits = ThumbnailLimits(),
         thumbnailGenerator: ThumbnailGenerator? = nil) {
        precondition(thumbnailLimits.active > 0 && thumbnailLimits.queued >= 0 && thumbnailLimits.cached > 0 && thumbnailLimits.retries >= 0 && thumbnailLimits.retryDelay > .zero)
        self.thumbnailLimits = thumbnailLimits
        self.thumbnailGenerator = thumbnailGenerator ?? { item, completion in
            FileIconCache.generateThumbnail(for: item, completion: completion)
        }
    }

    private static func generateThumbnail(for item: FileItem, completion: @escaping (NSImage?) -> Void) -> (() -> Void) {
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url, size: CGSize(width: 160, height: 160), scale: 2.0,
            representationTypes: .thumbnail
        )
        let generator = QLThumbnailGenerator.shared
        generator.generateBestRepresentation(for: request) { representation, _ in
            completion(representation?.nsImage)
        }
        // Retain the exact native handle until completion or cancellation.
        return { generator.cancel(request) }
    }

    var activeThumbnailCount: Int { activeThumbnails.count }
    var queuedThumbnailCount: Int { queuedThumbnails.count }
    var completedThumbnailCount: Int { completedThumbnailPaths.count }
    var retainedThumbnailVersionCount: Int { thumbnailVersions.count }

    public func invalidate(containing changedPath: String) {
        let path = URL(fileURLWithPath: changedPath).standardizedFileURL.path
        let candidates = Set(thumbnailVersions.keys)
        for candidate in candidates where candidate == path || candidate.hasPrefix(path == "/" ? "/" : path + "/") {
            discardThumbnail(path: candidate)
            cache.removeValue(forKey: candidate)
        }
        drainThumbnailQueue()
        scheduleThumbnailRetryWake()
        publishThumbnailCapacity()
    }

    private func discardThumbnail(path: String) {
        // Remove identity BEFORE invoking cancel: cancellation can race completion.
        let work = activeThumbnails.removeValue(forKey: path)
        queuedThumbnails.removeAll { $0.item.path == path }
        thumbnailVersions.removeValue(forKey: path)
        completedThumbnailPaths.removeAll { $0 == path }
        thumbnailFailures.removeValue(forKey: path)
        if thumbnails[path] != nil { thumbnails.removeValue(forKey: path) }
        work?.deadline?.cancel()
        work?.cancel?()
    }

    private func synchronizeThumbnailVersion(for item: FileItem) {
        let version = ThumbnailVersion(size: item.size, modified: item.modificationDate, created: item.creationDate)
        if let existing = thumbnailVersions[item.path], existing != version {
            discardThumbnail(path: item.path)
            drainThumbnailQueue()
        }
    }

    public func icon(for item: FileItem, preferThumbnail: Bool = true) -> NSImage {
        if preferThumbnail && item.supportsRichThumbnail { synchronizeThumbnailVersion(for: item) }
        if preferThumbnail && item.supportsRichThumbnail, let thumb = thumbnails[item.path] {
            return thumb
        }
        if preferThumbnail && item.supportsRichThumbnail {
            requestThumbnailIfNeeded(for: item)
        }
        let cacheKey = item.isDirectory || item.fileExtension.isEmpty
            ? item.path : "ext:\(item.fileExtension.lowercased()):\(item.isSymlink)"
        if let cached = cache[cacheKey] { return cached }
        if !pendingIcons.contains(cacheKey), pendingIcons.count < 256 {
            pendingIcons.insert(cacheKey)
            let path = item.path
            iconQueue.addOperation { [weak self] in
                let image = NSWorkspace.shared.icon(forFile: path)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pendingIcons.remove(cacheKey)
                    if self.cache.count > 2500 { self.cache.removeAll(keepingCapacity: true) }
                    self.cache[cacheKey] = image
                }
            }
        }
        // Type icons don't inspect the file or wait for its metadata provider.
        let type = item.isDirectory ? UTType.folder : (UTType(filenameExtension: item.fileExtension) ?? .data)
        if let generic = genericIcons[type.identifier] { return generic }
        let generic = NSWorkspace.shared.icon(for: type)
        genericIcons[type.identifier] = generic
        return generic
    }

    public func requestThumbnailIfNeeded(for item: FileItem) {
        guard item.supportsRichThumbnail else { return }
        synchronizeThumbnailVersion(for: item)
        let path = item.path
        let retry = thumbnailFailures[path]
        if thumbnailVersions[path] != nil {
            guard let retryAt = retry?.retryAt, retryAt <= .now else { return }
        }
        // Keep admitted work FIFO. Never evict queued work silently: callers that
        // were not admitted get another chance on the next capacity notification.
        guard activeThumbnails.count < thumbnailLimits.active || queuedThumbnails.count < thumbnailLimits.queued else { return }
        let version = ThumbnailVersion(size: item.size, modified: item.modificationDate, created: item.creationDate)
        let work = ThumbnailWork(id: UUID(), item: item, version: version, attempt: retry.map { $0.attempt + 1 } ?? 0)
        completedThumbnailPaths.removeAll { $0 == path }
        thumbnailFailures.removeValue(forKey: path)
        thumbnailVersions[path] = version
        if activeThumbnails.count < thumbnailLimits.active {
            startThumbnail(work)
        } else {
            queuedThumbnails.append(work)
        }
    }

    private func startThumbnail(_ work: ThumbnailWork) {
        let path = work.item.path
        activeThumbnails[path] = work
        let cancel = thumbnailGenerator(work.item) { [weak self] image in
            Task { @MainActor [weak self] in
                self?.completeThumbnail(path: path, id: work.id, version: work.version, image: image)
            }
        }
        // Also safe with an injected generator that invokes completion inline:
        // completion is always delivered through the main actor task above.
        if activeThumbnails[path]?.id == work.id {
            activeThumbnails[path]?.cancel = cancel
            let timeout = thumbnailLimits.timeout
            activeThumbnails[path]?.deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, self.activeThumbnails[path]?.id == work.id else { return }
                // A provider need not ever call back. Release logical admission
                // after cancellation; framework cancellation remains best effort.
                self.activeThumbnails[path]?.cancel?()
                self.completeThumbnail(path: path, id: work.id, version: work.version, image: nil)
            }
        } else {
            cancel()
        }
    }

    private func completeThumbnail(path: String, id: UUID, version: ThumbnailVersion, image: NSImage?) {
        guard activeThumbnails[path]?.id == id, thumbnailVersions[path] == version else { return }
        guard let finished = activeThumbnails.removeValue(forKey: path) else { return }
        finished.deadline?.cancel()
        while completedThumbnailPaths.count >= thumbnailLimits.cached {
            let evicted = completedThumbnailPaths.removeFirst()
            if thumbnails[evicted] != nil { thumbnails.removeValue(forKey: evicted) }
            thumbnailVersions.removeValue(forKey: evicted)
            thumbnailFailures.removeValue(forKey: evicted)
        }
        completedThumbnailPaths.append(path)
        if let image {
            thumbnails[path] = image
        } else {
            // A nil representation does not prove permanent lack of support:
            // provider busy/errors and our deadline receive bounded delayed retries.
            // Exhausted failures remain stable until invalidation/version change
            // or ordinary bounded-cache eviction, avoiding a malformed-file loop.
            let retryAt: ContinuousClock.Instant? = finished.attempt < thumbnailLimits.retries
                ? .now.advanced(by: thumbnailLimits.retryDelay * (finished.attempt + 1)) : nil
            thumbnailFailures[path] = ThumbnailFailure(attempt: finished.attempt, retryAt: retryAt)
        }
        scheduleThumbnailRetryWake()
        drainThumbnailQueue()
        // Success, error and cancellation must all wake rejected visible demand.
        // No rejected-key set or scheduled retry tasks can grow without bound.
        publishThumbnailCapacity()
    }

    private func scheduleThumbnailRetryWake() {
        retryWake?.cancel()
        retryWake = nil
        let now = ContinuousClock.now
        // Due failures remain cached until visible demand actually retries them.
        // Do not spin or retain a task per failed file.
        guard let next = thumbnailFailures.values.compactMap(\.retryAt).filter({ $0 > now }).min() else { return }
        retryWake = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: now.duration(to: next)) } catch { return }
            guard let self else { return }
            self.publishThumbnailCapacity()
            self.scheduleThumbnailRetryWake()
        }
    }

    private func publishThumbnailCapacity() {
        guard !capacityNotificationPending else { return }
        capacityNotificationPending = true
        Task { @MainActor [weak self] in
            // Batch completions/invalidation bursts into one observer wake-up.
            await Task.yield()
            guard let self else { return }
            self.capacityNotificationPending = false
            self.thumbnailCapacityRevision &+= 1
        }
    }

    private func drainThumbnailQueue() {
        while activeThumbnails.count < thumbnailLimits.active && !queuedThumbnails.isEmpty {
            let work = queuedThumbnails.removeFirst()
            if work.admittedAt.duration(to: .now) >= thumbnailLimits.maxQueueAge {
                // No per-view ownership exists in this shared cache. Expire old
                // queued demand instead of letting a previous folder monopolize
                // admission; still-visible views may re-admit after notification.
                thumbnailVersions.removeValue(forKey: work.item.path)
                publishThumbnailCapacity()
                continue
            }
            startThumbnail(work)
        }
    }
}
