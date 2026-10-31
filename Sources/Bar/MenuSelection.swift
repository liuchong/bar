import AppKit
import SwiftUI

@MainActor
enum MenuSelection {
    /// A popup's action runs inside menu tracking. Moving its row at that point
    /// destroys the control before AppKit has finished dismissing its menu.
    static func commit(_ change: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { change() }
        }
    }
}

/// Keep an actual AppKit popup control alive for the entire native menu action.
struct SettingsMenuPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    let choices: [(Value, String)]
    let selection: Value
    let onChange: (Value) -> Void
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selected(_:))
        button.setAccessibilityLabel(title)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.values = choices.map(\.0)
        context.coordinator.onChange = onChange
        let titles = choices.map(\.1)
        if button.itemTitles != titles { button.removeAllItems(); button.addItems(withTitles: titles) }
        if let index = choices.firstIndex(where: { $0.0 == selection }) { button.selectItem(at: index) }
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
    }
    @MainActor final class Coordinator: NSObject {
        var values: [Value] = []
        var onChange: ((Value) -> Void)?
        @objc func selected(_ sender: NSPopUpButton) {
            guard values.indices.contains(sender.indexOfSelectedItem), let change = onChange else { return }
            let value = values[sender.indexOfSelectedItem]
            MenuSelection.commit { change(value) }
        }
    }
}
