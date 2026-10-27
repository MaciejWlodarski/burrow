import AppKit
import Foundation
import CoreFoundation

/// Direct production-delegate/model integration, not an NSApplication modal quit
/// or a rendered SwiftUI interaction test. Runs in its own isolated process.
@main struct TerminalLiveIntegration {
    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(description: message) }
    }
    @MainActor static func wait(_ label: String, seconds: Double = 5,
                               until condition: () -> Bool) throws {
        let end = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        while !condition() && DispatchTime.now().uptimeNanoseconds < end {
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
            Thread.sleep(forTimeInterval: 0.005)
        }
        try require(condition(), "Timed out: \(label)")
    }
    @MainActor static func main() {
        guard let path = ProcessInfo.processInfo.environment["BURROW_TEST_ROOT"] else {
            fputs("FAIL missing isolated test root\n", stderr); exit(1)
        }
        let root = URL(fileURLWithPath: path).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let state = AppState.shared
        let workspace = state.terminalWorkspace
        let lifecycle = TerminalApplicationLifecycle.shared
        var failure: Error?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try require(lifecycle.activeCount == 0 && workspace.tabs.isEmpty, "Harness must start isolated")
            let first = workspace.add(directory: root)!
            let second = workspace.add(directory: root)!
            func exists(_ name: String) -> Bool {
                FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
            }
            first.execute("printf ready > first-ready; exec /bin/sleep 20")
            // Bounded gate lets us prove this real shell remains alive after closing
            // the other tab. Only synthetic files inside the unique test root are used.
            second.execute("printf ready > second-ready; SECONDS=0; while [[ ! -e continue-second && $SECONDS -lt 10 ]]; do /bin/sleep 0.05; done; [[ -e continue-second ]] || exit 90; printf alive > second-alive; exec /bin/sleep 20")
            try wait("both real shells ready") { exists("first-ready") && exists("second-ready") }
            try require(lifecycle.activeCount == 2 && first.isRunning && second.isRunning, "Both real tabs must be owned")
            state.showTerminalDrawer = true
            workspace.select(first.id)
            workspace.select(second.id)
            state.showTerminalDrawer = false
            try require(lifecycle.activeCount == 2 && first.isRunning && second.isRunning, "Switch/hide model state cannot cancel workers")
            workspace.close(first.id)
            try wait("only first worker physically released") { lifecycle.activeCount == 1 }
            try require(second.isRunning && workspace.selectedID == second.id, "Close must preserve second tab")
            try Data().write(to: root.appendingPathComponent("continue-second"))
            try wait("second shell acknowledges after first close") { exists("second-alive") }
            try require(second.isRunning && lifecycle.activeCount == 1, "Second shell remains owned after acknowledgment")

            let third = workspace.add(directory: root)!
            third.execute("printf ready > third-ready; exec /bin/sleep 20")
            try wait("third real shell ready") { exists("third-ready") }
            try require(lifecycle.activeCount == 2, "Quit must cover two physically running workers")
            let delegate = AppDelegate()
            var replies: [(Bool, Int)] = []
            delegate.terminationReplyForTesting = { replies.append(($0, lifecycle.activeCount)) }
            let decision = delegate.applicationShouldTerminate(NSApplication.shared)
            try require(decision == .terminateLater && replies.isEmpty, "Delegate must defer, not synchronously approve quit")
            try wait("delegate reply after all workers release") { !replies.isEmpty && !second.isRunning && !third.isRunning }
            try require(replies.count == 1 && replies[0].0 && replies[0].1 == 0 && lifecycle.activeCount == 0,
                        "Exactly one successful reply is allowed, only at registry zero")
            // Drain a further interval to catch duplicate completion delivery.
            let end = DispatchTime.now().uptimeNanoseconds + 100_000_000
            while DispatchTime.now().uptimeNanoseconds < end { CFRunLoopRunInMode(.defaultMode, 0.01, false) }
            try require(replies.count == 1, "Late callbacks cannot duplicate the delegate reply")
            second.execute("printf should-not-launch")
            try require(!second.isRunning && lifecycle.activeCount == 0, "Quit barrier must reject new commands")
        } catch { failure = error }

        // Fail closed: all paths cancel/drain only workers admitted by this isolated
        // process. Never signal arbitrary PIDs or report success with workers owned.
        for tab in workspace.tabs { tab.cancel() }
        _ = lifecycle.beginTermination { _ in }
        do { try wait("cleanup physical worker drain", seconds: 6) { lifecycle.activeCount == 0 } }
        catch {
            fputs("FAIL CLEANUP: \(error); fixture retained at \(root.path)\n", stderr)
            exit(2)
        }
        if let failure {
            fputs("FAIL: \(failure); fixture retained at \(root.path)\n", stderr)
            exit(1)
        }
        try? FileManager.default.removeItem(at: root)
        print("PASS real multi-tab switch/hide model, close-one survival, direct AppDelegate quit and physical registry drain")
    }
}
