import Foundation

/// Content verification precedes admission to the mutation gate. This immutable
/// selection keeps the verified snapshots; the worker rejects malformed plans
/// and rechecks keeper/candidate snapshots immediately before every Trash call.
struct DuplicateCleanupPlan: Sendable {
    let groups: [DuplicateFileGroup]
    let onlyPath: String?
    var candidateCount: Int {
        groups.reduce(0) { $0 + $1.files.dropFirst().filter { onlyPath == nil || $0.path == onlyPath }.count }
    }
}

enum DuplicateTrashOutcome: Sendable {
    case moved(recoveryURL: URL?)
    /// An OS error does not establish that the source remained untouched.
    case notConfirmed(String)
}
struct DuplicateCleanupIO: Sendable {
    var snapshot: @Sendable (URL) throws -> DuplicateFileSnapshot = DuplicateFileSafety.snapshot
    var trash: @Sendable (URL) -> DuplicateTrashOutcome
    static func captureTrashOutcome(_ operation: () throws -> URL?) -> DuplicateTrashOutcome {
        do { return .moved(recoveryURL: try operation()) }
        catch { return .notConfirmed(error.localizedDescription) }
    }
    static let live = DuplicateCleanupIO(trash: { url in
        captureTrashOutcome {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            return result as URL?
        }
    })
}
final class DuplicateCleanupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
struct DuplicateCleanupProgress: Sendable {
    let currentFile: String
    let attempted: Int
    let total: Int
}
/// History actions contain immutable URLs and captured identities. The existing
/// generic history type predates Sendable; no manager state crosses this boundary.
struct DuplicateCleanupResult: @unchecked Sendable {
    enum Stop: Sendable { case complete, cancelled, invalidated(String) }
    let total: Int
    let attempted: Int
    let confirmedMoved: Int
    let movedWithoutURL: Int
    let recoveryIdentityMissing: Int
    let unconfirmed: Int
    let errors: [String]
    let stop: Stop
    let undoActions: [FileHistoryAction]
    let touchedDirectories: Set<String>
    var unattempted: Int { total - attempted }
    var verifiedRecoveryCount: Int { undoActions.count - recoveryIdentityMissing }
    var summary: String {
        var parts = ["Duplikaty: potwierdzono przeniesienie do Kosza \(confirmedMoved) z \(total)."]
        switch stop {
        case .complete: break
        case .cancelled: parts.append("Anulowano dalsze kroki; niewykonane: \(unattempted).")
        case .invalidated(let reason): parts.append("Przerwano: \(reason). Niewykonane: \(unattempted).")
        }
        if unconfirmed > 0 { parts.append("Niepotwierdzony wynik operacji: \(unconfirmed). Sprawdź folder i Kosz; nie ponowiono automatycznie.") }
        if movedWithoutURL > 0 { parts.append("Brak ścieżki przywracania dla \(movedWithoutURL) przeniesionych plików; ⌘Z ich nie przywróci.") }
        if recoveryIdentityMissing > 0 { parts.append("Niepotwierdzona tożsamość \(recoveryIdentityMissing) rekordów przywracania; zapisano je jako oczekujące, ale nie można ich teraz wykonać.") }
        if verifiedRecoveryCount > 0 { parts.append("⌘Z: zapisano \(verifiedRecoveryCount) sprawdzonych rekordów przywracania w jednej operacji.") }
        if !errors.isEmpty { parts.append(errors.joined(separator: "; ")) }
        return parts.joined(separator: " ")
    }
}

/// Adapter snapshot only. FileOperationIO's injected callbacks follow the same
/// worker-use contract as existing transfer/history executors; no mutation of
/// this copy or its closures takes place after dispatch.
struct DuplicateCleanupWorkerIO: @unchecked Sendable {
    let cleanup: DuplicateCleanupIO
    let history: FileOperationIO
}

