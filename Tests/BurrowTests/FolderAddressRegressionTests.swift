import Foundation
import AppKit
import SwiftUI

struct FolderAddressRegressionTests {
    @MainActor static func runAll() throws {
        let base = URL(fileURLWithPath: "/tmp/Address Base", isDirectory: true)
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let examples = [
            ("/Volumes/My Share/Folder", "/Volumes/My Share/Folder"),
            ("~", "/Users/test"), ("~/Documents", "/Users/test/Documents"),
            ("../Sibling", "/tmp/Sibling"), ("folder with spaces", "/tmp/Address Base/folder with spaces"),
            ("file:///Volumes/My%20Share/Folder", "/Volumes/My Share/Folder"),
            ("file://localhost/tmp/Folder", "/tmp/Folder"),
            ("file:///tmp/a%20b/%C5%BC%C3%B3%C5%82%C4%87", "/tmp/a b/żółć"),
            ("file:///tmp/%F0%9F%93%81", "/tmp/📁"),
            ("file:///tmp/%2500literal", "/tmp/%00literal"),
            ("file:///tmp/%252Fsingle-decode", "/tmp/%2Fsingle-decode"),
            ("/tmp/literal%00", "/tmp/literal%00"),
            ("/tmp/name#fragment?literal", "/tmp/name#fragment?literal"),
            ("/tmp/ leading and trailing ", "/tmp/ leading and trailing ")
        ]
        for (input, expected) in examples {
            let resolved = try FolderAddress.resolve(input, relativeTo: base, home: home)
            try expect(resolved.path == expected)
        }
        for invalid in ["", "~another/Documents", "smb://server/share", "https://example.com", "file://server/share",
                        "file://user:secret@localhost/tmp", "file:///tmp?q=1", "file:///tmp#fragment",
                        "file:///tmp/%00secret", "file:///tmp/%0Aline",
                        "file:///tmp/mixed%20name%00suffix", "file:///tmp/%0aline", "file:///tmp/%0dline",
                        "file:///tmp/%09tab", "file:///tmp/%7fdelete", "file:///tmp/%C2%85nextline",
                        "file:///tmp/%c2%85nextline", "file:///tmp/%FFinvalid", "file:///tmp/%C0%80overlong",
                        "file:///tmp/%", "file:///tmp/%0", "file:///tmp/%GG", "file://localhost:42/tmp", "a\nb", String(repeating: "x", count: 16_385)] {
            do {
                _ = try FolderAddress.resolve(invalid, relativeTo: base, home: home)
                throw RegressionFailure(description: "Address unexpectedly accepted: \(invalid.prefix(40))")
            } catch is FolderAddress.Failure { }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bf-address-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("one.txt"))
        let pane = PaneTabState(initialURL: root), other = PaneTabState(initialURL: child)
        try expect(pane.navigate(to: root))
        pane.selectedPaths = [root.appendingPathComponent("one.txt").path]
        let current = pane.currentURL, history = pane.historyBack, selection = pane.selectedPaths
        let listing = pane.directoryItems.map(\.path)
        pane.requestPathEditing()
        let firstRequest = pane.pathEditRequest
        pane.requestPathEditing()
        try expect(pane.isEditingPathBar && pane.pathEditRequest != firstRequest)
        try expect(!other.isEditingPathBar && other.pathEditRequest == 0)
        let missing = try FolderAddress.resolve("missing", relativeTo: pane.currentURL, home: home)
        try expect(!pane.navigate(to: missing, clearSearch: true))
        try expect(pane.currentURL == current && pane.historyBack == history && pane.selectedPaths == selection)
        try expect(pane.directoryItems.map(\.path) == listing && pane.isEditingPathBar)
        let parsedChild = try FolderAddress.resolve(child.path, relativeTo: pane.currentURL, home: home)
        try expect(pane.navigate(to: parsedChild, clearSearch: true))
        try expect(pane.currentURL.path == child.path && pane.historyBack.last?.path == current.path)
        try testNativeBridgeCommands()
        print("PASS folder address parsing, repeated edit request, transactional navigation and native delegate routing regressions")
    }

    @MainActor private static func testNativeBridgeCommands() throws {
        var draft = "/tmp/initial", commits = 0, cancels = 0, changes = 0
        let bridge = FolderAddressTextField(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isEditing: true, focusRequest: 2, mayFocus: { true },
            beginEditing: {}, endEditing: {}, changed: { changes += 1 },
            submit: { commits += 1 }, cancel: { cancels += 1 }
        )
        let coordinator = bridge.makeCoordinator()
        let field = NSTextField(string: "/tmp/edited")
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try expect(draft == "/tmp/edited" && changes == 1)
        let editor = NSTextView()
        editor.string = "/tmp/committed"
        try expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try expect(draft == "/tmp/committed" && commits == 1 && cancels == 0)
        try expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        try expect(cancels == 1 && commits == 1)
        try expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        FolderAddressTextField.dismantleNSView(field, coordinator: coordinator)
        try expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try expect(commits == 1)
        // Actual first-responder selection and two-pane window behavior remain
        // native GUI harness gates; delegate calls alone cannot establish them.
    }

}
