import AppKit
import ApplicationServices
import BarCore
import OSLog

/// Native items that may need to open a menu belong before Bar. This is a setup operation,
/// never part of opening, closing or periodically refreshing the drawer.
@MainActor
enum NativePlacement {
    private static var arranging = false
    private static var heldPoint: CGPoint?
    static func releaseInput() {
        if let heldPoint { post(.leftMouseUp, at: heldPoint, command: true) }
    }
    @MainActor private struct SettingsFocus {
        weak var window: NSWindow?
        let owners: Set<String>
        init(owners: Set<String>) {
            let key = NSApp?.keyWindow
            window = NSApp?.isActive == true && key?.identifier?.rawValue == "Bar.Settings" ? key : nil
            self.owners = owners.union([Bundle.main.bundleIdentifier ?? "com.liuchong.bar",
                "com.apple.MenuBarAgent", "com.apple.systemuiserver", "com.apple.controlcenter"])
        }
        func restore() {
            guard let app = NSApp, let window, window.isVisible, !window.isMiniaturized, !app.isHidden,
                  !app.isActive || !window.isKeyWindow,
                  let owner = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  owners.contains(owner) else { return }
            // Restore only focus lost to the native placement gesture. An unrelated
            // application chosen by the user must keep its focus.
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            Logger(subsystem: "com.liuchong.bar", category: "Lifecycle").notice("Settings focus restored after native placement")
        }
    }
    /// Pins remain native status items. Reorder only after a configuration or application change.
    static func order(_ items: [MenuItem], side: ItemSide, anchor: @escaping () -> CGRect?,
                      scan: @escaping (String) async -> [MenuItem]) async -> Set<String> {
        guard !items.isEmpty else { return [] }
        for _ in 0..<100 {
            if !arranging { break }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return [] }
        }
        guard !arranging else { return Set(items.map(\.bundle)) }
        arranging = true
        defer { arranging = false }
        var fresh: [String: MenuItem] = [:]
        for bundle in Set(items.map(\.bundle)) { for item in await scan(bundle) { fresh[item.id] = item } }
        func matches(_ bar: CGRect) -> Bool {
            let frames = items.compactMap { fresh[$0.id]?.frame }
            return frames.count == items.count && frames.allSatisfy { frame in
                frame.width > 1 && frame.height > 1 && displayFrames().contains(where: { $0.contains(frame) && $0.contains(bar) }) &&
                abs(frame.midY - bar.midY) < max(frame.height, bar.height) &&
                (side == .left ? frame.maxX <= bar.minX + 1 : frame.minX >= bar.maxX - 1)
            } && zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 1 }
        }
        guard let bar = anchor() else { return Set(items.map(\.bundle)) }
        if matches(bar) { return [] }
        let pointer = CGEvent(source: nil)?.location
        let focus = SettingsFocus(owners: Set(items.map(\.bundle)))
        var inputPosted = false
        var lastPosted: CGPoint?
        defer {
            if let pointer, let lastPosted, let now = CGEvent(source: nil)?.location,
               NSEvent.pressedMouseButtons == 0, hypot(now.x - lastPosted.x, now.y - lastPosted.y) < 8 {
                post(.mouseMoved, at: pointer, command: false)
            }
            if inputPosted { focus.restore() }
        }
        let sequence = side == .left ? items : Array(items.reversed())
        for original in sequence {
            guard !Task.isCancelled else { return [] }
            guard let bar = anchor() else { return Set(items.map(\.bundle)) }
            let entries = await scan(original.bundle)
            guard let item = entries.first(where: { $0.id == original.id }),
                  item.frame.width > 1, item.frame.height > 1,
                  displayFrames().contains(where: { $0.contains(item.frame) && $0.contains(bar) }),
                  abs(item.frame.midY - bar.midY) < max(item.frame.height, bar.height),
                  CGPreflightPostEventAccess(), NSEvent.pressedMouseButtons == 0,
                  NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { continue }
            let source = CGPoint(x: item.frame.midX, y: item.frame.midY)
            let destination = CGPoint(x: side == .left ? bar.minX - 8 : bar.maxX + 8, y: bar.midY)
            post(.mouseMoved, at: source, command: false)
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return [] }
            inputPosted = true
            post(.leftMouseDown, at: source, command: true)
            for step in 1...12 {
                if Task.isCancelled { break }
                let t = CGFloat(step) / 12
                let point = CGPoint(x: source.x + (destination.x - source.x) * t,
                                    y: source.y + (destination.y - source.y) * t)
                post(.leftMouseDragged, at: point, command: true); lastPosted = point
                try? await Task.sleep(for: .milliseconds(16))
            }
            post(.leftMouseUp, at: destination, command: true)
            try? await Task.sleep(for: .milliseconds(180))
        }
        fresh = [:]
        for bundle in Set(items.map(\.bundle)) { for item in await scan(bundle) { fresh[item.id] = item } }
        if let bar = anchor(), matches(bar) { return [] }
        return Set(items.map(\.bundle))
    }

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
        let focus = SettingsFocus(owners: Set(items.map(\.bundle)))
        var inputPosted = false
        var lastPosted: CGPoint?
        defer {
            if let pointer, let lastPosted, let now = CGEvent(source: nil)?.location,
               NSEvent.pressedMouseButtons == 0, hypot(now.x - lastPosted.x, now.y - lastPosted.y) < 8 {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pointer, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            if inputPosted { focus.restore() }
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
                guard !Task.isCancelled else { return safe }
                inputPosted = true
                post(.leftMouseDown, at: source, command: true)
                for step in 1...12 {
                    if Task.isCancelled { break }
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
        let source = CGEventSource(stateID: .combinedSessionState)
        if command && type == .leftMouseDown {
            let key = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
            key?.flags = .maskCommand; key?.post(tap: .cghidEventTap)
            heldPoint = point
        }
        if type == .leftMouseDragged && heldPoint != nil { heldPoint = point }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        event?.flags = command ? .maskCommand : []
        event?.post(tap: .cghidEventTap)
        if command && type == .leftMouseUp {
            let key = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)
            key?.flags = []; key?.post(tap: .cghidEventTap)
            heldPoint = nil
        }
    }
}
