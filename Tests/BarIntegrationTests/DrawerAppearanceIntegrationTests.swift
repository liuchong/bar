import AppKit
import ApplicationServices
import Testing
import BarCore
@testable import Bar

@Suite("Drawer presentation")
struct DrawerAppearanceIntegrationTests {
    @Test @MainActor func drawerStatesAreMonochromeAndHaveDistinctPullDirections() throws {
        var directionalMasks: [[UInt8]] = []
        for (expanded, paused, style) in [(false, false, ExpansionStyle.below), (true, false, .below),
                                         (true, false, .left), (false, true, .below)] {
            let icon = Brand.menuIcon(expanded: expanded, paused: paused, style: style)
            #expect(icon.isTemplate)
            #expect(icon.size == NSSize(width: 20, height: 20))
            let source = try #require(icon.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let width = source.width, height = source.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            try bytes.withUnsafeMutableBytes { pixels in
                let context = try #require(CGContext(data: pixels.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
                var visible = 0
                for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 0 {
                    visible += 1
                    #expect(pixels[index] == pixels[index + 1] && pixels[index + 1] == pixels[index + 2])
                }
                if expanded && !paused { directionalMasks.append(stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }) }
                #expect(visible > 20)
                #expect(pixels[3] == 0)
                #expect(pixels[(width - 1) * 4 + 3] == 0)
            }
        }
        #expect(directionalMasks.count == 2)
        let different = zip(directionalMasks[0], directionalMasks[1]).filter { abs(Int($0) - Int($1)) > 64 }.count
        // Pull direction changes the whole drawer silhouette, rather than just a tiny corner badge.
        #expect(different > directionalMasks[0].count / 10)
    }

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
                #expect(row.maxX == button.midX)
                let next = DrawerLayout.belowRow(width: 160, screen: screen, anchor: button,
                    menuBarBottom: bar.minY, height: 38, row: 1, backingScale: scale)
                #expect(next.maxY == row.minY)
                #expect(!next.intersects(row))
            }
        }
    }

    @Test func bothColumnsShareTheSameLowerRowGeometry() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1920, y: -400, width: 1920, height: 1080)] {
            let anchor = CGRect(x: screen.midX, y: screen.maxY - 28, width: 24, height: 22)
            for scale in [CGFloat(1), CGFloat(2)] {
                for index in 0..<3 {
                    let left = DrawerLayout.belowRow(width: 160, screen: screen, anchor: anchor,
                        menuBarBottom: screen.maxY - 38, height: 38, row: index, backingScale: scale)
                    let right = DrawerLayout.belowRow(width: 160, screen: screen, anchor: anchor,
                        menuBarBottom: screen.maxY - 38, height: 38, row: index, backingScale: scale, side: .right)
                    #expect(left.size == right.size)
                    #expect(left.minY == right.minY)
                    #expect(left.maxY == screen.maxY - 38 - 1 / scale - CGFloat(index) * 38)
                    #expect(left.maxX == anchor.midX)
                    #expect(right.minX == anchor.midX)
                    #expect(left.maxX == right.minX)
                    #expect(!left.intersects(right))
                }
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
        #expect(surface.glass.isHidden)
        #expect(surface.layer?.backgroundColor?.alpha == 0)
        surface.configure(style: .below)
        #expect(surface.glass.isHidden == NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        #expect(surface.glass.style == .clear)
        #expect(surface.glass.tintColor == nil)
        surface.configure(style: .left)
        #expect(surface.glass.isHidden)
    }

    @Test @MainActor func continuousBackgroundReachesTransparentGlassAndSolidWithoutFadingIcons() {
        let surface = DrawerSurfaceView(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        let glyphs = NSView(frame: surface.bounds)
        surface.hosting = glyphs; surface.addSubview(glyphs)
        surface.configure(style: .below, density: 0)
        #expect(surface.glass.isHidden && surface.solid.isHidden)
        surface.configure(style: .below, density: 0.65)
        #expect(surface.glass.tintColor == nil)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            #expect(!surface.glass.isHidden && surface.solid.isHidden)
            #expect(surface.glass.alphaValue == 1)
        }
        surface.configure(style: .below, density: 1)
        #expect(surface.glass.isHidden && !surface.solid.isHidden)
        #expect(surface.solid.layer?.backgroundColor?.alpha == 1)
        #expect(glyphs.alphaValue == 1 && surface.subviews.last === glyphs)
        for density in [0.0, 0.25, 0.65, 0.85, 1] {
            surface.configure(style: .left, density: density)
            #expect(surface.glass.isHidden && surface.solid.isHidden)
        }
    }

    @Test @MainActor func densitySavesAndRestoresWithoutStartingNativeIconOperations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        let model = AppModel(store: store, imageAuthorization: { false })
        defer { model.shutdown() }
        model.configuration.setPlacement(.left, for: "app.one")
        let original = model.configuration
        var changes = 0
        model.presentationChanged = { changes += 1 }
        for value in [0.0, 0.25, 0.65, 0.85, 1] {
            model.setDrawerBackgroundDensity(value)
            let restored = try store.load()
            #expect(restored.drawerBackgroundDensity == value)
            #expect(restored.dispositions == original.dispositions && restored.order == original.order)
            #expect(!model.orderingItems && !model.capturingImages)
        }
        #expect(changes == 5)
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
