import AppKit
import Testing
import BarCore
@testable import Bar

@Suite("Popup menu selection and settings persistence")
struct MenuSelectionIntegrationTests {
    @Test @MainActor func movingAnIgnoredRowWaitsUntilMenuTrackingHasFinished() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        let model = AppModel(store: store, imageAuthorization: { false })
        model.paused = true; model.trusted = false
        defer { model.shutdown() }
        MenuSelection.commit { model.setPlacement("app.one", .right) }
        #expect(model.configuration.placement(for: "app.one") == .ignored)
        RunLoop.main.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.005))
        #expect(model.configuration.placement(for: "app.one") == .ignored)
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        #expect(model.configuration.placement(for: "app.one") == .right)
        #expect(model.configuration.display(for: "app.one") == .hidden)
        #expect(try store.load() == model.configuration)
    }
}
