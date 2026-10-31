import AppKit
import BarNative
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: BarController?
    private let lifecycleLog = Logger(subsystem: "com.liuchong.bar", category: "Lifecycle")
    func applicationDidFinishLaunching(_ notification: Notification) {
        lifecycleLog.notice("Bar started")
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)) else {
            let alert = NSAlert(); alert.messageText = "Bar 需要 macOS 27.2 或以上版本。"
            alert.runModal(); NSApp.terminate(nil); return
        }
        if CommandLine.arguments.contains("--diagnose") {
            let result: [String: Any] = ["system": ProcessInfo.processInfo.operatingSystemVersionString,
                "visibilityService": BARVisibilityLease.isAvailable(), "accessibility": AXIsProcessTrusted(),
                "bundle": Bundle.main.bundleIdentifier ?? "unbundled", "menuBarImages": MenuBarImages.authorized]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            NSApp.terminate(nil); return
        }
        let own = Bundle.main.bundleIdentifier ?? "com.liuchong.bar"
        if NSRunningApplication.runningApplications(withBundleIdentifier: own).contains(where: {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }) { NSApp.terminate(nil); return }
        NSApp.applicationIconImage = Brand.applicationIcon
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel()
        controller = BarController(model: model)
        model.start()
        if !model.trusted || !model.imageAccess || CommandLine.arguments.contains("--settings") { controller?.showSettings() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        lifecycleLog.notice("Bar terminating")
        controller?.shutdown()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.showSettings()
        return true
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
