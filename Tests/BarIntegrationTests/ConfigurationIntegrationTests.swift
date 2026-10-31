import Foundation
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
                expanded: false, temporary: nil, host: "bar.host"))
            #expect(collapsed.isSuperset(of: ["app.keep", "app.new", "bar.host"]))
            #expect(!collapsed.contains("app.collect") && !collapsed.contains("app.hide"))
            let expanded = try #require(VisibilityPolicy.allowed(running: running, configuration: restored,
                expanded: style == .left, temporary: nil, host: "bar.host"))
            #expect(expanded.contains("app.collect") == (style == .left))
            #expect(!expanded.contains("app.hide"))
            let opening = try #require(VisibilityPolicy.allowed(running: running, configuration: restored,
                expanded: false, temporary: "app.collect", host: "bar.host"))
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
        // No hidden applications remain: release the system restriction completely.
        #expect(VisibilityPolicy.allowed(running: running, configuration: configuration,
            expanded: state.expanded, temporary: nil, host: "bar.host") == nil)
        state.tick(now: 1, inside: false, interacting: true, configuration: configuration)
        state.tick(now: 8, inside: false, interacting: true, configuration: configuration)
        #expect(state.expanded)
        state.tick(now: 9, inside: false, interacting: false, configuration: configuration)
        state.tick(now: 10, inside: false, interacting: false, configuration: configuration)
        #expect(!state.expanded)
        #expect(VisibilityPolicy.allowed(running: running, configuration: configuration,
            expanded: state.expanded, temporary: nil, host: "bar.host")?.contains("app.collect") == false)
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
