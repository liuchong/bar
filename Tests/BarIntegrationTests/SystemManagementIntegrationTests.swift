import Foundation
import Testing
import BarCore
@testable import Bar

@Suite("System management and independent saved choices")
struct SystemManagementIntegrationTests {
    @Test @MainActor func disablingSystemManagementRetainsEverySavedRuleAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        let battery = "com.apple.menuextra.battery", wifi = "com.apple.menuextra.wifi"
        var original = Configuration()
        original.manageSystemIcons = true
        original.dispositions = [battery: .collected, wifi: .pinned, "app.collect": .collected]
        original.sides = [battery: .right, wifi: .left]
        original.order = [wifi, "app.collect", battery]
        original.ignored = [battery: false, wifi: false]
        try store.save(original)
        let model = AppModel(store: store, imageAuthorization: { false })
        model.paused = true; model.trusted = false
        defer { model.shutdown() }
        model.setSystemManagement(false)
        let disabled = try store.load()
        #expect(!disabled.manageSystemIcons)
        #expect(disabled.dispositions == original.dispositions)
        #expect(disabled.sides == original.sides)
        #expect(disabled.ignored == original.ignored)
        #expect(disabled.order == original.order)
        #expect(disabled.disposition(for: battery) == .untouched)
        #expect(disabled.placement(for: battery) == .right)
        #expect(disabled.display(for: wifi) == .shown)
        #expect(SystemItemPolicy.allowed(configuration: disabled) == Set(0..<64))
        let restarted = AppModel(store: store, imageAuthorization: { false })
        restarted.paused = true; restarted.trusted = false
        defer { restarted.shutdown() }
        restarted.setSystemManagement(true)
        #expect(try store.load() == original)
        #expect(!SystemItemPolicy.allowed(configuration: restarted.configuration).contains(0))
        #expect(SystemItemPolicy.allowed(configuration: restarted.configuration).contains(6))
    }

    @Test @MainActor func ignoringAndRestoringAPlacementKeepsDisplayChoiceAndSavesImmediately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        let model = AppModel(store: store, imageAuthorization: { false })
        model.paused = true; model.trusted = false
        defer { model.shutdown() }
        model.setPlacement("app.one", .right)
        model.setItemDisplay("app.one", .shown)
        model.setPlacement("app.one", .ignored)
        #expect(model.configuration.disposition(for: "app.one") == .untouched)
        #expect(model.configuration.display(for: "app.one") == .shown)
        #expect(model.configuration.side(for: "app.one") == .right)
        #expect(try store.load() == model.configuration)
        model.setPlacement("app.one", .left)
        #expect(model.configuration.disposition(for: "app.one") == .pinned)
        model.setItemDisplay("app.one", .hidden)
        #expect(model.configuration.disposition(for: "app.one") == .collected)
        #expect(try store.load() == model.configuration)
    }

    @Test func systemAndApplicationVisibilityPoliciesStayIndependentAndProtectFixedEntrypoints() throws {
        let wifi = "com.apple.menuextra.wifi"
        var configuration = Configuration()
        configuration.manageSystemIcons = true
        configuration.dispositions = [wifi: .collected, "app.hide": .collected,
            "com.apple.menuextra.clock": .collected, "com.apple.menuextra.controlcenter": .hidden]
        let applicationAllowed = try #require(VisibilityPolicy.allowed(running: ["app.hide", "app.show"],
            configuration: configuration, temporary: nil, host: "bar.host"))
        #expect(applicationAllowed.contains("app.show"))
        #expect(!applicationAllowed.contains("app.hide"))
        let systemAllowed = SystemItemPolicy.allowed(configuration: configuration)
        #expect(!systemAllowed.contains(6))
        #expect(systemAllowed.contains(2) && systemAllowed.contains(8))
        #expect(SystemItemPolicy.allowed(configuration: configuration, temporary: [wifi]).contains(6))
        configuration.manageSystemIcons = false
        #expect(VisibilityPolicy.allowed(running: ["app.hide", "app.show"], configuration: configuration,
            temporary: nil, host: "bar.host") == applicationAllowed)
        #expect(SystemItemPolicy.allowed(configuration: configuration).count == 64)
    }

    @Test func preparationKeepsOnlyNewlyManagedOriginalsVisibleUntilCaptureCompletes() throws {
        var configuration = Configuration()
        configuration.dispositions = ["app.new": .collected, "app.old": .collected]
        let allowed = try #require(VisibilityPolicy.allowed(running: ["app.new", "app.old"],
            configuration: configuration, temporary: nil, host: "bar.host", preparing: ["app.new"]))
        #expect(allowed.contains("app.new"))
        #expect(!allowed.contains("app.old"))
    }
}
