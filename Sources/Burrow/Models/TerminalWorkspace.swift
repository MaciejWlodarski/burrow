import Foundation
import Combine

/// Command tabs outlive drawer rendering. Hiding/switching never destroys a worker.
@MainActor
final class TerminalWorkspace: ObservableObject {
    static let tabLimit = 8
    @Published private(set) var tabs: [TerminalTab] = []
    @Published var selectedID: UUID?
    private let lifecycle: TerminalApplicationLifecycle
    private var nextOrdinal = 1
    init(lifecycle: TerminalApplicationLifecycle = .shared) { self.lifecycle = lifecycle }
    var selected: TerminalTab? { tabs.first { $0.id == selectedID } }
    @discardableResult func add(directory: URL) -> TerminalTab? {
        guard tabs.count < Self.tabLimit else { return nil }
        let tab = TerminalTab(directory: directory, lifecycle: lifecycle, ordinal: nextOrdinal)
        nextOrdinal += 1
        tabs.append(tab); selectedID = tab.id
        return tab
    }
    func ensureInitial(directory: URL) { if tabs.isEmpty { _ = add(directory: directory) } }
    func select(_ id: UUID) { if tabs.contains(where: { $0.id == id }) { selectedID = id } }
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].close()
        tabs.remove(at: index)
        if selectedID == id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }
}

@MainActor
final class TerminalTab: ObservableObject, Identifiable {
    let id = UUID()
    let ordinal: Int
    @Published private(set) var directory: URL
    @Published var commandInput = ""
    @Published private(set) var transcript = TerminalTranscript()
    @Published private(set) var commandHistory: [String] = []
    @Published private(set) var isRunning = false
    private var session: TerminalCommandSession?
    private var token: UUID?
    private var closed = false
    private let lifecycle: TerminalApplicationLifecycle
    private let reconcile: @MainActor (String) -> Void
    init(directory: URL, lifecycle: TerminalApplicationLifecycle = .shared, ordinal: Int = 1,
         reconcile: @escaping @MainActor (String) -> Void = { AppState.shared.reconcileTerminalCommand(at: $0) }) {
        self.directory = directory
        self.ordinal = ordinal
        self.lifecycle = lifecycle
        self.reconcile = reconcile
        transcript.append(text: "Zsh • każda komenda uruchamia osobny proces. Samodzielne cd zmienia folder tej karty. Polecenia interaktywne wymagają zewnętrznego terminala.")
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    #if BURROW_TESTING
    /// Static renderer only: no admission, process or lifecycle claim.
    func setRunningPresentationForTesting(_ running: Bool) { isRunning = running }
    #endif
    func clear() { transcript.removeAll() }
    func cancel() { session?.cancel() }
    func close() { closed = true; session?.cancel(); token = nil; session = nil; isRunning = false }
    func execute(_ raw: String) {
        guard !closed, !isRunning, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let cwd = directory
        transcript.append(parts: ["[", cwd.lastPathComponent, "] % ", raw], isCommand: true)
        if raw.utf8.prefix(16_385).count <= 16_384 { commandHistory.append(raw); commandHistory = Array(commandHistory.suffix(100)) }
        if raw == "clear" { clear(); return }
        let directoryTarget = TerminalDirectoryCommand.target(for: raw, directory: cwd)
        let request = UUID(); token = request
        let reconcileAfterCommand = reconcile
        let executable = directoryTarget.map { "builtin cd -- " + Self.shellQuote($0.path) } ?? raw
        // Classification resolves relative operands against the tab's cwd without
        // I/O. Validate the absolute target in the admitted worker, launched from
        // a stable directory so a removed/renamed cwd cannot prevent cd itself.
        let launchDirectory = directoryTarget == nil ? cwd : URL(fileURLWithPath: "/", isDirectory: true)
        guard let worker = lifecycle.start(command: executable, directory: launchDirectory, completion: { [weak self] result in
            // Reconcile even a closed tab's mutations, without touching another tab's UI.
            if directoryTarget == nil { reconcileAfterCommand(cwd.path) }
            guard let self, !self.closed, self.token == request else { return }
            switch result {
            case .success(let value):
                if let target = directoryTarget, value.status == 0, !value.wasCancelled {
                    self.directory = target
                    self.transcript.append(text: "→ \(target.path)")
                }
                self.transcript.appendOutput(value.output)
                if value.wasTruncated { self.transcript.append(text: "[Wyjście ograniczone do 1 MiB; dalsze dane odczytano i pominięto.]") }
                if value.wasCancelled || value.status != 0 {
                    self.transcript.append(text: value.wasCancelled ? "[Polecenie przerwane]" : "[Polecenie zakończone błędem: \(value.status)]", isError: true)
                }
            case .failure(let error): self.transcript.append(text: "Błąd wykonania: \(error.localizedDescription)", isError: true)
            }
            self.session = nil; self.token = nil; self.isRunning = false
        }) else {
            token = nil
            transcript.append(text: "[Nie uruchomiono polecenia: trwa zamykanie aplikacji lub osiągnięto limit aktywnych procesów.]", isError: true)
            return
        }
        session = worker; isRunning = true
    }
}
