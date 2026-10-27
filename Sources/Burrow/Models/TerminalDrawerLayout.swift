import Foundation

/// Pure sizing policy. The requested height is retained while the window is small,
/// so growing the window or showing the drawer again restores the user's choice.
enum TerminalDrawerLayout {
    static let defaultHeight: CGFloat = 220
    static let minimumHeight: CGFloat = 180
    static let minimumFileHeight: CGFloat = 180
    static let dividerHeight: CGFloat = 10
    static let keyboardStep: CGFloat = 40

    static func bounds(availableHeight: CGFloat) -> ClosedRange<CGFloat> {
        let available = availableHeight.isFinite ? max(0, availableHeight - dividerHeight) : 0
        // The normal minimum window comfortably accommodates both minima. For an
        // unexpectedly smaller host, share space rather than creating overflow.
        let maximum = max(0, available - min(minimumFileHeight, available / 2))
        return min(minimumHeight, maximum)...maximum
    }

    static func height(requested: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let range = bounds(availableHeight: availableHeight)
        let value = requested.isFinite ? requested : defaultHeight
        return min(range.upperBound, max(range.lowerBound, value))
    }

    static func draggedHeight(start: CGFloat, translation: CGFloat, availableHeight: CGFloat) -> CGFloat {
        height(requested: start - (translation.isFinite ? translation : 0), availableHeight: availableHeight)
    }
}
