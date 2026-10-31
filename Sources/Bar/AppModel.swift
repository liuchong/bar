import AppKit
import BarCore
import BarNative
import Combine
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration: Configuration
    @Published var items: [MenuItem] = []
    @Published var menuImages: [String: MenuBarImage] = [:]
    @Published var imageAccess = MenuBarImages.authorized
    @Published var capturingImages = false
    @Published var imageMessage: String?
    var imagesDidRefresh: (() -> Void)?
    var nativeBarAnchor: (() -> CGRect?)?
    private var safeNativeBundles = Set<String>()
    private var temporaryBundle: String?
    private var imageTask: Task<Void, Never>?
    private var imagesCapturedAt = Date.distantPast
    private var requestedImageIDs: Set<String> = []
    private var initialCaptureComplete = false
    private var dispositionRequests: [String: Int] = [:]
    private var acknowledgedAllowed: Set<String>?
    @Published var trusted = AXIsProcessTrusted()
    @Published var message: String?
    @Published var engineAvailable = BARVisibilityLease.isAvailable()
    @Published var expanded = false
    @Published var paused = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    var presentationChanged: (() -> Void)?
    var beforeOpeningItem: (() -> Void)?
    private let store: ConfigurationStore
    private let worker = DispatchQueue(label: "bar.accessibility", qos: .userInitiated)
    private let actionWorker = DispatchQueue(label: "bar.menu-actions", qos: .userInitiated)
    private var scanning = false
    private var stopping = false
    private var appearanceObserver: NSObjectProtocol?
    private var lease: BARVisibilityLease?
    private var lastAllowed: Set<String>?
    private var generation = 0
    private var scanTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var menuItem: MenuItem?
    private var menuStarted = Date.distantPast
    private var menuSeen = false
    private var checkingMenu = false
    private var engineFailed = false
    private var checkingExternalMenu = false
    private(set) var externalMenuOpen = false
    let host = Bundle.main.bundleIdentifier ?? "com.liuchong.bar"
    var menuIsActive: Bool { menuItem != nil }
    var visibilitySettled: Bool { initialCaptureComplete && acknowledgedAllowed == lastAllowed }

    init(store: ConfigurationStore? = nil) {
        let location = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bar/settings.json")
        self.store = store ?? ConfigurationStore(url: location)
        do { configuration = try self.store.load() }
        catch { configuration = Configuration(); message = "设置读取失败，已保持所有图标可见：\(error.localizedDescription)" }
    }

    var collected: [MenuItem] {
        let ranks = Dictionary(configuration.sorted(Array(Set(items.map(\.bundle)))).enumerated()
            .map { ($1, $0) }, uniquingKeysWith: min)
        return items.filter { configuration.disposition(for: $0.bundle) == .collected }
            .sorted {
                let left = ranks[$0.bundle] ?? 0, right = ranks[$1.bundle] ?? 0
                return left == right ? $0.id.localizedStandardCompare($1.id) == .orderedAscending : left < right
            }
    }

    func iconWidth(_ item: MenuItem) -> CGFloat {
        max(22, menuImages[item.id]?.width ?? min(32, item.frame.width))
    }

    var applications: [(id: String, name: String, icon: NSImage?, count: Int)] {
        let grouped = Dictionary(grouping: items, by: \.bundle)
        return configuration.sorted(Array(Set(grouped.keys).union(configuration.dispositions.keys)))
            .filter { !$0.hasPrefix("com.apple.") && $0 != host }
            .map { id in
                let entries = grouped[id] ?? []
                return (id, entries.first?.appName ?? id, entries.first?.icon, entries.count)
            }
    }

    func start() {
        scan()
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshImages(force: true) }
            }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.applyVisibility(); self?.scan() }
            })
        }
    }

    func update(_ change: (inout Configuration) -> Void) {
        var next = configuration
        change(&next); next.normalize()
        do { try store.save(next) }
        catch { message = "无法保存设置：\(error.localizedDescription)"; return }
        configuration = next
        engineFailed = false
        applyVisibility()
        presentationChanged?()
        refreshImages()
    }

    private func freshItems(_ bundle: String) async -> [MenuItem] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundle }
        return await withCheckedContinuation { continuation in
            worker.async { continuation.resume(returning: MenuAccessibility.scan(apps)) }
        }
    }

    func setDisposition(_ bundle: String, _ mode: ItemDisposition) {
        guard bundle != host, !bundle.hasPrefix("com.apple.") else { return }
        let request = (dispositionRequests[bundle] ?? 0) + 1
        dispositionRequests[bundle] = request
        // Read a newly collected item while it is still visible. Never reveal hidden items to refresh.
        let visible = items.filter { $0.bundle == bundle && configuration.disposition(for: bundle) == .untouched }
        guard mode == .collected, imageAccess, !visible.isEmpty else {
            update { $0.dispositions[bundle] = mode }; return
        }
        Task { [weak self] in
            guard let self else { return }
            let safe = await NativePlacement.arrange(visible, anchor: { self.nativeBarAnchor?() }, scan: self.freshItems)
            self.safeNativeBundles.formUnion(safe)
            let fresh = await self.freshItems(bundle)
            if let captured = try? await MenuBarImages.capture(fresh) {
                for (id, image) in captured { self.menuImages[id] = image }
            }
            guard !self.stopping, self.dispositionRequests[bundle] == request else { return }
            self.update { $0.dispositions[bundle] = mode }
        }
    }

    func move(_ bundle: String, direction: Int) {
        let ids = applications.map(\.id)
        guard let current = ids.firstIndex(of: bundle), ids.indices.contains(current + direction) else { return }
        var result = ids; result.swapAt(current, current + direction)
        update { $0.order = result }
    }

    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func scan() {
        let permission = AXIsProcessTrusted()
        if trusted != permission {
            trusted = permission
            if !permission { releaseVisibility(); items = [] }
        }
        guard trusted, !scanning else { return }
        scanning = true
        let apps = NSWorkspace.shared.runningApplications
        worker.async { [weak self] in
            let found = MenuAccessibility.scan(apps)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                guard self.trusted else { return }
                let running = Set(apps.map(\.processIdentifier))
                let ids = Set(found.map(\.id))
                self.items = found + self.items.filter { running.contains($0.pid) && !ids.contains($0.id) && self.configuration.disposition(for: $0.bundle) != .untouched }
                self.refreshImages()
                self.applyVisibility()
            }
        }
    }

    func requestImageAccess() {
        MenuBarImages.requestAccess()
        imageAccess = MenuBarImages.authorized
        refreshImages(force: true)
    }

    func refreshImages(force: Bool = false) {
        imageAccess = MenuBarImages.authorized
        guard !stopping, trusted, !menuIsActive, imageTask == nil else { return }
        if !imageAccess {
            if collected.isEmpty { initialCaptureComplete = true }
            return
        }
        let ids = Set(items.map(\.id))
        guard force || !initialCaptureComplete || ids != requestedImageIDs || Date().timeIntervalSince(imagesCapturedAt) > 60 else { return }
        requestedImageIDs = ids
        // Hidden icons keep their last genuine glyph. Sampling them by revealing native items
        // would reflow Bar and the unmodified icons to its right.
        let visible = items.filter { lease == nil || configuration.disposition(for: $0.bundle) == .untouched }
        capturingImages = true
        imageTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.initialCaptureComplete = true; self.capturingImages = false; self.imageTask = nil
                self.imagesCapturedAt = Date(); self.applyVisibility(); self.imagesDidRefresh?()
            }
            do {
                var candidates = visible
                if !self.initialCaptureComplete && !self.paused {
                    let safe = await NativePlacement.arrange(self.collected,
                        anchor: { self.nativeBarAnchor?() }, scan: self.freshItems)
                    self.safeNativeBundles.formUnion(safe)
                    candidates = []
                    for bundle in Set(visible.map(\.bundle)).sorted() { candidates += await self.freshItems(bundle) }
                }
                let captured = try await MenuBarImages.capture(candidates)
                if Task.isCancelled { return }
                for (id, image) in captured { self.menuImages[id] = image }
                self.imageMessage = self.collected.contains(where: { self.menuImages[$0.id] == nil })
                    ? "部分图标尚无图像。可暂停管理后刷新一次，再恢复管理；刷新不会临时展开原生图标。" : nil
            } catch { self.imageMessage = "无法读取菜单栏图像：\(error.localizedDescription)" }
        }
    }

    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value; applyVisibility()
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value { releaseVisibility() } else {
            engineFailed = false; initialCaptureComplete = false; safeNativeBundles = []
            refreshImages(force: true)
        }
    }

    func applyVisibility() {
        guard !stopping, initialCaptureComplete, trusted, engineAvailable, !paused, !engineFailed else { releaseVisibility(); return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        guard let allowed = VisibilityPolicy.allowed(running: running, configuration: configuration,
            temporary: temporaryBundle, host: host) else {
            releaseVisibility(); return
        }
        // The system resolves allow-listed identities through installed application registrations.
        // Refuse a restriction when it could also remove an explicitly unmanaged application.
        let directories = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
        for entry in items where configuration.disposition(for: entry.bundle) == .untouched && !entry.bundle.hasPrefix("com.apple.") {
            guard let app = NSRunningApplication(processIdentifier: entry.pid), let actual = app.bundleURL else { continue }
            let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundle)
            let installed = directories.contains { actual.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }
            if !installed || actual.standardizedFileURL != registered?.standardizedFileURL {
                releaseVisibility()
                message = "\(entry.appName) 的运行副本未被系统正确登记，暂未收起图标，以保持“不管理”的应用原样。请从应用程序目录启动该应用，或将它设为收纳。"
                return
            }
        }
        guard allowed != lastAllowed else { return }
        generation += 1
        let current = generation
        lastAllowed = allowed
        BARVisibilityLease.activate(withBundles: allowed.sorted()) { [weak self] newLease, error in
            Task { @MainActor in
                guard let self, self.generation == current else { newLease?.invalidate(); return }
                guard let newLease, error == nil else {
                    self.engineFailed = true
                    self.releaseVisibility()
                    self.message = "显隐未生效，已恢复图标：\(error?.localizedDescription ?? "系统服务没有响应")"
                    return
                }
                let old = self.lease; self.lease = newLease; self.acknowledgedAllowed = allowed; old?.invalidate()
                self.presentationChanged?()
            }
        }
    }

    func releaseVisibility() {
        generation += 1; lease?.invalidate(); lease = nil; lastAllowed = nil; acknowledgedAllowed = nil
    }

    func open(_ item: MenuItem, right: Bool = false) {
        guard trusted, !menuIsActive, !capturingImages else { return }
        guard safeNativeBundles.contains(item.bundle) else {
            message = "该图标的原生位置尚未整理到 Bar 左侧。请暂停管理，将它拖到 Bar 左侧后恢复管理，以避免打开菜单时移动右侧图标。"
            return
        }
        beforeOpeningItem?()
        temporaryBundle = item.bundle
        menuItem = item; menuStarted = Date(); menuSeen = false
        applyVisibility()
        // The original is verified to be left of Bar; revealing it cannot insert anything into the fixed right band.
        actionWorker.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            let error = MenuAccessibility.press(item, right: right)
            DispatchQueue.main.async {
                if error != .success && error != .cannotComplete {
                    self?.message = "无法打开 \(item.appName) 的图标（\(error.rawValue)），请刷新后重试。"
                    self?.finishMenu()
                }
            }
        }
    }

    func pollMenu(pointerInBar: Bool) {
        guard let item = menuItem, !checkingMenu else { return }
        checkingMenu = true
        actionWorker.async { [weak self] in
            let open = MenuAccessibility.hasOpenMenu(item)
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingMenu = false
                guard self.menuItem?.id == item.id else { return }
                self.menuSeen = self.menuSeen || open
                if !open && (self.menuSeen || (Date().timeIntervalSince(self.menuStarted) > 2 && !pointerInBar)) {
                    self.finishMenu()
                }
            }
        }
    }

    func pollExternalMenus() {
        guard trusted, !checkingExternalMenu, menuItem == nil else { return }
        checkingExternalMenu = true
        let candidates = collected
        actionWorker.async { [weak self] in
            let open = candidates.contains { MenuAccessibility.hasOpenMenu($0) }
            DispatchQueue.main.async {
                self?.checkingExternalMenu = false; self?.externalMenuOpen = open
            }
        }
    }

    private func finishMenu() {
        menuItem = nil; temporaryBundle = nil
        applyVisibility(); presentationChanged?()
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch { message = "开机启动设置失败：\(error.localizedDescription)" }
    }

    func shutdown() {
        stopping = true
        if let appearanceObserver { DistributedNotificationCenter.default().removeObserver(appearanceObserver) }
        imageTask?.cancel(); imageTask = nil
        scanTimer?.invalidate(); scanTimer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        releaseVisibility()
    }
}
