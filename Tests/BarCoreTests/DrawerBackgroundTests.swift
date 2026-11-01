import Foundation
import Testing
import BarCore

@Suite("Continuous drawer background")
struct DrawerBackgroundTests {
    @Test func concentrationMovesContinuouslyFromTransparentThroughGlassToSolid() {
        #expect(DrawerBackground.glassOpacity(0) == 0)
        #expect(DrawerBackground.solidOpacity(0) == 0)
        #expect(DrawerBackground.glassOpacity(DrawerBackground.defaultDensity) == 1)
        #expect(DrawerBackground.solidOpacity(DrawerBackground.defaultDensity) == 0)
        #expect(DrawerBackground.solidOpacity(1) == 1)
        var previousGlass = 0.0, previousSolid = 0.0
        for step in 0...1000 {
            let value = Double(step) / 1000
            let glass = DrawerBackground.glassOpacity(value), solid = DrawerBackground.solidOpacity(value)
            #expect((0...1).contains(glass) && (0...1).contains(solid))
            #expect(glass >= previousGlass && glass - previousGlass < 0.01)
            #expect(solid >= previousSolid && solid - previousSolid < 0.01)
            previousGlass = glass; previousSolid = solid
        }
    }

    @Test func densityIsBoundedAndDoesNotChangeSavedCollectionRules() throws {
        var config = Configuration()
        config.setPlacement(.left, for: "app.one")
        for (input, expected) in [(-1.0, 0.0), (2, 1), (.nan, 0.65), (.infinity, 0.65)] {
            config.drawerBackgroundDensity = input; config.normalize()
            #expect(config.drawerBackgroundDensity == expected)
            #expect(config.disposition(for: "app.one") == .collected)
        }
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        #expect(restored == config)
    }
}
