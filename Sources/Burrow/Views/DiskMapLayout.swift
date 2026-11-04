import SwiftUI
import AppKit
import CoreGraphics

/// One rectangle of the map in bitmap pixels. Folders precede their contents,
/// so the last tile containing a point is the deepest one.
public struct DiskMapTile: Sendable, Equatable {
    public let node: DiskTree.NodeID
    public let x0: Int32, y0: Int32, x1: Int32, y1: Int32
    public let isFolder: Bool
    /// Stands for the children too small to draw individually.
    public let isRemainder: Bool
    public let hasHeader: Bool
    /// 0 for the map's direct children, so their labels can line up with
    /// the labels inside neighbouring folders.
    public let depth: UInt16
    /// A folder too small for a header, drawn as one labelled tile instead of
    /// a cluster of bare rectangles.
    public var isCollapsed: Bool = false

    func contains(x: Int32, y: Int32) -> Bool { x >= x0 && x < x1 && y >= y0 && y < y1 }
}

public struct DiskMapLayout: Sendable {
    public let width: Int
    public let height: Int
    public let tiles: [DiskMapTile]

    public func tile(atX x: Int32, y: Int32) -> DiskMapTile? {
        tiles.last { $0.contains(x: x, y: y) }
    }

    /// Topmost tile for a node, or its nearest drawn ancestor.
    public func tile(for node: DiskTree.NodeID, in tree: DiskTree) -> DiskMapTile? {
        var current: DiskTree.NodeID? = node
        while let id = current {
            if let match = tiles.first(where: { $0.node == id && !$0.isRemainder }) { return match }
            current = tree.parent(id)
        }
        return nil
    }
}

/// Squarified treemap (Bruls, Huizing, van Wijk) of every level of a subtree.
/// Recursion stops at sub-pixel sizes, so tile count follows the bitmap's area
/// rather than the number of files on disk.
public enum DiskMapLayoutEngine {
    static let headerHeightPoints = 22.0
    /// A header strip narrower than its label would be an empty grey band.
    private static let minimumHeaderWidthPoints = 72.0
    private static let minimumHeaderHeightPoints = 52.0
    /// A folder filling its parent repeats the same rectangle; stacked headers
    /// of `Users/me/dev/...` chains would only eat the map.
    private static let maximumHeaderedParentShare = 0.75

    public static func layout(tree: DiskTree, scope: DiskTree.NodeID, width: Int, height: Int,
                              scale: Double, isCancelled: @escaping () -> Bool = { false }) -> DiskMapLayout? {
        guard width > 0, height > 0 else { return nil }
        var builder = Builder(tree: tree, scale: scale,
            minimumArea: max(5, Double(width) * Double(height) / 300_000), isCancelled: isCancelled)
        builder.placeChildren(of: scope, x: 0, y: 0, width: Double(width), height: Double(height))
        return builder.wasCancelled ? nil : DiskMapLayout(width: width, height: height, tiles: builder.tiles)
    }

    private struct Builder {
        let tree: DiskTree
        let scale: Double
        var tiles: [DiskMapTile] = []
        let minimumArea: Double
        let isCancelled: () -> Bool
        var wasCancelled = false
        var depth: UInt16 = 0

