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
    /// The active pane's path bar in dual pane: equally visible in both appearances.
    static let activePaneTint = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.13 : 0.10)
    })
    /// Search matches: a wash strong enough to find in both appearances.
    static let matchHighlight = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.22 : 0.16)
    })
}

/// The status bar must describe the same projection that commands can act on.
struct FinderSelectionSummary: Equatable {
    let totalCount: Int
    let selectedCount: Int
    let isSearching: Bool
    let isAnalysis: Bool
    let hasQuery: Bool

    @MainActor init(pane: PaneTabState) {
        totalCount = pane.selectableItems.count
        selectedCount = pane.selectedItems.count
        isSearching = pane.isSearching
        hasQuery = !pane.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        isAnalysis = pane.viewMode == .wiztree && pane.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var countDescription: String {
        if isSearching { return String(localized: "Searching…") }
        if selectedCount > 0 { return String(localized: "\(selectedCount.formatted()) of \(totalCount.formatted()) selected") }
        // Search results and the disk map state their totals in their own headers;
        // the footer only adds the selection, never a second count.
        if hasQuery || isAnalysis { return "" }
        return totalCount == 1 ? String(localized: "1 item") : String(localized: "\(totalCount.formatted()) items")
    }

    /// Items whose size is not already in another selected item: search
    /// results and expanded folders can list a folder and files inside it.
    static func countedItems(_ items: [FileItem]) -> [FileItem] {
        let folders = Set(items.lazy.filter(\.isDirectory).map(\.path))
        guard !folders.isEmpty else { return items }
        return items.filter { item in
            var path = item.parentPath
            while path.count > 1 {
                if folders.contains(path) { return false }
                path = (path as NSString).deletingLastPathComponent
            }
            return !(folders.contains("/") && item.path != "/")
        }
    }

    /// Bytes of a selection counted once, as folder sizes and the disk map do:
    /// items inside a selected folder are part of its size, and hard links to
    /// one file count once. Folders without a known size add nothing.
    static func knownBytes(of items: [FileItem], folderSize: (String) -> Int64?) -> Int64 {
        var links = Set<String>()
        var total: Int64 = 0
        for item in countedItems(items) {
            if item.isDirectory {
                total += folderSize(item.path) ?? 0
            } else if item.hardLinkID == 0 || links.insert("\(item.hardLinkDevice):\(item.hardLinkID)").inserted {
                total += max(0, item.size)
            }
        }
        return total
    }
}

/// Marks the matched part of a search result name.
struct SearchMatchAttribute: TextAttribute {}

/// Draws a soft rounded wash behind matched runs, slightly outset so it never
/// clips the glyphs, then the text on top.
struct SearchMatchRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[SearchMatchAttribute.self] != nil {
                // The same 2 pt of room on both sides; the wash reaches outside the text, so
                // the glyphs themselves keep the name column's left edge.
                let bounds = run.typographicBounds.rect
                let rect = CGRect(x: bounds.minX - 2, y: bounds.minY - 1, width: bounds.width + 4, height: bounds.height + 2)
                context.fill(Path(roundedRect: rect, cornerRadius: 3.5), with: .color(FinderUI.matchHighlight))
            }
            for run in line { context.draw(run) }
        }
    }
}

/// The one look for every draggable horizontal split (tree and map, files and
/// terminal): a 10 pt strip on the window surface, a hairline along its top edge
/// and a centred grip.
struct SplitGripStrip: View {
    var isHighlighted = false
    var isFocused = false
    static let height: CGFloat = 10

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: 0) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                Spacer(minLength: 0)
            }
            Capsule()
                .fill(isFocused ? Color.accentColor : Color.secondary.opacity(isHighlighted ? 0.8 : 0.45))
                .frame(width: 34, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
    }
}
