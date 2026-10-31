import Foundation
import AppKit
import ApplicationServices
import Testing
import BarCore
@testable import Bar

@Suite("Managed left and right columns")
struct ManagedColumnsIntegrationTests {
    @Test @MainActor func movingWithinOneColumnKeepsTheOtherColumnsOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        let model = AppModel(store: store, imageAuthorization: { false })
        model.paused = true
        defer { model.shutdown() }
        let ids = ["left.a", "right.a", "unmanaged", "left.b", "right.b"]
        model.configuration.order = ids
        model.configuration.dispositions = Dictionary(uniqueKeysWithValues: ids.filter { $0 != "unmanaged" }.map { ($0, .collected) })
        model.configuration.sides = ["right.a": .right, "right.b": .right]
        model.items = ids.map { id in
            MenuItem(id: id, bundle: id, appName: id, label: id, icon: NSImage(),
                element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                frame: .zero, pid: ProcessInfo.processInfo.processIdentifier)
        }
        #expect(!model.canMove("left.a", direction: -1))
        #expect(!model.canMove("unmanaged", direction: 1))
        model.move("unmanaged", direction: 1)
        #expect(model.configuration.order == ids)
        model.move("left.b", direction: -1)
        #expect(model.configuration.sorted(ids) == ["left.b", "right.a", "unmanaged", "left.a", "right.b"])
        #expect(try store.load() == model.configuration)
    }

    @Test @MainActor func unavailableAnchorDoesNotReportSortingSuccess() async {
        let item = MenuItem(id: "app.pin#0", bundle: "app.pin", appName: "Pin", label: "Pin", icon: NSImage(),
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
            frame: CGRect(x: 100, y: 0, width: 24, height: 24), pid: ProcessInfo.processInfo.processIdentifier)
        let failed = await NativePlacement.order([item], side: .right, anchor: { nil }, scan: { _ in [item] })
        #expect(failed == ["app.pin"])
    }

    @Test func legacyPreferencesMigrateWithoutLosingRulesOrOrder() throws {
        let data = Data(#"{"dispositions":{"a":"collected","b":"hidden"},"order":["b","a"],"style":"left","behavior":"automatic","hoverDelay":0.3,"hideDelay":2}"#.utf8)
        let configuration = try JSONDecoder().decode(Configuration.self, from: data)
        #expect(configuration.side(for: "a") == .left)
        #expect(configuration.disposition(for: "a") == .collected)
        #expect(configuration.disposition(for: "b") == .hidden)
        #expect(configuration.order == ["b", "a"])
        #expect(configuration.style == .left)
        #expect(configuration.behavior == .automatic)
    }

    @Test func bothColumnsMixPinnedAndCollectedAndSurviveRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        var configuration = Configuration()
        configuration.dispositions = ["left.pin": .pinned, "right.pin": .pinned,
            "left.collect": .collected, "right.collect": .collected, "hidden": .hidden]
        configuration.sides = ["right.pin": .right, "right.collect": .right]
        configuration.order = ["right.pin", "left.collect", "left.pin", "right.collect"]
        try store.save(configuration)
        let restored = try store.load()
        #expect(restored == configuration)
        let running: Set<String> = ["left.pin", "right.pin", "left.collect", "right.collect", "hidden", "untouched"]
        let allowed = try #require(VisibilityPolicy.allowed(running: running, configuration: restored, temporary: nil, host: "bar.host"))
        #expect(allowed.isSuperset(of: ["left.pin", "right.pin", "untouched"]))
        #expect(allowed.isDisjoint(with: ["left.collect", "right.collect", "hidden"]))
        #expect(restored.sorted(Array(running)).filter { restored.side(for: $0) == .right } == ["right.pin", "right.collect"])
        #expect(restored.sorted(Array(running)).filter { restored.disposition(for: $0) == .pinned } == ["right.pin", "left.pin"])
    }

    @Test func independentColumnBehaviorsPersistAndKeepSeparateExpansionStates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        var configuration = Configuration()
        configuration.behavior = .manual
        #expect(configuration.behavior(for: .left) == .manual)
        #expect(configuration.behavior(for: .right) == .manual)
        configuration.columnBehaviors = ["left": .automatic, "right": .always]
        try store.save(configuration)
        let restored = try store.load()
        #expect(restored == configuration)
        var left = ExpansionState(), right = ExpansionState()
        left.configure(restored.behavior(for: .left)); right.configure(restored.behavior(for: .right))
        for time in [0.0, 1.0, 3.0] {
            left.tick(now: time, inside: true, interacting: false, configuration: restored.expansionConfiguration(for: .left))
            right.tick(now: time, inside: true, interacting: false, configuration: restored.expansionConfiguration(for: .right))
        }
        #expect(left.expanded && right.expanded)
        for time in [4.0, 8.0] {
            left.tick(now: time, inside: false, interacting: false, configuration: restored.expansionConfiguration(for: .left))
            right.tick(now: time, inside: false, interacting: false, configuration: restored.expansionConfiguration(for: .right))
        }
        #expect(!left.expanded && right.expanded)
        right.close(restored.behavior(for: .right))
        #expect(right.expanded)
        let legacy = try JSONDecoder().decode(Configuration.self, from: Data(#"{"behavior":"automatic"}"#.utf8))
        #expect(ItemSide.allCases.allSatisfy { legacy.behavior(for: $0) == .automatic })
    }

    @Test func orderingIsIndependentOfApplicationLaunchOrder() {
        var configuration = Configuration()
        configuration.order = ["b", "a", "c"]
        configuration.sides = ["a": .right, "b": .right]
        configuration.dispositions = ["a": .pinned, "b": .pinned, "c": .collected]
        for launchOrder in [["a", "b", "c"], ["c", "b", "a"], ["b", "c", "a"]] {
            #expect(configuration.sorted(launchOrder) == ["b", "a", "c"])
        }
    }
}
