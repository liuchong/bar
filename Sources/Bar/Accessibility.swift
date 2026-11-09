import AppKit
import ApplicationServices
import BarCore

struct MenuItem: Identifiable {
    let id: String
    let bundle: String
    let appName: String
    let label: String
    let icon: NSImage
    let element: AXUIElement
    let frame: CGRect
    let pid: pid_t
}

enum MenuAccessibility {
    // These hosts expose the same controls through AXExtrasMenuBar and the
    // system-item tree. Only the latter has individual, persistent identities.
    static let systemHosts: Set<String> = ["com.apple.MenuBarAgent", "com.apple.TextInputMenuAgent",
        "com.apple.controlcenter", "com.apple.systemuiserver"]
    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    static func text(_ element: AXUIElement, _ name: String) -> String {
        value(element, name) as? String ?? ""
    }
    static func frame(_ element: AXUIElement) -> CGRect {
        var point = CGPoint.zero, size = CGSize.zero
        if let raw = value(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(raw as! AXValue, .cgPoint, &point)
        }
        if let raw = value(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            AXValueGetValue(raw as! AXValue, .cgSize, &size)
        }
        guard [point.x, point.y, size.width, size.height].allSatisfy(\.isFinite),
              abs(point.x) < 1_000_000_000, abs(point.y) < 1_000_000_000,
              size.width >= 0, size.height >= 0, size.width < 1_000_000, size.height < 1_000_000 else { return .zero }
        return CGRect(origin: point, size: size)
    }
    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return names as? [String] ?? []
    }
    /// Runs on a serial worker. A timeout bounds each app's IPC; own app and Apple system daemons are excluded.
    static func scan(_ apps: [NSRunningApplication]) -> [MenuItem] {
        var items: [MenuItem] = []
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for app in apps where app.processIdentifier != selfPID && app.activationPolicy != .prohibited {
            guard let bundle = app.bundleIdentifier,
                  !bundle.hasPrefix("com.apple."),
                  !systemHosts.contains(bundle) else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.12)
            guard let raw = value(root, "AXExtrasMenuBar"), CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let bar = raw as! AXUIElement
            for (index, container) in children(bar).enumerated() {
                let element = actions(container).isEmpty ? (children(container).first ?? container) : container
                AXUIElementSetMessagingTimeout(element, 0.12)
                let description = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .map { text(element, $0).components(separatedBy: .newlines).first ?? "" }
                    .first { !$0.isEmpty } ?? ""
                let appName = app.localizedName ?? bundle
                items.append(MenuItem(id: "\(bundle)#\(index)", bundle: bundle, appName: appName,
                                      label: description.isEmpty ? appName : description,
                                      icon: app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!,
                                      element: element, frame: frame(element), pid: app.processIdentifier))
            }
        }
        return items
    }
    /// System controls have individual identities even though they share one owning process.
    static func systemIdentifier(_ id: String, label: String, role: String, inputSourceNames: Set<String>) -> String? {
        if SystemItemPolicy.isSystem(id) { return SystemItemPolicy.canonical(id) }
        if [kAXButtonRole, kAXMenuBarItemRole].contains(role), !label.isEmpty, inputSourceNames.contains(label) {
            return SystemItemPolicy.prefix + "textinput"
        }
        return nil
    }
    static func systemItems(_ apps: [NSRunningApplication], inputSourceNames: Set<String> = []) -> [MenuItem] {
        guard let agent = apps.first(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" }) else { return [] }
        let root = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.08)
        var pending = [root], visited: [AXUIElement] = [], result: [String: MenuItem] = [:]
        for _ in 0..<4 {
            var next: [AXUIElement] = []
            for element in pending.prefix(128) where visited.count < 128 {
                guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
                visited.append(element)
                AXUIElementSetMessagingTimeout(element, 0.08)
                let id = text(element, kAXIdentifierAttribute)
                let label = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].map {
                    text(element, $0).components(separatedBy: .newlines).first ?? ""
                }.first { !$0.isEmpty } ?? ""
                if let key = systemIdentifier(id, label: label, role: text(element, kAXRoleAttribute), inputSourceNames: inputSourceNames) {
                    let knownTitle = SystemItemPolicy.title(key)
                    let title = knownTitle == key && !label.isEmpty ? label : knownTitle
                    result[key] = MenuItem(id: key, bundle: key, appName: title, label: label.isEmpty ? title : label,
                        icon: NSImage(systemSymbolName: SystemItemPolicy.symbol(key), accessibilityDescription: title) ?? NSImage(),
                        element: element, frame: frame(element), pid: agent.processIdentifier)
                } else {
                    next += children(element)
                    next += value(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
                }
            }
            pending = next
            if pending.isEmpty || visited.count >= 128 { break }
        }
        return result.values.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }
    static func press(_ item: MenuItem, right: Bool) -> AXError {
        AXUIElementSetMessagingTimeout(item.element, 0.15)
        let action = right && actions(item.element).contains(kAXShowMenuAction) ? kAXShowMenuAction : kAXPressAction
        return AXUIElementPerformAction(item.element, action as CFString)
    }
    static func hasOpenMenu(_ item: MenuItem) -> Bool {
        children(item.element).contains {
            text($0, kAXRoleAttribute) == kAXMenuRole && frame($0).width > 0
        }
    }
}
