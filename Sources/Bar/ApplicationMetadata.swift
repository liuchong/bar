import AppKit

@MainActor
struct ApplicationMetadata {
    let name: String
    let icon: NSImage

    static func resolve(_ identifier: String) -> ApplicationMetadata? {
        var candidate = identifier
        // Menu-bar helpers can be registered under a child identity of their installed application.
        while candidate.split(separator: ".").count >= 3 {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) {
                return load(at: url)
            }
            guard let separator = candidate.lastIndex(of: ".") else { break }
            candidate = String(candidate[..<separator])
        }
        return nil
    }

    static func load(at url: URL) -> ApplicationMetadata? {
        var application = url, parent = url.deletingLastPathComponent()
        while parent.pathComponents.count > 1 {
            if parent.pathExtension == "app" { application = parent }
            parent.deleteLastPathComponent()
        }
        guard let bundle = Bundle(url: application) else { return nil }
        let name = ["CFBundleDisplayName", "CFBundleName"].compactMap {
            bundle.object(forInfoDictionaryKey: $0) as? String
        }.first(where: { !$0.isEmpty }) ?? application.deletingPathExtension().lastPathComponent
        return ApplicationMetadata(name: name, icon: NSWorkspace.shared.icon(forFile: application.path))
    }
}
