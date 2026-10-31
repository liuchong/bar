import AppKit
import BarCore

enum Brand {
    static let name = "Bar"
    static let applicationIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "Bar", withExtension: "icns"), let image = NSImage(contentsOf: url) { return image }
        return menuIcon(expanded: true)
    }()
    static func menuIcon(expanded: Bool = false, paused: Bool = false, style: ExpansionStyle = .below) -> NSImage {
        // Keep the fixed canvas; inset the glyph slightly to match neighboring status symbols.
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let inset = NSAffineTransform()
            inset.translateX(by: 0.5, yBy: 0.5)
            inset.scale(by: 0.95)
            inset.concat()
            NSColor.black.setStroke()
            let box = NSBezierPath()
            box.lineWidth = 2.2; box.lineCapStyle = .round; box.lineJoinStyle = .round
            if expanded && !paused {
                box.move(to: NSPoint(x: 2, y: 12))
                box.line(to: NSPoint(x: 2, y: 3))
                box.line(to: NSPoint(x: 18, y: 3))
                box.line(to: NSPoint(x: 18, y: 12))
                let arrow = NSBezierPath()
                arrow.lineWidth = 2.2; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
                if style == .left {
                    arrow.move(to: NSPoint(x: 17, y: 16)); arrow.line(to: NSPoint(x: 4, y: 16))
                    arrow.move(to: NSPoint(x: 7, y: 19)); arrow.line(to: NSPoint(x: 4, y: 16)); arrow.line(to: NSPoint(x: 7, y: 13))
                } else {
                    arrow.move(to: NSPoint(x: 10, y: 18)); arrow.line(to: NSPoint(x: 10, y: 8))
                    arrow.move(to: NSPoint(x: 6.5, y: 11.5)); arrow.line(to: NSPoint(x: 10, y: 8)); arrow.line(to: NSPoint(x: 13.5, y: 11.5))
                }
                arrow.stroke()
            } else {
                box.lineWidth = 1.9
                box.appendRoundedRect(NSRect(x: 2, y: 3, width: 16, height: 14), xRadius: 2.2, yRadius: 2.2)
                box.move(to: NSPoint(x: 2, y: 13)); box.line(to: NSPoint(x: 8, y: 13))
                box.move(to: NSPoint(x: 12, y: 13)); box.line(to: NSPoint(x: 18, y: 13))
                if paused {
                    box.move(to: NSPoint(x: 7, y: 6)); box.line(to: NSPoint(x: 7, y: 9))
                    box.move(to: NSPoint(x: 13, y: 6)); box.line(to: NSPoint(x: 13, y: 9))
                } else {
                    box.move(to: NSPoint(x: 8, y: 17)); box.line(to: NSPoint(x: 8, y: 10))
                    box.line(to: NSPoint(x: 10, y: 11)); box.line(to: NSPoint(x: 12, y: 10))
                    box.line(to: NSPoint(x: 12, y: 17))
                    box.move(to: NSPoint(x: 13, y: 6)); box.line(to: NSPoint(x: 16, y: 6))
                }
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
