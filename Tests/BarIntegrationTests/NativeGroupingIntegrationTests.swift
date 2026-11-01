import AppKit
import ApplicationServices
import Testing
import BarCore
@testable import Bar

@Suite("Managed bands and the native right boundary")
struct NativeGroupingIntegrationTests {
    @Test @MainActor func collectingAnIgnoredItemDoesNotInvalidateNativeOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(store: ConfigurationStore(url: directory.appendingPathComponent("settings.json")), imageAuthorization: { false })
        model.trusted = false
        defer { model.shutdown() }
        model.items = ["app.pin", "app.new"].enumerated().map { index, id in
            MenuItem(id: id, bundle: id, appName: id, label: id, icon: NSImage(),
                element: AXUIElementCreateApplication(10), frame: CGRect(x: 160 + index * 30, y: 0, width: 24, height: 24), pid: 10)
        }
        model.configuration.setPlacement(.right, for: "app.pin")
        model.configuration.setDisplay(.shown, for: "app.pin")
        let anchor = CGRect(x: 100, y: 0, width: 24, height: 24)
        let before = model.nativeOrderingPlan(anchor: anchor)
        model.setPlacement("app.new", .left)
        let collected = model.nativeOrderingPlan(anchor: anchor)
        #expect(collected.preservesOrder(of: before))
        #expect(collected.right.map(\.id) == ["app.pin"])
        model.configuration.style = .left
        #expect(model.nativeOrderingPlan(anchor: anchor).preservesOrder(of: collected))
        model.setItemDisplay("app.new", .shown)
        #expect(!model.nativeOrderingPlan(anchor: anchor).preservesOrder(of: collected))
        #expect(StableMenuBar.canInteract(originals: model.items.map(\.frame), anchor: anchor,
            displays: [CGRect(x: 0, y: 0, width: 1440, height: 900)]))
    }
    @Test @MainActor func overlappingSystemHitPaddingDoesNotTriggerUnnecessaryNativeDrags() async {
        let ids = ["com.apple.menuextra.wifi", "com.apple.menuextra.textinput"]
        let items = ids.enumerated().map { index, id in
            MenuItem(id: id, bundle: id, appName: id, label: id, icon: NSImage(),
                element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                frame: CGRect(x: 150 + index * 28, y: 0, width: 30, height: 24), pid: ProcessInfo.processInfo.processIdentifier)
        }
        let result = await NativePlacement.order(items, side: .right, preservedIDs: Set(ids),
            anchor: { CGRect(x: 100, y: 0, width: 24, height: 24) }, scan: { id in items.filter { $0.bundle == id } })
        #expect(result.isEmpty)
    }

    @Test @MainActor func cancelledPlacementDoesNotAcquireThePointer() async {
        let task = Task { @MainActor in
            await NativePointer.drag(from: .zero, to: CGPoint(x: 20, y: 0))
        }
        task.cancel()
        #expect(await task.value == false)
        NativePointer.cancel() // Teardown is safe even when no transaction started.
    }

    @Test @MainActor func groupingKeepsManagedSystemRowsTogetherAndIgnoredItemsAfterRightPins() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(store: ConfigurationStore(url: directory.appendingPathComponent("settings.json")), imageAuthorization: { false })
        model.paused = true; model.trusted = false
        defer { model.shutdown() }
        let wifi = "com.apple.menuextra.wifi", battery = "com.apple.menuextra.battery"
        let clock = "com.apple.menuextra.clock", control = "com.apple.menuextra.controlcenter"
        model.configuration.manageSystemIcons = true
        model.configuration.order = [clock, battery, control, wifi, "app.left"]
        model.configuration.dispositions = [wifi: .pinned, battery: .pinned, "app.left": .pinned, "app.collected": .collected]
        model.configuration.sides = [wifi: .right, battery: .right]
        model.items = [("app.ignored.first", 10.0), ("app.left", 50), (wifi, 80), (battery, 130),
            ("app.collected", 70), ("app.ignored.second", 200), (control, 250), (clock, 280)].map { id, x in
            MenuItem(id: id, bundle: id, appName: id, label: id, icon: NSImage(),
                element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
                frame: CGRect(x: x, y: 0, width: 20, height: 24), pid: ProcessInfo.processInfo.processIdentifier)
        }
        let plan = model.nativeOrderingPlan(anchor: CGRect(x: 100, y: 0, width: 24, height: 24))
        #expect(plan.left.map(\.bundle) == ["app.left"])
        #expect(plan.right.map(\.bundle) == [battery, wifi, "app.ignored.first", "app.ignored.second", control, clock])
        #expect(plan.preservedIDs == ["app.ignored.first", "app.ignored.second", control, clock])
        #expect(model.systemApplications.map(\.id) == [battery, wifi, clock, control])
        #expect(model.configuration.disposition(for: "app.ignored.first") == .untouched)
        #expect(!model.configuration.dispositions.keys.contains("app.ignored.first"))
    }

    @Test @MainActor func aFixedEntrypointOnTheWrongSideIsReportedWithoutDraggingIt() async {
        let id = "com.apple.menuextra.clock"
        let item = MenuItem(id: id, bundle: id, appName: "Clock", label: "Clock", icon: NSImage(),
            element: AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
            frame: CGRect(x: 60, y: 0, width: 24, height: 24), pid: ProcessInfo.processInfo.processIdentifier)
        let failed = await NativePlacement.order([item], side: .right, preservedIDs: [id],
            anchor: { CGRect(x: 100, y: 0, width: 24, height: 24) }, scan: { _ in [item] })
        #expect(failed == [id])
    }

    @Test @MainActor func nativeMovementDoesNotBecomeAnotherOrderingRequest() {
        func entry(_ id: String, x: Double, pid: Int32 = 10) -> MenuItem {
            MenuItem(id: id, bundle: id, appName: id, label: id, icon: NSImage(),
                element: AXUIElementCreateApplication(pid), frame: CGRect(x: x, y: 0, width: 24, height: 24), pid: pid)
        }
        let before = NativeOrderingPlan(left: [], right: [entry("pin", x: 100), entry("ignored.a", x: 20), entry("ignored.b", x: 80)],
            preservedIDs: ["ignored.a", "ignored.b"])
        let shifted = NativeOrderingPlan(left: [], right: [entry("pin", x: 240), entry("ignored.b", x: 340), entry("ignored.a", x: 400)],
            preservedIDs: ["ignored.a", "ignored.b"])
        #expect(before.signature(revision: 1) == shifted.signature(revision: 1))
        #expect(before.signature(revision: 1) != shifted.signature(revision: 2))
        let launched = NativeOrderingPlan(left: [], right: shifted.right + [entry("new", x: 440)],
            preservedIDs: ["ignored.a", "ignored.b", "new"])
        #expect(launched.signature(revision: 1) != before.signature(revision: 1))
        let restarted = NativeOrderingPlan(left: [], right: [entry("pin", x: 100, pid: 11)] + Array(before.right.dropFirst()),
            preservedIDs: before.preservedIDs)
        #expect(restarted.signature(revision: 1) != before.signature(revision: 1))
    }

    @Test @MainActor func collectionAppearsOnlyAfterNativeHideAcknowledgementAndDisappearsBeforeReveal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(store: ConfigurationStore(url: directory.appendingPathComponent("settings.json")), imageAuthorization: { false })
        model.trusted = false
        defer { model.shutdown() }
        let id = "app.new"
        let item = MenuItem(id: id, bundle: id, appName: "New", label: "New", icon: NSImage(),
            element: AXUIElementCreateApplication(10), frame: CGRect(x: 200, y: 0, width: 24, height: 24), pid: 10)
        model.items = [item]
        model.menuImages[id] = MenuBarImage(image: NSImage(size: NSSize(width: 24, height: 24)), dark: false, width: 24)
        model.configuration.setPlacement(.left, for: id)
        let system = Set(0..<64)
        model.beginVisibilityRequest(allowed: [id], systemItems: system)
        model.acknowledgeVisibility(allowed: [id], systemItems: system)
        #expect(model.drawerEntries.isEmpty) // Still present in the native bar.
        model.beginVisibilityRequest(allowed: [], systemItems: system)
        #expect(model.drawerEntries.isEmpty) // Request sent; old acknowledgement still allows it.
        model.acknowledgeVisibility(allowed: [], systemItems: system)
        #expect(model.drawerEntries.compactMap(\.item).map(\.id) == [id])
        model.setExpanded(true)
        #expect(model.expanded)
        #expect(model.drawerEntries.compactMap(\.item).map(\.id) == [id])
        model.setExpanded(false)
        #expect(!model.expanded)
        #expect(model.drawerEntries.compactMap(\.item).map(\.id) == [id])
        model.beginVisibilityRequest(allowed: [id], systemItems: system)
        #expect(model.drawerEntries.isEmpty) // Hide the copy before the original is restored.
        model.releaseVisibility()
        #expect(model.drawerEntries.isEmpty)
    }

    @Test func anInputSourceButtonWithoutASystemIdentifierIsStillDiscovered() {
        let names: Set<String> = ["Example Input", "ABC"]
        #expect(MenuAccessibility.systemIdentifier("", label: "Example Input", role: kAXButtonRole,
            inputSourceNames: names) == "com.apple.menuextra.textinput")
        #expect(MenuAccessibility.systemIdentifier("", label: "Unrelated App", role: kAXButtonRole,
            inputSourceNames: names) == nil)
        #expect(MenuAccessibility.systemIdentifier("", label: "ABC", role: kAXStaticTextRole,
            inputSourceNames: names) == nil)
        #expect(MenuAccessibility.systemIdentifier("com.apple.menuextra.sound", label: "Sound", role: kAXButtonRole,
            inputSourceNames: names) == "com.apple.menuextra.volume")
    }
}
