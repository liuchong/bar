import AppKit
import CoreGraphics
import OSLog

/// A short native placement transaction. Never start while the user is moving
/// the pointer; keep the synthetic drag invisible and yield to physical input.
@MainActor
enum NativePointer {
    private static let tag: Int64 = 0x42617244726167
    private final class Session {
        let origin: CGPoint
        let display: CGDirectDisplayID
        var point: CGPoint
        var delta = CGPoint.zero
        var monitors: [Any] = []
        init(origin: CGPoint, source: CGPoint, display: CGDirectDisplayID) {
            self.origin = origin; self.point = source; self.display = display
        }
    }
    private static var session: Session?

    static func cancel() {
        guard let current = session else { return }
        session = nil
        post(.leftMouseUp, at: current.point, command: true)
        for monitor in current.monitors { NSEvent.removeMonitor(monitor) }
        let destination = CGPoint(x: current.origin.x + current.delta.x, y: current.origin.y + current.delta.y)
        CGWarpMouseCursorPosition(destination)
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(current.display)
        let restored = CGEvent(source: nil)?.location ?? destination
        Logger(subsystem: "com.liuchong.bar", category: "Ordering").notice("Pointer restored; error=\(hypot(restored.x - destination.x, restored.y - destination.y))")
    }

    static func drag(from source: CGPoint, to destination: CGPoint) async -> Bool {
        // Bounded idle wait, including mouse movement inside our settings window.
        var previous = CGEvent(source: nil)?.location, stable = 0
        for _ in 0..<100 {
            guard !Task.isCancelled else { return false }
            let now = CGEvent(source: nil)?.location
            let idle = now == previous && NSEvent.pressedMouseButtons == 0 &&
                NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            stable = idle ? stable + 1 : 0
            previous = now
            if stable >= 7 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard stable >= 7, !Task.isCancelled, session == nil,
              let origin = CGEvent(source: nil)?.location else { return false }
        let display = CGMainDisplayID()
        guard CGDisplayHideCursor(display) == .success else { return false }
        guard CGAssociateMouseAndMouseCursorPosition(0) == .success else {
            CGDisplayShowCursor(display); return false
        }
        let current = Session(origin: origin, source: source, display: display)
        session = current
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let receive: (NSEvent) -> Void = { event in
            guard session === current, event.cgEvent?.getIntegerValueField(.eventSourceUserData) != tag else { return }
            current.delta.x += event.cgEvent?.getDoubleValueField(.mouseEventDeltaX) ?? 0
            current.delta.y += event.cgEvent?.getDoubleValueField(.mouseEventDeltaY) ?? 0
            cancel()
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: receive) { current.monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in receive(event); return event }) {
            current.monitors.append(monitor)
        }
        defer { if session === current { cancel() } }
        post(.mouseMoved, at: source, command: false)
        try? await Task.sleep(for: .milliseconds(30))
        guard session === current, !Task.isCancelled else { return false }
        post(.leftMouseDown, at: source, command: true)
        for step in 1...8 {
            guard session === current, !Task.isCancelled else { return false }
            let t = CGFloat(step) / 8
            current.point = CGPoint(x: source.x + (destination.x - source.x) * t,
                                    y: source.y + (destination.y - source.y) * t)
            post(.leftMouseDragged, at: current.point, command: true)
            try? await Task.sleep(for: .milliseconds(8))
        }
        return session === current && !Task.isCancelled
    }

    private static func post(_ type: CGEventType, at point: CGPoint, command: Bool) {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents,
            .permitSystemDefinedEvents], state: .eventSuppressionStateRemoteMouseDrag)
        if type == .leftMouseDown || type == .leftMouseUp {
            let key = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: type == .leftMouseDown)
            key?.flags = type == .leftMouseDown ? .maskCommand : []
            key?.setIntegerValueField(.eventSourceUserData, value: tag)
            if type == .leftMouseDown { key?.post(tap: .cghidEventTap) }
            if type == .leftMouseUp {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                event?.flags = .maskCommand; event?.setIntegerValueField(.eventSourceUserData, value: tag)
                event?.post(tap: .cghidEventTap)
                key?.post(tap: .cghidEventTap)
                return
            }
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.flags = command ? .maskCommand : []
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        event?.setIntegerValueField(.eventSourceUserData, value: tag)
        event?.post(tap: .cghidEventTap)
    }
}
