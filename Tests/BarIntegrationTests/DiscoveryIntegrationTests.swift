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

    @Test func staleProcessRecordsCannotHideANewProcessWhileAuxiliaryHelpersStayCollected() {
        var configuration = Configuration()
        configuration.setPlacement(.left, for: "app.saved")
        #expect(VisibilityPolicy.awaitingDiscovery(running: ["app.saved": [22]], discovered: ["app.saved": [11]],
            configuration: configuration) == ["app.saved"])
        #expect(VisibilityPolicy.awaitingDiscovery(running: ["app.saved": [22, 33]], discovered: ["app.saved": [11]],
            configuration: configuration) == ["app.saved"])
        // An auxiliary helper sharing the bundle identifier must not unhide an already discovered running status item.
        #expect(VisibilityPolicy.awaitingDiscovery(running: ["app.saved": [11, 22]], discovered: ["app.saved": [11]],
            configuration: configuration).isEmpty)
        #expect(VisibilityPolicy.awaitingDiscovery(running: ["app.saved": [22]], discovered: ["app.saved": [11, 22]],
            configuration: configuration).isEmpty)
    }

    @Test func controlledNotificationPopOutRevealsAndRetractsAfterConfiguredDelay() throws {
        var configuration = Configuration()
        let lark = "com.larksuite.larkApp.helper"
        let other = "com.google.antigravity"
        configuration.setPlacement(.left, for: lark)
        configuration.setDisplay(.hidden, for: lark)
        configuration.setPlacement(.left, for: other)
        configuration.setDisplay(.hidden, for: other)
        configuration.revealOnNotification = true
        configuration.notificationRetractDelay = 4.0
        let running: Set<String> = [lark, other, "app.keep"]
        let prepared: Set<String> = [lark, other]
        var state = NotificationRevealState()

        // Initial discovery of prepared items sets baseline without popping out.
        let initial = [
            StatusItemSnapshot(id: "\(lark)#0", bundle: lark, pid: 59968, label: "Lark Helper", appName: "Lark Helper", width: 36),
            StatusItemSnapshot(id: "\(other)#0", bundle: other, pid: 75078, label: "Antigravity", appName: "Antigravity", width: 40)
        ]
        #expect(state.observe(initial, preparedBundles: prepared, now: 10, configuration: configuration).isEmpty)
        #expect(state.activeBundles(now: 10, configuration: configuration).isEmpty)

        // New message arrives: AXTitle becomes "1" and width expands from 36 to 48.
        let unreadOne = [
            StatusItemSnapshot(id: "\(lark)#0", bundle: lark, pid: 59968, label: "1", appName: "Lark Helper", width: 48),
            StatusItemSnapshot(id: "\(other)#0", bundle: other, pid: 75078, label: "Antigravity", appName: "Antigravity", width: 40)
        ]
        #expect(state.observe(unreadOne, preparedBundles: prepared, now: 12, configuration: configuration) == [lark])
        let activeAt13 = state.activeBundles(now: 13, configuration: configuration)
        #expect(activeAt13 == [lark])
        let revealed = try #require(VisibilityPolicy.allowed(running: running, configuration: configuration,
            temporary: nil, host: "bar.host", preparing: activeAt13))
        #expect(revealed.contains(lark))
        #expect(!revealed.contains(other))

        // Second message arrives at t=14: deadline extends to 14 + 4 = 18.
        let unreadTwo = [
            StatusItemSnapshot(id: "\(lark)#0", bundle: lark, pid: 59968, label: "2", appName: "Lark Helper", width: 48),
            StatusItemSnapshot(id: "\(other)#0", bundle: other, pid: 75078, label: "Antigravity", appName: "Antigravity", width: 40)
        ]
        #expect(state.observe(unreadTwo, preparedBundles: prepared, now: 14, configuration: configuration) == [lark])
        #expect(state.activeBundles(now: 17.5, configuration: configuration) == [lark])

        // After delay expires at t=18.1, item automatically retracts back into drawer.
        state.pruneExpired(now: 18.1, configuration: configuration)
        let activeAt18 = state.activeBundles(now: 18.1, configuration: configuration)
        #expect(activeAt18.isEmpty)
        let retracted = try #require(VisibilityPolicy.allowed(running: running, configuration: configuration,
            temporary: nil, host: "bar.host", preparing: activeAt18))
        #expect(!retracted.contains(lark))
        #expect(!retracted.contains(other))

        // Reading one chat ("2" -> "1") or clearing unread ("1" -> "Lark Helper") does not re-trigger pop-out.
        #expect(state.observe(unreadOne, preparedBundles: prepared, now: 20, configuration: configuration).isEmpty)
        #expect(state.observe(initial, preparedBundles: prepared, now: 22, configuration: configuration).isEmpty)

        // When revealOnNotification is disabled, new notifications stay strictly in the drawer.
        configuration.revealOnNotification = false
        #expect(state.observe(unreadOne, preparedBundles: prepared, now: 25, configuration: configuration).isEmpty)
        #expect(state.activeBundles(now: 25, configuration: configuration).isEmpty)
    }
}
