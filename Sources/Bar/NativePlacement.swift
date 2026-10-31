import AppKit
import ApplicationServices
import BarCore

/// Native items that may need to open a menu belong before Bar. This is a setup operation,
/// never part of opening, closing or periodically refreshing the drawer.
@MainActor
enum NativePlacement {
    private static var arranging = false
    static func arrange(_ items: [MenuItem], anchor: @escaping () -> CGRect?,
                        scan: @escaping (String) async -> [MenuItem]) async -> Set<String> {
        for _ in 0..<100 {
            if !arranging { break }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return [] }
        }
        guard !arranging else { return [] }
        arranging = true
        defer { arranging = false }
        var safe = Set<String>()
        let pointer = CGEvent(source: nil)?.location
        var lastPosted: CGPoint?
        defer {
            if let pointer, let lastPosted, let now = CGEvent(source: nil)?.location,
               NSEvent.pressedMouseButtons == 0, hypot(now.x - lastPosted.x, now.y - lastPosted.y) < 8 {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pointer, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        }
        for bundle in Set(items.map(\.bundle)).sorted() {
            var entries = await scan(bundle)
            var succeeded = true
            let identifiers = entries.map(\.id)
            for id in identifiers {
                entries = await scan(bundle)
                guard let item = entries.first(where: { $0.id == id }) else { succeeded = false; continue }
                guard !Task.isCancelled, let bar = anchor() else { return safe }
                let displays = displayFrames()
                if StableMenuBar.canReveal(originals: [item.frame], anchor: bar, displays: displays) { continue }
                let onScreen = displays.contains { $0.contains(item.frame) }
                guard onScreen, item.frame.width > 1, item.frame.height > 1,
                      displays.contains(where: { $0.contains(bar) }),
                      abs(item.frame.midY - bar.midY) < max(item.frame.height, bar.height),
                      CGPreflightPostEventAccess(), NSEvent.pressedMouseButtons == 0,
                      NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                else { succeeded = false; continue }
                let source = CGPoint(x: item.frame.midX, y: item.frame.midY)
                let destination = CGPoint(x: bar.minX - 8, y: bar.midY)
                post(.mouseMoved, at: source, command: false)
                try? await Task.sleep(for: .milliseconds(100))
                post(.leftMouseDown, at: source, command: true)
                for step in 1...12 {
                    let t = CGFloat(step) / 12
                    let point = CGPoint(x: source.x + (destination.x - source.x) * t,
                                        y: source.y + (destination.y - source.y) * t)
                    post(.leftMouseDragged, at: point, command: true)
                    lastPosted = point
                    try? await Task.sleep(for: .milliseconds(16))
                }
                post(.leftMouseUp, at: destination, command: true)
                try? await Task.sleep(for: .milliseconds(180))
                if Task.isCancelled { return safe }
            }
            entries = await scan(bundle)
            if let bar = anchor(), succeeded, !entries.isEmpty,
               StableMenuBar.canReveal(originals: entries.map(\.frame), anchor: bar, displays: displayFrames()) { safe.insert(bundle) }
        }
        return safe
    }

    private static func displayFrames() -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(id.uint32Value)
        }
    }

    private static func post(_ type: CGEventType, at point: CGPoint, command: Bool) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = command ? .maskCommand : []
        event?.post(tap: .cghidEventTap)
    }
}
