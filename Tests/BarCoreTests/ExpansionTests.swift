import Foundation
import Testing
import BarCore

@Suite("Expansion safety boundaries")
struct ExpansionTests {
    @Test func manualIgnoresPointerAndAlwaysIgnoresCollapse() {
        var config = Configuration()
        var state = ExpansionState()
        state.configure(.manual)
        state.tick(now: 0, inside: true, interacting: false, configuration: config)
        state.tick(now: 100, inside: true, interacting: false, configuration: config)
        #expect(!state.expanded)
        state.toggle(.manual)
        state.tick(now: 200, inside: false, interacting: false, configuration: config)
        #expect(state.expanded)
        state.toggle(.manual)
        #expect(!state.expanded)
        config.behavior = .always
        state.configure(.always); state.toggle(.always); state.close(.always)
        state.tick(now: 500, inside: false, interacting: false, configuration: config)
        #expect(state.expanded)
        state.configure(.manual)
        #expect(!state.expanded)
    }

    @Test func clickToCloseDoesNotReopenUntilPointerLeaves() {
        var config = Configuration(); config.behavior = .automatic
        var state = ExpansionState(); state.configure(.automatic)
        state.toggle(.automatic)
        #expect(state.expanded)
        state.toggle(.automatic)
        state.tick(now: 0, inside: true, interacting: false, configuration: config)
        state.tick(now: 5, inside: true, interacting: false, configuration: config)
        #expect(!state.expanded)
        state.tick(now: 6, inside: false, interacting: false, configuration: config)
        state.tick(now: 7, inside: true, interacting: false, configuration: config)
        state.tick(now: 8, inside: true, interacting: false, configuration: config)
        #expect(state.expanded)
    }

    @Test func systemHostAndUnmanagedAreProtected() {
        var config = Configuration()
        config.dispositions = ["com.apple.controlcenter": .hidden, "bar.host": .hidden,
                               "app.hidden": .hidden, "app.collected": .collected, "app.offline": .hidden]
        let running: Set<String> = ["com.apple.controlcenter", "bar.host", "app.hidden", "app.collected", "app.new"]
        let allow = VisibilityPolicy.allowed(running: running, configuration: config,
            temporary: "app.hidden", host: "bar.host")
        #expect(allow?.isSuperset(of: ["com.apple.controlcenter", "bar.host", "app.new"]) == true)
        #expect(allow?.contains("app.hidden") == false)
        #expect(allow?.contains("app.collected") == false)
        config.dispositions = ["app.offline": .hidden]
        #expect(VisibilityPolicy.allowed(running: running, configuration: config,
            temporary: nil, host: "bar.host") == nil)
    }

    @Test func invalidDelayAndDuplicateOrderAreNormalized() {
        var config = Configuration()
        config.order = ["a", "a", "b", "a"]
        config.hoverDelay = .nan; config.hideDelay = -.infinity
        config.normalize()
        #expect(config.order == ["a", "b"])
        #expect(config.hoverDelay == 0.25 && config.hideDelay == 1.2)
        config.hoverDelay = -10; config.hideDelay = 100
        config.normalize()
        #expect(config.hoverDelay == 0.1 && config.hideDelay == 10)
    }

    @Test func ignoringACollectedItemReleasesItsNativeIconButRetainsTheRule() {
        var config = Configuration()
        config.setPlacement(.right, for: "app.one")
        config.setDisplay(.hidden, for: "app.one")
        config.setPlacement(.ignored, for: "app.one")
        let running: Set<String> = ["app.one", "app.other"]
        #expect(VisibilityPolicy.allowed(running: running, configuration: config,
            temporary: nil, host: "bar.host") == nil)
        config.dispositions["app.other"] = .collected
        let allowed = VisibilityPolicy.allowed(running: running, configuration: config,
            temporary: nil, host: "bar.host")
        #expect(allowed?.contains("app.one") == true)
        #expect(allowed?.contains("app.other") == false)
        #expect(config.side(for: "app.one") == .right && config.display(for: "app.one") == .hidden)
        config.setPlacement(.right, for: "app.one")
        #expect(VisibilityPolicy.allowed(running: running, configuration: config,
            temporary: nil, host: "bar.host")?.contains("app.one") == false)
    }

    @Test func notificationSettingsNormalizeAndDecodeBackwardCompatibly() throws {
        var config = Configuration()
        #expect(config.revealOnNotification == true)
        #expect(config.notificationRetractDelay == 5.0)
        config.notificationRetractDelay = .nan
        config.normalize()
        #expect(config.notificationRetractDelay == 5.0)
        config.notificationRetractDelay = 0.2
        config.normalize()
        #expect(config.notificationRetractDelay == 1.0)
        config.notificationRetractDelay = 120
        config.normalize()
        #expect(config.notificationRetractDelay == 30.0)

        let legacyJSON = Data(#"{"behavior":"manual","style":"left"}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(Configuration.self, from: legacyJSON)
        #expect(decodedLegacy.revealOnNotification == true)
        #expect(decodedLegacy.notificationRetractDelay == 5.0)
    }

    @Test func statusItemSnapshotDistinguishesNewNotificationsFromReadClearsAndRestarts() {
        let idle = StatusItemSnapshot(id: "lark#0", bundle: "lark", pid: 100, label: "Lark Helper", appName: "Lark Helper", width: 36)
        let unread1 = StatusItemSnapshot(id: "lark#0", bundle: "lark", pid: 100, label: "1", appName: "Lark Helper", width: 48)
        let unread2 = StatusItemSnapshot(id: "lark#0", bundle: "lark", pid: 100, label: "2", appName: "Lark Helper", width: 48)
        let restarted = StatusItemSnapshot(id: "lark#0", bundle: "lark", pid: 200, label: "1", appName: "Lark Helper", width: 48)
        let widenedDot = StatusItemSnapshot(id: "lark#0", bundle: "lark", pid: 100, label: "Lark Helper", appName: "Lark Helper", width: 42)

        #expect(StatusItemSnapshot.isNotificationChange(from: idle, to: unread1))
        #expect(StatusItemSnapshot.isNotificationChange(from: unread1, to: unread2))
        #expect(!StatusItemSnapshot.isNotificationChange(from: unread2, to: unread1))
        #expect(!StatusItemSnapshot.isNotificationChange(from: unread1, to: idle))
        #expect(!StatusItemSnapshot.isNotificationChange(from: idle, to: restarted))
        #expect(StatusItemSnapshot.isNotificationChange(from: idle, to: widenedDot))
    }
}
