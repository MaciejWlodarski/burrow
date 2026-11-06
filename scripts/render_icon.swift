import AppKit

// render_icon <icon.svg> <output dir>: writes the PNGs of a macOS .iconset, each size
// rendered from the vector source rather than scaled down from one large bitmap.
// The set starts at 128 pt on purpose: macOS 26 puts an icon whose own 16 or 32 pt
// images it cannot match to the app-icon shape on a grey plate in lists and the
// sidebar, while it scales the larger images down for those sizes without one.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: render_icon <icon.svg> <iconset dir>\n".utf8))
    exit(2)
}
let source = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
guard let image = NSImage(contentsOf: source), image.isValid else {
    FileHandle.standardError.write(Data("render_icon: cannot load \(source.path)\n".utf8))
    exit(1)
}

func render(pixels: Int, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { throw CocoaError(.fileWriteUnknown) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

do {
    for points in [128, 256, 512] {
        try render(pixels: points, to: output.appendingPathComponent("icon_\(points)x\(points).png"))
        try render(pixels: points * 2, to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
} catch {
    FileHandle.standardError.write(Data("render_icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
