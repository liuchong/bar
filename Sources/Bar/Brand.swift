import AppKit
import BarCore

enum Brand {
    static let name = "Bar"
    static let applicationIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "Bar", withExtension: "icns"), let image = NSImage(contentsOf: url) { return image }
        return NSImage(systemSymbolName: "tray.2.fill", accessibilityDescription: "Bar") ?? NSImage(size: NSSize(width: 20, height: 20))
    }()
    static func menuIcon(expanded: Bool = false, paused: Bool = false, style: ExpansionStyle = .below) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            // Only the collapsed state uses the application's logo silhouette.
            if !expanded && !paused {
                let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
                if let symbol = NSImage(systemSymbolName: "tray.2.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                    let scale = min(18.5 / symbol.size.width, 18.5 / symbol.size.height)
                    let width = symbol.size.width * scale, height = symbol.size.height * scale
                    symbol.draw(in: NSRect(x: (20 - width) / 2, y: (20 - height) / 2, width: width, height: height))
                }
                return true
            }
            // Each full-size arrow starts inside the box and passes through an open side.
            let inset = NSAffineTransform()
            inset.translateX(by: 0.5, yBy: 0.5); inset.scale(by: 0.95); inset.concat()
            NSColor.black.setStroke()
            let box = NSBezierPath()
            box.lineWidth = 2; box.lineCapStyle = .round; box.lineJoinStyle = .round
            if paused {
                box.lineWidth = 1.9
                box.appendRoundedRect(NSRect(x: 2, y: 3, width: 16, height: 14), xRadius: 2.2, yRadius: 2.2)
                box.move(to: NSPoint(x: 2, y: 13)); box.line(to: NSPoint(x: 8, y: 13))
                box.move(to: NSPoint(x: 12, y: 13)); box.line(to: NSPoint(x: 18, y: 13))
                box.move(to: NSPoint(x: 7, y: 6)); box.line(to: NSPoint(x: 7, y: 9))
                box.move(to: NSPoint(x: 13, y: 6)); box.line(to: NSPoint(x: 13, y: 9))
            } else {
                let arrow = NSBezierPath()
                arrow.lineWidth = 2.2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
                if style == .left {
                    box.move(to: NSPoint(x: 6, y: 6)); box.line(to: NSPoint(x: 6, y: 3))
                    box.line(to: NSPoint(x: 18, y: 3)); box.line(to: NSPoint(x: 18, y: 14))
                    box.line(to: NSPoint(x: 16, y: 18)); box.line(to: NSPoint(x: 8, y: 18))
                    box.line(to: NSPoint(x: 6, y: 14))
                    box.move(to: NSPoint(x: 9, y: 14)); box.line(to: NSPoint(x: 18, y: 14))
                    arrow.move(to: NSPoint(x: 14, y: 10)); arrow.line(to: NSPoint(x: 1.5, y: 10))
                    arrow.move(to: NSPoint(x: 5.5, y: 14)); arrow.line(to: NSPoint(x: 1.5, y: 10)); arrow.line(to: NSPoint(x: 5.5, y: 6))
                } else {
                    box.move(to: NSPoint(x: 6.5, y: 7)); box.line(to: NSPoint(x: 3, y: 7))
                    box.line(to: NSPoint(x: 3, y: 15)); box.line(to: NSPoint(x: 6, y: 18))
                    box.line(to: NSPoint(x: 14, y: 18)); box.line(to: NSPoint(x: 17, y: 15))
                    box.line(to: NSPoint(x: 17, y: 7)); box.line(to: NSPoint(x: 13.5, y: 7))
                    box.move(to: NSPoint(x: 3, y: 15)); box.line(to: NSPoint(x: 17, y: 15))
                    arrow.move(to: NSPoint(x: 10, y: 12)); arrow.line(to: NSPoint(x: 10, y: 1.5))
                    arrow.move(to: NSPoint(x: 6, y: 5.5)); arrow.line(to: NSPoint(x: 10, y: 1.5)); arrow.line(to: NSPoint(x: 14, y: 5.5))
                }
                arrow.stroke()
            }
            box.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
    static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16); image?.isTemplate = true
        return image
    }
}
