import Foundation
import Testing
import BarCore
@testable import Bar

@Suite("Visibility initialization without image permission")
struct ImagePermissionIntegrationTests {
    @Test @MainActor func missingScreenRecordingDoesNotBlockCollectionInitialization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigurationStore(url: directory.appendingPathComponent("settings.json"))
        var configuration = Configuration()
        configuration.dispositions = ["app.collect": .collected, "app.hide": .hidden]
        try store.save(configuration)
        let model = AppModel(store: store, imageAuthorization: { false })
        model.trusted = true
        // Keep the native OS service outside this test; exercise the real initialization task.
        model.paused = true
        defer { model.shutdown() }
        model.refreshImages(force: true)
        for _ in 0..<100 where model.capturingImages { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.capturingImages)
        #expect(!model.imageAccess)
        #expect(model.visibilitySettled)
        #expect(model.imageMessage != nil)
        let allowed = VisibilityPolicy.allowed(running: ["app.collect", "app.hide", "app.keep"],
            configuration: model.configuration, temporary: nil, host: model.host)
        #expect(allowed?.contains("app.collect") == false)
        #expect(allowed?.contains("app.hide") == false)
        #expect(allowed?.contains("app.keep") == true)
        model.refreshImages(force: true)
        #expect(!model.capturingImages)
        #expect(model.visibilitySettled)
        model.shutdown()
        let restarted = AppModel(store: store, imageAuthorization: { false })
        defer { restarted.shutdown() }
        #expect(restarted.configuration == configuration)
        restarted.trusted = true
        restarted.paused = true
        restarted.refreshImages(force: true)
        for _ in 0..<100 where restarted.capturingImages { try await Task.sleep(for: .milliseconds(10)) }
        #expect(restarted.visibilitySettled)
        #expect(restarted.configuration.disposition(for: "app.collect") == .collected)
        #expect(restarted.configuration.disposition(for: "app.hide") == .hidden)
    }
}
