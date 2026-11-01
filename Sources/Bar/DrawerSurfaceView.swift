import AppKit
import BarCore
import SwiftUI

/// The drawer intentionally does not activate Bar. Its first click must still
/// reach a glyph button when another application owns keyboard focus.
final class DrawerHostingView: NSHostingView<DrawerView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct DrawerEntry: Identifiable {
    let item: MenuItem?
    let width: CGFloat
    var id: String { item?.id ?? "bar.image-permission" }
}

/// The top row already has the system menu-bar backdrop. Only the lower row needs blur.
final class DrawerSurfaceView: NSView {
    let glass = NSGlassEffectView()
    let solid = NSView()
    var hosting: NSView?
    private var style: ExpansionStyle = .left
    private var density = DrawerBackground.defaultDensity
    private var accessibilityObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        glass.style = .clear
        glass.tintColor = nil
        glass.cornerRadius = 0
        glass.effectIsInteractive = false
        glass.contentView = NSView()
        addSubview(glass)
        solid.wantsLayer = true
        addSubview(solid)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMaterial() }
            }
        configure(style: .left)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) } }

    func configure(style: ExpansionStyle, density: Double = DrawerBackground.defaultDensity) {
        self.style = style; self.density = DrawerBackground.normalized(density)
        layer?.masksToBounds = style == .below
        updateMaterial()
    }

    private func updateMaterial() {
        let lower = style == .below && density > 0
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let opacity = reduce ? 1 : DrawerBackground.solidOpacity(density)
        glass.isHidden = !lower || opacity == 1
        glass.alphaValue = DrawerBackground.glassOpacity(density)
        solid.isHidden = !lower || opacity == 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(opacity).cgColor
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateMaterial()
    }
    override func layout() {
        super.layout()
        glass.frame = bounds; solid.frame = bounds
        glass.contentView?.frame = glass.bounds
        hosting?.frame = bounds
    }
}

/// Use the actual drawer material in settings so its transparency is visible while adjusting it.
struct DrawerBackgroundPreview: NSViewRepresentable {
    let density: Double
    func makeNSView(context: Context) -> DrawerBackgroundPreviewView { DrawerBackgroundPreviewView() }
    func updateNSView(_ view: DrawerBackgroundPreviewView, context: Context) {
        view.surface.configure(style: .below, density: density)
    }
}

final class DrawerBackgroundPreviewView: NSView {
    let surface = DrawerSurfaceView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(surface)
        let symbols = NSStackView()
        symbols.orientation = .horizontal; symbols.spacing = 24
        for name in ["wifi", "bolt.fill", "speaker.wave.2.fill", "cloud.fill"] {
            let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)!)
            image.contentTintColor = .labelColor
            symbols.addArrangedSubview(image)
        }
        symbols.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(symbols)
        NSLayoutConstraint.activate([symbols.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            symbols.centerYAnchor.constraint(equalTo: surface.centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [.systemTeal.withAlphaComponent(0.45), .systemPink.withAlphaComponent(0.35),
            .systemYellow.withAlphaComponent(0.5)])?.draw(in: bounds, angle: 0)
        let text = "Aa   文字与颜色   Aa   文字与颜色   Aa   文字与颜色   Aa"
        (text as NSString).draw(at: NSPoint(x: 8, y: bounds.midY - 8), withAttributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor.withAlphaComponent(0.6)])
    }
    override func layout() {
        super.layout()
        surface.frame = NSRect(x: 0, y: 10, width: bounds.width, height: bounds.height - 20)
    }
}
