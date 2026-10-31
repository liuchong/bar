import AppKit
import ApplicationServices
import Testing
import BarCore
@testable import Bar

@Suite("Drawer presentation")
struct DrawerAppearanceIntegrationTests {
    @Test @MainActor func wallpaperTintInWhiteGlyphEdgesDoesNotTurnItIntoAColoredIcon() throws {
        let width = 24, height = 24
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let alpha: Double = (8..<16).contains(x) && (5..<19).contains(y)
                    ? ((10..<14).contains(x) && (7..<17).contains(y) ? 1 : 0.4) : 0
                for (channel, background) in [0.0, 150.0, 180.0].enumerated() {
                    bytes[(y * width + x) * 4 + channel] = UInt8(background + alpha * (255 - background))
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let source = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let glyph = try #require(MenuBarImages.extract(source, points: CGSize(width: width, height: height)))
        #expect(glyph.image.isTemplate)
        #expect(glyph.dark)
    }

    @Test @MainActor func topRowUsesExistingBackdropAndLowerRowBlurs() {
        let surface = DrawerSurfaceView(frame: CGRect(x: 0, y: 0, width: 100, height: 24))
        surface.configure(style: .left)
        #expect(surface.blur.isHidden)
        #expect(surface.layer?.backgroundColor?.alpha == 0)
        surface.configure(style: .below)
        #expect(!surface.blur.isHidden)
        #expect(surface.blur.blendingMode == .behindWindow)
        surface.configure(style: .left)
        #expect(surface.blur.isHidden)
    }

    @Test @MainActor func missingImagesHaveOneActionAlongsideGenuineGlyphs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(store: ConfigurationStore(url: directory.appendingPathComponent("settings.json")),
                             imageAuthorization: { false })
        defer { model.shutdown() }
        let bundles = ["app.one", "app.two", "app.three"]
        for bundle in bundles { model.configuration.dispositions[bundle] = .collected }
        model.items = bundles.map { bundle in
            MenuItem(id: bundle, bundle: bundle, appName: bundle, label: bundle, icon: NSImage(),
                     element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                     frame: CGRect(x: 0, y: 0, width: 24, height: 24), pid: ProcessInfo.processInfo.processIdentifier)
        }
        #expect(model.drawerEntries.count == 1)
        #expect(model.drawerEntries.first?.item == nil)
        let glyph = NSImage(size: NSSize(width: 24, height: 24))
        model.menuImages["app.one"] = MenuBarImage(image: glyph, dark: true, width: 24)
        #expect(model.drawerEntries.compactMap(\.item).map(\.id) == ["app.one"])
        #expect(model.drawerEntries.filter { $0.item == nil }.count == 1)
        for bundle in bundles { model.menuImages[bundle] = MenuBarImage(image: glyph, dark: true, width: 24) }
        #expect(model.drawerEntries.count == 3)
        #expect(model.drawerEntries.allSatisfy { $0.item != nil })
    }
}
