// Renders Resources/AppIcon.icns: a white columns building on a green rounded square,
// sized and inset like other Mac app icons. Run: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Mac icons leave a margin around the tile (824 of 1024) for the shadow.
    let inset = s * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.28)
    drop.shadowBlurRadius = s * 0.018
    drop.shadowOffset = NSSize(width: 0, height: -s * 0.008)
    drop.set()
    NSColor(srgbRed: 0.16, green: 0.45, blue: 0.29, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Lighter at the top, like light falling on it.
    NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.60, blue: 0.39, alpha: 1),
               ending: NSColor(srgbRed: 0.12, green: 0.38, blue: 0.24, alpha: 1))?
        .draw(in: shape, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.40, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "building.columns.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        NSGraphicsContext.saveGraphicsState()
        let lift = NSShadow()
        lift.shadowColor = NSColor.black.withAlphaComponent(0.22)
        lift.shadowBlurRadius = s * 0.012
        lift.shadowOffset = NSSize(width: 0, height: -s * 0.006)
        lift.set()
        symbol.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2 + s * 0.01,
                               width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = URL(fileURLWithPath: "build/AppIcon.iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
