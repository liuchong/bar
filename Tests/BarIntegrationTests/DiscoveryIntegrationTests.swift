import Testing
import BarCore

@Suite("Discover status items before restricting visibility")
struct DiscoveryIntegrationTests {
    @Test func aSavedRuleDoesNotHideAnUndiscoveredRunningApplication() throws {
        var configuration = Configuration()
        configuration.setPlacement(.left, for: "app.saved")
        configuration.setDisplay(.hidden, for: "app.saved")
        configuration.setPlacement(.right, for: "app.ready")
        configuration.setDisplay(.hidden, for: "app.ready")
        let original = configuration
        let running: [String: Set<Int32>] = ["app.saved": [10], "app.ready": [20], "app.ignored": [30]]
        let pending = VisibilityPolicy.awaitingDiscovery(running: running, discovered: ["app.ready": [20]], configuration: configuration)
        #expect(pending == ["app.saved"])
        let allowed = try #require(VisibilityPolicy.allowed(running: Set(running.keys), configuration: configuration,
            temporary: nil, host: "bar.host", preparing: pending))
        #expect(allowed.contains("app.saved") && allowed.contains("app.ignored"))
        #expect(!allowed.contains("app.ready"))
        let discovered = VisibilityPolicy.awaitingDiscovery(running: running, discovered: ["app.saved": [10], "app.ready": [20]], configuration: configuration)
        #expect(discovered.isEmpty)
        let collected = try #require(VisibilityPolicy.allowed(running: Set(running.keys), configuration: configuration,
            temporary: nil, host: "bar.host", preparing: discovered))
        #expect(!collected.contains("app.saved"))
        #expect(configuration == original)
    }

    @Test func staleAndPartialProcessRecordsCannotHideANewProcess() {
        var configuration = Configuration()
        configuration.setPlacement(.left, for: "app.saved")
        #expect(VisibilityPolicy.awaitingDiscovery(running: ["app.saved": [22]], discovered: ["app.saved": [11]],
            configuration: configuration) == ["app.saved"])
        #expect(VisibilityPolicy.awaitingDiscovery(running: ["app.saved": [11, 22]], discovered: ["app.saved": [11]],
            configuration: configuration) == ["app.saved"])
        #expect(VisibilityPolicy.awaitingDiscovery(running: ["app.saved": [22]], discovered: ["app.saved": [11, 22]],
            configuration: configuration).isEmpty)
    }
}
