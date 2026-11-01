import AppKit
import Testing
import BarCore
@testable import Bar

@Suite("Density slider interaction")
struct DensitySliderIntegrationTests {
    @Test @MainActor func clicksUseFivePercentStopsButDragsKeepContinuousSavedValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        let model = AppModel(store: store, imageAuthorization: { false })
        defer { model.shutdown() }
        let slider = DensitySliderControl(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        let first = slider.rectOfTickMark(at: 0).midX
        let span = slider.rectOfTickMark(at: 20).midX - first
        #expect(span > 0 && slider.numberOfTickMarks == 21)
        #expect(!slider.allowsTickMarkValuesOnly)
        let x = first + span * 0.663
        let click = slider.pointerValue(at: x, startX: x, startValue: 0.65, grabbedKnob: false, dragged: false)
        #expect(abs(click - 0.65) < 0.000001)
        let drag = slider.pointerValue(at: x, startX: first, startValue: 0, grabbedKnob: false, dragged: true)
        #expect(abs(drag - 0.663) < 0.000001)
        model.setDrawerBackgroundDensity(drag)
        #expect(abs(try store.load().drawerBackgroundDensity - 0.663) < 0.000001)
        #expect(!model.orderingItems)
    }

    @Test @MainActor func grabbingAnOffGridKnobPreservesItsOffsetAndEndpointsStayReachable() {
        let slider = DensitySliderControl(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        let first = slider.rectOfTickMark(at: 0).midX
        let last = slider.rectOfTickMark(at: 20).midX
        let span = last - first
        let start = first + span * 0.663 + 4
        #expect(abs(slider.pointerValue(at: start + span * 0.01, startX: start, startValue: 0.663,
            grabbedKnob: true, dragged: true) - 0.673) < 0.000001)
        for (x, expected) in [(first - 20, 0.0), (last + 20, 1.0)] {
            #expect(slider.pointerValue(at: x, startX: first, startValue: 0, grabbedKnob: false, dragged: false) == expected)
            #expect(slider.pointerValue(at: x, startX: first, startValue: 0, grabbedKnob: false, dragged: true) == expected)
        }
    }
}