        mutating func placeChildren(of parent: DiskTree.NodeID, x startX: Double, y startY: Double,
                                    width startWidth: Double, height startHeight: Double) {
            let total = tree.allocatedSize(parent)
            guard total > 0, startWidth >= 1, startHeight >= 1 else { return }
            if tiles.count & 0x3FFF == 0, isCancelled() { wasCancelled = true }
            if wasCancelled { return }
            let parentArea = startWidth * startHeight
            let pixelsPerByte = parentArea / Double(total)
            var x = startX, y = startY, width = startWidth, height = startHeight
            var row: [(id: DiskTree.NodeID, area: Double)] = []
            var remainderStart: DiskTree.NodeID?
            var rowArea = 0.0, largest = 0.0, smallest = 0.0, worst = Double.infinity

            func worstRatio(sum: Double, largest: Double, smallest: Double, side: Double) -> Double {
                let sum2 = sum * sum, side2 = side * side
                return max(side2 * largest / sum2, sum2 / (side2 * smallest))
            }

            // Items under 1% of their folder (and too small to label) merge
            // into one "smaller items" tile instead of a confetti of slivers.
            let mergeArea = max(minimumArea, 44 * 30 * scale * scale, min(parentArea * 0.01, 48 * 48 * scale * scale))
            let kids = tree.children(of: parent)
            var index = 0
            while index < kids.count {
                let id = kids[index]
                let area = Double(tree.allocatedSize(id)) * pixelsPerByte
                // Sorted largest-first: everything from here on is too small.
                if area < minimumArea || (index > 0 && area < mergeArea) {
                    if area > 0 { remainderStart = id }
                    break
                }
                let side = min(width, height)
                let candidate = worstRatio(sum: rowArea + area, largest: max(largest, area),
                                           smallest: row.isEmpty ? area : min(smallest, area), side: side)
                if row.isEmpty || candidate <= worst {
                    row.append((id, area))
                    rowArea += area
                    largest = max(largest, area)
                    smallest = row.count == 1 ? area : min(smallest, area)
                    worst = candidate
                    index += 1
                } else {
                    emit(row, rowArea: rowArea, parentArea: parentArea, x: &x, y: &y, width: &width, height: &height)
                    row.removeAll(keepingCapacity: true)
                    rowArea = 0
                    largest = 0
                    smallest = 0
                    worst = .infinity
                }
            }
            if !row.isEmpty { emit(row, rowArea: rowArea, parentArea: parentArea, x: &x, y: &y, width: &width, height: &height) }
            if let remainderStart, width >= 1, height >= 1 {
                append(remainderStart, x, y, x + width, y + height, isFolder: false, isRemainder: true, hasHeader: false)
            }
        }

        private mutating func emit(_ row: [(id: DiskTree.NodeID, area: Double)], rowArea: Double, parentArea: Double,
                                   x: inout Double, y: inout Double, width: inout Double, height: inout Double) {
            let vertical = width >= height
            let thickness = vertical ? min(width, rowArea / height) : min(height, rowArea / width)
            var cursor = vertical ? y : x
            for item in row {
                let length = thickness > 0 ? item.area / thickness : 0
                if vertical {
                    place(item.id, x, cursor, x + thickness, cursor + length, parentArea: parentArea)
                } else {
                    place(item.id, cursor, y, cursor + length, y + thickness, parentArea: parentArea)
                }
                cursor += length
            }
            if vertical {
                x += thickness
                width = max(0, width - thickness)
            } else {
                y += thickness
                height = max(0, height - thickness)
            }
        }

        private mutating func place(_ id: DiskTree.NodeID, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                                    parentArea: Double) {
            let directory = tree.isDirectory(id)
            let isGroup = directory && tree.childCount(id) > 0
            let showsHeader = isGroup && (x1 - x0) / scale >= minimumHeaderWidthPoints
                && (y1 - y0) / scale >= minimumHeaderHeightPoints
                && (x1 - x0) * (y1 - y0) <= parentArea * maximumHeaderedParentShare
            // Headerless only because it is small (not because it fills its parent):
            // one tile with the folder's name says more than its unnamed contents.
            let collapses = isGroup && !showsHeader
                && (x1 - x0) * (y1 - y0) <= parentArea * maximumHeaderedParentShare
            append(id, x0, y0, x1, y1, isFolder: directory, isRemainder: false, hasHeader: showsHeader, isCollapsed: collapses)
            guard isGroup, !collapses else { return }
            // A wider inset than the gap between files, so folders read as groups.
            let inset = (x1 - x0 > 12 && y1 - y0 > 12) ? (2 * scale).rounded() : 0
            let header = showsHeader ? (headerHeightPoints * scale).rounded() : 0
            depth += 1
            placeChildren(of: id, x: x0 + inset, y: y0 + inset + header,
                          width: x1 - x0 - 2 * inset, height: y1 - y0 - 2 * inset - header)
            depth -= 1
        }

