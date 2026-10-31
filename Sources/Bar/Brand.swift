import AppKit
import BarCore

enum Brand {
    static let name = "Bar"
    static let applicationIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "Bar", withExtension: "icns"), let image = NSImage(contentsOf: url) { return image }
        return menuIcon(expanded: true)
    }()
    static func menuIcon(expanded: Bool = false, paused: Bool = false, style: ExpansionStyle = .below) -> NSImage {
        let name = paused ? "pause.circle" : (expanded ? "tray.and.arrow.down" : "shippingbox")
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: Brand.name)!
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: 9, yBy: 9)
            // The native downward tray arrow rotates clockwise to point left.
            if expanded && !paused && style == .left { transform.rotate(byDegrees: -90) }
            transform.concat()
            let scale = min(17 / symbol.size.width, 17 / symbol.size.height)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            symbol.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
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
