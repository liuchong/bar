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
}