        private mutating func append(_ id: DiskTree.NodeID, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                                     isFolder: Bool, isRemainder: Bool, hasHeader: Bool, isCollapsed: Bool = false) {
            let left = Int32(x0.rounded()), top = Int32(y0.rounded())
            let right = Int32(x1.rounded()), bottom = Int32(y1.rounded())
            guard right > left, bottom > top else { return }
            tiles.append(DiskMapTile(node: id, x0: left, y0: top, x1: right, y1: bottom,
                                     isFolder: isFolder, isRemainder: isRemainder, hasHeader: hasHeader, depth: depth,
                                     isCollapsed: isCollapsed))
        }
    }
}

/// Rasterizes a layout directly into a pixel buffer. Tiles are flat colour
/// with a one-pixel gutter, so neighbouring files stay distinct without the
/// glare of cushion shading, and labels never cut off a size.
public enum DiskMapRenderer {
    struct RGB {
        let red: Double, green: Double, blue: Double
        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
        /// WCAG relative luminance, to pick the more legible label colour.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        /// Whichever of near-black or white has the higher WCAG contrast on this fill.
        func prefersDarkText(dark: Bool) -> Bool {
            let onWhite = 1.05 / (luminance + 0.05)
            let onDark = (luminance + 0.05) / (0.007 + 0.05)
            return onDark > onWhite
        }
        var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
        /// Dark backgrounds make saturated fills glare: pull them toward grey and down a little.
        /// Light backgrounds: lift fills toward white so a big tile does not shout.
        var forLightAppearance: RGB {
            func lift(_ c: Double) -> Double { c * 0.8 + 0.2 }
            return RGB(lift(red), lift(green), lift(blue))
        }
        func adapted(dark: Bool) -> RGB { dark ? forDarkAppearance : forLightAppearance }
        var forDarkAppearance: RGB {
            let gray = 0.299 * red + 0.587 * green + 0.114 * blue
            func soften(_ c: Double) -> Double { (c * 0.86 + gray * 0.14) * 0.88 }
            return RGB(soften(red), soften(green), soften(blue))
        }
    }

    private struct Palette {
        let gutter: RGB, folderBody: RGB, folderHeader: RGB, folderText: NSColor
        let remainder: RGB, synthetic: RGB

        static let light = Palette(gutter: RGB(0.97, 0.97, 0.98), folderBody: RGB(0.97, 0.97, 0.98),
                                   folderHeader: RGB(0.88, 0.89, 0.91), folderText: NSColor(white: 0.18, alpha: 1),
                                   remainder: RGB(0.74, 0.76, 0.79), synthetic: RGB(0.80, 0.80, 0.82))
        static let dark = Palette(gutter: RGB(0.11, 0.11, 0.12), folderBody: RGB(0.11, 0.11, 0.12),
                                  folderHeader: RGB(0.22, 0.23, 0.25), folderText: NSColor(white: 0.92, alpha: 1),
                                  remainder: RGB(0.34, 0.35, 0.38), synthetic: RGB(0.28, 0.28, 0.30))
    }

    /// The same hues as `FileKindCategory.treemapColor`, so the legend,
    /// the tree bars and the map agree.
    static func color(_ category: FileKindCategory) -> RGB {
        switch category {
        case .folder: return RGB(0.47, 0.53, 0.62)
        case .code: return RGB(0.55, 0.47, 0.85)
        case .document: return RGB(0.22, 0.60, 0.66)
        case .image: return RGB(0.86, 0.38, 0.50)
        case .audio: return RGB(0.36, 0.68, 0.45)
        case .video: return RGB(0.92, 0.56, 0.27)
        case .archive: return RGB(0.85, 0.69, 0.27)
        case .executable: return RGB(0.82, 0.34, 0.31)
        case .other: return RGB(0.56, 0.60, 0.66)
        }
    }

    public static func image(layout: DiskMapLayout, tree: DiskTree, scale: Double, dark: Bool = true,
                             isCancelled: () -> Bool = { false }) -> CGImage? {
        let palette = dark ? Palette.dark : Palette.light
        let width = layout.width, height = layout.height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space, bitmapInfo: info),
              let data = context.data else { return nil }
        let stride = context.bytesPerRow / 4
        let pixels = data.bindMemory(to: UInt32.self, capacity: stride * height)
        fill(pixels, stride: stride, 0, 0, Int32(width), Int32(height), palette.gutter)

