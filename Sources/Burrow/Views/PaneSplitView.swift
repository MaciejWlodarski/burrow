import SwiftUI
import AppKit

/// Two panes side by side with a draggable hairline between them.
///
/// A SwiftUI layout rather than HSplitView: HSplitView hosts each pane in its own
/// AppKit split item, which made live window resizing slow and could loop AppKit's
/// constraint passes until it raised an exception.
struct PaneSplitView<Left: View, Right: View>: View {
    @Binding var fraction: CGFloat
    let minPaneWidth: CGFloat
    let left: Left
    let right: Right
    @ViewState private var width = PaneSplitWidth()

    init(fraction: Binding<CGFloat>, minPaneWidth: CGFloat,
         @ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        _fraction = fraction
        self.minPaneWidth = minPaneWidth
        self.left = left()
        self.right = right()
    }

    var body: some View {
        PaneSplitLayout(fraction: fraction, minPaneWidth: minPaneWidth, width: width) {
            left
            divider.zIndex(1)
            right
        }
        .coordinateSpace(name: "PaneSplit")
    }

    private var divider: some View {
        VerticalSplitDivider(
            coordinateSpace: "PaneSplit",
            onDrag: { value in
                let available = width.value - PaneSplitLayout.dividerWidth
                guard available > 0 else { return }
                fraction = PaneSplitLayout.clamped(value.location.x / available,
                                                   available: available, minPaneWidth: minPaneWidth)
            },
            onReset: { fraction = 0.5 }
        )
        .accessibilityElement()
        .accessibilityLabel("Pane divider")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let available = width.value - PaneSplitLayout.dividerWidth
            let step: CGFloat = direction == .increment ? 0.05 : -0.05
            fraction = PaneSplitLayout.clamped(fraction + step, available: available, minPaneWidth: minPaneWidth)
        }
        .help("Drag to resize the panes. Double-click to make them equal.")
    }
}

/// A hairline between side-by-side views with a wider grab area, the left-right
/// resize cursor and a double-click reset, like a split view's divider.
struct VerticalSplitDivider: View {
    let coordinateSpace: String
    let onDrag: (DragGesture.Value) -> Void
    var onEnded: () -> Void = {}
    let onReset: () -> Void

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: PaneSplitLayout.dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .background(PaneSplitCursor())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpace))
                            .onChanged(onDrag)
                            .onEnded { _ in onEnded() }
                    )
                    .onTapGesture(count: 2, perform: onReset)
            }
    }
}

/// The container's last laid-out width, for turning a drag into a fraction. A
/// reference, so recording it during layout never invalidates the view.
final class PaneSplitWidth {
    var value: CGFloat = 0
}

/// Left pane, divider, right pane: the panes share the width less the divider,
/// split at `fraction` and kept at least `minPaneWidth` wide while there is room.
struct PaneSplitLayout: Layout {
    static let dividerWidth: CGFloat = 1
    var fraction: CGFloat
    var minPaneWidth: CGFloat
    var width: PaneSplitWidth

    static func clamped(_ fraction: CGFloat, available: CGFloat, minPaneWidth: CGFloat) -> CGFloat {
        guard available > 0 else { return 0.5 }
        let lower = min(0.5, minPaneWidth / available)
        return min(max(fraction, lower), 1 - lower)
    }

    static func leftWidth(available: CGFloat, fraction: CGFloat, minPaneWidth: CGFloat) -> CGFloat {
        (available * clamped(fraction, available: available, minPaneWidth: minPaneWidth)).rounded()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Fills what it is offered, but never less than two minimum panes.
        let minimum = 2 * minPaneWidth + Self.dividerWidth
        return CGSize(width: max(proposal.width ?? minimum, minimum), height: proposal.height ?? 300)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        width.value = bounds.width
        let available = max(0, bounds.width - Self.dividerWidth)
        let left = Self.leftWidth(available: available, fraction: fraction, minPaneWidth: minPaneWidth)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: left, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + left, y: bounds.minY),
                          proposal: ProposedViewSize(width: Self.dividerWidth, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.minX + left + Self.dividerWidth, y: bounds.minY),
                          proposal: ProposedViewSize(width: available - left, height: bounds.height))
    }
}

/// The left-right resize cursor over the divider's grab area.
private struct PaneSplitCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> PaneSplitCursorView { PaneSplitCursorView() }
    func updateNSView(_ view: PaneSplitCursorView, context: Context) {
        view.window?.invalidateCursorRects(for: view)
    }
}

final class PaneSplitCursorView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
    // SwiftUI keeps the drag and double-click gestures.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension ClosedRange {
    func clamp(_ value: Bound) -> Bound { Swift.min(Swift.max(value, lowerBound), upperBound) }
}
