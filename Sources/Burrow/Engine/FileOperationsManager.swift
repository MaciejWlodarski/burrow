import Foundation
import AppKit
import Darwin

public enum NewFileTemplate: String, CaseIterable, Identifiable {
    case emptyText = "Text File (.txt)"
    case markdown = "Markdown Document (.md)"
    case swift = "Swift Source (.swift)"
    case json = "JSON File (.json)"
    case python = "Python Script (.py)"
    case shell = "Shell Script (.sh)"

    public var id: String { rawValue }

    public var defaultFilename: String {
        switch self {
        case .emptyText: return "Untitled.txt"
        case .markdown: return "Notes.md"
        case .swift: return "File.swift"
        case .json: return "config.json"
        case .python: return "script.py"
        case .shell: return "run.sh"
        }
    }

    public var initialContent: String {
        switch self {
        case .emptyText: return ""
        case .markdown: return "# Title\n\n"
        case .swift: return "import Foundation\n\n"
        case .json: return "{\n  \n}\n"
        case .python: return "#!/usr/bin/env python3\n\n"
        case .shell: return "#!/usr/bin/env zsh\nset -euo pipefail\n\n"
        }
    }
}

public enum FileConflictPolicy: String, CaseIterable, Identifiable {
    case ask = "Pytaj przy konflikcie"
    case keepBoth = "Zachowaj oba (dopisz licznik)"
    case overwrite = "Zastąp istniejący"
    case skip = "Pomiń istniejący"

    public var id: String { rawValue }
}

public struct PendingTransferConflict: Identifiable {
    public let id: UUID
    public let sourceURLs: [URL]
    public let destinationDirectory: URL
    public let conflictingNames: [String]
    public let isMove: Bool
    public let copyAcrossVolumes: Bool
    public let completion: (@MainActor ([URL]) -> Void)?
}

public struct TransferProgressInfo {
    public let title: String
    public let currentFile: String
    public let completedCount: Int
    public let totalCount: Int
    public let isCancellable: Bool

    public init(title: String, currentFile: String, completedCount: Int, totalCount: Int, isCancellable: Bool = false) {
        self.title = title
        self.currentFile = currentFile
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.isCancellable = isCancellable
    }

    public var fraction: Double {
        guard totalCount > 0 else { return 1.0 }
        return Double(completedCount) / Double(totalCount)
    }
}

public struct GitStatusSnapshot: Sendable {
    /// Inspection deliberately never executes conversion helpers. With configured
    /// filters (including LFS), raw bytes can look modified even when trusted Git's
    /// filtered comparison would be clean. Submodule contents are not inspected.
    public let usesRawContentComparison: Bool
    public let repositoryRoot: String
    public let statuses: [String: GitFileStatus]
}

public struct UndoableFileOperation {
    public enum Kind {
        case actions([FileHistoryAction])
    }
    /// Both stacks retain this identity while a transaction is only partly applied.
    public let transactionID: UUID
    public let label: String
    public let kind: Kind

    public init(label: String, kind: Kind, transactionID: UUID = UUID()) {
        self.transactionID = transactionID
        self.label = label
        self.kind = kind
    }
}

/// Actions describe the next direction to execute, so replacement undo and redo keep
/// both the incoming item and the displaced original, including after a partial failure.
/// No-follow identity of the directory entry, not the data its symlink points
/// at. Content, size, mtime and permissions deliberately do not define identity:
/// legitimate edits to the same object must not invalidate its history.
struct FileEntryIdentity: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let type: UInt32
    let generation: UInt32
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    static func read(_ url: URL) throws -> FileEntryIdentity {
        var value = stat()
        guard url.path.withCString({ lstat($0, &value) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard value.st_ino != 0 else {
            throw FileOperationFailure(message: "Wolumin nie udostępnia wiarygodnej tożsamości elementu.")
        }
        return FileEntryIdentity(device: Int64(value.st_dev), inode: UInt64(value.st_ino),
            type: UInt32(value.st_mode & S_IFMT), generation: UInt32(value.st_gen),
            birthSeconds: Int64(value.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec))
    }
}

public struct FileHistoryAction {
    enum Operation {
        case move(from: URL, to: URL)
        case restore(from: URL, to: URL)
        case trash(URL)
    }
    let operation: Operation
    let identity: FileEntryIdentity?

    private init(_ operation: Operation, source: URL, io: FileOperationIO) {
        self.operation = operation
        self.identity = try? io.identity(source)
    }

    // Capture at operation completion, NEVER when the user later presses Undo.
    // Failed identity reads remain explicit unexecutable recovery records.
    static func move(from: URL, to: URL, io: FileOperationIO = .live) -> Self {
        Self(.move(from: from, to: to), source: from, io: io)
    }
    static func restore(from: URL, to: URL, io: FileOperationIO = .live) -> Self {
        Self(.restore(from: from, to: to), source: from, io: io)
    }
    static func trash(_ url: URL, io: FileOperationIO = .live) -> Self {
        Self(.trash(url), source: url, io: io)
    }
    var sourceURL: URL {
        switch operation {
        case .move(let from, _), .restore(let from, _): return from
        case .trash(let url): return url
        }
    }
    func validate(io: FileOperationIO) throws {
        guard let identity, let current = try? io.identity(sourceURL), current == identity else {
            throw FileOperationFailure(message: "Nie wykonano historii dla „\(sourceURL.lastPathComponent)”: obiekt zmienił się lub nie można potwierdzić jego tożsamości. Zachowano oczekującą operację.")
        }
    }
}

struct FileOperationIO {
    var identity: (URL) throws -> FileEntryIdentity
    var readPermissions: (URL) throws -> UInt16
    var writePermissions: (URL, UInt16) throws -> Void
    var resolveEntryPath: (URL) -> String
    var resolveDirectoryPath: (URL) -> String
    var exists: (URL) -> Bool
    var createDirectory: (URL) throws -> Void
    var move: (URL, URL) throws -> Void
    var copy: (URL, URL) throws -> Void
    var publishExclusive: (URL, URL) throws -> Void
    var trash: (URL) throws -> URL
    var removeEmptyDirectory: (URL) -> Void

    static let live = FileOperationIO(
        identity: FileEntryIdentity.read,
        readPermissions: { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let mode = attributes[.posixPermissions] as? NSNumber else {
                throw FileOperationFailure(message: "Nie można odczytać uprawnień elementu.")
            }
            return mode.uint16Value & 0o7777
        },
        writePermissions: { url, mode in
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        },
        resolveEntryPath: { FileTransferPaths.entryPath($0) },
        resolveDirectoryPath: { $0.resolvingSymlinksInPath().standardizedFileURL.path },
        exists: { (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil },
        createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) },
        move: { try FileManager.default.moveItem(at: $0, to: $1) },
        copy: { try FileManager.default.copyItem(at: $0, to: $1) },
        publishExclusive: { try SafeArchivePublication.moveExclusive(from: $0, to: $1) },
        trash: { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            guard let trashed = result as URL? else {
                throw FileOperationFailure(message: "Element „\(url.lastPathComponent)” jest w Koszu, ale system nie zwrócił ścieżki do przywrócenia.")
            }
            return trashed
        },
        removeEmptyDirectory: { url in
            // rmdir cannot recursively delete an item left behind by a failed transfer.
            _ = url.path.withCString { rmdir($0) }
        }
    )
}

struct PosixPermissionSnapshot: Sendable {
    let identity: FileEntryIdentity
    let mode: UInt16

    static func read(_ url: URL, io: FileOperationIO = .live) throws -> Self {
        let identity = try io.identity(url)
        guard identity.type == UInt32(S_IFREG) || identity.type == UInt32(S_IFDIR) else {
            throw FileOperationFailure(message: "Edytor nie zmienia uprawnień dowiązań ani specjalnych wpisów.")
        }
        let mode = try io.readPermissions(url)
        guard try io.identity(url) == identity else {
            throw FileOperationFailure(message: "Element zmienił się podczas odczytu uprawnień.")
        }
        return Self(identity: identity, mode: mode)
    }
}

enum PosixPermissionChange: Sendable {
    case bit(UInt16, enabled: Bool)
    case ordinaryMode(UInt16)

    func applying(to current: UInt16) throws -> UInt16 {
        switch self {
        case .bit(let bit, let enabled):
            guard bit != 0, bit & (bit - 1) == 0, bit & ~0o777 == 0 else {
                throw FileOperationFailure(message: "Nieprawidłowy bit uprawnień.")
            }
            return enabled ? current | bit : current & ~bit
        case .ordinaryMode(let mode):
            guard mode & ~0o777 == 0 else {
                throw FileOperationFailure(message: "Preset może zmieniać tylko zwykłe bity uprawnień.")
            }
            return (current & ~0o777) | mode
        }
    }

