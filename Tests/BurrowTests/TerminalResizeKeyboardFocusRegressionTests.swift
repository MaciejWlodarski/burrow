import AppKit

@MainActor
struct TerminalResizeKeyboardFocusRegressionTests {
    static func runAll() throws {
        _ = NSApplication.shared
        func window() -> NSWindow {
            let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            result.isReleasedWhenClosed = false
            return result
        }
        func arrow(_ key: UInt16, in window: NSWindow) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil,
                             characters: key == 126 ? "\u{F700}" : "\u{F701}",
                             charactersIgnoringModifiers: key == 126 ? "\u{F700}" : "\u{F701}",
                             isARepeat: false, keyCode: key)!
        }
        let first = window(), second = window()
        defer { first.close(); second.close() }
        let separator = TerminalResizeKeyboardView(frame: NSRect(x: 0, y: 0, width: 300, height: 8))
        let replacement = TerminalResizeKeyboardView(frame: NSRect(x: 0, y: 20, width: 300, height: 8))
        let otherSeparator = TerminalResizeKeyboardView(frame: NSRect(x: 0, y: 0, width: 300, height: 8))
        first.contentView!.addSubview(separator)
        first.contentView!.addSubview(replacement)
        second.contentView!.addSubview(otherSeparator)
        var adjustments = 0
        separator.onIncrease = { adjustments += 1 }
        separator.onDecrease = { adjustments -= 1 }
        try expect(first.makeFirstResponder(separator))
        let up = arrow(126, in: first), down = arrow(125, in: first)
        // These are the exact predicate and responder delivery used by the local
        // monitor. Both arrows must survive the monitor before reaching the view.
        try expect(!FinderCommandRouting.shouldRouteFileKeyEvent(up))
        first.sendEvent(up)
        try expect(adjustments == 1)
        try expect(!FinderCommandRouting.shouldRouteFileKeyEvent(down))
        first.sendEvent(down)
        try expect(adjustments == 0)

        // The event window decides routing even while another window is key.
        second.makeKey()
        try expect(first.firstResponder === separator)
        try expect(!FinderCommandRouting.shouldRouteFileKeyEvent(up))
        try expect(FinderCommandRouting.shouldRouteFileKeyEvent(arrow(126, in: second)))
        try expect(second.makeFirstResponder(otherSeparator))
        try expect(!FinderCommandRouting.shouldRouteFileKeyEvent(arrow(126, in: second)))
        try expect(first.makeFirstResponder(nil))
        try expect(FinderCommandRouting.shouldRouteFileKeyEvent(up))
        try expect(!FinderCommandRouting.shouldRouteFileKeyEvent(arrow(126, in: second)))

        // Delayed teardown/blur of an old separator cannot revoke its replacement
        // or a different window's owner. No mutable global focus flag is involved.
        try expect(first.makeFirstResponder(replacement))
        separator.releaseKeyboardFocus()
        _ = separator.resignFirstResponder()
        separator.removeFromSuperview()
        try expect(first.firstResponder === replacement)
        try expect(!FinderCommandRouting.shouldRouteFileKeyEvent(up))
        try expect(!FinderCommandRouting.shouldRouteFileKeyEvent(arrow(126, in: second)))
        replacement.removeFromSuperview()
        try expect(first.firstResponder !== replacement)
        try expect(FinderCommandRouting.shouldRouteFileKeyEvent(up))
        otherSeparator.releaseKeyboardFocus()
        try expect(FinderCommandRouting.shouldRouteFileKeyEvent(arrow(126, in: second)))

        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        first.contentView!.addSubview(editor)
        try expect(first.makeFirstResponder(editor))
        try expect(!FinderCommandRouting.shouldRouteFileKeyEvent(up))
        try expect(first.makeFirstResponder(nil))
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        try expect(!FinderCommandRouting.shouldRouteFileKeyEvent(arrow(126, in: panel)))
        print("PASS terminal separator receives arrows; routing follows live per-window responder and teardown")
    }
}
