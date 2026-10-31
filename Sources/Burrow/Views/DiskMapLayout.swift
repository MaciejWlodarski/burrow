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
    static let headerHeightPoints = 14.0
    private static let minimumHeaderWidthPoints = 44.0
    private static let minimumHeaderHeightPoints = 56.0
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

            let kids = tree.children(of: parent)
            var index = 0
            while index < kids.count {
                let id = kids[index]
                let area = Double(tree.allocatedSize(id)) * pixelsPerByte
                // Sorted largest-first: everything from here on is too small.
                if area < minimumArea {
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
            append(id, x0, y0, x1, y1, isFolder: directory, isRemainder: false, hasHeader: showsHeader)
            guard isGroup else { return }
            let inset = (x1 - x0 > 6 && y1 - y0 > 6) ? 1.0 : 0
            let header = showsHeader ? (headerHeightPoints * scale).rounded() : 0
            placeChildren(of: id, x: x0 + inset, y: y0 + inset + header,
                          width: x1 - x0 - 2 * inset, height: y1 - y0 - 2 * inset - header)
        }

        private mutating func append(_ id: DiskTree.NodeID, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double,
                                     isFolder: Bool, isRemainder: Bool, hasHeader: Bool) {
            let left = Int32(x0.rounded()), top = Int32(y0.rounded())
            let right = Int32(x1.rounded()), bottom = Int32(y1.rounded())
            guard right > left, bottom > top else { return }
            tiles.append(DiskMapTile(node: id, x0: left, y0: top, x1: right, y1: bottom,
                                     isFolder: isFolder, isRemainder: isRemainder, hasHeader: hasHeader))
        }
    }
}

/// Rasterizes a layout directly into a pixel buffer: per-tile cushion shading
/// costs one table lookup per pixel, which keeps full-disk maps interactive.
public enum DiskMapRenderer {
    private struct RGB {
        let red: Double, green: Double, blue: Double
        init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    private static let background = RGB(0.10, 0.11, 0.13)
    private static let folderBody = RGB(0.17, 0.19, 0.23)
    private static let folderHeader = RGB(0.24, 0.28, 0.35)
    private static let remainder = RGB(0.36, 0.38, 0.42)
    private static let synthetic = RGB(0.30, 0.30, 0.31)

    private static func color(_ category: FileKindCategory) -> RGB {
        switch category {
        case .folder: return RGB(0.26, 0.46, 0.86)
        case .code: return RGB(0.42, 0.40, 0.90)
        case .document: return RGB(0.16, 0.66, 0.70)
        case .image: return RGB(0.94, 0.33, 0.52)
        case .audio: return RGB(0.26, 0.78, 0.66)
        case .video: return RGB(0.96, 0.58, 0.18)
        case .archive: return RGB(0.90, 0.76, 0.20)
        case .executable: return RGB(0.90, 0.30, 0.26)
        case .other: return RGB(0.28, 0.66, 0.92)
        }
    }

    public static func image(layout: DiskMapLayout, tree: DiskTree, scale: Double,
                             isCancelled: () -> Bool = { false }) -> CGImage? {
        let width = layout.width, height = layout.height
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space, bitmapInfo: info),
              let data = context.data else { return nil }
        let stride = context.bytesPerRow / 4
        let pixels = data.bindMemory(to: UInt32.self, capacity: stride * height)
        fill(pixels, stride: stride, 0, 0, Int32(width), Int32(height), background, shade: nil)

        var shadeX = [Double](), shadeY = [Double]()
        for (index, tile) in layout.tiles.enumerated() {
            if index & 0xFFF == 0, isCancelled() { return nil }
            let w = Int(tile.x1 - tile.x0), h = Int(tile.y1 - tile.y0)
            if tile.isFolder && tree.childCount(tile.node) > 0 {
                fill(pixels, stride: stride, tile.x0, tile.y0, tile.x1, tile.y1, folderBody, shade: nil)
                if tile.hasHeader {
                    let header = Int32((DiskMapLayoutEngine.headerHeightPoints * scale).rounded())
                    fill(pixels, stride: stride, tile.x0, tile.y0, tile.x1, tile.y0 + header + 1, folderHeader, shade: nil)
                }
                continue
            }
            let base: RGB
            if tile.isRemainder { base = remainder }
            else if tree.isSynthetic(tile.node) { base = synthetic }
            else { base = color(tree.category(tile.node)) }
            cushion(&shadeX, count: w)
            cushion(&shadeY, count: h)
            fill(pixels, stride: stride, tile.x0, tile.y0, tile.x1, tile.y1, base, shade: (shadeX, shadeY))
        }

        drawLabels(context, layout: layout, tree: tree, scale: scale)
        return context.makeImage()
    }

    /// Parabolic height profile of a tile edge; bright centre, dark rim.
    private static func cushion(_ table: inout [Double], count: Int) {
        table.removeAll(keepingCapacity: true)
        table.reserveCapacity(count)
        guard count > 1 else { table.append(1); return }
        for index in 0..<count {
            let position = (Double(index) + 0.5) / Double(count) * 2 - 1
            table.append(1 - position * position)
        }
    }

    private static func packed(_ red: Double, _ green: Double, _ blue: Double) -> UInt32 {
        let r = UInt32(min(255, max(0, red * 255))), g = UInt32(min(255, max(0, green * 255)))
        let b = UInt32(min(255, max(0, blue * 255)))
        return 0xFF00_0000 | (r << 16) | (g << 8) | b
    }

    private static func fill(_ pixels: UnsafeMutablePointer<UInt32>, stride: Int, _ x0: Int32, _ y0: Int32,
                             _ x1: Int32, _ y1: Int32, _ color: RGB, shade: (x: [Double], y: [Double])?) {
        let left = Int(x0), right = Int(x1), top = Int(y0), bottom = Int(y1)
        guard let shade else {
            let value = packed(color.red, color.green, color.blue)
            for y in top..<bottom {
                let row = pixels + y * stride
                for x in left..<right { row[x] = value }
            }
            return
        }
        for y in top..<bottom {
            let row = pixels + y * stride
            let vertical = shade.y[y - top]
            for x in left..<right {
                let light = 0.62 + 0.55 * vertical * shade.x[x - left]
                row[x] = packed(color.red * light, color.green * light, color.blue * light)
            }
        }
    }

    private static func drawLabels(_ context: CGContext, layout: DiskMapLayout, tree: DiskTree, scale: Double) {
        let height = CGFloat(layout.height)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let folderFont = NSFont.systemFont(ofSize: CGFloat(10 * scale), weight: .semibold)
        let fileFont = NSFont.systemFont(ofSize: CGFloat(10 * scale), weight: .medium)
        let header = (DiskMapLayoutEngine.headerHeightPoints * scale).rounded()
        var drawn = 0
        for tile in layout.tiles where drawn < 800 && !tile.isRemainder {
            let width = Double(tile.x1 - tile.x0), tileHeight = Double(tile.y1 - tile.y0)
            let isGroup = tile.isFolder && tree.childCount(tile.node) > 0
            if isGroup ? !tile.hasHeader : width / scale < 56 || tileHeight / scale < 18 { continue }
            let text = "\(tree.name(tile.node))  \(FormatHelpers.formatBytes(tree.allocatedSize(tile.node)))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: isGroup ? folderFont : fileFont,
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph
            ]
            let inset = 3 * scale
            NSAttributedString(string: text, attributes: attributes).draw(in: CGRect(
                x: Double(tile.x0) + inset, y: Double(tile.y0) + scale,
                width: width - inset * 2, height: header))
            drawn += 1
        }
    }
}
