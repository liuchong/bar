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
        let command: Bool
        let right: Bool
        var pressed = false
        let source = CGEventSource(stateID: .hidSystemState)
        init(origin: CGPoint, source: CGPoint, display: CGDirectDisplayID, command: Bool, right: Bool) {
            self.origin = origin; self.point = source; self.display = display
            self.command = command; self.right = right
        }
    }
    private static var session: Session?

    static func cancel() {
        guard let current = session else { return }
        session = nil
        if current.pressed { post(current.right ? .rightMouseUp : .leftMouseUp, at: current.point, command: current.command, source: current.source) }
        for monitor in current.monitors { NSEvent.removeMonitor(monitor) }
        let destination = CGPoint(x: current.origin.x + current.delta.x, y: current.origin.y + current.delta.y)
        CGWarpMouseCursorPosition(destination)
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(current.display)
        let restored = CGEvent(source: nil)?.location ?? destination
        Logger(subsystem: "com.liuchong.bar", category: "Ordering").notice("Pointer restored; error=\(hypot(restored.x - destination.x, restored.y - destination.y))")
    }

    private static func begin(at source: CGPoint, command: Bool, right: Bool = false) async -> Session? {
        // Bounded idle wait, including mouse movement inside our settings window.
        var previous = CGEvent(source: nil)?.location, stable = 0
        for _ in 0..<100 {
            guard !Task.isCancelled else { return nil }
            let now = CGEvent(source: nil)?.location
            let idle = now == previous && NSEvent.pressedMouseButtons == 0 &&
                NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            stable = idle ? stable + 1 : 0
            previous = now
            if stable >= 7 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard stable >= 7, !Task.isCancelled, session == nil,
              let origin = CGEvent(source: nil)?.location else { return nil }
        let display = CGMainDisplayID()
        guard CGDisplayHideCursor(display) == .success else { return nil }
        guard CGAssociateMouseAndMouseCursorPosition(0) == .success else {
            CGDisplayShowCursor(display); return nil
        }
        let current = Session(origin: origin, source: source, display: display, command: command, right: right)
        session = current
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
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
        return current
    }

    static func click(at point: CGPoint, right: Bool) async -> Bool {
        guard let current = await begin(at: point, command: false, right: right) else { return false }
        defer { if session === current { cancel() } }
        post(.mouseMoved, at: point, command: false)
        try? await Task.sleep(for: .milliseconds(30))
        guard session === current, !Task.isCancelled else { return false }
        current.pressed = true
        post(right ? .rightMouseDown : .leftMouseDown, at: point, command: false)
        try? await Task.sleep(for: .milliseconds(20))
        return session === current && !Task.isCancelled
    }

    static func drag(from source: CGPoint, to destination: CGPoint) async -> Bool {
        guard let current = await begin(at: source, command: true) else { return false }
        defer { if session === current { cancel() } }
        post(.mouseMoved, at: source, command: false)
        try? await Task.sleep(for: .milliseconds(30))
        guard session === current, !Task.isCancelled else { return false }
        current.pressed = true
        post(.leftMouseDown, at: source, command: true)
        try? await Task.sleep(for: .milliseconds(60))
        for step in 1...12 {
            guard session === current, !Task.isCancelled else { return false }
            let t = CGFloat(step) / 12
            current.point = CGPoint(x: source.x + (destination.x - source.x) * t,
                                    y: source.y + (destination.y - source.y) * t)
            post(.leftMouseDragged, at: current.point, command: true)
            try? await Task.sleep(for: .milliseconds(12))
        }
        return session === current && !Task.isCancelled
    }

    private static func post(_ type: CGEventType, at point: CGPoint, command: Bool, source explicitSource: CGEventSource? = nil) {
        let source = explicitSource ?? session?.source ?? CGEventSource(stateID: .hidSystemState)
        // With the physical mouse disconnected, event coordinates alone do not
        // advance the cursor used by the menu-bar drag manager. Warp while hidden;
        // physical input still cancels the transaction and restores the user's point.
        if session != nil { CGWarpMouseCursorPosition(point) }
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents,
            .permitSystemDefinedEvents], state: .eventSuppressionStateRemoteMouseDrag)
        if command && (type == .leftMouseDown || type == .leftMouseUp) {
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
        let button: CGMouseButton = type == .rightMouseDown || type == .rightMouseUp ? .right : .left
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.flags = command ? .maskCommand : []
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        event?.setIntegerValueField(.eventSourceUserData, value: tag)
        event?.post(tap: .cghidEventTap)
    }
}