    static func format(_ mode: UInt16) -> String {
        let chars: [Character] = [
            mode & 0o400 != 0 ? "r" : "-", mode & 0o200 != 0 ? "w" : "-",
            mode & 0o4000 != 0 ? (mode & 0o100 != 0 ? "s" : "S") : (mode & 0o100 != 0 ? "x" : "-"),
            mode & 0o040 != 0 ? "r" : "-", mode & 0o020 != 0 ? "w" : "-",
            mode & 0o2000 != 0 ? (mode & 0o010 != 0 ? "s" : "S") : (mode & 0o010 != 0 ? "x" : "-"),
            mode & 0o004 != 0 ? "r" : "-", mode & 0o002 != 0 ? "w" : "-",
            mode & 0o1000 != 0 ? (mode & 0o001 != 0 ? "t" : "T") : (mode & 0o001 != 0 ? "x" : "-")
        ]
        return String(format: "%@ (%04o)", String(chars), mode & 0o7777)
    }
}

struct FileOperationFailure: LocalizedError {
    let message: String
    var recoveryActions: [FileHistoryAction] = []
    var errorDescription: String? { message }
}

/// Archive subprocesses only touch privately reserved staging paths. Final
/// publication is one same-filesystem, no-replace rename, not a check-then-move.
enum SafeArchivePublication {
    static func stagingDirectory(in parent: URL) throws -> URL {
        let staging = parent.appendingPathComponent(".burrow-archive-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return staging
    }

    static func moveExclusive(from source: URL, to destination: URL) throws {
        // Some network/filesystem implementations do not support exclusive
        // rename. Do not fall back to a racy check followed by ordinary rename.
        let parent = destination.deletingLastPathComponent()
        let capabilities = try parent.resourceValues(forKeys: [.volumeSupportsExclusiveRenamingKey])
        guard capabilities.volumeSupportsExclusiveRenaming == true else {
            throw FileOperationFailure(message: "Ten wolumin nie obsługuje bezpiecznego publikowania bez zastępowania; zachowano dane tymczasowe.")
        }
        let result = source.path.withCString { from in
            destination.path.withCString { to in
                Darwin.renamex_np(from, to, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST || code == ENOTEMPTY {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }
}

/// Resolve traversed parent directories, but not the entry itself: copying a
/// symbolic link copies the link, not the directory it happens to point at.
/// These checks prevent stable aliases from bypassing containment checks. They
/// are not filesystem locks against another process retargeting a link mid-copy.
enum FileTransferPaths {
    private static func contains(_ path: String, within ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor == "/" ? "/" : ancestor + "/")
    }

    static func entryPath(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }

    static func destinationIsInsideSource(_ directory: URL, source: URL, io: FileOperationIO = .live) -> Bool {
        let sourcePath = io.resolveEntryPath(source)
        let destinationPath = io.resolveDirectoryPath(directory)
        return contains(destinationPath, within: sourcePath)
    }

    static func sameEntry(_ lhs: URL, _ rhs: URL, io: FileOperationIO = .live) -> Bool {
        io.resolveEntryPath(lhs) == io.resolveEntryPath(rhs)
    }

    static func sourceIsInsideTarget(_ source: URL, target: URL, io: FileOperationIO = .live) -> Bool {
        let sourcePath = io.resolveEntryPath(source)
        let targetPath = io.resolveEntryPath(target)
        return contains(sourcePath, within: targetPath)
    }
}

enum SafeFileReplacement {
    /// Fully prepare the incoming item before touching the destination. The staging
    /// directory is on the destination volume, so installation is a local move.
    static func replace(source: URL, target: URL, isMove: Bool, io: FileOperationIO = .live) throws -> [FileHistoryAction] {
        guard !FileTransferPaths.sourceIsInsideTarget(source, target: target, io: io) else {
            throw FileOperationFailure(message: "Nie można zastąpić folderu zawierającego plik źródłowy.")
        }
        let stagingDirectory = target.deletingLastPathComponent()
            .appendingPathComponent(".burrow-transfer-\(UUID().uuidString)", isDirectory: true)
        let staged = stagingDirectory.appendingPathComponent(source.lastPathComponent)
        try io.createDirectory(stagingDirectory)
        var displaced: URL?
        var restoreDisplaced: FileHistoryAction?
        var restoreStaged: FileHistoryAction?
        do {
            if isMove {
                try io.move(source, staged)
            } else {
                try io.copy(source, staged)
            }
            if isMove { restoreStaged = .move(from: staged, to: source, io: io) }
            let original = try io.trash(target)
            displaced = original
            restoreDisplaced = .move(from: original, to: target, io: io)
            try io.move(staged, target)
            io.removeEmptyDirectory(stagingDirectory)
            let undoIncoming: FileHistoryAction = isMove ? .move(from: target, to: source, io: io) : .trash(target, io: io)
            return [undoIncoming, restoreDisplaced!]
        } catch {
            var details = [error.localizedDescription]
            var recoveryActions: [FileHistoryAction] = []
            if let displaced {
                do {
                    try restoreDisplaced?.validate(io: io)
                    try io.move(displaced, target)
                } catch {
                    details.append("Nie przywrócono oryginału; zachowano go w \(displaced.path): \(error.localizedDescription)")
                    if let restoreDisplaced { recoveryActions.append(restoreDisplaced) }
                }
            }
            if isMove && io.exists(staged) {
                // A failed move may have left an owned partial entry in staging.
                // Bind that recovery entry now; never store a bare deferred path.
                let recovery = restoreStaged ?? .move(from: staged, to: source, io: io)
                do {
                    try recovery.validate(io: io)
                    try io.move(staged, source)
                } catch {
                    details.append("Plik źródłowy zachowano w \(staged.path): \(error.localizedDescription)")
                    recoveryActions.append(recovery)
                }
            }
            // Keep partial copies/moves for recovery; never remove an original as a fallback.
            if io.exists(staged) {
                details.append("Dane operacji zachowano w \(staged.path)")
            }
            io.removeEmptyDirectory(stagingDirectory)
            throw FileOperationFailure(message: details.joined(separator: "; "), recoveryActions: recoveryActions)
        }
    }
}

enum FileHistoryExecutor {
    struct Result {
        var inverse: [FileHistoryAction] = []
        var pending: [FileHistoryAction] = []
        var touchedDirectories = Set<String>()
        var completedCount = 0
        var error: String?
    }

    static func execute(_ actions: [FileHistoryAction], io: FileOperationIO = .live) -> Result {
        var result = Result()
        for (index, action) in actions.enumerated() {
            do {
                try action.validate(io: io)
                switch action.operation {
                case .move(let from, let to):
                    try io.move(from, to)
                    result.inverse.append(.move(from: to, to: from, io: io))
                    result.touchedDirectories.insert(from.deletingLastPathComponent().path)
                    result.touchedDirectories.insert(to.deletingLastPathComponent().path)
                case .restore(let from, let requested):
                    let to = io.exists(requested) ? FileOperationsManager.uniqueURL(for: requested) : requested
                    try io.move(from, to)
                    result.inverse.append(.move(from: to, to: from, io: io))
                    result.touchedDirectories.insert(from.deletingLastPathComponent().path)
                    result.touchedDirectories.insert(to.deletingLastPathComponent().path)
                case .trash(let url):
                    let trashed = try io.trash(url)
                    result.inverse.append(.move(from: trashed, to: url, io: io))
                    result.touchedDirectories.insert(url.deletingLastPathComponent().path)
                }
                result.completedCount += 1
            } catch {
                result.pending = Array(actions[index...])
                result.error = error.localizedDescription
                break
            }
        }
        result.inverse.reverse()
        return result
    }
}

struct CutClipboardSnapshot {
    let changeCount: Int

    func remainingURLs(_ urls: [URL], internalChangeCount: Int, systemChangeCount: Int, movedSources: [URL]) -> [URL]? {
        guard internalChangeCount == changeCount, systemChangeCount == changeCount else { return nil }
        let movedPaths = Set(movedSources.map { $0.standardizedFileURL.path })
        return urls.filter { !movedPaths.contains($0.standardizedFileURL.path) }
    }
}

/// Thread-safe cancellation flag shared between the UI and a background transfer.
private final class TransferCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

@MainActor
public final class FileOperationsManager: ObservableObject {
    public static let shared = FileOperationsManager()

    public enum ClipboardMode {
        case copy
        case cut
    }

    @Published public private(set) var clipboardURLs: [URL] = []
    @Published public private(set) var clipboardMode: ClipboardMode = .copy
    @Published public var lastStatusMessage: String? {
        didSet { scheduleStatusMessageExpiry() }
    }
    private var statusMessageGeneration: UInt64 = 0

    /// Transient confirmations ("Skopiowano…") should not linger in the status bar
    /// forever; a newer message restarts the timer and is never cleared early.
    private func scheduleStatusMessageExpiry() {
        statusMessageGeneration &+= 1
        #if !BURROW_TESTING
        guard lastStatusMessage != nil else { return }
        let generation = statusMessageGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.statusMessageGeneration == generation else { return }
            self.lastStatusMessage = nil
        }
        #endif
    }

    // Undo / Redo Stacks
    @Published public private(set) var undoStack: [UndoableFileOperation] = []
    @Published public private(set) var redoStack: [UndoableFileOperation] = []

    // Conflict Resolution & Transfer Progress
    @Published public var defaultConflictPolicy: FileConflictPolicy = .ask {
        didSet {
            #if !BURROW_TESTING
            UserDefaults.standard.set(defaultConflictPolicy.rawValue, forKey: "bf.defaultConflictPolicy")
            #endif
        }
    }
    @Published public var pendingConflict: PendingTransferConflict? = nil
    @Published public private(set) var activeTransfer: TransferProgressInfo? = nil

    /// `NSPasteboard.changeCount` captured when this app last wrote files to the pasteboard.
    /// Used to detect whether the internal cut/copy clipboard is still current.
    private var clipboardChangeCount: Int = -1
    private var transferCancellation: TransferCancellationFlag?
    private var preflightRequestID: UUID?
    private static let duplicateCleanupQueue = DispatchQueue(label: "com.burrow.duplicate-cleanup", qos: .userInitiated)
    @Published private(set) var activeDuplicateCleanupID: UUID?
    private var duplicateCleanupCancellation: DuplicateCleanupCancellation?
    private let duplicateCleanupIO: DuplicateCleanupIO

    private let fileIO: FileOperationIO
    private let reloadVisiblePanes: @MainActor () -> Void
    nonisolated private let enqueueDirectoryRefresh: @Sendable (String) -> Void

    // Internal injection keeps regression tests on the actual manager path without
    // touching the user's Trash, clipboard, or visible panes.
    init(fileIO: FileOperationIO = .live,
         duplicateCleanupIO: DuplicateCleanupIO = .live,
         reloadVisiblePanes: @escaping @MainActor () -> Void = { AppState.shared.reloadVisiblePanes() },
         enqueueDirectoryRefresh: @escaping @Sendable (String) -> Void = { FSearchIndex.shared.enqueueDirectoryRefresh($0) }) {
        self.fileIO = fileIO
        self.duplicateCleanupIO = duplicateCleanupIO
        self.reloadVisiblePanes = reloadVisiblePanes
        self.enqueueDirectoryRefresh = enqueueDirectoryRefresh
        #if !BURROW_TESTING
        if let raw = UserDefaults.standard.string(forKey: "bf.defaultConflictPolicy"),
           let policy = FileConflictPolicy(rawValue: raw) {
            defaultConflictPolicy = policy
        }
        #endif
    }

    public var canUndo: Bool { !isBusy && !undoStack.isEmpty }
    public var canRedo: Bool { !isBusy && !redoStack.isEmpty }
    public var isBusy: Bool { activeTransfer != nil }

    public var undoLabel: String {
        guard let last = undoStack.last else { return "Cofnij" }
        return "Cofnij: \(last.label)"
    }

    public var redoLabel: String {
        guard let last = redoStack.last else { return "Ponów" }
        return "Ponów: \(last.label)"
    }

    public func isCut(_ path: String) -> Bool {
        guard clipboardMode == .cut, NSPasteboard.general.changeCount == clipboardChangeCount else { return false }
        return clipboardURLs.contains { $0.path == path }
    }

    // MARK: - Undo / Redo Engine (⌘Z / ⌘Shift+Z)

    private func pushUndo(_ op: UndoableFileOperation) {
        undoStack.append(op)
        if undoStack.count > 40 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    public func undoLastOperation() {
        applyHistory(isUndo: true)
    }

    public func redoLastOperation() {
        applyHistory(isUndo: false)
    }

    /// All file-mutating entry points share this gate, including context-menu and
    /// inspector actions. MainActor checks and acquisition cannot interleave.
    private func canStartMutation() -> Bool {
        guard !isBusy else {
            lastStatusMessage = "Poczekaj na zakończenie bieżącej operacji"
            return false
        }
        return true
    }

    private func beginMutation(title: String, currentFile: String = "", totalCount: Int = 1) -> Bool {
        guard canStartMutation() else { return false }
        activeTransfer = TransferProgressInfo(title: title, currentFile: currentFile,
                                              completedCount: 0, totalCount: totalCount)
        return true
    }

    private func applyHistory(isUndo: Bool) {
        guard canStartMutation() else { return }
        guard let op = isUndo ? undoStack.popLast() : redoStack.popLast() else {
            lastStatusMessage = isUndo ? "Brak operacji do cofnięcia" : "Brak operacji do ponowienia"
            return
        }
        // Acquire before dispatch, not inside the worker: another mutation must
        // never alter paths/history while this transaction is in flight.
        activeTransfer = TransferProgressInfo(title: isUndo ? "Cofanie" : "Ponawianie",
                                              currentFile: op.label, completedCount: 0, totalCount: 1)
        let io = fileIO
        Task.detached(priority: .userInitiated) { [self] in
            let actions: [FileHistoryAction]
            switch op.kind {
            case .actions(let stored): actions = stored
            }
            let result = FileHistoryExecutor.execute(actions, io: io)
            for dir in result.touchedDirectories {
                self.enqueueDirectoryRefresh(dir)
            }
            await MainActor.run {
                if !result.pending.isEmpty {
                    let pending = UndoableFileOperation(label: op.label, kind: .actions(result.pending), transactionID: op.transactionID)
                    if isUndo { self.undoStack.append(pending) } else { self.redoStack.append(pending) }
                }
                if !result.inverse.isEmpty {
                    // Retrying or reversing a partial transaction must reconnect
                    // its completed prefix to the still-pending suffix.
                    if isUndo {
                        Self.appendHistoryInverse(result.inverse, for: op, to: &self.redoStack)
                    } else {
                        Self.appendHistoryInverse(result.inverse, for: op, to: &self.undoStack)
                    }
                }
                let message: String
                if let error = result.error {
                    message = "Nie udało się \(isUndo ? "cofnąć" : "ponowić"): \(op.label) (\(result.completedCount) z \(actions.count) kroków): \(error)"
                } else {
                    message = "\(isUndo ? "Cofnięto" : "Ponowiono"): \(op.label)"
                }
                self.activeTransfer = nil
                self.finishUndoRedo(touchedDirs: result.touchedDirectories, message: message)
            }
        }
    }

    private static func appendHistoryInverse(_ actions: [FileHistoryAction], for operation: UndoableFileOperation,
                                             to stack: inout [UndoableFileOperation]) {
        var combined = actions
        if let prior = stack.last, prior.transactionID == operation.transactionID,
           case .actions(let pending) = prior.kind {
            stack.removeLast()
            combined += pending
        }
        stack.append(UndoableFileOperation(label: operation.label, kind: .actions(combined),
                                          transactionID: operation.transactionID))
    }

    private func finishUndoRedo(touchedDirs: Set<String>, message: String) {
        for dir in touchedDirs {
            FolderSizeCache.shared.invalidate(containing: dir)
        }
        lastStatusMessage = message
        reloadVisiblePanes()
    }

    // MARK: - Copy / Cut / Paste / Drop with Conflict Detection & Progress

    public func copyItems(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        writeClipboard(items.map(\.url), mode: .copy)
        lastStatusMessage = "Skopiowano \(items.count) elem. do schowka"
    }

    public func cutItems(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        writeClipboard(items.map(\.url), mode: .cut)
        lastStatusMessage = "Wycięto \(items.count) elem. (⌘V aby przenieść)"
    }

    private func writeClipboard(_ urls: [URL], mode: ClipboardMode) {
        clipboardURLs = urls
        clipboardMode = mode
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        clipboardChangeCount = pb.changeCount
    }

    /// Pastes files from the clipboard. Uses the internal cut/copy state only if nobody else
    /// has written to the system pasteboard since; otherwise falls back to file URLs on the pasteboard.
    /// `forceMove` (⌘⌥V) moves copied items instead of duplicating them, like Finder.
    public func paste(into destinationDirectory: URL, explicitPolicy: FileConflictPolicy? = nil, forceMove: Bool = false) {
        let pb = NSPasteboard.general
        var sourceURLs: [URL] = []
        var isMove = false

        if !clipboardURLs.isEmpty && pb.changeCount == clipboardChangeCount {
            sourceURLs = clipboardURLs
            isMove = (clipboardMode == .cut)
        } else {
            clipboardURLs = []
            clipboardMode = .copy
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let pbURLs = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
                sourceURLs = pbURLs
            }
        }
        guard !sourceURLs.isEmpty else {
            lastStatusMessage = "Schowek nie zawiera plików do wklejenia"
            return
        }
        performTransfer(
            sourceURLs: sourceURLs,
            into: destinationDirectory,
            isMove: isMove || forceMove,
            explicitPolicy: explicitPolicy
        )
    }

    /// Drag & drop: moves within the same volume, copies across volumes (Finder semantics).
    /// Holding Option forces a copy.
    public func handleDropURLs(_ urls: [URL], into destinationDirectory: URL, copyInsteadOfMove: Bool = false) {
        // Keep the UI-only cheap lexical filter. Alias resolution belongs to the
        // background preflight, including for slow or disconnected volumes.
        let destPath = destinationDirectory.standardizedFileURL.path
        let validURLs = urls.filter {
            let p = $0.standardizedFileURL.path
            return p != destPath && $0.standardizedFileURL.deletingLastPathComponent().path != destPath
        }
        guard !validURLs.isEmpty else { return }
        performTransfer(
            sourceURLs: validURLs,
            into: destinationDirectory,
            isMove: !copyInsteadOfMove,
            explicitPolicy: nil,
            copyAcrossVolumes: true
        )
    }

    /// Returns a stable request identity immediately; conflict discovery and all
    /// filesystem preflight run off MainActor while the mutation gate is held.
    @discardableResult
    public func performTransfer(
        sourceURLs: [URL],
        into destinationDirectory: URL,
        isMove: Bool,
        explicitPolicy: FileConflictPolicy? = nil,
        copyAcrossVolumes: Bool = false,
        requestID: UUID = UUID(),
        completion: (@MainActor ([URL]) -> Void)? = nil
    ) -> UUID? {
        guard !sourceURLs.isEmpty, canStartMutation() else { return nil }
        guard pendingConflict == nil else {
            lastStatusMessage = "Najpierw rozstrzygnij oczekujący konflikt"
            return nil
        }
        let io = fileIO
        let policy = explicitPolicy ?? defaultConflictPolicy
        let clipboardSnapshot = isMove && clipboardMode == .cut && NSPasteboard.general.changeCount == clipboardChangeCount
            ? CutClipboardSnapshot(changeCount: clipboardChangeCount) : nil
        let flag = TransferCancellationFlag()
        preflightRequestID = requestID
        transferCancellation = flag
        activeTransfer = TransferProgressInfo(title: "Sprawdzanie transferu", currentFile: "",
                                              completedCount: 0, totalCount: sourceURLs.count, isCancellable: true)
        Task.detached(priority: .userInitiated) { [self] in
            var validSources: [URL] = []
            var rejectedNested = 0
            var conflicts: [String] = []
            for source in sourceURLs {
                if flag.isCancelled { break }
                if FileTransferPaths.destinationIsInsideSource(destinationDirectory, source: source, io: io) {
                    rejectedNested += 1
                    continue
                }
                validSources.append(source)
                if policy == .ask {
                    let target = destinationDirectory.appendingPathComponent(source.lastPathComponent)
                    if !FileTransferPaths.sameEntry(target, source, io: io) && io.exists(target) {
                        conflicts.append(source.lastPathComponent)
                    }
                }
            }
            let preparedSources = validSources
            let preparedConflicts = conflicts
            let preparedRejected = rejectedNested
            await MainActor.run {
                guard self.preflightRequestID == requestID else { return }
                self.preflightRequestID = nil
                if flag.isCancelled || preparedSources.isEmpty {
                    self.activeTransfer = nil
                    self.transferCancellation = nil
                    self.lastStatusMessage = flag.isCancelled
                        ? "Anulowano przygotowanie transferu"
                        : "Nie można umieścić folderu wewnątrz samego siebie"
                } else if !preparedConflicts.isEmpty {
                    self.pendingConflict = PendingTransferConflict(
                        id: requestID, sourceURLs: preparedSources, destinationDirectory: destinationDirectory,
                        conflictingNames: preparedConflicts, isMove: isMove,
                        copyAcrossVolumes: copyAcrossVolumes, completion: completion)
                    self.activeTransfer = nil
                    self.transferCancellation = nil
                } else {
                    self.executePreparedTransfer(sourceURLs: preparedSources, into: destinationDirectory,
                        isMove: isMove, policy: policy, copyAcrossVolumes: copyAcrossVolumes,
                        rejectedNested: preparedRejected, clipboardSnapshot: clipboardSnapshot,
                        flag: flag, completion: completion)
                }
            }
        }
        return requestID
    }

    /// Closing the initiating sheet may cancel its pending preflight/conflict,
    /// but never another sheet's request or a transfer already writing files.
    public func cancelPendingTransferRequest(_ requestID: UUID) {
        if preflightRequestID == requestID { transferCancellation?.cancel() }
        if pendingConflict?.id == requestID { pendingConflict = nil }
    }

    private func executePreparedTransfer(
        sourceURLs validSources: [URL], into destinationDirectory: URL,
        isMove: Bool, policy: FileConflictPolicy, copyAcrossVolumes: Bool,
        rejectedNested: Int, clipboardSnapshot: CutClipboardSnapshot?,
        flag: TransferCancellationFlag, completion: (@MainActor ([URL]) -> Void)?
    ) {
        let io = fileIO
        let total = validSources.count
        let title = isMove ? "Przenoszenie" : "Kopiowanie"
        activeTransfer = TransferProgressInfo(
            title: title,
            currentFile: validSources[0].lastPathComponent,
            completedCount: 0,
            totalCount: total,
            isCancellable: total > 1
        )

        Task.detached(priority: .userInitiated) { [self] in
            var resultURLs: [URL] = []
            var copiedURLs: [URL] = []
            var movedPairs: [(from: URL, to: URL)] = []
            var undoActions: [FileHistoryAction] = []
            var skipped = rejectedNested
            var touchedDirs = Set<String>([destinationDirectory.path])
            var errors: [String] = []
            var lastProgressUpdate = DispatchTime.now().uptimeNanoseconds

            for (idx, src) in validSources.enumerated() {
                if flag.isCancelled { break }

                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastProgressUpdate > 50_000_000 || idx == 0 {
                    lastProgressUpdate = now
                    let info = TransferProgressInfo(
                        title: title,
                        currentFile: src.lastPathComponent,
                        completedCount: idx,
                        totalCount: total,
                        isCancellable: total > 1
                    )
                    await MainActor.run { self.activeTransfer = info }
                }

                // Recheck after conflict-sheet delay and immediately before IO.
                guard !FileTransferPaths.destinationIsInsideSource(destinationDirectory, source: src, io: io) else {
                    errors.append("\(src.lastPathComponent): folder docelowy znajduje się wewnątrz źródła")
                    continue
                }
                let doMove = isMove && (!copyAcrossVolumes || Self.isSameVolume(src, destinationDirectory))
                var targetURL = destinationDirectory.appendingPathComponent(src.lastPathComponent)
                var replacesExisting = false
                if FileTransferPaths.sameEntry(targetURL, src, io: io) {
                    if doMove { skipped += 1; continue }
                    targetURL = Self.uniqueURL(for: targetURL)
                } else if io.exists(targetURL) {
                    switch policy {
                    case .skip:
                        skipped += 1
                        continue
                    case .overwrite:
                        replacesExisting = true
                    case .keepBoth, .ask:
                        targetURL = Self.uniqueURL(for: targetURL)
                    }
                }

                touchedDirs.insert(src.deletingLastPathComponent().path)
                do {
                    let itemUndo: [FileHistoryAction]
                    if replacesExisting {
                        itemUndo = try SafeFileReplacement.replace(source: src, target: targetURL, isMove: doMove, io: io)
                    } else if doMove {
                        try io.move(src, targetURL)
                        itemUndo = [.move(from: targetURL, to: src, io: io)]
                    } else {
                        try io.copy(src, targetURL)
                        itemUndo = [.trash(targetURL, io: io)]
                    }
                    undoActions.append(contentsOf: itemUndo.reversed())
                    if doMove {
                        movedPairs.append((from: src, to: targetURL))
                    } else {
                        copiedURLs.append(targetURL)
                    }
                    resultURLs.append(targetURL)
                } catch {
                    errors.append("\(src.lastPathComponent): \(error.localizedDescription)")
                    if let failure = error as? FileOperationFailure {
                        undoActions.append(contentsOf: failure.recoveryActions.reversed())
                    }
                }
            }

            for dir in touchedDirs {
                self.enqueueDirectoryRefresh(dir)
            }

            let wasCancelled = flag.isCancelled
            let finalMoved = movedPairs
            let finalCopied = copiedURLs
            let finalUndo = Array(undoActions.reversed())
            let finalSkipped = skipped
            let finalResults = resultURLs
            let finalError = errors.isEmpty ? nil : errors.joined(separator: "; ")
            let finalTouched = touchedDirs

            await MainActor.run {
                let manager = self
                manager.activeTransfer = nil
                manager.transferCancellation = nil

                if !finalUndo.isEmpty {
                    let label = finalResults.isEmpty ? "Przywrócenie danych po błędzie" : "Transfer \(finalResults.count) elem."
                    manager.pushUndo(UndoableFileOperation(label: label, kind: .actions(finalUndo)))
                }
                if let clipboardSnapshot, !finalMoved.isEmpty,
                   manager.clipboardMode == .cut,
                   let remaining = clipboardSnapshot.remainingURLs(
                    manager.clipboardURLs,
                    internalChangeCount: manager.clipboardChangeCount,
                    systemChangeCount: NSPasteboard.general.changeCount,
                    movedSources: finalMoved.map { $0.from }
                   ) {
                    manager.writeClipboard(remaining, mode: remaining.isEmpty ? .copy : .cut)
                }

                if let err = finalError {
                    manager.lastStatusMessage = "Błąd operacji (ukończono \(finalResults.count) z \(total)): \(err)"
                } else if wasCancelled {
                    manager.lastStatusMessage = "Przerwano – \(title.lowercased()) \(finalResults.count) z \(total) elem."
                } else {
                    manager.lastStatusMessage = "Przeniesiono \(finalMoved.count), skopiowano \(finalCopied.count), pominięto \(finalSkipped) elem."
                }

                for dir in finalTouched {
                    FolderSizeCache.shared.invalidate(containing: dir)
                }
                manager.reloadVisiblePanes()
                completion?(finalResults)
            }
        }
    }

    public func cancelActiveTransfer() {
        if let id = activeDuplicateCleanupID {
            cancelDuplicateCleanup(id)
        } else {
            transferCancellation?.cancel()
        }
    }

    // MARK: - Create Folder / Create File

    @discardableResult
    public func createFolder(named name: String, in directory: URL) -> URL? {
        guard beginMutation(title: "Tworzenie folderu") else { return nil }
        defer { activeTransfer = nil }
        guard let safeName = Self.validatedFileName(name) else {
            lastStatusMessage = "Nieprawidłowa nazwa folderu"
            return nil
        }
        let fm = FileManager.default
        do {
            let target = try Self.createUniqueItem(at: directory.appendingPathComponent(safeName)) { target in
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
            }
            pushUndo(UndoableFileOperation(label: "Utworzenie folderu \(target.lastPathComponent)", kind: .actions([.trash(target, io: fileIO)])))
            self.enqueueDirectoryRefresh(directory.path)
            lastStatusMessage = "Utworzono folder \(target.lastPathComponent)"
            return target
        } catch {
            lastStatusMessage = "Nie udało się utworzyć folderu: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    public func createFile(named name: String, content: String = "", in directory: URL) -> URL? {
        guard beginMutation(title: "Tworzenie pliku") else { return nil }
        defer { activeTransfer = nil }
        guard let safeName = Self.validatedFileName(name) else {
            lastStatusMessage = "Nieprawidłowa nazwa pliku"
            return nil
        }
        do {
            let target = try Self.createUniqueItem(at: directory.appendingPathComponent(safeName)) { target in
                // O_EXCL-style creation; an atomic replacement write could overwrite
                // another process's file/symlink created after uniqueURL's check.
                try Data(content.utf8).write(to: target, options: .withoutOverwriting)
            }
            if safeName.hasSuffix(".sh") || content.hasPrefix("#!") {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            }
            pushUndo(UndoableFileOperation(label: "Utworzenie pliku \(target.lastPathComponent)", kind: .actions([.trash(target, io: fileIO)])))
            self.enqueueDirectoryRefresh(directory.path)
            lastStatusMessage = "Utworzono plik \(target.lastPathComponent)"
            return target
        } catch {
            lastStatusMessage = "Nie udało się utworzyć pliku: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Rename / Batch Rename / Duplicate / Trash

    @discardableResult
    public func renameItem(_ item: FileItem, to newName: String) -> URL? {
        guard beginMutation(title: "Zmiana nazwy") else { return nil }
        defer { activeTransfer = nil }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return nil }
        guard let safeName = Self.validatedFileName(trimmed) else {
            lastStatusMessage = "Nazwa nie może zawierać znaku „/” ani być „.” lub „..”"
            return nil
        }
        let dst = item.url.deletingLastPathComponent().appendingPathComponent(safeName)
        let isCaseOnlyChange = safeName.lowercased() == item.name.lowercased()
        if !isCaseOnlyChange && fileIO.exists(dst) {
            lastStatusMessage = "Element o nazwie „\(safeName)” już istnieje"
            return nil
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: dst)
            pushUndo(UndoableFileOperation(label: "Zmiana nazwy \(item.name) → \(safeName)", kind: .actions([.move(from: dst, to: item.url, io: fileIO)])))
            self.enqueueDirectoryRefresh(item.parentPath)
            lastStatusMessage = "Zmieniono nazwę na \(safeName)"
            return dst
        } catch {
            lastStatusMessage = "Błąd zmiany nazwy: \(error.localizedDescription)"
            return nil
        }
    }

    /// Asks for confirmation and permanently removes everything in `~/.Trash`.
    public func emptySystemTrash(completion: (@MainActor () -> Void)? = nil) {
        guard !isBusy else {
            lastStatusMessage = "Poczekaj na zakończenie bieżącej operacji"
            return
        }
        let trashPath = "\(NSHomeDirectory())/.Trash"
        let fm = FileManager.default
        let items: [String]
        do {
            items = try fm.contentsOfDirectory(atPath: trashPath)
        } catch {
            lastStatusMessage = "Nie można odczytać Kosza: \(error.localizedDescription)"
            return
        }
        guard !items.isEmpty else {
            lastStatusMessage = "Kosz jest pusty"
            return
        }

        let alert = NSAlert()
        alert.messageText = "Czy na pewno opróżnić Kosz?"
        alert.informativeText = "Elementy (\(items.count)) zostaną trwale usunięte. Tej operacji nie można cofnąć."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Opróżnij Kosz")
        alert.addButton(withTitle: "Anuluj")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The modal alert runs a nested event loop, during which another operation can start.
        guard !isBusy else {
            lastStatusMessage = "Poczekaj na zakończenie bieżącej operacji"
            return
        }

        activeTransfer = TransferProgressInfo(title: "Opróżnianie Kosza", currentFile: "\(items.count) elem.", completedCount: 0, totalCount: 1)
        Task.detached(priority: .userInitiated) {
            var removed: [URL] = []
            var lastError: String?
            for name in items {
                let url = URL(fileURLWithPath: trashPath).appendingPathComponent(name)
                do {
                    try FileManager.default.removeItem(at: url)
                    removed.append(url)
                } catch {
                    lastError = error.localizedDescription
                }
            }
            self.enqueueDirectoryRefresh(trashPath)
            let removedURLs = removed
            let finalError = lastError
            await MainActor.run {
                let manager = self
                manager.activeTransfer = nil
                // Undo entries pointing into the Trash are no longer restorable.
                manager.undoStack.removeAll { Self.referencesRemovedItems($0.kind, removed: removedURLs) }
                manager.redoStack.removeAll { Self.referencesRemovedItems($0.kind, removed: removedURLs) }
                manager.lastStatusMessage = finalError.map {
                    "Nie opróżniono całego Kosza (usunięto \(removedURLs.count) z \(items.count)): \($0)"
                } ?? "Opróżniono Kosz (usunięto \(removedURLs.count) elem.)"
                manager.reloadVisiblePanes()
                completion?()
            }
        }
    }

    /// Duplicate can copy multi-gigabyte trees, so it owns the same mutation gate
    /// as transfers and runs off MainActor. Completion reports only created items.
    public func duplicateItems(_ items: [FileItem], completion: (@MainActor ([URL]) -> Void)? = nil) {
        guard !items.isEmpty, beginMutation(title: "Duplikowanie", totalCount: items.count) else { return }
        let io = fileIO
        Task.detached(priority: .userInitiated) { [self] in
            var created: [URL] = []
            var undo: [FileHistoryAction] = []
            var errors: [String] = []
            var touched = Set<String>()
            for (index, item) in items.enumerated() {
                await MainActor.run {
                    self.activeTransfer = TransferProgressInfo(title: "Duplikowanie", currentFile: item.name,
                                                              completedCount: index, totalCount: items.count)
                }
                let destination = Self.uniqueURL(for: item.url, suffixWord: " copy")
                do {
                    try io.copy(item.url, destination)
                    created.append(destination)
                    undo.append(.trash(destination, io: io))
                    touched.insert(item.parentPath)
                } catch {
                    errors.append("\(item.name): \(error.localizedDescription)")
                }
            }
            for directory in touched { self.enqueueDirectoryRefresh(directory) }
            let finalCreated = created
            let finalUndo = Array(undo.reversed())
            let finalErrors = errors
            let finalTouched = touched
            await MainActor.run {
                if !finalCreated.isEmpty {
                    self.pushUndo(UndoableFileOperation(label: "Duplikacja \(finalCreated.count) elem.", kind: .actions(finalUndo)))
                }
                for directory in finalTouched { FolderSizeCache.shared.invalidate(containing: directory) }
                self.lastStatusMessage = finalErrors.isEmpty
                    ? "Zduplikowano \(finalCreated.count) elem."
                    : "Zduplikowano \(finalCreated.count) z \(items.count) elem.: " + finalErrors.joined(separator: "; ")
                self.activeTransfer = nil
                self.reloadVisiblePanes()
                completion?(finalCreated)
            }
        }
    }

    /// Duplicate-only async mutation. Content verification and live-owner
    /// admission happen before this call; the worker preserves the verified plan
    /// and checks keeper/candidate snapshots immediately before each Trash.
    /// Rejection does not queue a later destructive action.
    @discardableResult
    func startDuplicateCleanup(_ plan: DuplicateCleanupPlan, requestID: UUID,
        completion: (@MainActor (DuplicateCleanupResult) -> Void)? = nil) -> Bool {
        let total = plan.candidateCount
        guard total > 0 else {
            lastStatusMessage = "Brak nadmiarowych plików do przeniesienia."
            return false
        }
        guard beginMutation(title: "Usuwanie duplikatów", totalCount: total) else { return false }
        let cancellation = DuplicateCleanupCancellation()
        duplicateCleanupCancellation = cancellation
        activeDuplicateCleanupID = requestID
        activeTransfer = TransferProgressInfo(title: "Usuwanie duplikatów", currentFile: "",
            completedCount: 0, totalCount: total, isCancellable: true)
        let io = DuplicateCleanupWorkerIO(cleanup: duplicateCleanupIO, history: fileIO)
        let relay = DuplicateCleanupProgressRelay { [weak self] progress in
            guard let self, self.activeDuplicateCleanupID == requestID, !cancellation.isCancelled else { return }
            self.activeTransfer = TransferProgressInfo(title: "Usuwanie duplikatów", currentFile: progress.currentFile,
                completedCount: progress.attempted, totalCount: progress.total, isCancellable: true)
        }
        Self.duplicateCleanupQueue.async { [self] in
            let result = DuplicateCleanupExecutor.execute(plan, io: io, cancellation: cancellation,
                progress: { relay.offer($0) })
            for directory in result.touchedDirectories { self.enqueueDirectoryRefresh(directory) }
            Task { @MainActor in
                // Complete manager-owned history even after the initiating view
                // disappears. The gate remains held through physical return and
                // this single finalization; stale progress cannot affect a new job.
                relay.close()
                guard self.activeDuplicateCleanupID == requestID else { return }
                if !result.undoActions.isEmpty {
                    self.pushUndo(UndoableFileOperation(label: "Usuwanie duplikatów (\(result.undoActions.count) rekordów)",
                        kind: .actions(result.undoActions)))
                }
                for directory in result.touchedDirectories { FolderSizeCache.shared.invalidate(containing: directory) }
                self.lastStatusMessage = result.summary
                self.reloadVisiblePanes()
                self.activeDuplicateCleanupID = nil
                self.duplicateCleanupCancellation = nil
                self.activeTransfer = nil
                completion?(result)
            }
        }
        return true
    }

    /// Ownership prevents a disappearing old analysis pane from cancelling a
    /// later transfer or another cleanup operation.
    func cancelDuplicateCleanup(_ requestID: UUID) {
        guard activeDuplicateCleanupID == requestID, let cancellation = duplicateCleanupCancellation,
              !cancellation.isCancelled else { return }
        cancellation.cancel()
        if let progress = activeTransfer {
            activeTransfer = TransferProgressInfo(title: "Anulowanie po bieżącej operacji…", currentFile: progress.currentFile,
                completedCount: progress.completedCount, totalCount: progress.totalCount, isCancellable: false)
        }
    }

    public func moveToTrash(_ items: [FileItem], validating: ((FileItem) throws -> Void)? = nil) {
        guard !items.isEmpty, beginMutation(title: "Przenoszenie do Kosza", totalCount: items.count) else { return }
        defer { activeTransfer = nil }
        var trashedPairs: [(original: URL, trashed: URL)] = []
        var undo: [FileHistoryAction] = []
        var failures = 0
        var validationError: String?
        for item in items {
            do {
                // A stale duplicate scan must not be allowed to remove the last
                // surviving or newly modified copy. Abort the batch on invalidation.
                try validating?(item)
            } catch {
                validationError = error.localizedDescription
                break
            }
            do {
                let trashed = try fileIO.trash(item.url)
                trashedPairs.append((original: item.url, trashed: trashed))
                undo.append(.restore(from: trashed, to: item.url, io: fileIO))
                self.enqueueDirectoryRefresh(item.parentPath)
                FolderSizeCache.shared.invalidate(containing: item.parentPath)
            } catch {
                failures += 1
            }
        }
        if !trashedPairs.isEmpty {
            pushUndo(UndoableFileOperation(label: "Kosz (\(trashedPairs.count) elem.)", kind: .actions(undo)))
        }
        if let validationError {
            lastStatusMessage = "Przerwano usuwanie: \(validationError) (przeniesiono \(trashedPairs.count) elem.)"
        } else if failures > 0 {
            lastStatusMessage = "Nie udało się przenieść do Kosza \(failures) elem. (brak uprawnień?)"
        } else {
            lastStatusMessage = "Przeniesiono do Kosza: \(trashedPairs.count) elem. (⌘Z aby przywrócić)"
        }
    }

    // MARK: - Native macOS Finder Color Tags

    public func toggleTag(_ color: FinderTagColor, for items: [FileItem]) {
        guard beginMutation(title: "Zmiana tagów") else { return }
        defer { activeTransfer = nil }
        guard !items.isEmpty else { return }
        // When tagging several items, either add the tag to all of them or (if all have it) remove it.
        do {
            let tags = try items.map { item in
                try FinderTagColor.readTagNames(for: item.url).compactMap { FinderTagColor.from(rawTagName: $0) }
            }
            let allHaveTag = tags.allSatisfy { $0.contains(color) }
            var failures = 0
            var lastError: String?
            for (item, existing) in zip(items, tags) {
                var current = existing
                if allHaveTag {
                    current.removeAll { $0 == color }
                } else if !current.contains(color) {
                    current.append(color)
                }
                do {
                    try FinderTagColor.writeTags(current, to: item.url)
                } catch {
                    failures += 1
                    lastError = error.localizedDescription
                }
            }
            lastStatusMessage = lastError.map { "Nie zaktualizowano tagów dla \(failures) z \(items.count) elem.: \($0)" }
                ?? "Zaktualizowano tagi (\(color.displayName))"
        } catch {
            lastStatusMessage = "Nie można odczytać tagów: \(error.localizedDescription)"
        }
    }

    public func clearTags(for items: [FileItem]) {
        guard beginMutation(title: "Usuwanie tagów") else { return }
        defer { activeTransfer = nil }
        guard !items.isEmpty else { return }
        var failures = 0
        var lastError: String?
        for item in items {
            do {
                try FinderTagColor.clearAllTags(for: item.url)
            } catch {
                failures += 1
                lastError = error.localizedDescription
            }
        }
        lastStatusMessage = lastError.map { "Nie wyczyszczono tagów dla \(failures) z \(items.count) elem.: \($0)" }
            ?? "Wyczyszczono tagi"
    }

    // MARK: - Open With & Native Share Sheet

    public func availableApplications(for url: URL) -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }

    public func open(_ url: URL, withApplication appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
    }

    public func showShareSheet(for items: [FileItem]) {
        guard !items.isEmpty,
              let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: items.map(\.url))
        let mouse = contentView.window?.mouseLocationOutsideOfEventStream ?? .zero
        let local = contentView.convert(mouse, from: nil)
        let rect = NSRect(x: local.x, y: local.y, width: 1, height: 1)
        picker.show(relativeTo: rect, of: contentView, preferredEdge: .minY)
    }

    // MARK: - Compress & One-Click Archive Extraction

    /// Archive tools get a minimal environment. In particular ZIPOPT=-m must
    /// never turn a non-destructive compression command into source deletion;
    /// TAR_OPTIONS, UNZIP*, and shell startup variables are excluded as well.
    nonisolated static func archiveProcessEnvironment(inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = inherited[key] { environment[key] = value }
        }
        return environment
    }

    public func compressItems(_ items: [FileItem], in directory: URL) {
        guard !items.isEmpty, canStartMutation() else { return }
        let parents = Set(items.map { $0.url.deletingLastPathComponent().path })
        let workingDir = parents.count == 1 ? items[0].url.deletingLastPathComponent() : directory
        let archiveBaseName = items.count == 1 ? "\(items[0].url.deletingPathExtension().lastPathComponent).zip" : "Archiwum.zip"
        let requestedURL = workingDir.appendingPathComponent(archiveBaseName)
        // A filename such as "-m" is always an operand, never ZIP's move option.
        let names = parents.count == 1 ? items.map { "./" + $0.url.lastPathComponent } : items.map(\.path)
        let io = fileIO
        activeTransfer = TransferProgressInfo(title: "Kompresowanie", currentFile: requestedURL.lastPathComponent, completedCount: 0, totalCount: 1)
        Task.detached(priority: .userInitiated) { [self] in
            var staging: URL?
            var published: URL?
            var undo: [FileHistoryAction] = []
            var failure: String?
            do {
                let root = try SafeArchivePublication.stagingDirectory(in: workingDir)
                staging = root
                let stagedURL = root.appendingPathComponent("archive.zip")
                let status = Self.runProcess("/usr/bin/zip", arguments: ["-r", "-q", "-y", stagedURL.path] + names,
                                             in: workingDir, environment: Self.archiveProcessEnvironment())
                guard status == 0 else { throw FileOperationFailure(message: "Kompresja nie powiodła się (kod \(status))") }
                published = try Self.createUniqueItem(at: requestedURL) { candidate in
                    try io.publishExclusive(stagedURL, candidate)
                }
                if let published { undo = [.trash(published, io: io)] }
                io.removeEmptyDirectory(root)
            } catch {
                failure = error.localizedDescription
                if let staging {
                    // Only the owned empty directory may be removed. Partial data
                    // stays discoverable and never becomes a whole-output undo entry.
                    io.removeEmptyDirectory(staging)
                    if io.exists(staging) { failure! += "; dane operacji zachowano w \(staging.path)" }
                }
            }
            self.enqueueDirectoryRefresh(workingDir.path)
            let finalURL = published
            let finalUndo = undo
            let finalError = failure
            await MainActor.run {
                if let finalURL {
                    self.pushUndo(UndoableFileOperation(label: "Utworzenie archiwum \(finalURL.lastPathComponent)", kind: .actions(finalUndo)))
                    self.lastStatusMessage = "Utworzono archiwum \(finalURL.lastPathComponent)"
                } else {
                    self.lastStatusMessage = finalError ?? "Kompresja nie powiodła się"
                }
                self.activeTransfer = nil
                self.reloadVisiblePanes()
            }
        }
    }

    public func extractArchive(_ item: FileItem) {
        guard canStartMutation() else { return }
        let parentDir = item.url.deletingLastPathComponent()
        let ext = item.fileExtension.lowercased()
        let lowerName = item.name.lowercased()
        if ext == "dmg" {
            activeTransfer = TransferProgressInfo(title: "Montowanie", currentFile: item.name, completedCount: 0, totalCount: 1)
            Task.detached(priority: .userInitiated) { [self] in
                let status = Self.runProcess("/usr/bin/hdiutil", arguments: ["attach", item.path], in: parentDir,
                                             environment: Self.archiveProcessEnvironment())
                await MainActor.run {
                    self.activeTransfer = nil
                    self.lastStatusMessage = status == 0
                        ? "Zamontowano obraz \(item.name)"
                        : "Nie udało się zamontować \(item.name) (kod \(status))"
                    AppState.shared.refreshMountedVolumes()
                }
            }
            return
        }
        var baseFolder = item.url.deletingPathExtension().lastPathComponent
        if baseFolder.lowercased().hasSuffix(".tar") { baseFolder = String(baseFolder.dropLast(4)) }
        let requestedURL = parentDir.appendingPathComponent(baseFolder, isDirectory: true)
        let isTarball = ext == "tar" || ext == "tgz" || lowerName.hasSuffix(".tar.gz") ||
                        lowerName.hasSuffix(".tar.bz2") || lowerName.hasSuffix(".tar.xz")
        let io = fileIO
        activeTransfer = TransferProgressInfo(title: "Rozpakowywanie", currentFile: item.name, completedCount: 0, totalCount: 1)
        Task.detached(priority: .userInitiated) { [self] in
            var staging: URL?
            var published: URL?
            var undo: [FileHistoryAction] = []
            var failure: String?
            do {
                let root = try SafeArchivePublication.stagingDirectory(in: parentDir)
                staging = root
                let stagedURL = root.appendingPathComponent("contents", isDirectory: true)
                try FileManager.default.createDirectory(at: stagedURL, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                let environment = Self.archiveProcessEnvironment()
                let status: Int32
                if isTarball {
                    status = Self.runProcess("/usr/bin/tar", arguments: ["-xf", item.path, "-C", stagedURL.path], in: parentDir, environment: environment)
                } else if ext == "gz" || ext == "bz2" || ext == "xz" {
                    let outName = item.url.deletingPathExtension().lastPathComponent
                    status = try Self.decompressSingleFile(from: item.url,
                                                           to: stagedURL.appendingPathComponent(outName))
                } else {
                    status = Self.runProcess("/usr/bin/ditto", arguments: ["-x", "-k", item.path, stagedURL.path], in: parentDir, environment: environment)
                }
                guard status == 0 else { throw FileOperationFailure(message: "Nie udało się rozpakować \(item.name) (kod \(status))") }
                published = try Self.createUniqueItem(at: requestedURL) { candidate in
                    try io.publishExclusive(stagedURL, candidate)
                }
                if let published { undo = [.trash(published, io: io)] }
                io.removeEmptyDirectory(root)
            } catch {
                failure = error.localizedDescription
                if let staging {
                    io.removeEmptyDirectory(staging.appendingPathComponent("contents", isDirectory: true))
                    io.removeEmptyDirectory(staging)
                    if io.exists(staging) { failure! += "; dane operacji zachowano w \(staging.path)" }
                }
            }
            self.enqueueDirectoryRefresh(parentDir.path)
            let finalURL = published
            let finalUndo = undo
            let finalError = failure
            await MainActor.run {
                if let finalURL {
                    self.pushUndo(UndoableFileOperation(label: "Rozpakowanie \(item.name)", kind: .actions(finalUndo)))
                    self.lastStatusMessage = "Rozpakowano do: \(finalURL.lastPathComponent)"
                } else {
                    self.lastStatusMessage = finalError ?? "Rozpakowanie nie powiodło się"
                }
                self.activeTransfer = nil
                self.reloadVisiblePanes()
            }
        }
    }

    /// Apple's gzip supports gzip, bzip2 and xz streams. Unlike tar, it does
    /// not require an archive container around the decompressed bytes. Stream
    /// directly to an exclusively created file inside our private staging tree;
    /// never interpolate filenames into a shell or modify the compressed input.
    nonisolated static func decompressSingleFile(from source: URL, to output: URL) throws -> Int32 {
        let descriptor = output.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-d", "-c", "--", source.path]
        process.currentDirectoryURL = source.deletingLastPathComponent()
        process.environment = archiveProcessEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try handle.close()
        return process.terminationStatus
    }

    // MARK: - POSIX Permissions (chmod) & Checksums (SHA-256 / MD5)

    /// The inspector changes only the requested ordinary bits. Read fresh mode
    /// on the worker, never replay special bits from an old UI snapshot.
    @discardableResult
    func updatePosixPermissions(_ change: PosixPermissionChange, for item: FileItem,
                                expectedIdentity: FileEntryIdentity,
                                completion: @escaping @MainActor (PosixPermissionSnapshot?, String?) -> Void) -> Bool {
        guard beginMutation(title: "Zmiana uprawnień") else { return false }
        let io = fileIO
        Task.detached(priority: .userInitiated) { [self] in
            var updated: PosixPermissionSnapshot?
            var failure: String?
            do {
                let current = try PosixPermissionSnapshot.read(item.url, io: io)
                guard current.identity == expectedIdentity else {
                    throw FileOperationFailure(message: "Nie zmieniono uprawnień: pod ścieżką znajduje się inny obiekt.")
                }
                let requested = try change.applying(to: current.mode)
                try io.writePermissions(item.url, requested)
                let actual = try PosixPermissionSnapshot.read(item.url, io: io)
                guard actual.identity == expectedIdentity else {
                    throw FileOperationFailure(message: "Element zmienił się podczas zapisu uprawnień; odśwież inspektor.")
                }
                updated = actual
            } catch { failure = error.localizedDescription }
            let finalSnapshot = updated
            let finalFailure = failure
            await MainActor.run {
                self.activeTransfer = nil
                if let finalSnapshot {
                    self.lastStatusMessage = "Zmieniono uprawnienia \(item.name): \(PosixPermissionChange.format(finalSnapshot.mode))"
                } else { self.lastStatusMessage = finalFailure ?? "Nie zmieniono uprawnień." }
                completion(finalSnapshot, finalFailure)
            }
        }
        return true
    }

    // MARK: - Developer & Power User Actions

    public func copyPaths(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let joined = items.map(\.path).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(joined, forType: .string)
        lastStatusMessage = items.count == 1
            ? "Skopiowano ścieżkę: \(items[0].path)"
            : "Skopiowano \(items.count) ścieżek"
    }

    public func copyPathString(_ path: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(path, forType: .string)
        lastStatusMessage = "Skopiowano ścieżkę: \(path)"
    }

    public func openInTerminal(at url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let targetDir = isDir.boolValue ? url : url.deletingLastPathComponent()
        let candidates = [
            "/Applications/iTerm.app",
            "/Applications/Ghostty.app",
            "/Applications/Warp.app",
            "/System/Applications/Utilities/Terminal.app"
        ]
        let appPath = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates.last!

        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([targetDir], withApplicationAt: URL(fileURLWithPath: appPath), configuration: config)
        lastStatusMessage = "Otwarto w Terminalu: \(targetDir.lastPathComponent)"
    }

    public func openInCodeEditor(at url: URL) {
        let editors = [
            "/Applications/Cursor.app",
            "/Applications/Visual Studio Code.app",
            "/Applications/Zed.app",
            "/Applications/Sublime Text.app"
        ]
        if let found = editors.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: found), configuration: config)
            lastStatusMessage = "Otwarto w edytorze kodu"
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    public func revealInAppleFinder(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    // MARK: - Git Status Detection

    nonisolated public static func fetchGitStatusMap(for directoryPath: String) -> [String: GitFileStatus] {
        guard let snapshot = fetchGitStatusSnapshot(for: directoryPath) else { return [:] }
        FSearchIndex.shared.recordGitStatuses(snapshot.statuses, repositoryRoot: snapshot.repositoryRoot)
        return snapshot.statuses
    }

    /// A successful empty snapshot clears stale statuses; nil means status was not
    /// available and must not be confused with a clean repository.
    nonisolated public static func fetchGitStatusSnapshot(for directoryPath: String) -> GitStatusSnapshot? {
        // Browsing is read-only, not permission to execute a worktree's fsmonitor
        // helper, hooks, or recursively inspect untrusted submodule configuration.
        let safeOptions = ["--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]
        guard let rootData = runProcessCapturingOutput(
            "/usr/bin/git",
            arguments: safeOptions + ["rev-parse", "--show-toplevel"],
            in: URL(fileURLWithPath: directoryPath)
        ), var gitRoot = String(data: rootData, encoding: .utf8) else { return nil }
        // Remove exactly Git's delimiter, not whitespace that belongs to a path.
        if gitRoot.hasSuffix("\n") { gitRoot.removeLast() }
        guard !gitRoot.isEmpty else { return nil }
        // Git emits physical /private/var paths on macOS; Foundation's file
        // URLs use the normalized /var namespace. Normalize once off-main so
        // status keys match the directory crawler and successful-empty clears.
        gitRoot = URL(fileURLWithPath: gitRoot).standardizedFileURL.resolvingSymlinksInPath().path

        // Status may run clean/process filters from .gitattributes when comparing
        // a tracked same-size edit. Enumerate keys without running Git plumbing,
        // then override every configured driver. Never interpret config as shell.
        guard let configurationKeys = runProcessCapturingOutput(
            "/usr/bin/git",
            arguments: safeOptions + ["config", "--includes", "--null", "--name-only", "--list"],
            in: URL(fileURLWithPath: directoryPath)
        ), let disabledFilters = disabledGitFilterOptions(configurationKeys: configurationKeys) else { return nil }

        guard let data = runProcessCapturingOutput(
            "/usr/bin/git",
            arguments: safeOptions + disabledFilters + ["-c", "core.quotepath=false", "status", "--porcelain=v1", "-z", "-uall", "--ignore-submodules=all"],
            in: URL(fileURLWithPath: directoryPath)
        ) else { return nil }

        return GitStatusSnapshot(usesRawContentComparison: !disabledFilters.isEmpty, repositoryRoot: gitRoot,
                                 statuses: parseGitStatusRecords(data, repositoryRoot: gitRoot))
    }

    nonisolated static func parseGitStatusRecords(_ data: Data, repositoryRoot: String) -> [String: GitFileStatus] {
        var statusMap: [String: GitFileStatus] = [:]
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var i = 0
        while i < records.count {
            let record = Array(records[i])
            i += 1
            guard record.count > 3 else { continue }
            let x = record[0]
            let y = record[1]
            let relPath = String(decoding: record[3...], as: UTF8.self)
            // Renames/copies are followed by an extra record holding the original path.
            if x == UInt8(ascii: "R") || x == UInt8(ascii: "C") ||
               y == UInt8(ascii: "R") || y == UInt8(ascii: "C") {
                i += 1
            }

            let status: GitFileStatus
            if x == UInt8(ascii: "?") {
                status = .untracked
            } else if x == UInt8(ascii: "R") || y == UInt8(ascii: "R") {
                status = .renamed
            } else if x == UInt8(ascii: "D") || y == UInt8(ascii: "D") {
                status = .deleted
            } else if x != UInt8(ascii: " ") {
                status = .staged
            } else {
                status = .modified
            }
            statusMap[URL(fileURLWithPath: repositoryRoot).appendingPathComponent(relPath).path] = status
        }
        return statusMap
    }

    /// Git's NUL-delimited name-only output retains subsection spelling. A name
    /// containing "=" cannot safely be passed through `-c key=value`; fail closed
    /// rather than silently leave a potentially executable driver enabled.
    nonisolated static func disabledGitFilterOptions(configurationKeys: Data) -> [String]? {
        var drivers = Set<String>()
        for record in configurationKeys.split(separator: 0, omittingEmptySubsequences: true) {
            guard let key = String(data: Data(record), encoding: .utf8) else { return nil }
            let lower = key.lowercased()
            guard lower.hasPrefix("filter."),
                  let suffix = [".clean", ".process", ".required"].first(where: { lower.hasSuffix($0) }) else { continue }
            let driver = String(key.dropFirst("filter.".count).dropLast(suffix.count))
            guard !driver.isEmpty, !driver.contains("="),
                  !driver.contains("\n"), !driver.contains("\r") else { return nil }
            drivers.insert(driver)
        }
        return drivers.sorted().flatMap { driver in
            ["-c", "filter.\(driver).clean=", "-c", "filter.\(driver).process=",
             "-c", "filter.\(driver).required=false"]
        }
    }

    // MARK: - Helpers

    nonisolated private static func referencesRemovedItems(_ kind: UndoableFileOperation.Kind, removed: [URL]) -> Bool {
        let urls: [URL]
        switch kind {
        case .actions(let actions):
            urls = actions.flatMap { action -> [URL] in
                switch action.operation {
                case .move(let from, let to), .restore(let from, let to): return [from, to]
                case .trash(let url): return [url]
                }
            }
        }
        return urls.contains { url in
            let path = url.standardizedFileURL.path
            return removed.contains {
                let removedPath = $0.standardizedFileURL.path
                return path == removedPath || path.hasPrefix(removedPath + "/")
            }
        }
    }

    public func uniqueDestinationURL(for url: URL, suffixWord: String = "") -> URL {
        Self.uniqueURL(for: url, suffixWord: suffixWord)
    }

    nonisolated public static func uniqueURL(for url: URL, suffixWord: String = "") -> URL {
        if suffixWord.isEmpty && !FileOperationIO.live.exists(url) {
            return url
        }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let baseName = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))

        var counter = 1
        while true {
            let suffix = counter == 1 && !suffixWord.isEmpty ? suffixWord : "\(suffixWord) \(counter)"
            let candidateName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            let candidateURL = dir.appendingPathComponent(candidateName)
            if !FileOperationIO.live.exists(candidateURL) {
                return candidateURL
            }
            counter += 1
        }
    }

    /// The creator must fail rather than overwrite an occupied entry. A racing
    /// creator is handled by picking a fresh name, with a bound against livelock.
    nonisolated static func createUniqueItem(at requested: URL, create: (URL) throws -> Void) throws -> URL {
        for _ in 0..<100 {
            let candidate = uniqueURL(for: requested)
            do {
                try create(candidate)
                return candidate
            } catch {
                let nsError = error as NSError
                guard nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError else { throw error }
            }
        }
        throw FileOperationFailure(message: "Nie można wybrać wolnej nazwy pliku; spróbuj ponownie.")
    }

    /// Returns a trimmed, safe single path component or `nil` if the name is invalid.
    nonisolated public static func validatedFileName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\0") else { return nil }
        return trimmed
    }

