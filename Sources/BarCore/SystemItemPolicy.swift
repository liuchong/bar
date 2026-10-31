import Foundation

/// System item identifiers verified against the current macOS menu-bar framework.
public enum SystemItemPolicy {
    public static let prefix = "com.apple.menuextra."
    public static let identifiers: [String: Int] = [
        prefix + "battery": 0, prefix + "bluetooth": 1, prefix + "clock": 2,
        prefix + "displays": 3, prefix + "textinput": 4, prefix + "volume": 5,
        prefix + "wifi": 6, prefix + "screenmirroring": 7, prefix + "controlcenter": 8
    ]
    public static func isSystem(_ id: String) -> Bool { id.hasPrefix(prefix) }
    public static func isManageable(_ id: String) -> Bool {
        identifiers[id] != nil && id != prefix + "clock" && id != prefix + "controlcenter"
    }
    public static func canonical(_ id: String) -> String {
        switch id {
        case prefix + "sound": prefix + "volume"
        case prefix + "display": prefix + "displays"
        case prefix + "keyboard": prefix + "textinput"
        default: id
        }
    }
    public static func title(_ id: String) -> String {
        switch id {
        case prefix + "battery": "电池"
        case prefix + "bluetooth": "蓝牙"
        case prefix + "clock": "时钟"
        case prefix + "displays": "显示器"
        case prefix + "textinput": "输入法"
        case prefix + "volume": "声音"
        case prefix + "wifi": "Wi-Fi"
        case prefix + "screenmirroring": "屏幕镜像"
        case prefix + "controlcenter": "控制中心"
        default: id
        }
    }
    public static func symbol(_ id: String) -> String {
        switch id {
        case prefix + "battery": "battery.100percent"
        case prefix + "bluetooth": "antenna.radiowaves.left.and.right"
        case prefix + "clock": "clock"
        case prefix + "displays": "display"
        case prefix + "textinput": "keyboard"
        case prefix + "volume": "speaker.wave.2"
        case prefix + "wifi": "wifi"
        case prefix + "screenmirroring": "rectangle.on.rectangle"
        case prefix + "controlcenter": "switch.2"
        default: "gearshape"
        }
    }
    public static func allowed(configuration: Configuration, temporary: Set<String> = []) -> Set<Int> {
        var allowed = Set(0..<64)
        guard configuration.manageSystemIcons else { return allowed }
        for (id, number) in identifiers where isManageable(id) {
            let mode = configuration.disposition(for: id)
            if mode == .hidden || (mode == .collected && !temporary.contains(id)) { allowed.remove(number) }
        }
        return allowed
    }
}