enum DuplicateCleanupExecutor {
    private struct Candidate {
        let item: FileItem
        let keeper: FileItem
        let expected: DuplicateFileSnapshot
        let kept: DuplicateFileSnapshot
    }
    private static func candidates(_ plan: DuplicateCleanupPlan) throws -> [Candidate] {
        var result: [Candidate] = []
        var keeperPaths = Set<String>(), keeperIdentities = Set<String>()
        var candidatePaths = Set<String>(), candidateIdentities = Set<String>()
        func identity(_ snapshot: DuplicateFileSnapshot) -> String { "\(snapshot.device):\(snapshot.inode)" }
        for group in plan.groups {
            guard group.files.count > 1, group.snapshots.count == group.files.count,
                  let keeper = group.files.first, let kept = group.snapshots[keeper.path] else { throw DuplicateSafetyError.changed }
            var groupIdentities = Set<String>()
            for file in group.files {
                guard let snapshot = group.snapshots[file.path], groupIdentities.insert(identity(snapshot)).inserted else { throw DuplicateSafetyError.changed }
            }
            keeperPaths.insert(keeper.path)
            keeperIdentities.insert(identity(kept))
            for item in group.files.dropFirst() where plan.onlyPath == nil || item.path == plan.onlyPath {
                guard let expected = group.snapshots[item.path], item.path != keeper.path,
                      candidatePaths.insert(item.path).inserted,
                      candidateIdentities.insert(identity(expected)).inserted else { throw DuplicateSafetyError.changed }
                result.append(Candidate(item: item, keeper: keeper, expected: expected, kept: kept))
            }
        }
        guard !result.isEmpty, keeperPaths.isDisjoint(with: candidatePaths),
              keeperIdentities.isDisjoint(with: candidateIdentities) else { throw DuplicateSafetyError.changed }
        return result
    }

    static func execute(_ plan: DuplicateCleanupPlan, io: DuplicateCleanupWorkerIO,
                        cancellation: DuplicateCleanupCancellation,
                        progress: @Sendable (DuplicateCleanupProgress) -> Void) -> DuplicateCleanupResult {
        let total = plan.candidateCount
        var attempted = 0, moved = 0, missingURL = 0, missingIdentity = 0, unconfirmed = 0
        var actions: [FileHistoryAction] = [], errors: [String] = []
        var touched = Set<String>()
        var stop: DuplicateCleanupResult.Stop = .complete
        func result() -> DuplicateCleanupResult {
            // Independent original paths permit verified restores first. A
            // later missing identity must not block earlier known-good recovery.
            // Preserve reverse mutation order within each partition; retain all
            // unknown records for the existing fail-closed pending-history path.
            let reversed = Array(actions.reversed())
            let recovery = reversed.filter { $0.identity != nil } + reversed.filter { $0.identity == nil }
            return DuplicateCleanupResult(total: total, attempted: attempted, confirmedMoved: moved,
                movedWithoutURL: missingURL, recoveryIdentityMissing: missingIdentity,
                unconfirmed: unconfirmed, errors: errors, stop: stop,
                undoActions: recovery, touchedDirectories: touched)
        }
        if cancellation.isCancelled { stop = .cancelled; return result() }
        let selected: [Candidate]
        do { selected = try candidates(plan) }
        catch { stop = .invalidated("Plan duplikatów jest nieaktualny lub zawiera nakładające się pliki"); return result() }
        for candidate in selected {
            if cancellation.isCancelled { stop = .cancelled; break }
            progress(DuplicateCleanupProgress(currentFile: candidate.item.name, attempted: attempted, total: total))
            do {
                // No actor hop or progress post between final checks and Trash.
                guard try io.cleanup.snapshot(candidate.keeper.url) == candidate.kept else { throw DuplicateSafetyError.changed }
                if cancellation.isCancelled { stop = .cancelled; break }
                guard try io.cleanup.snapshot(candidate.item.url) == candidate.expected else { throw DuplicateSafetyError.changed }
                if cancellation.isCancelled { stop = .cancelled; break }
                guard try io.cleanup.snapshot(candidate.keeper.url) == candidate.kept else { throw DuplicateSafetyError.changed }
                if cancellation.isCancelled { stop = .cancelled; break }
            } catch {
                stop = cancellation.isCancelled ? .cancelled : .invalidated(String(error.localizedDescription.prefix(400)))
                break
            }
            attempted += 1
            touched.insert(candidate.item.parentPath)
            switch io.cleanup.trash(candidate.item.url) {
            case .moved(let recoveryURL):
                moved += 1
                if let recoveryURL {
                    // Always record a completed mutation, even if Cancel arrived
                    // during Trash. Never defer/retry the identity capture to Undo.
                    let action = FileHistoryAction.restore(from: recoveryURL, to: candidate.item.url, io: io.history)
                    if action.identity == nil { missingIdentity += 1 }
                    actions.append(action)
                    touched.insert(recoveryURL.deletingLastPathComponent().path)
                } else { missingURL += 1 }
            case .notConfirmed(let error):
                unconfirmed += 1
                if errors.count < 8 { errors.append(candidate.item.name + ": " + String(error.prefix(300))) }
            }
        }
        if cancellation.isCancelled { stop = .cancelled }
        return result()
    }
}

