import AppKit
import ApplicationServices

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
        return CGRect(origin: point, size: size)
    }
    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return names as? [String] ?? []
    }
    /// Runs on a serial worker. A timeout bounds each app's IPC; own app is deliberately excluded.
    static func scan(_ apps: [NSRunningApplication]) -> [MenuItem] {
        var items: [MenuItem] = []
        for app in apps where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            guard let bundle = app.bundleIdentifier else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.08)
            guard let raw = value(root, "AXExtrasMenuBar"), CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let bar = raw as! AXUIElement
            for (index, container) in children(bar).enumerated() {
                let element = actions(container).isEmpty ? (children(container).first ?? container) : container
                AXUIElementSetMessagingTimeout(element, 0.08)
                let description = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
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
