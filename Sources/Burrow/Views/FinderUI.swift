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
    static let captionFont: Font = .caption
    static let titleFont: Font = .headline
}

/// The status bar must describe the same projection that commands can act on.
struct FinderSelectionSummary: Equatable {
    let totalCount: Int
    let selectedCount: Int
    let isSearching: Bool
    let isAnalysis: Bool

    @MainActor init(pane: PaneTabState) {
        totalCount = pane.selectableItems.count
        selectedCount = pane.selectedItems.count
        isSearching = pane.isSearching
        isAnalysis = pane.viewMode == .wiztree && pane.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var countDescription: String {
        if isSearching { return "Wyszukiwanie…" }
        if selectedCount > 0 { return "Zaznaczono \(selectedCount.formatted()) z \(totalCount.formatted())" }
        if isAnalysis { return "Elementy analizy: \(totalCount.formatted())" }
        return "Elementy: \(totalCount.formatted())"
    }
}
