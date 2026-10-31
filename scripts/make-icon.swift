import AppKit

// Generate the native application icon at every macOS icon size from one vector symbol.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let artwork = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let bounds = NSRect(x: 52, y: 52, width: 920, height: 920)
    let shape = NSBezierPath(roundedRect: bounds, xRadius: 210, yRadius: 210)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    NSColor.systemBlue.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.70, blue: 1, alpha: 1),
               ending: NSColor(srgbRed: 0.08, green: 0.31, blue: 0.83, alpha: 1))!.draw(in: shape, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let sheen = NSBezierPath(ovalIn: NSRect(x: -150, y: 580, width: 1350, height: 500))
    NSColor.white.withAlphaComponent(0.09).setFill(); sheen.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.28).setStroke(); shape.lineWidth = 3; shape.stroke()
    let configuration = NSImage.SymbolConfiguration(pointSize: 540, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "tray.2.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        let width: CGFloat = 620
        let height = width * symbol.size.height / symbol.size.width
        NSGraphicsContext.saveGraphicsState()
        let symbolShadow = NSShadow(); symbolShadow.shadowColor = .black.withAlphaComponent(0.16)
        symbolShadow.shadowBlurRadius = 12; symbolShadow.shadowOffset = NSSize(width: 0, height: -8); symbolShadow.set()
        symbol.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2 - 8, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
    }
    return true
}
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let file = output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    }
}