        // About 1.5 pt, so neighbouring blocks of one colour stay apart.
        let gap = Int32(max(1, (scale * 1.5).rounded()))
        for (index, tile) in layout.tiles.enumerated() {
            if index & 0xFFF == 0, isCancelled() { return nil }
            // Leave a gutter on the right and bottom edges of every tile.
            let x1 = tile.x1 - tile.x0 > gap * 2 ? tile.x1 - gap : tile.x1
            let y1 = tile.y1 - tile.y0 > gap * 2 ? tile.y1 - gap : tile.y1
            if tile.isFolder && tree.childCount(tile.node) > 0 && !tile.isCollapsed {
                fill(pixels, stride: stride, tile.x0, tile.y0, x1, y1, palette.folderBody)
                if tile.hasHeader {
                    let header = Int32((DiskMapLayoutEngine.headerHeightPoints * scale).rounded())
                    fill(pixels, stride: stride, tile.x0, tile.y0, x1, min(y1, tile.y0 + header + 1), palette.folderHeader)
                }
                continue
            }
            let base: RGB
            if tile.isCollapsed { base = palette.folderHeader }
            else if tile.isRemainder { base = palette.remainder }
            else if tree.isSynthetic(tile.node) { base = palette.synthetic }
            else { base = color(tree.category(tile.node)).adapted(dark: dark) }
            fill(pixels, stride: stride, tile.x0, tile.y0, x1, y1, base)
        }

