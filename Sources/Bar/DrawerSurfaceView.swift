import AppKit
import BarCore

struct DrawerEntry: Identifiable {
    let item: MenuItem?
    let width: CGFloat
    var id: String { item?.id ?? "bar.image-permission" }
}

/// The top row already has the system menu-bar backdrop. Only the lower row needs blur.
final class DrawerSurfaceView: NSView {
    let blur = NSVisualEffectView()
    var hosting: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.alphaValue = 0.10
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(style: ExpansionStyle) {
        blur.isHidden = style == .left
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 0
        layer?.masksToBounds = style == .below
    }
    override func layout() {
        super.layout()
        blur.frame = bounds
        hosting?.frame = bounds
    }
}
