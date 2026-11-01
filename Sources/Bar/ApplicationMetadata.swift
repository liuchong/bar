import AppKit

@MainActor
struct ApplicationMetadata {
    let name: String
    let icon: NSImage

    static func resolve(_ identifier: String, applicationDirectories: [URL]? = nil) -> ApplicationMetadata? {
        var candidate = identifier
        // Menu-bar helpers can be registered under a child identity of their installed application.
        while !candidate.isEmpty {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) {
                return load(at: url)
            }
            guard let separator = candidate.lastIndex(of: ".") else { break }
            candidate = String(candidate[..<separator])
        }
        // Launch Services can miss unregistered or recently installed applications.
        // Search application directories only, skipping package contents and hidden files.
        let roots = applicationDirectories ?? FileManager.default.urls(for: .applicationDirectory,
            in: [.userDomainMask, .localDomainMask, .systemDomainMask])
        for root in roots {
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in entries {
                if entries.level > 3 { entries.skipDescendants(); continue }
                guard url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier,
                      identifier == id || identifier.hasPrefix(id + ".") else { continue }
                if let metadata = load(at: url) { return metadata }
            }
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