        drawLabels(context, layout: layout, tree: tree, scale: scale, palette: palette, dark: dark)
        return context.makeImage()
    }

    private static func packed(_ color: RGB) -> UInt32 {
        let r = UInt32(min(255, max(0, color.red * 255))), g = UInt32(min(255, max(0, color.green * 255)))
        let b = UInt32(min(255, max(0, color.blue * 255)))
        return 0xFF00_0000 | (r << 16) | (g << 8) | b
    }

    private static func fill(_ pixels: UnsafeMutablePointer<UInt32>, stride: Int, _ x0: Int32, _ y0: Int32,
                             _ x1: Int32, _ y1: Int32, _ color: RGB) {
        let left = Int(x0), right = Int(x1), top = Int(y0), bottom = Int(y1)
        guard right > left, bottom > top else { return }
        let value = packed(color)
        for y in top..<bottom {
            let row = pixels + y * stride
            for x in left..<right { row[x] = value }
        }
    }

    private static func drawLabels(_ context: CGContext, layout: DiskMapLayout, tree: DiskTree, scale: Double,
                                   palette: Palette, dark: Bool) {
        let height = CGFloat(layout.height)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        // File names keep both ends ("iMac-B…Shoot") so similar names stay distinct.
        let middleTruncating = NSMutableParagraphStyle()
        middleTruncating.lineBreakMode = .byTruncatingMiddle
        let wrapping = NSMutableParagraphStyle()
        wrapping.lineBreakMode = .byWordWrapping
        let nameFont = NSFont.systemFont(ofSize: CGFloat(12 * scale), weight: .medium)
        let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(12 * scale), weight: .regular)
        let header = (DiskMapLayoutEngine.headerHeightPoints * scale).rounded()
        let lineHeight = 15 * scale
        // Below this a label is noise; hovering still identifies the tile.
        let minimumLabelWidth = 60 * scale, minimumLabelHeight = 40 * scale, minimumNameWidth = 50 * scale
        // File tiles beside headed folders start their label below the header line.
        let alignsWithHeaders = layout.tiles.contains { $0.depth == 0 && $0.hasHeader }
        var drawn = 0
        for tile in layout.tiles where drawn < 800 {
            let width = Double(tile.x1 - tile.x0) - scale, tileHeight = Double(tile.y1 - tile.y0) - scale
            // Roomier insets where the tile allows them; small tiles keep every point for text.
            let inset = (width >= 100 * scale && tileHeight >= 56 * scale ? 8 : 6) * scale
            let isGroup = tile.isFolder && tree.childCount(tile.node) > 0 && !tile.isRemainder && !tile.isCollapsed
            if isGroup && !tile.hasHeader { continue }
            if !isGroup && (width < minimumLabelWidth || tileHeight < minimumLabelHeight) { continue }
            let textColor: NSColor
            if isGroup || tile.isCollapsed {
                textColor = palette.folderText
            } else {
                var base = tile.isRemainder ? palette.remainder
                    : tree.isSynthetic(tile.node) ? palette.synthetic : color(tree.category(tile.node))
                if !tile.isRemainder && !tree.isSynthetic(tile.node) { base = base.adapted(dark: dark) }
                textColor = base.prefersDarkText(dark: dark) ? NSColor(white: 0.08, alpha: 0.92) : NSColor.white
            }
            let bytes: Int64
            let shownName: String
            if tile.isRemainder, let parent = tree.parent(tile.node) {
                let rest = tree.children(of: parent).drop { $0 != tile.node }
                bytes = rest.reduce(0) { $0 + tree.allocatedSize($1) }
                shownName = rest.count == 1 ? tree.name(tile.node)
                    : String(localized: "\(rest.count.formatted()) smaller items")
            } else {
                bytes = tree.allocatedSize(tile.node)
                // Inside a coloured tile the colour already says the type.
                let rawName = tree.name(tile.node)
                let stem = (rawName as NSString).deletingPathExtension
                shownName = isGroup || tile.isFolder || stem.isEmpty ? rawName : stem
            }
            let size = NSAttributedString(string: FormatHelpers.formatBytes(bytes), attributes: [
                .font: sizeFont, .foregroundColor: textColor.withAlphaComponent(isGroup ? 0.7 : 0.85)])
            let name = NSAttributedString(string: shownName, attributes: [
                .font: nameFont, .foregroundColor: textColor, .paragraphStyle: truncating])
            let available = width - inset * 2
            let sizeWidth = size.size().width
            // A name cut to a few letters ("Brand…") says nothing; leave it to hover.
            let nameFits = name.size().width <= available
            let truncatedNameWidth = 72 * scale
            let x = Double(tile.x0) + inset
            if isGroup {
                let top = Double(tile.y0) + (header - lineHeight) / 2
                let nameWidth = available - sizeWidth - 6 * scale
                guard nameFits || available >= truncatedNameWidth else { continue }
                if nameWidth >= minimumNameWidth && (name.size().width <= nameWidth || nameWidth >= truncatedNameWidth) {
                    name.draw(in: CGRect(x: x, y: top, width: nameWidth, height: lineHeight))
                    size.draw(at: CGPoint(x: x + available - sizeWidth, y: top))
                } else {
                    name.draw(in: CGRect(x: x, y: top, width: available, height: lineHeight))
                }
            } else {
                // The name always leads; the size follows when it fits whole.
                let offset = alignsWithHeaders && tile.depth == 0 && tileHeight >= header + lineHeight * 3 ? header + scale : 0
                let top = Double(tile.y0) + offset + inset - 2 * scale
                let room = tileHeight - offset - 2 * (inset - 2 * scale)
                // Tall tiles may give a long name a second line, broken between words only;
                // otherwise one line, shortened in the middle.
                let wrapped = NSAttributedString(string: shownName, attributes: [
                    .font: nameFont, .foregroundColor: textColor, .paragraphStyle: wrapping])
                let wordsFit = shownName.split(separator: " ").allSatisfy {
                    NSAttributedString(string: String($0), attributes: [.font: nameFont]).size().width <= available
                }
                let twoLines = !nameFits && wordsFit && room >= lineHeight * 3
                    && wrapped.boundingRect(with: CGSize(width: available, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin]).height <= lineHeight * 2 + scale
                guard available >= minimumNameWidth, nameFits || twoLines || available >= truncatedNameWidth else { continue }
                let nameLines: Double = twoLines ? 2 : 1
                if twoLines {
                    wrapped.draw(with: CGRect(x: x, y: top, width: available, height: lineHeight * 2 + scale),
                                 options: [.usesLineFragmentOrigin])
                } else {
                    NSAttributedString(string: shownName, attributes: [
                        .font: nameFont, .foregroundColor: textColor, .paragraphStyle: middleTruncating])
                        .draw(in: CGRect(x: x, y: top, width: available, height: lineHeight))
                }
                if sizeWidth <= available, room >= lineHeight * (nameLines + 1) {
                    size.draw(at: CGPoint(x: x, y: top + lineHeight * nameLines))
                }
            }
            drawn += 1
        }
    }
}
