import AppKit
import Testing
import BarCore
@testable import Bar

@Suite("Status item activation and presentation lifetime")
struct MenuInteractionIntegrationTests {
    private func window(_ id: CGWindowID, pid: pid_t = 42, layer: Int = 0, height: CGFloat = 300) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: id,
         kCGWindowLayer as String: layer,
         kCGWindowBounds as String: CGRect(x: 100, y: 30, width: 300, height: height).dictionaryRepresentation]
    }

    @Test func normalWindowsCompleteActionsWithoutBlockingLaterIcons() {
        let before = MenuPresentation(windowInfo: [window(1)], pids: [42])
        let normal = MenuPresentation(windowInfo: [window(1), window(2)], pids: [42])
        #expect(normal.hasNewPresentation(comparedTo: before))
        #expect(!normal.hasNewTransientPresentation(comparedTo: before))
        let popup = MenuPresentation(windowInfo: [window(1), window(3, layer: 101), window(4, layer: 25, height: 33), window(5, pid: 43, layer: 101)], pids: [42])
        #expect(popup.hasNewTransientPresentation(comparedTo: before))
        #expect(popup.transientWindows.keys.sorted() == [3])
        #expect(!before.hasNewTransientPresentation(comparedTo: popup))
    }

    @Test @MainActor func nonactivatingDrawersAcceptTheFirstClickAndCancelledClicksLeaveInputAlone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(store: ConfigurationStore(url: directory.appendingPathComponent("settings.json")), imageAuthorization: { false })
        defer { model.shutdown() }
        let view = DrawerHostingView(rootView: DrawerView(model: model, items: [], height: 24))
        #expect(view.acceptsFirstMouse(for: nil))
        let task = Task { @MainActor in await NativePointer.click(at: .zero, right: false) }
        task.cancel()
        #expect(await task.value == false)
    }
}
