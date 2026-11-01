import AppKit
import ApplicationServices
import BarCore
import OSLog

/// Native items that may need to open a menu belong before Bar. This is a setup operation,
/// never part of opening, closing or periodically refreshing the drawer.
@MainActor
enum NativePlacement {
    private static var arranging = false
    static func releaseInput() { NativePointer.cancel() }
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
    /// Move our own entry before the preserved native band, without dragging its icons.
    static func moveEntry(before bundles: Set<String>, anchor: @escaping () -> CGRect?,
                          scan: @escaping (String) async -> [MenuItem]) async -> Bool {
        for _ in 0..<100 {
            if !arranging { break }
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return false }
        }
        guard !arranging, !Task.isCancelled else { return false }
        arranging = true
        defer { arranging = false }
        func preserved() async -> [MenuItem] {
            var result: [MenuItem] = []
            for bundle in bundles { result += await scan(bundle) }
            return result
        }
        guard let bar = anchor() else { return false }
        let displays = displayFrames()
        let items = await preserved()
        let row = items.filter { item in item.frame.width > 1 && item.frame.height > 1 &&
            abs(item.frame.midY - bar.midY) < max(item.frame.height, bar.height) &&
            displays.contains(where: { $0.contains(item.frame) && $0.contains(bar) }) }
        guard Set(row.map(\.bundle)) == bundles, let first = row.map(\.frame.minX).min() else { return false }
        if first >= bar.maxX - 1 { return true }
        guard displays.contains(where: { $0.contains(bar) }), CGPreflightPostEventAccess(),
              NSEvent.pressedMouseButtons == 0,
              NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        let source = CGPoint(x: bar.midX, y: bar.midY)
        let destination = CGPoint(x: first - 8, y: bar.midY)
        guard displays.contains(where: { $0.contains(destination) }) else { return false }
        let focus = SettingsFocus(owners: [])
        let moved = await NativePointer.drag(from: source, to: destination)
        guard moved else { return false }
        defer { focus.restore() }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled, let updated = anchor() else { return false }
        let refreshed = await preserved().filter { item in item.frame.width > 1 && item.frame.height > 1 &&
            abs(item.frame.midY - updated.midY) < max(item.frame.height, updated.height) &&
            displays.contains(where: { $0.contains(item.frame) && $0.contains(updated) }) }
        return Set(refreshed.map(\.bundle)) == Set(row.map(\.bundle)) && refreshed.allSatisfy {
            $0.frame.width > 1 && $0.frame.minX >= updated.maxX - 1
        }
    }
    /// Pins remain native status items. Reorder only after a configuration or application change.
    static func order(_ items: [MenuItem], side: ItemSide, preservedIDs: Set<String> = [], anchor: @escaping () -> CGRect?,
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
            // System controls can have overlapping accessibility hit rectangles.
            // Their centers establish native order; hit padding is not visual overlap.
            } && zip(frames, frames.dropFirst()).allSatisfy { $0.midX < $1.midX }
        }
        guard let bar = anchor() else { return Set(items.map(\.bundle)) }
        if matches(bar) { return [] }
        let displays = displayFrames()
        let blockedPreserved = items.filter { original in
            guard preservedIDs.contains(original.id) else { return false }
            guard let item = fresh[original.id] else { return true }
            return item.frame.width <= 1 || item.frame.height <= 1 || item.frame.minX < bar.maxX - 1 ||
                abs(item.frame.midY - bar.midY) >= max(item.frame.height, bar.height) ||
                !displays.contains(where: { $0.contains(item.frame) && $0.contains(bar) })
        }
        guard blockedPreserved.isEmpty else { return Set(blockedPreserved.map(\.bundle)) }
        let focus = SettingsFocus(owners: Set(items.map(\.bundle)))
        var restoreFocus = false
        defer { if restoreFocus { focus.restore() } }
        let movable = items.filter { !preservedIDs.contains($0.id) }
        let sequence = side == .left ? movable : Array(movable.reversed())
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
            guard await NativePointer.drag(from: source, to: destination) else { restoreFocus = false; break }
            restoreFocus = true
            try? await Task.sleep(for: .milliseconds(180))
        }
        fresh = [:]
        for bundle in Set(items.map(\.bundle)) { for item in await scan(bundle) { fresh[item.id] = item } }
        if let bar = anchor() {
            if matches(bar) { return [] }
            let positions = items.enumerated().map { index, original in
                "\(index):\(fresh[original.id]?.frame.minX ?? -1):\(fresh[original.id]?.frame.width ?? 0)"
            }.joined(separator: ",")
            Logger(subsystem: "com.liuchong.bar", category: "Ordering").notice("Order mismatch \(side.rawValue, privacy: .public) bar=\(bar.minX)-\(bar.maxX) entries=\(positions, privacy: .public)")
        }
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
        let focus = SettingsFocus(owners: Set(items.map(\.bundle)))
        var restoreFocus = false
        defer { if restoreFocus { focus.restore() } }
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
                guard await NativePointer.drag(from: source, to: destination) else { restoreFocus = false; succeeded = false; break }
                restoreFocus = true
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

}
