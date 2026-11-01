import AppKit
import SwiftUI
import BarCore

/// Native tick marks are hints for clicks, not restrictions on continuous drags.
struct DensitySlider: NSViewRepresentable {
    let value: Double
    let onChange: (Double) -> Void
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> DensitySliderControl {
        let slider = DensitySliderControl()
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }
    func updateNSView(_ slider: DensitySliderControl, context: Context) {
        context.coordinator.onChange = onChange
        if !slider.isTrackingPointer { slider.doubleValue = value }
        slider.isEnabled = enabled
    }
    @MainActor final class Coordinator: NSObject {
        var onChange: ((Double) -> Void)?
        @objc func changed(_ sender: NSSlider) { onChange?(sender.doubleValue) }
    }
}

final class DensitySliderControl: NSSlider {
    private(set) var isTrackingPointer = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        minValue = 0; maxValue = 1
        isContinuous = true
        numberOfTickMarks = 21
        tickMarkPosition = .below
        allowsTickMarkValuesOnly = false
        tintProminence = .primary
        setAccessibilityLabel("下方抽屉背景浓度")
        toolTip = "点击吸附到最近的 5%；拖动连续调整。"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Use native tick geometry, including the knob's end insets, for exact 0–100% mapping.
    func pointerValue(at x: CGFloat, startX: CGFloat, startValue: Double, grabbedKnob: Bool, dragged: Bool) -> Double {
        let first = rectOfTickMark(at: 0).midX
        let last = rectOfTickMark(at: numberOfTickMarks - 1).midX
        guard abs(last - first) > 0 else { return doubleValue }
        let value = dragged && grabbedKnob ? startValue + Double((x - startX) / (last - first))
            : Double((x - first) / (last - first))
        let normalized = DrawerBackground.normalized(value)
        return dragged ? normalized : closestTickMarkValue(toValue: normalized)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        window.makeFirstResponder(self)
        let start = convert(event.locationInWindow, from: nil)
        let original = doubleValue
        let grabbedKnob = (cell as? NSSliderCell)?.knobRect(flipped: isFlipped).contains(start) == true
        var dragged = false
        isTrackingPointer = true
        defer { isTrackingPointer = false }
        // Keep AppKit's native drawing, keyboard and accessibility behavior. Only
        // pointer tracking distinguishes a click from a drag; mouse-up never snaps a drag.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                         inMode: .eventTracking, dequeue: true) {
            let point = convert(next.locationInWindow, from: nil)
            dragged = dragged || hypot(point.x - start.x, point.y - start.y) >= 3
            if dragged || next.type == .leftMouseUp {
                doubleValue = pointerValue(at: dragged ? point.x : start.x, startX: start.x,
                    startValue: original, grabbedKnob: grabbedKnob, dragged: dragged)
                if let action { sendAction(action, to: target) }
            }
            if next.type == .leftMouseUp { break }
        }
    }
}
