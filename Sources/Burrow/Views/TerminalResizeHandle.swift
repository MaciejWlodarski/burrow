import SwiftUI
import AppKit

struct TerminalResizeHandle: View {
    let height: CGFloat
    let onIncrease: () -> Void
    let onDecrease: () -> Void
    let onReset: () -> Void
    @StateObject private var keyboardFocus = TerminalResizeKeyboardFocus()
    @ViewState private var isHovered = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            Capsule()
                .fill(keyboardFocus.hasFocus ? Color.accentColor : Color.secondary.opacity(isHovered ? 0.8 : 0.45))
                .frame(width: 34, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: TerminalDrawerLayout.dividerHeight)
        .contentShape(Rectangle())
        .background(TerminalResizeCursor(focus: keyboardFocus, onIncrease: onIncrease, onDecrease: onDecrease))
        .onHover { isHovered = $0 }
        .simultaneousGesture(TapGesture().onEnded { keyboardFocus.requestFocus() })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Wysokość terminala")
        .accessibilityValue("\(Int(height)) punktów")
        .accessibilityHint("Przeciągnij w górę lub w dół. Po zaznaczeniu użyj strzałek, aby zmienić wysokość.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onIncrease()
            case .decrement: onDecrease()
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Przywróć domyślną wysokość"), onReset)
        .contextMenu {
            Button("Powiększ terminal", action: onIncrease)
            Button("Zmniejsz terminal", action: onDecrease)
            Divider()
            Button("Domyślna wysokość", action: onReset)
        }
        .help("Przeciągnij, aby zmienić wysokość terminala. Strzałki ↑/↓ zmieniają wysokość po zaznaczeniu separatora.")
    }
}

/// Cursor rectangles follow geometry/lifetime without an unbalanced global push/pop.
private struct TerminalResizeCursor: NSViewRepresentable {
    let focus: TerminalResizeKeyboardFocus
    let onIncrease: () -> Void
    let onDecrease: () -> Void

    func makeNSView(context: Context) -> TerminalResizeKeyboardView {
        let view = TerminalResizeKeyboardView()
        focus.view = view
        view.onFocusChange = { [weak focus] in focus?.hasFocus = $0 }
        return view
    }
    func updateNSView(_ view: TerminalResizeKeyboardView, context: Context) {
        view.onIncrease = onIncrease
        view.onDecrease = onDecrease
        view.window?.invalidateCursorRects(for: view)
    }
    static func dismantleNSView(_ view: TerminalResizeKeyboardView, coordinator: ()) {
        view.releaseKeyboardFocus()
        view.onFocusChange = nil
        view.onIncrease = nil
        view.onDecrease = nil
    }
}

@MainActor
private final class TerminalResizeKeyboardFocus: ObservableObject {
    @Published var hasFocus = false
    weak var view: TerminalResizeKeyboardView?
    func requestFocus() {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
    }
}

/// AppKit owns focus identity and lifetime. A stale blur or dismantle of another
/// separator cannot clear the current responder, including in another window.
@MainActor
final class TerminalResizeKeyboardView: NSView, FinderFileKeyboardOwner {
    var onIncrease: (() -> Void)?
    var onDecrease: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocusChange?(true)
        return true
    }
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        onFocusChange?(false)
        return true
    }
    func releaseKeyboardFocus() {
        guard let window, window.firstResponder === self else { return }
        window.makeFirstResponder(nil)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { releaseKeyboardFocus() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            switch event.keyCode {
            case 126: onIncrease?(); return
            case 125: onDecrease?(); return
            case 48:
                if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
                else { window?.selectNextKeyView(self) }
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }
    // SwiftUI retains pointer gestures (including the parent's resize drag).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