/// At most one pending MainActor delivery, irrespective of batch size. Closing
/// suppresses queued progress after the final summary or a later operation.
final class DuplicateCleanupProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: DuplicateCleanupProgress?
    private var scheduled = false
    private var closed = false
    private let update: @MainActor @Sendable (DuplicateCleanupProgress) -> Void
    init(update: @escaping @MainActor @Sendable (DuplicateCleanupProgress) -> Void) { self.update = update }
    func offer(_ progress: DuplicateCleanupProgress) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        latest = progress
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if shouldSchedule { Task { @MainActor in self.deliver() } }
    }
    @MainActor private func deliver() {
        lock.lock()
        let value = closed ? nil : latest
        latest = nil
        scheduled = false
        lock.unlock()
        if let value { update(value) }
    }
    func close() { lock.lock(); closed = true; latest = nil; lock.unlock() }
}

/// Read at the actual handoff and completion, not copied from an old SwiftUI
/// render. This seam is shared by the view and deterministic ownership tests.
struct DuplicateCleanupViewState {
    let scanToken: AnalysisRequestToken?
    let resultReady: Bool
    let isComplete: Bool
    let mode: WizTreeSubMode
    let cleanupID: UUID?
}
@MainActor
enum DuplicateCleanupHandoff {
    private static func accepts(_ token: AnalysisRequestToken, state: DuplicateCleanupViewState,
                                appState: AppState) -> Bool {
        token.canUseAnalysisResult(active: state.scanToken, resultReady: state.resultReady,
            isComplete: state.isComplete, requiresComplete: true)
            && token.canPublishAnalysis(active: state.scanToken, appState: appState, mode: state.mode)
    }
    @discardableResult
    static func start(verified: AnalysisVerificationResult, plan: DuplicateCleanupPlan,
        scanToken: AnalysisRequestToken, requestID: UUID, appState: AppState,
        manager: FileOperationsManager, current: @escaping @MainActor () -> DuplicateCleanupViewState,
        didFinish: @escaping @MainActor (_ mayRescan: Bool) -> Void) -> Bool {
        guard case .verified = verified else { return false }
        let state = current()
        guard state.cleanupID == requestID, accepts(scanToken, state: state, appState: appState) else { return false }
        return manager.startDuplicateCleanup(plan, requestID: requestID) { _ in
            let currentState = current()
            // Manager has already finalized summary/history, independently of UI.
            // Never clear a new operation's state or rescan a replacement owner.
            guard currentState.cleanupID == requestID else { return }
            didFinish(accepts(scanToken, state: currentState, appState: appState))
        }
    }
    static func cancelOwned(_ requestID: UUID?, manager: FileOperationsManager) {
        if let requestID { manager.cancelDuplicateCleanup(requestID) }
    }
}
