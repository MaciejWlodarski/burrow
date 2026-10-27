import Foundation

public struct IndexingConfiguration: Codable, Equatable, Sendable {
    public let roots: [String]
    public let skippedDirectoryNames: Set<String>
    public let skipHeavyDevDirs: Bool
    public let usePersistentMMapCache: Bool

    public static let disabled = IndexingConfiguration(roots: [], skippedDirectoryNames: [],
        skipHeavyDevDirs: true, usePersistentMMapCache: false)

    var isValid: Bool {
        roots.count <= 1024 && skippedDirectoryNames.count <= 4096 &&
        roots.allSatisfy { $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") } &&
        skippedDirectoryNames.allSatisfy { !$0.isEmpty && $0.utf8.count <= 255 && !$0.contains("/") && !$0.contains("\0") }
    }
}

public protocol IndexingPreferencesStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}
extension UserDefaults: IndexingPreferencesStorage {}

/// Injected only by application composition; explicit fixture engines never read defaults.
public final class IndexingPreferences {
    public static let key = "bf.indexingConfiguration"
    private let defaults: any IndexingPreferencesStorage
    private struct Record: Codable { let version: Int; let configuration: IndexingConfiguration }
    public enum LoadResult { case configuration(IndexingConfiguration), blocked }
    public enum SaveError: Error { case repairRequired, invalidConfiguration, verificationFailed }
    public init(defaults: any IndexingPreferencesStorage) { self.defaults = defaults }

    public func load(defaultConfiguration: @autoclosure () -> IndexingConfiguration) -> LoadResult {
        guard let raw = defaults.object(forKey: Self.key) else { return .configuration(defaultConfiguration()) }
        guard let data = raw as? Data, data.count <= 1_048_576,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.configuration.isValid else { return .blocked }
        return .configuration(record.configuration)
    }

    public func save(_ configuration: IndexingConfiguration, explicitlyRepair: Bool = false) throws {
        guard configuration.isValid else { throw SaveError.invalidConfiguration }
        if case .blocked = load(defaultConfiguration: .disabled) {
            guard explicitlyRepair else { throw SaveError.repairRequired }
            // Retain the exact property-list value, including wrong-type records.
            // Each repair gets its own backup; later repairs cannot destroy it.
            if let raw = defaults.object(forKey: Self.key) {
                let backupKey = Self.key + ".preserved." + UUID().uuidString
                defaults.set(raw, forKey: backupKey)
                guard let original = raw as? NSObject,
                      original.isEqual(defaults.object(forKey: backupKey)) else {
                    throw SaveError.verificationFailed
                }
            }
        }
        let data = try JSONEncoder().encode(Record(version: 1, configuration: configuration))
        guard data.count <= 1_048_576 else { throw SaveError.invalidConfiguration }
        let original = defaults.object(forKey: Self.key)
        defaults.set(data, forKey: Self.key)
        guard defaults.object(forKey: Self.key) as? Data == data else {
            // A rejected write must not apply a new live configuration or launch a crawl.
            defaults.set(original, forKey: Self.key)
            throw SaveError.verificationFailed
        }
    }
}

public struct IndexingLifecycleEvent: Sendable {
    public let revision: UInt64
    public let generation: UInt64
    public let isIndexing: Bool
}

/// Main-actor consumers discard delayed older events, including old idle events.
public struct IndexingLifecycleState {
    public private(set) var revision: UInt64 = 0
    public private(set) var isIndexing = false
    public init() {}
    public mutating func apply(_ event: IndexingLifecycleEvent) {
        guard event.revision >= revision else { return }
        revision = event.revision
        isIndexing = event.isIndexing
    }
}