    nonisolated static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: keys).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: keys).volumeIdentifier else {
            return false
        }
        return (va as AnyObject).isEqual(vb)
    }

    @discardableResult
    nonisolated static func runProcess(_ executable: String, arguments: [String], in directory: URL,
                                       environment: [String: String]? = nil) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = directory
        if let environment { proc.environment = environment }
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return -1
        }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    /// Bounded read-only inspection. Nonblocking reads keep both output volume and
    /// elapsed time bounded even if a corrupt repository hangs Git or fills a pipe.
    nonisolated static func runProcessCapturingOutput(_ executable: String, arguments: [String], in directory: URL,
                                                       maxOutputBytes: Int = 8 * 1024 * 1024,
                                                       timeout: TimeInterval = 10) -> Data? {
        guard maxOutputBytes > 0, timeout.isFinite, timeout > 0 else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = directory
        let outPipe = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        try? outPipe.fileHandleForWriting.close()
        let reader = outPipe.fileHandleForReading
        defer {
            try? reader.close()
            if proc.isRunning { _ = Darwin.kill(proc.processIdentifier, SIGKILL) }
            proc.waitUntilExit()
        }
        let descriptor = reader.fileDescriptor
        let existingFlags = fcntl(descriptor, F_GETFL)
        guard existingFlags >= 0, fcntl(descriptor, F_SETFL, existingFlags | O_NONBLOCK) == 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var reachedEOF = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            if !reachedEOF {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    guard count <= maxOutputBytes, data.count <= maxOutputBytes - count else { return nil }
                    data.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 {
                    reachedEOF = true
                } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    return nil
                }
            }
            if reachedEOF && !proc.isRunning {
                proc.waitUntilExit()
                return proc.terminationStatus == 0 ? data : nil
            }
            if reachedEOF {
                usleep(10_000)
            } else {
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                _ = poll(&pollDescriptor, 1, 20)
            }
        }
        return nil
    }
}
