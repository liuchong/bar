import AppKit
import BarCore

enum Brand {
    static let name = "Bar"
    static let applicationIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "Bar", withExtension: "icns"), let image = NSImage(contentsOf: url) { return image }
        return DrawerArtwork.applicationIcon()
    }()
    static func menuIcon(expanded: Bool = false, paused: Bool = false, style: ExpansionStyle = .below) -> NSImage {
        let state: DrawerArtwork.State = paused ? .paused : (expanded ? (style == .left ? .left : .below) : .closed)
        let image = DrawerArtwork.image(state)
        image.isTemplate = true
        return image
    }
    static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.size = NSSize(width: 16, height: 16); image?.isTemplate = true
        return image
    }
}
