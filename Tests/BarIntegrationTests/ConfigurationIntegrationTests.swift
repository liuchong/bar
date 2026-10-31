import Foundation
import CoreGraphics
import Testing
import BarCore

@Suite("Configuration and visibility integration")
struct ConfigurationIntegrationTests {
    @Test func savedChoicesDriveBothExpansionStyles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("Bar/settings.json"))
        var configuration = try store.load()
        configuration.dispositions = ["app.collect": .collected, "app.hide": .hidden, "app.keep": .untouched]
        configuration.order = ["app.keep", "app.collect", "app.hide"]
        configuration.behavior = .automatic
        for style in ExpansionStyle.allCases {
            configuration.style = style
            try store.save(configuration)
            let restored = try store.load()
            #expect(restored == configuration)
            let running: Set<String> = ["app.collect", "app.hide", "app.keep", "app.new", "bar.host"]
            let collapsed = try #require(VisibilityPolicy.allowed(running: running, configuration: restored,
                temporary: nil, host: "bar.host"))
            #expect(collapsed.isSuperset(of: ["app.keep", "app.new", "bar.host"]))
            #expect(!collapsed.contains("app.collect") && !collapsed.contains("app.hide"))
            let expanded = try #require(VisibilityPolicy.allowed(running: running, configuration: restored,
                temporary: nil, host: "bar.host"))
            #expect(!expanded.contains("app.collect"))
            #expect(!expanded.contains("app.hide"))
            let opening = try #require(VisibilityPolicy.allowed(running: running, configuration: restored,
                temporary: "app.collect", host: "bar.host"))
            #expect(opening.contains("app.collect") && !opening.contains("app.hide"))
        }
    }

    @Test func automaticInteractionDrivesPolicy() throws {
        var configuration = Configuration()
        configuration.behavior = .automatic; configuration.style = .left
        configuration.dispositions["app.collect"] = .collected
        configuration.hoverDelay = 0.2; configuration.hideDelay = 0.8
        var state = ExpansionState(); state.configure(.automatic)
        let running: Set<String> = ["app.collect", "app.keep"]
        state.tick(now: 0, inside: true, interacting: false, configuration: configuration)
        state.tick(now: 0.3, inside: true, interacting: false, configuration: configuration)
        #expect(state.expanded)
        // Custom presentation keeps originals out of the system overflow even while expanded.
        #expect(VisibilityPolicy.allowed(running: running, configuration: configuration,
            temporary: nil, host: "bar.host")?.contains("app.collect") == false)
        state.tick(now: 1, inside: false, interacting: true, configuration: configuration)
        state.tick(now: 8, inside: false, interacting: true, configuration: configuration)
        #expect(state.expanded)
        state.tick(now: 9, inside: false, interacting: false, configuration: configuration)
        state.tick(now: 10, inside: false, interacting: false, configuration: configuration)
        #expect(!state.expanded)
        #expect(VisibilityPolicy.allowed(running: running, configuration: configuration,
            temporary: nil, host: "bar.host")?.contains("app.collect") == false)
    }

    @Test func orderingSurvivesRestartAndRetainsOfflineApplications() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        var configuration = Configuration()
        configuration.order = ["offline", "b", "a"]
        configuration.move("a", before: "b", available: ["a", "b", "new"])
        try store.save(configuration)
        let restored = try store.load()
        #expect(restored.order == ["offline", "a", "b", "new"])
        #expect(restored.sorted(["b", "new", "a"]) == ["a", "b", "new"])
    }

    @Test func savedOrderSpansBothSidesOfCameraWithoutNativeOverflow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        var configuration = Configuration()
        configuration.style = .left; configuration.behavior = .always
        let ids = (0..<24).map { "app.\($0)" }
        configuration.order = Array(ids.reversed())
        for id in ids { configuration.dispositions[id] = .collected }
        try store.save(configuration)
        let restored = try store.load()
        var state = ExpansionState(); state.configure(restored.behavior)
        #expect(state.expanded)
        let ordered = restored.sorted(ids)
        let screen = CGRect(x: 1440, y: -900, width: 1440, height: 900)
        let camera = CGRect(x: 2080, y: -32, width: 160, height: 32)
        let positions = DrawerLayout.left(widths: ordered.map { _ in 30 }, screen: screen,
            anchor: CGRect(x: 2700, y: -32, width: 30, height: 32), cutout: camera, height: 32)
        #expect(positions.count == ids.count)
        #expect(positions.contains { $0.frame.minX < camera.minX })
        #expect(positions.contains { $0.frame.minX > camera.maxX })
        for position in positions {
            #expect(screen.contains(position.frame))
            #expect(!position.frame.intersects(camera))
        }
        let allowed = try #require(VisibilityPolicy.allowed(running: Set(ids + ["app.keep"]),
            configuration: restored, temporary: nil, host: "bar.host"))
        #expect(allowed.contains("app.keep"))
        #expect(Set(ids).isDisjoint(with: allowed))
        #expect(ordered == Array(ids.reversed()))
    }

    @Test func nativeMenuCanOnlyTemporarilyRevealVerifiedLeftItems() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = CGRect(x: 1000, y: 0, width: 28, height: 32)
        var configuration = Configuration()
        configuration.dispositions = ["app.collect": .collected, "app.hide": .hidden]
        let running: Set<String> = ["app.collect", "app.hide", "app.keep"]
        for original in [CGRect(x: 968, y: 0, width: 30, height: 32), CGRect(x: 1040, y: 0, width: 30, height: 32)] {
            let safe = StableMenuBar.canReveal(originals: [original], anchor: anchor, displays: [screen])
            let allowed = try #require(VisibilityPolicy.allowed(running: running, configuration: configuration,
                temporary: safe ? "app.collect" : nil, host: "bar.host"))
            #expect(allowed.contains("app.collect") == (original.maxX <= anchor.minX))
            #expect(allowed.contains("app.keep"))
            #expect(!allowed.contains("app.hide"))
        }
    }

    @Test func corruptSettingsAreReportedAndPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        let corrupt = Data("{bad configuration}".utf8)
        try corrupt.write(to: url)
        #expect(throws: (any Error).self) { try ConfigurationStore(url: url).load() }
        #expect(try Data(contentsOf: url) == corrupt)
    }
}
