import Foundation

/// A saved search is a search context, not just text. Preference decoding is
/// deliberately pure: no directory access, indexing, mounting or navigation.
public struct SavedSmartFolderItem: Identifiable, Codable, Hashable, Sendable {
    public let version: Int
    public let id: String
    public let title: String
    public let query: String
    public let scope: SearchScopeMode
    public let rootPath: String?
    public let includeHidden: Bool
    public let fuzzyEnabled: Bool

    public init(id: String = UUID().uuidString, title: String, query: String,
                scope: SearchScopeMode, rootPath: String?,
                includeHidden: Bool, fuzzyEnabled: Bool) {
        self.version = 1
        self.id = id
        self.title = title
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope
        self.rootPath = scope == .wholeIndex ? nil : rootPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        }
        self.includeHidden = includeHidden
        self.fuzzyEnabled = fuzzyEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, title, query, scope, rootPath, includeHidden, fuzzyEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        query = try values.decode(String.self, forKey: .query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .query, in: values, debugDescription: "Empty saved search")
        }
        if !values.contains(.version) {
            // Original records contained exactly id/title/query. Never reinterpret
            // an incomplete newer record as a broader legacy whole-index search.
            guard !values.contains(.scope), !values.contains(.rootPath),
                  !values.contains(.includeHidden), !values.contains(.fuzzyEnabled) else {
                throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Missing saved-search version")
            }
            version = 1
            scope = .wholeIndex
            rootPath = nil
            includeHidden = false
            fuzzyEnabled = true
            return
        }
        version = try values.decode(Int.self, forKey: .version)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported saved-search version")
        }
        scope = try values.decode(SearchScopeMode.self, forKey: .scope)
        includeHidden = try values.decode(Bool.self, forKey: .includeHidden)
        fuzzyEnabled = try values.decode(Bool.self, forKey: .fuzzyEnabled)
        if scope == .wholeIndex {
            rootPath = nil
        } else {
            let path = try values.decode(String.self, forKey: .rootPath)
            guard path.hasPrefix("/"), !path.utf8.contains(0) else {
                throw DecodingError.dataCorruptedError(forKey: .rootPath, in: values, debugDescription: "Saved local search requires an absolute directory path")
            }
            rootPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        }
    }

    @MainActor public static func capture(from pane: PaneTabState, title: String? = nil) -> SavedSmartFolderItem {
        let query = pane.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return SavedSmartFolderItem(title: title ?? query, query: query, scope: pane.searchScope,
                                    rootPath: pane.currentURL.path, includeHidden: pane.showHiddenFiles,
                                    fuzzyEnabled: pane.fuzzyEnabled)
    }

    public func hasSameSearch(as other: SavedSmartFolderItem) -> Bool {
        query == other.query && scope == other.scope && rootPath == other.rootPath
            && includeHidden == other.includeHidden && fuzzyEnabled == other.fuzzyEnabled
    }

    @MainActor public func matches(_ pane: PaneTabState) -> Bool {
        hasSameSearch(as: Self.capture(from: pane))
    }

    public var scopeDescription: String {
        let location: String
        switch scope {
        case .wholeIndex: location = "Cały indeks"
        case .currentFolder: location = "Tylko folder: \(rootPath ?? "brak ścieżki")"
        case .recursiveFolder: location = "Folder i podfoldery: \(rootPath ?? "brak ścieżki")"
        }
        return location + (includeHidden ? " · z ukrytymi" : " · bez ukrytych")
            + (fuzzyEnabled ? " · dopasowanie przybliżone" : " · dopasowanie dokładne")
    }

    /// Called only after explicit invocation. A missing/unreadable root is an
    /// error, never a reason to silently widen the query or substitute home.
    public func validatedRootURL(fileManager: FileManager = .default) throws -> URL? {
        guard scope != .wholeIndex else { return nil }
        guard let path = rootPath, path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw SavedSearchError.unavailableRoot(rootPath ?? "brak ścieżki")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.isReadableFile(atPath: path), fileManager.isExecutableFile(atPath: path) else {
            throw SavedSearchError.unavailableRoot(path)
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
}

public enum SavedSearchError: LocalizedError {
    case unavailableRoot(String)

    public var errorDescription: String? {
        switch self {
        case .unavailableRoot(let path):
            return "Nie można otworzyć zapisanego wyszukiwania: folder jest niedostępny (\(path)). Przywróć dostęp lub podłącz dysk i wybierz wyszukiwanie ponownie. Zakres nie został zmieniony."
        }
    }
}

/// Preserve unsupported or malformed individual records when editing the valid
/// ones. A damaged outer document is not silently overwritten with an empty list.
struct SavedSearchArchive {
    let items: [SavedSmartFolderItem]
    private let opaqueRecords: [Data]

    init() {
        items = []
        opaqueRecords = []
    }

    init(data: Data) throws {
        guard let records = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var known: [SavedSmartFolderItem] = []
        var opaque: [Data] = []
        for record in records {
            let bytes = try JSONSerialization.data(withJSONObject: record, options: [.fragmentsAllowed])
            if let item = try? JSONDecoder().decode(SavedSmartFolderItem.self, from: bytes),
               !known.contains(where: { $0.id == item.id }) {
                known.append(item)
            } else {
                opaque.append(bytes)
            }
        }
        items = known
        opaqueRecords = opaque
    }

    func encoded(replacingItems items: [SavedSmartFolderItem], removingID: String? = nil) throws -> Data {
        var records = try items.map {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
        }
        records += try opaqueRecords.compactMap { bytes -> Any? in
            let record = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
            if let removingID, let object = record as? [String: Any], object["id"] as? String == removingID {
                return nil
            }
            return record
        }
        return try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
    }
}

struct PreparedSavedSearch: Sendable {
    let root: URL?
    let entries: [IndexedFileEntry]
}

/// Owns a queued or running operation and its continuation. Cancellation resumes
/// exactly once immediately, even if the OS call itself cannot be interrupted.
final class SavedSearchWork<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: BlockOperation?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        let operation = self.operation
        self.operation = nil
        lock.unlock()
        operation?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    func enqueue(on queue: OperationQueue, continuation: CheckedContinuation<Value, Error>,
                 work: @escaping @Sendable () throws -> Value) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let operation = BlockOperation { [self] in
            guard !isCancelled else { return }
            let result = Result { try work() }
            finish(result)
        }
        self.operation = operation
        lock.unlock()
        queue.addOperation(operation)
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.operation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

enum SavedSearchPreparation {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.burrow.saved-search-preparation"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func prepare(_ item: SavedSmartFolderItem, isCancelled: @Sendable () -> Bool = { false }) throws -> PreparedSavedSearch {
        if isCancelled() { throw CancellationError() }
        guard let root = try item.validatedRootURL() else {
            return PreparedSavedSearch(root: nil, entries: [])
        }
        if isCancelled() { throw CancellationError() }
        let result = BulkCrawler.readDirectoryResult(at: root.path, includeHidden: item.includeHidden,
                                                     isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        // Like session restore, an unreadable or truncated root is a failure, not an empty folder.
        if result.errorCode == EACCES || result.errorCode == EPERM { throw FinderSessionReadError.permissionDenied }
        guard result.isComplete else { throw FinderSessionReadError.incomplete }
        return PreparedSavedSearch(root: root, entries: result.entries)
    }

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T,
                                request: SavedSearchWork<T> = SavedSearchWork<T>()) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.enqueue(on: queue, continuation: continuation, work: work)
            }
        } onCancel: {
            request.cancel()
        }
    }
}
