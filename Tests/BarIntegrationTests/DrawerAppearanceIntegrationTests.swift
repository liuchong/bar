import AppKit
import ApplicationServices
import Testing
import BarCore
@testable import Bar

@Suite("Drawer presentation")
struct DrawerAppearanceIntegrationTests {
    @Test @MainActor func localBackdropSelectsContrastingMonochromeGlyphs() throws {
        for (gray, expectsLight) in [(CGFloat(1), false), (0.8, false), (0.1, true), (0, true)] {
            let context = try #require(CGContext(data: nil, width: 64, height: 8, bitsPerComponent: 8,
                bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 8))
            let image = try #require(context.makeImage())
            let luminance = try #require(DrawerContrast.luminance(of: image))
            #expect(DrawerContrast.prefersLight(luminance: luminance, previous: nil) == expectsLight)
        }
    }

    @Test @MainActor func middleGrayChangesDoNotFlickerBetweenBlackAndWhite() {
        #expect(DrawerContrast.prefersLight(luminance: 0.18, previous: true))
        #expect(!DrawerContrast.prefersLight(luminance: 0.18, previous: false))
        #expect(!DrawerContrast.prefersLight(luminance: 0.25, previous: true))
        #expect(DrawerContrast.prefersLight(luminance: 0.10, previous: false))
    }

    @Test func lowerStripClearsFullMenuBarEvenWhenItsButtonIsShorter() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1920, y: -400, width: 1920, height: 1080)] {
            let bar = CGRect(x: screen.minX, y: screen.maxY - 38, width: screen.width, height: 38)
            let button = CGRect(x: screen.maxX - 300, y: screen.maxY - 28, width: 24, height: 22)
            for scale in [CGFloat(1), CGFloat(2)] {
                let row = DrawerLayout.belowRow(width: 160, screen: screen, anchor: button,
                    menuBarBottom: bar.minY, height: 38, row: 0, backingScale: scale)
                #expect(row.maxY == bar.minY - 1 / scale)
                #expect(!row.intersects(bar))
                #expect(row.maxX == button.maxX)
                let next = DrawerLayout.belowRow(width: 160, screen: screen, anchor: button,
                    menuBarBottom: bar.minY, height: 38, row: 1, backingScale: scale)
                #expect(next.maxY == row.minY)
                #expect(!next.intersects(row))
            }
        }
    }

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
