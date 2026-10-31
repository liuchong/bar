import Foundation

public enum ItemDisposition: String, Codable, CaseIterable, Sendable {
    case untouched, collected, pinned, hidden
    public var title: String {
        switch self { case .untouched: "不管理"; case .collected: "按需收纳"; case .pinned: "始终显示"; case .hidden: "隐藏" }
    }
}

public enum ItemSide: String, Codable, CaseIterable, Sendable {
    case left, right
    public var title: String { self == .left ? "左栏" : "右栏" }
}

public enum ExpansionStyle: String, Codable, CaseIterable, Sendable {
    case left, below
    public var title: String { self == .left ? "向左展开" : "向下展开一行" }
}

public enum ExpansionBehavior: String, Codable, CaseIterable, Sendable {
    case manual, automatic, always
    public var title: String {
        switch self { case .manual: "点击展开 / 收起"; case .automatic: "自动显隐"; case .always: "一直展开" }
    }
}

public struct Configuration: Codable, Equatable, Sendable {
    public var dispositions: [String: ItemDisposition] = [:]
    public var order: [String] = []
    public var sides: [String: ItemSide] = [:]
    public var columnBehaviors: [String: ExpansionBehavior] = [:]
    public var style: ExpansionStyle = .below
    public var behavior: ExpansionBehavior = .manual
    public var hoverDelay: Double = 0.25
    public var hideDelay: Double = 1.2
    public init() {}
    enum CodingKeys: String, CodingKey { case dispositions, order, sides, columnBehaviors, style, behavior, hoverDelay, hideDelay }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dispositions = try values.decodeIfPresent([String: ItemDisposition].self, forKey: .dispositions) ?? [:]
        order = try values.decodeIfPresent([String].self, forKey: .order) ?? []
        sides = try values.decodeIfPresent([String: ItemSide].self, forKey: .sides) ?? [:]
        columnBehaviors = try values.decodeIfPresent([String: ExpansionBehavior].self, forKey: .columnBehaviors) ?? [:]
        style = try values.decodeIfPresent(ExpansionStyle.self, forKey: .style) ?? .below
        behavior = try values.decodeIfPresent(ExpansionBehavior.self, forKey: .behavior) ?? .manual
        hoverDelay = try values.decodeIfPresent(Double.self, forKey: .hoverDelay) ?? 0.25
        hideDelay = try values.decodeIfPresent(Double.self, forKey: .hideDelay) ?? 1.2
    }
    public func behavior(for side: ItemSide) -> ExpansionBehavior { columnBehaviors[side.rawValue] ?? behavior }
    public func expansionConfiguration(for side: ItemSide) -> Configuration {
        var result = self; result.behavior = behavior(for: side); return result
    }
    public func side(for bundle: String) -> ItemSide { sides[bundle] ?? .left }

    public func disposition(for bundle: String) -> ItemDisposition { dispositions[bundle] ?? .untouched }

    public func sorted(_ identifiers: [String]) -> [String] {
        let ranks = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return identifiers.sorted {
            let l = ranks[$0] ?? Int.max, r = ranks[$1] ?? Int.max
            return l == r ? $0.localizedStandardCompare($1) == .orderedAscending : l < r
        }
    }

    public mutating func move(_ identifier: String, before target: String, available: [String]) {
        guard identifier != target else { return }
        var result = sorted(Array(Set(order + available)))
        guard result.contains(identifier), result.contains(target) else { return }
        result.removeAll { $0 == identifier }
        result.insert(identifier, at: result.firstIndex(of: target)!)
        order = result
    }

    public mutating func normalize() {
        order = order.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        hoverDelay = hoverDelay.isFinite ? min(2, max(0.1, hoverDelay)) : 0.25
        hideDelay = hideDelay.isFinite ? min(10, max(0.3, hideDelay)) : 1.2
    }
}

public enum VisibilityPolicy {
    /// Restrictions operate on application identities; system controls and the host always survive.
    public static func allowed(running: Set<String>, configuration: Configuration,
                               temporary: String?, host: String) -> Set<String>? {
        let denied = Set(configuration.dispositions.compactMap { bundle, mode -> String? in
            guard running.contains(bundle), bundle != host, !bundle.hasPrefix("com.apple.") else { return nil }
            return mode == .hidden || (mode == .collected && bundle != temporary) ? bundle : nil
        })
        guard !denied.isEmpty else { return nil }
        return running.subtracting(denied).union([host, "com.apple.MenuBarAgent",
                                                  "com.apple.controlcenter", "com.apple.systemuiserver"])
    }
}

public struct ExpansionState: Sendable {
    public private(set) var expanded = false
    private var enteredAt: Double?
    private var leftAt: Double?
    private var clickCollapsed = false
    public init() {}

    public mutating func configure(_ behavior: ExpansionBehavior) {
        expanded = behavior == .always
        enteredAt = nil; leftAt = nil; clickCollapsed = false
    }

    public mutating func toggle(_ behavior: ExpansionBehavior) {
        guard behavior != .always else { expanded = true; return }
        expanded.toggle()
        clickCollapsed = !expanded
        enteredAt = nil; leftAt = nil
    }

    public mutating func close(_ behavior: ExpansionBehavior) {
        guard behavior != .always else { return }
        expanded = false; clickCollapsed = true
        enteredAt = nil; leftAt = nil
    }

    public mutating func tick(now: Double, inside: Bool, interacting: Bool, configuration: Configuration) {
        guard configuration.behavior == .automatic else { return }
        if interacting { leftAt = nil; return }
        if inside {
            leftAt = nil
            if enteredAt == nil { enteredAt = now }
            if !clickCollapsed && now - (enteredAt ?? now) >= configuration.hoverDelay { expanded = true }
        } else {
            enteredAt = nil; clickCollapsed = false
            if leftAt == nil { leftAt = now }
            if now - (leftAt ?? now) >= configuration.hideDelay { expanded = false }
        }
    }
}

public struct ConfigurationStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        var value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        value.normalize()
        return value
    }
    public func save(_ configuration: Configuration) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: url, options: .atomic)
    }
}
