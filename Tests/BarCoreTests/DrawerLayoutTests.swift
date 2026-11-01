import CoreGraphics
import Testing
import BarCore

@Suite("Visible drawer layout")
struct DrawerLayoutTests {
    @Test func cameraGapAndRowCapacityNeverDropIcons() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let camera = CGRect(x: 620, y: 868, width: 200, height: 32)
        let positions = DrawerLayout.left(widths: Array(repeating: 30, count: 120), screen: screen,
            anchor: CGRect(x: 1320, y: 868, width: 30, height: 32), cutout: camera, height: 32)
        #expect(positions.allSatisfy { $0.frame.maxX <= 1318 })
        #expect(positions.count == 120)
        #expect(Set(positions.map(\.index)).count == 120)
        for position in positions {
            #expect(screen.contains(position.frame))
            #expect(!position.frame.intersects(camera))
        }
        for (index, position) in positions.enumerated() {
            for other in positions.dropFirst(index + 1) { #expect(!position.frame.intersects(other.frame)) }
        }
    }

    @Test func nativeRevealRejectsUnknownOrUnstableGeometry() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGRect(x: 1000, y: 0, width: 28, height: 32)
        let good = CGRect(x: 960, y: 0, width: 32, height: 32)
        #expect(StableMenuBar.canInteract(originals: [good], anchor: anchor, displays: [screen]))
        #expect(StableMenuBar.canInteract(originals: [good, CGRect(x: 1030, y: 0, width: 32, height: 32)], anchor: anchor, displays: [screen]))
        for bad in [CGRect.zero, CGRect(x: -40, y: 0, width: 32, height: 32),
                    CGRect(x: 1000, y: 0, width: 28, height: 32),
                    CGRect(x: 960, y: 400, width: 32, height: 32)] {
            #expect(!StableMenuBar.canInteract(originals: [good, bad], anchor: anchor, displays: [screen]))
        }
        #expect(!StableMenuBar.canInteract(originals: [], anchor: anchor, displays: [screen]))
    }

    @Test func externalScreenUsesItsOwnOriginAndHasNoArtificialCameraGap() {
        let screen = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let positions = DrawerLayout.left(widths: [22, 42, 75], screen: screen,
            anchor: CGRect(x: -80, y: 1176, width: 24, height: 24), cutout: nil, height: 24)
        #expect(positions.map(\.frame.width) == [22, 42, 75])
        #expect(positions[0].frame.maxX == -82)
        #expect(positions[1].frame.maxX == positions[0].frame.minX)
        #expect(positions[2].frame.maxX == positions[1].frame.minX)
        #expect(positions.allSatisfy { screen.contains($0.frame) })
    }
}
