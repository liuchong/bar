import AppKit

enum Brand {
    static let name = "Bar"
    static let applicationIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "Bar", withExtension: "icns"), let image = NSImage(contentsOf: url) { return image }
        return menuIcon(expanded: true)
    }()
    static func menuIcon(expanded: Bool = false, paused: Bool = false) -> NSImage {
        let name = paused ? "pause.circle" : (expanded ? "tray.2.fill" : "tray.2")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: Brand.name)!
        image.isTemplate = true
        return image
    }
    static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16); image?.isTemplate = true
        return image
    }
}
