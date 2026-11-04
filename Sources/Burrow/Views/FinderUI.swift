import SwiftUI
import AppKit

/// Shared native desktop metrics. System fonts and semantic colors follow macOS settings.
enum FinderUI {
    // Keep chrome geometry separate from document content. These surfaces are
    // deliberately opaque: behind-window vibrancy made the sidebar depend on
    // the wallpaper and turn into a pale slab beside a dark document pane.
    static let sidebarSurface = Color(nsColor: .windowBackgroundColor)
    static let contentSurface = Color(nsColor: .controlBackgroundColor)
    static let chromeInset: CGFloat = 12
    static let panelInset: CGFloat = 16
    static let sidebarInset: CGFloat = 12
    static let sidebarRowInset: CGFloat = 8
    static let sidebarRowHeight: CGFloat = 30
    static let sidebarRowGap: CGFloat = 2
    static let sidebarSectionGap: CGFloat = 14
    static let sidebarIconWidth: CGFloat = 20
    static let chromeHeight: CGFloat = 36
    static let sheetPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 16
    static let rowSpacing: CGFloat = 8
    static let compactSpacing: CGFloat = 4
    static let cornerRadius: CGFloat = 6
    static let iconButtonSize: CGFloat = 28
    static let bodyFont: Font = .body
    static let detailFont: Font = .callout
    static let captionFont: Font = .subheadline
    static let titleFont: Font = .headline
    /// Sizes, dates and kinds: quieter than names but still easy to read.
    static let metadataColor = Color.primary.opacity(0.68)
    /// Zebra rows: a faint wash that guides the eye without banding, in either appearance.
    static let stripeColor = Color.primary.opacity(0.035)
    /// Search matches: a wash strong enough to find in both appearances.
    static let matchHighlight = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.30 : 0.16)
    })
}

/// The status bar must describe the same projection that commands can act on.
struct FinderSelectionSummary: Equatable {
    let totalCount: Int
    let selectedCount: Int
    let isSearching: Bool
    let isAnalysis: Bool
    let hasQuery: Bool
    let analysisSummary: String?

    @MainActor init(pane: PaneTabState) {
        totalCount = pane.selectableItems.count
        selectedCount = pane.selectedItems.count
        isSearching = pane.isSearching
        analysisSummary = pane.analysisSummary
        hasQuery = !pane.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        isAnalysis = pane.viewMode == .wiztree && pane.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var countDescription: String {
        if isSearching { return String(localized: "Searching…") }
        if selectedCount > 0 { return String(localized: "\(selectedCount.formatted()) of \(totalCount.formatted()) selected") }
        if hasQuery { return totalCount == 1 ? String(localized: "1 result") : String(localized: "\(totalCount.formatted()) results") }
        // The disk map shows its own totals in its header.
        if isAnalysis { return analysisSummary ?? "" }
        return totalCount == 1 ? String(localized: "1 item") : String(localized: "\(totalCount.formatted()) items")
    }
}

/// Marks the matched part of a search result name.
@available(macOS 15.0, *)
struct SearchMatchAttribute: TextAttribute {}

/// Draws a soft rounded wash behind matched runs, slightly outset so it never
/// clips the glyphs, then the text on top.
@available(macOS 15.0, *)
struct SearchMatchRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[SearchMatchAttribute.self] != nil {
                let rect = run.typographicBounds.rect.insetBy(dx: -2, dy: -1)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(FinderUI.matchHighlight))
            }
            for run in line { context.draw(run) }
        }
    }
}
