// Renders Assets/AppIcon.svg into Assets/AppIcon.icns via an iconset.
// Usage: DEVELOPER_DIR=... swift script/make_appicon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let svgURL = root.appendingPathComponent("Assets/AppIcon.svg")
let icnsURL = root.appendingPathComponent("Assets/AppIcon.icns")
let iconsetURL = FileManager.default.temporaryDirectory.appendingPathComponent("MemeMemo-AppIcon.iconset")

guard let source = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write(Data("cannot read \(svgURL.path)\n".utf8))
    exit(1)
}

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func writePNG(points: Int, scale: Int) throws {
    let pixels = points * scale
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { exit(1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    let suffix = scale == 1 ? "" : "@2x"
    try png.write(to: iconsetURL.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}

for points in [16, 32, 128, 256, 512] {
    try writePNG(points: points, scale: 1)
    try writePNG(points: points, scale: 2)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: iconsetURL)
print("wrote \(icnsURL.path)")
