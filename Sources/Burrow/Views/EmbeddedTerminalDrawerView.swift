import SwiftUI
import AppKit
import Darwin

struct TerminalCommandResult: Sendable {
    let output: String
    /// Exit code, or 128 + terminating signal (shell convention), never raw waitpid bits.
    let status: Int32
    let wasCancelled: Bool
    let wasTruncated: Bool
    /// Diagnostic count used to verify bounded waiting after pipe EOF.
    let waitIterations: Int
}

/// One bounded merged output pipe removes the stdout/stderr dependency cycle.
/// A dedicated POSIX process group allows cancellation of the shell and ordinary
/// pipeline children while the session is running. Background jobs may outlive a
/// completed shell; deliberately detached children can also leave its process group.
final class TerminalCommandSession: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let outputLimit: Int
    init(outputLimit: Int = 1_048_576) { self.outputLimit = max(1, outputLimit) }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run(command: String, directory: URL, shell: String = "/bin/zsh") throws -> TerminalCommandResult {
        if isCancelled { return TerminalCommandResult(output: "", status: 0, wasCancelled: true, wasTruncated: false, waitIterations: 0) }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw posixError(errno) }
        let readFD = descriptors[0], writeFD = descriptors[1]
        defer { Darwin.close(readFD) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var actionError = posix_spawn_file_actions_init(&actions)
        guard actionError == 0 else { Darwin.close(writeFD); throw posixError(actionError) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        actionError = posix_spawnattr_init(&attributes)
        guard actionError == 0 else { Darwin.close(writeFD); throw posixError(actionError) }
        defer { posix_spawnattr_destroy(&attributes) }
        // Do not expose app stdin; noninteractive readers must see EOF.
        let setupErrors = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, readFD),
            posix_spawn_file_actions_addclose(&actions, writeFD),
            posix_spawn_file_actions_addchdir_np(&actions, directory.path),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
            posix_spawnattr_setpgroup(&attributes, 0)
        ]
        if let error = setupErrors.first(where: { $0 != 0 }) { Darwin.close(writeFD); throw posixError(error) }
        var argv = [strdup(shell), strdup("-c"), strdup(command), nil]
        defer { for pointer in argv { if let pointer { free(pointer) } } }
        // Own a stable environment snapshot through the spawn call instead of
        // relying on the C environment accessor unavailable in this Swift toolchain.
        var environment: [UnsafeMutablePointer<CChar>?] = []
        defer { for pointer in environment { if let pointer { free(pointer) } } }
        for (key, value) in ProcessInfo.processInfo.environment {
            guard let entry = strdup("\(key)=\(value)") else {
                Darwin.close(writeFD)
                throw posixError(ENOMEM)
            }
            environment.append(entry)
        }
        environment.append(nil)
        var pid: pid_t = 0
        let spawnError = argv.withUnsafeMutableBufferPointer { args in
            environment.withUnsafeMutableBufferPointer { env in
                posix_spawn(&pid, shell, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        Darwin.close(writeFD)
        guard spawnError == 0 else { throw posixError(spawnError) }
        let flags = fcntl(readFD, F_GETFL)
        guard flags >= 0, fcntl(readFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let savedError = errno
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            throw posixError(savedError)
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        var status: Int32 = 0
        var truncated = false
        var cancellationStarted: UInt64?
        var killed = false
        var exited = false
        var outputEOF = false
        var waitIterations = 0
        while !exited {
            if isCancelled && cancellationStarted == nil {
                cancellationStarted = DispatchTime.now().uptimeNanoseconds
                kill(-pid, SIGTERM)
            }
            if let started = cancellationStarted, !killed,
               DispatchTime.now().uptimeNanoseconds - started >= 500_000_000 {
                // Escalate before reaping the leader, so its group ID cannot be reused.
                kill(-pid, SIGKILL)
                killed = true
            }
            // POLLHUP stays ready forever after EOF. Ignore that descriptor and
            // retain the bounded 50ms wait while the child remains alive.
            waitIterations += 1
            var event = pollfd(fd: outputEOF ? -1 : readFD, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&event, 1, 50)
            // Drain in bounded chunks even after the display limit is reached.
            for _ in 0..<(outputEOF ? 0 : 32) {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress!, $0.count) }
                if count == 0 { outputEOF = true; break }
                if count < 0 {
                    if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { outputEOF = true }
                    break
                }
                let remaining = max(0, outputLimit - output.count)
                output.append(contentsOf: buffer.prefix(min(count, remaining)))
                if count > remaining { truncated = true }
            }
            // Keep the shell unreaped until cancellation escalation has finished.
            if cancellationStarted == nil || killed {
                let waited = waitpid(pid, &status, WNOHANG)
                exited = waited == pid || (waited < 0 && errno == ECHILD)
            }
        }
        // Consume bytes already buffered, without waiting for EOF from detached children.
        for _ in 0..<64 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress!, $0.count) }
            if count <= 0 { break }
            let remaining = max(0, outputLimit - output.count)
            output.append(contentsOf: buffer.prefix(min(count, remaining)))
            if count > remaining { truncated = true }
        }
        let signal = status & 0x7f
        let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        return TerminalCommandResult(output: String(decoding: output, as: UTF8.self), status: exitCode,
            wasCancelled: isCancelled, wasTruncated: truncated, waitIterations: waitIterations)
    }

    private func posixError(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
}

public struct EmbeddedTerminalDrawerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var activeTab: PaneTabState
    @ObservedObject private var workspace: TerminalWorkspace
    public init(appState: AppState, activeTab: PaneTabState) {
        self.appState = appState; self.activeTab = activeTab
        self.workspace = appState.terminalWorkspace
    }
    public var body: some View {
        VStack(spacing: 0) {
            // One header: tabs (or a title while there is only one), the folder,
            // then the actions. The output below starts right after it.
            HStack(spacing: FinderUI.rowSpacing) {
                if workspace.tabs.count > 1 {
                    tabStrip
                } else {
                    Label("Terminal", systemImage: "terminal")
                        .font(FinderUI.detailFont.weight(.semibold))
                        .fixedSize()
                }
                if let tab = workspace.selected {
                    TerminalFolderLabel(terminal: tab, browsedPath: activeTab.currentURL.standardizedFileURL.path)
                }
                Spacer(minLength: FinderUI.rowSpacing)
                if let tab = workspace.selected {
                    TerminalTabActions(terminal: tab)
                    Divider().frame(height: 16)
                }
                terminalHeaderButton("New terminal tab in the active pane’s folder", icon: "plus",
                                     accessibility: "New Terminal Tab") {
                    _ = workspace.add(directory: activeTab.currentURL)
                }
                .disabled(workspace.tabs.count >= TerminalWorkspace.tabLimit)
                terminalHeaderButton("Hide Terminal (Ctrl+`)", icon: "chevron.down", accessibility: "Hide Terminal") {
                    appState.showTerminalDrawer = false
                }
            }
            .padding(.leading, FinderUI.sectionSpacing)
            .padding(.trailing, FinderUI.panelInset)
            .frame(height: 32)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            if let tab = workspace.selected {
                TerminalTabContent(appState: appState, terminal: tab).id(tab.id)
            } else {
                VStack(spacing: 12) {
                    Text("No terminal tabs").foregroundStyle(.secondary)
                    Button("New Tab") { _ = workspace.add(directory: activeTab.currentURL) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { workspace.ensureInitial(directory: activeTab.currentURL) }
    }

    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.tabs) { tab in
                        let isSelected = workspace.selectedID == tab.id
                        HStack(spacing: 2) {
                            Button { workspace.select(tab.id) } label: {
                                Text("Terminal \(tab.ordinal)")
                                    .font(FinderUI.detailFont.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                    .lineLimit(1)
                                    .padding(.leading, 10)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            Button { workspace.close(tab.id) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 4)
                            .help("Close the tab and cancel its command")
                            .accessibilityLabel("Close Terminal \(tab.ordinal)")
                        }
                        // Grey like the other mode pills; blue stays for selection in lists.
                        .background(isSelected ? Color.primary.opacity(0.08) : Color.clear, in: Capsule())
                        .id(tab.id)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: 420, alignment: .leading)
            .onChange(of: workspace.selectedID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                if let id = workspace.selectedID { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

/// Header controls shared by the drawer: borderless, secondary, 24 pt targets.
private func terminalHeaderButton(_ help: LocalizedStringKey, icon: String, accessibility: LocalizedStringKey,
                                  action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: icon)
            .font(FinderUI.detailFont)
            .foregroundStyle(FinderUI.metadataColor)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(help)
    .accessibilityLabel(accessibility)
}

/// The selected tab's folder, kept current as `cd` moves it. Shown only when the
/// shell has moved away from the folder being browsed; the prompt names it anyway.
private struct TerminalFolderLabel: View {
    @ObservedObject var terminal: TerminalTab
    let browsedPath: String
    var body: some View {
        if terminal.directory.standardizedFileURL.path != browsedPath {
            label
        }
    }

    private var label: some View {
        Text(terminal.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            .font(FinderUI.detailFont)
            .foregroundStyle(FinderUI.metadataColor)
            .lineLimit(1)
            .truncationMode(.head)
            .textSelection(.enabled)
            .help(terminal.directory.path)
            .accessibilityLabel("Current folder: \(terminal.directory.path)")
    }
}

private struct TerminalTabActions: View {
    @ObservedObject var terminal: TerminalTab
    var body: some View {
        HStack(spacing: 2) {
            terminalHeaderButton("Clear Terminal Output", icon: "eraser", accessibility: "Clear Terminal Output") {
                terminal.clear()
            }
            .disabled(terminal.transcript.lines.isEmpty)
            terminalHeaderButton("Open Folder in External Terminal", icon: "arrow.up.forward.app",
                                 accessibility: "Open Folder in External Terminal") {
                FileOperationsManager.shared.openInTerminal(at: terminal.directory)
            }
        }
    }
}

private struct TerminalTabContent: View {
    @ObservedObject var appState: AppState
    @ObservedObject var terminal: TerminalTab
    @FocusState private var isInputFocused: Bool
    private var outputLines: [TerminalOutputLine] { terminal.transcript.lines }
    private var isRunning: Bool { terminal.isRunning }
    private static let monoFont = Font.system(size: 13, design: .monospaced)

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if outputLines.isEmpty {
                            Text(isRunning ? String(localized: "Running command…") : String(localized: "No output. Enter a command below."))
                                .font(FinderUI.detailFont)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(Array(outputLines.enumerated()), id: \.element.id) { index, line in
                            outputLine(line)
                                // A little air before each command groups it with its output.
                                .padding(.top, line.isCommand && index > 0 ? 8 : 0)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, FinderUI.sectionSpacing)
                    .padding(.vertical, FinderUI.rowSpacing + 2)
                }
                .onChange(of: outputLines.last?.id) { _, _ in
                    if let last = outputLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            // The prompt continues the transcript, like a terminal, behind a hairline.
            Divider().opacity(0.6)
            HStack(spacing: FinderUI.rowSpacing) {
                Text("\(terminal.directory.lastPathComponent) %")
                    .font(Self.monoFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140, alignment: .leading)
                    .fixedSize()
                    .help(terminal.directory.path)
                    .accessibilityHidden(true)

                TextField("Enter a zsh command…", text: $terminal.commandInput)
                    .textFieldStyle(.plain)
                    .font(Self.monoFont)
                    .focused($isInputFocused)
                    .disabled(isRunning)
                    .accessibilityLabel("Terminal command")
                    .help("Press Return to run the command in the current folder. Interactive commands require an external terminal.")
                    .onSubmit {
                        let cmd = terminal.commandInput
                        guard !isRunning, !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        terminal.commandInput = ""
                        terminal.execute(cmd)
                    }

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Running command")
                    Button("Cancel") { terminal.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Cancel the current command")
                }
            }
            .padding(.horizontal, FinderUI.sectionSpacing)
            .padding(.vertical, 8)
        }
        // One step off the file list's surface, so the two regions never blur together.
        .background(Color(nsColor: .textBackgroundColor).overlay(Color.primary.opacity(0.035)))
        .onAppear { isInputFocused = true }
    }

    /// Commands read "Studio % ls -lh": the prompt quiet, the command firm.
    /// Output is plain; errors use the system red.
    @ViewBuilder
    private func outputLine(_ line: TerminalOutputLine) -> some View {
        Group {
            if line.isCommand, let split = line.text.range(of: "] % "), line.text.hasPrefix("[") {
                let folder = String(line.text[line.text.index(after: line.text.startIndex)..<split.lowerBound])
                let command = String(line.text[split.upperBound...])
                (Text(verbatim: "\(folder) % ").foregroundColor(.secondary)
                    + Text(verbatim: command).fontWeight(.semibold).foregroundColor(.primary))
                    .font(Self.monoFont)
            } else {
                Text(line.text)
                    .font(Self.monoFont.weight(line.isCommand ? .semibold : .regular))
                    .foregroundStyle(line.isError ? Color(nsColor: .systemRed) : Color.primary.opacity(0.85))
            }
        }
        .lineSpacing(3)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
