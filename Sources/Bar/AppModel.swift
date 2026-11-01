import AppKit
import BarCore
import BarNative
import Combine
import ServiceManagement

struct NativeOrderingPlan {
    let left: [MenuItem]
    let right: [MenuItem]
    let preservedIDs: Set<String>
    var items: [MenuItem] { left + right }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration: Configuration
    @Published var items: [MenuItem] = []
    @Published var systemItems: [MenuItem] = []
    @Published var menuImages: [String: MenuBarImage] = [:]
    @Published var imageAccess = false
    @Published var capturingImages = false
    @Published var imageMessage: String?
    var imagesDidRefresh: (() -> Void)?
    var nativeBarAnchor: (() -> CGRect?)?
    private var safeNativeBundles = Set<String>()
    private var applicationMetadata: [String: ApplicationMetadata] = [:]
    private var applicationMetadataAttempts: [String: Date] = [:]
    private var temporaryBundle: String?
    private var imageTask: Task<Void, Never>?
    private var imagesCapturedAt = Date.distantPast
    private var requestedImageIDs: Set<String> = []
    private var initialCaptureComplete = false
    private var dispositionRequests: [String: Int] = [:]
    private var acknowledgedAllowed: Set<String>?
    private var acknowledgedSystemItems: Set<Int>?
    private var lastSystemItems: Set<Int>?
    private var preparing = Set<String>()
    private var unplaced = Set<String>()
    private var ruleTask: Task<Void, Never>?
    var ownMenusTracking = 0
    var preparingRules: Bool { ruleTask != nil || !preparing.isEmpty }
    @Published var trusted = AXIsProcessTrusted()
    @Published var message: String?
    @Published var orderingMessage: String?
    @Published var orderingVerified = false
    private var orderingTask: Task<Void, Never>?
    var orderingItems: Bool { orderingTask != nil }
    private var orderRevision = 0
    private var checkedOrder = ""
    @Published var engineAvailable = BARVisibilityLease.isAvailable()
    @Published var expanded = false
    @Published var paused = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    var presentationChanged: (() -> Void)?
    var beforeOpeningItem: (() -> Void)?
    private let imageAuthorization: @MainActor () -> Bool
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
    var visibilitySettled: Bool { initialCaptureComplete && acknowledgedAllowed == lastAllowed && acknowledgedSystemItems == lastSystemItems }

    init(store: ConfigurationStore? = nil, imageAuthorization: @escaping @MainActor () -> Bool = { MenuBarImages.authorized }) {
        self.imageAuthorization = imageAuthorization
        self.imageAccess = imageAuthorization()
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

    var nativePreservedItems: [MenuItem] {
        items.filter { item in
            let mode = configuration.disposition(for: item.bundle)
            return mode == .untouched || mode == .pinned || preparing.contains(item.bundle) || unplaced.contains(item.bundle)
        }
    }

    var pinned: [MenuItem] {
        let ranks = Dictionary(configuration.sorted(items.map(\.bundle)).enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return items.filter { configuration.disposition(for: $0.bundle) == .pinned }.sorted {
            let a = ranks[$0.bundle] ?? 0, b = ranks[$1.bundle] ?? 0
            return a == b ? $0.id.localizedStandardCompare($1.id) == .orderedAscending : a < b
        }
    }
    func entries(on side: ItemSide) -> [DrawerEntry] {
        let selected = collected.filter { configuration.side(for: $0.bundle) == side }
        let ready = selected.filter { menuImages[$0.id] != nil }
        var entries = ready.map { DrawerEntry(item: $0, width: iconWidth($0)) }
        if ready.count != selected.count { entries.append(DrawerEntry(item: nil, width: 116)) }
        return entries
    }

    var drawerEntries: [DrawerEntry] { entries(on: .left) + entries(on: .right) }

    func setSide(_ bundle: String, _ side: ItemSide) {
        update { $0.sides[bundle] = side }
    }

    func nativeOrderingPlan(anchor: CGRect) -> NativeOrderingPlan {
        let ignored = items.filter {
            $0.bundle != host && configuration.disposition(for: $0.bundle) == .untouched &&
            $0.frame.width > 1 && $0.frame.height > 1 &&
            abs($0.frame.midY - anchor.midY) < max($0.frame.height, anchor.height)
        }.sorted { $0.frame.minX == $1.frame.minX ? $0.id < $1.id : $0.frame.minX < $1.frame.minX }
        return NativeOrderingPlan(left: pinned.filter { configuration.side(for: $0.bundle) == .left },
            right: pinned.filter { configuration.side(for: $0.bundle) == .right } + ignored,
            preservedIDs: Set(ignored.map(\.id)))
    }

    func reconcilePinnedOrder() {
        guard !stopping, !paused, trusted, visibilitySettled, !capturingImages, !menuIsActive,
              ownMenusTracking == 0, NSEvent.pressedMouseButtons == 0,
              !preparingRules, orderingTask == nil, let anchor = nativeBarAnchor?() else { return }
        let plan = nativeOrderingPlan(anchor: anchor), revision = orderRevision
        let selected = plan.items
        let signature = "\(orderRevision):\(anchor.minX):\(anchor.maxX)" + selected.map {
            "\($0.id):\($0.pid):\(configuration.disposition(for: $0.bundle).rawValue):\(configuration.side(for: $0.bundle).rawValue):\($0.frame.minX)"
        }.joined(separator: "|")
        guard signature != checkedOrder else { return }
        checkedOrder = signature
        orderingVerified = false
        orderingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.orderingTask = nil; self.scheduleRulePreparation() }
            let boundary = plan.right
            if boundary.contains(where: { $0.frame.minX < anchor.maxX - 1 }) {
                let collecting = Set(self.collected.map(\.bundle))
                self.preparing.formUnion(collecting)
                self.safeNativeBundles.subtract(collecting)
                self.applyVisibility()
                for _ in 0..<100 {
                    if self.visibilitySettled || Task.isCancelled { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled, self.visibilitySettled else { return }
                let moved = await NativePlacement.moveEntry(before: Set(boundary.map(\.bundle)),
                    anchor: { self.nativeBarAnchor?() }, scan: self.freshItems)
                guard !Task.isCancelled else { return }
                self.checkedOrder = moved ? "" : signature
                self.orderingMessage = moved ? nil : "Bar 入口尚未移动到忽略项目左侧。请关闭菜单后点击“重新整理菜单栏顺序”重试。"
                self.presentationChanged?()
                if collecting.isEmpty && moved {
                    DispatchQueue.main.async { self.reconcilePinnedOrder() }
                }
                return
            }
            var failures = Set<String>()
            failures.formUnion(await NativePlacement.order(plan.left, side: .left,
                anchor: { self.nativeBarAnchor?() }, scan: self.freshItems))
            guard !Task.isCancelled else { return }
            failures.formUnion(await NativePlacement.order(plan.right, side: .right, preservedIDs: plan.preservedIDs,
                anchor: { self.nativeBarAnchor?() }, scan: self.freshItems))
            guard !Task.isCancelled else { return }
            var refreshed: [MenuItem] = []
            for bundle in Set(selected.map(\.bundle)) { refreshed += await self.freshItems(bundle) }
            let ids = Set(refreshed.map(\.id))
            self.items = self.items.filter { !ids.contains($0.id) } + refreshed
            guard revision == self.orderRevision else {
                self.checkedOrder = ""
                DispatchQueue.main.async { self.reconcilePinnedOrder() }
                return
            }
            self.orderingVerified = failures.isEmpty && !selected.isEmpty
            let failedNames = Set(selected.filter { failures.contains($0.bundle) }.map(\.appName)).sorted().joined(separator: "、")
            self.orderingMessage = failures.isEmpty ? nil : "尚未整理：\(failedNames)。请关闭菜单后点击“重新整理菜单栏顺序”重试；忽略及系统固定入口不被拖动。"
            self.presentationChanged?()
        }
    }
    func retryPinnedOrder() { orderRevision += 1; reconcilePinnedOrder() }

    func iconWidth(_ item: MenuItem) -> CGFloat {
        max(22, menuImages[item.id]?.width ?? min(32, item.frame.width))
    }

    var applications: [(id: String, name: String, icon: NSImage?, count: Int)] {
        let grouped = Dictionary(grouping: items, by: \.bundle)
        return configuration.sorted(Array(Set(grouped.keys).union(configuration.dispositions.keys)))
            .filter { (!$0.hasPrefix("com.apple.") || SystemItemPolicy.isSystem($0)) && $0 != host }
            .map { id in
                let entries = grouped[id] ?? []
                let system = SystemItemPolicy.isSystem(id)
                if !system && entries.isEmpty && applicationMetadata[id] == nil &&
                    Date().timeIntervalSince(applicationMetadataAttempts[id] ?? .distantPast) >= 30 {
                    applicationMetadataAttempts[id] = Date()
                    applicationMetadata[id] = ApplicationMetadata.resolve(id)
                }
                let metadata = applicationMetadata[id]
                return (id, entries.first?.appName ?? metadata?.name ?? (system ? SystemItemPolicy.title(id) : id),
                    entries.first?.icon ?? metadata?.icon ?? (system ? NSImage(systemSymbolName: SystemItemPolicy.symbol(id), accessibilityDescription: nil) : nil), entries.count)
            }
    }

    var systemApplications: [(id: String, name: String, icon: NSImage?, count: Int)] {
        let system = applications.filter { SystemItemPolicy.isSystem($0.id) }
        return system.filter { SystemItemPolicy.isManageable($0.id) } +
            system.filter { !SystemItemPolicy.isManageable($0.id) }
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
        if let orderingTask { orderingTask.cancel(); NativePlacement.releaseInput() }
        checkedOrder = ""
        configuration = next
        orderRevision += 1
        engineFailed = false
        applyVisibility()
        presentationChanged?()
        refreshImages()
        reconcilePinnedOrder()
    }

    private func freshItems(_ bundle: String) async -> [MenuItem] {
        let system = SystemItemPolicy.isSystem(bundle)
        let apps = NSWorkspace.shared.runningApplications.filter { system || $0.bundleIdentifier == bundle }
        let inputSourceNames = system ? InputSourceMenu.names() : []
        return await withCheckedContinuation { continuation in
            worker.async {
                let found = system ? MenuAccessibility.systemItems(apps, inputSourceNames: inputSourceNames).filter { $0.bundle == bundle } : MenuAccessibility.scan(apps)
                continuation.resume(returning: found)
            }
        }
    }

    func setPlacement(_ id: String, _ placement: ItemPlacement) {
        changeRule(id) { $0.setPlacement(placement, for: id) }
    }
    func setItemDisplay(_ id: String, _ display: ItemDisplay) {
        changeRule(id) { $0.setDisplay(display, for: id) }
    }
    func setDisposition(_ id: String, _ mode: ItemDisposition) {
        changeRule(id) { value in
            if mode == .untouched { value.setPlacement(.ignored, for: id) }
            else { value.ignored[id] = false; value.dispositions[id] = mode }
        }
    }
    func setSystemManagement(_ enabled: Bool) {
        let affected = items.filter { SystemItemPolicy.isManageable($0.bundle) }
        if enabled {
            for item in affected where configuration.placement(for: item.bundle) != .ignored && configuration.storedDisposition(for: item.bundle) == .collected {
                preparing.insert(item.bundle)
            }
        } else {
            ruleTask?.cancel(); NativePlacement.releaseInput()
            preparing = preparing.filter { !SystemItemPolicy.isSystem($0) }
            unplaced = unplaced.filter { !SystemItemPolicy.isSystem($0) }
        }
        update { $0.manageSystemIcons = enabled }
        scheduleRulePreparation()
    }
    private func changeRule(_ id: String, _ change: (inout Configuration) -> Void) {
        guard id != host, !id.hasPrefix("com.apple.") || SystemItemPolicy.isManageable(id) else { return }
        let before = configuration.disposition(for: id)
        var next = configuration; change(&next)
        let after = next.disposition(for: id)
        dispositionRequests[id, default: 0] += 1
        if after == .collected && (before == .untouched || before == .pinned) { preparing.insert(id) }
        if after != .collected { preparing.remove(id); unplaced.remove(id) }
        update { $0 = next }
        scheduleRulePreparation()
    }
    private func scheduleRulePreparation() {
        guard ruleTask == nil, !preparing.isEmpty, !stopping, !paused, trusted else { return }
        ruleTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.ruleTask = nil
                self.applyVisibility(); self.presentationChanged?(); self.reconcilePinnedOrder()
            }
            // A picker/context-menu action must finish before sending any native drag events.
            try? await Task.sleep(for: .milliseconds(180))
            for _ in 0..<100 {
                if self.ownMenusTracking == 0 && !self.menuIsActive && !self.capturingImages && NSEvent.pressedMouseButtons == 0 { break }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self.ownMenusTracking == 0, !self.menuIsActive, !self.capturingImages else { return }
            while let id = self.preparing.sorted().first {
                guard !Task.isCancelled, !self.paused else { return }
                guard self.configuration.disposition(for: id) == .collected else { self.preparing.remove(id); continue }
                let request = self.dispositionRequests[id] ?? 0
                let visible = await self.freshItems(id)
                let safe = await NativePlacement.arrange(visible, anchor: { self.nativeBarAnchor?() }, scan: self.freshItems)
                if Task.isCancelled { return }
                let fresh = await self.freshItems(id)
                if self.imageAccess, let captured = try? await MenuBarImages.capture(fresh) {
                    for (key, image) in captured { self.menuImages[key] = image }
                }
                guard !Task.isCancelled else { return }
                guard request == (self.dispositionRequests[id] ?? 0) else { continue }
                self.safeNativeBundles.formUnion(safe)
                if !visible.isEmpty && !safe.contains(id) {
                    self.unplaced.insert(id)
                    self.message = "部分图标尚未完成位置整理，暂时保持原生显示。关闭菜单后可点击刷新重试。"
                } else { self.unplaced.remove(id) }
                self.preparing.remove(id)
            }
        }
    }

    func canMove(_ bundle: String, direction: Int) -> Bool {
        let ids = applications.map(\.id).filter { configuration.disposition(for: $0) != .untouched && configuration.side(for: $0) == configuration.side(for: bundle) }
        guard let index = ids.firstIndex(of: bundle) else { return false }
        return ids.indices.contains(index + direction)
    }
    func move(_ bundle: String, direction: Int) {
        let ids = applications.map(\.id).filter { configuration.disposition(for: $0) != .untouched && configuration.side(for: $0) == configuration.side(for: bundle) }
        guard let current = ids.firstIndex(of: bundle), ids.indices.contains(current + direction) else { return }
        var result = applications.map(\.id)
        guard let from = result.firstIndex(of: bundle), let to = result.firstIndex(of: ids[current + direction]) else { return }
        result.swapAt(from, to)
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
            if !permission { releaseVisibility(); items = []; systemItems = [] }
        }
        guard trusted, !scanning else { return }
        scanning = true
        let apps = NSWorkspace.shared.runningApplications
        let inputSourceNames = InputSourceMenu.names()
        worker.async { [weak self] in
            let found = MenuAccessibility.scan(apps)
            let systemItems = MenuAccessibility.systemItems(apps, inputSourceNames: inputSourceNames)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                guard self.trusted else { return }
                let running = Set(apps.map(\.processIdentifier))
                let discovered = found + systemItems
                let ids = Set(discovered.map(\.id))
                self.items = discovered + self.items.filter { running.contains($0.pid) && !ids.contains($0.id) && self.configuration.disposition(for: $0.bundle) != .untouched }
                self.systemItems = self.items.filter { SystemItemPolicy.isSystem($0.bundle) }
                self.refreshImages()
                self.applyVisibility()
                self.reconcilePinnedOrder()
                self.scheduleRulePreparation()
            }
        }
    }

    func refreshManagedItems() {
        applicationMetadata.removeAll(); applicationMetadataAttempts.removeAll()
        preparing.formUnion(unplaced); unplaced.removeAll()
        scan(); refreshImages(force: true); scheduleRulePreparation()
    }

    func requestImageAccess() {
        MenuBarImages.requestAccess()
        if imageAuthorization() {
            initialCaptureComplete = false; safeNativeBundles = []; releaseVisibility()
        }
        refreshImages(force: true)
    }

    func refreshImages(force: Bool = false) {
        let previouslyAuthorized = imageAccess
        imageAccess = imageAuthorization()
        if !previouslyAuthorized && imageAccess {
            initialCaptureComplete = false; safeNativeBundles = []; releaseVisibility()
        }
        guard !stopping, trusted, !menuIsActive, imageTask == nil, ruleTask == nil, orderingTask == nil else { return }
        if !imageAccess {
            imageMessage = "收纳和隐藏可正常使用。尚未允许屏幕录制，展开后可点击“允许图标图像…”完成授权，再显示原菜单栏图标。"
            // Image permission affects glyphs only. Native placement and visibility must still initialize.
            if initialCaptureComplete { return }
        }
        let ids = Set(items.map(\.id))
        guard force || !initialCaptureComplete || ids != requestedImageIDs || Date().timeIntervalSince(imagesCapturedAt) > 60 else { return }
        requestedImageIDs = ids
        // Hidden icons keep their last genuine glyph. Sampling them by revealing native items
        // would reflow Bar and the unmodified icons to its right.
        let visible = items.filter { lease == nil || [.untouched, .pinned].contains(configuration.disposition(for: $0.bundle)) }
        capturingImages = true
        imageTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.initialCaptureComplete = true; self.capturingImages = false; self.imageTask = nil
                self.imagesCapturedAt = Date(); self.applyVisibility(); self.imagesDidRefresh?(); self.reconcilePinnedOrder(); self.scheduleRulePreparation()
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
                guard self.imageAccess else { return }
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
        if value {
            orderingTask?.cancel(); imageTask?.cancel(); ruleTask?.cancel(); NativePlacement.releaseInput()
            checkedOrder = ""; releaseVisibility()
        } else {
            engineFailed = false; initialCaptureComplete = false; safeNativeBundles = []
            refreshImages(force: true)
        }
    }

    func applyVisibility() {
        guard !stopping, initialCaptureComplete, trusted, engineAvailable, !paused, !engineFailed else { releaseVisibility(); return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let pending = preparing.union(unplaced)
        let temporary = pending.union(temporaryBundle.map { [$0] } ?? [])
        let systemAllowed = SystemItemPolicy.allowed(configuration: configuration, temporary: temporary)
        let applicationAllowed = VisibilityPolicy.allowed(running: running, configuration: configuration,
            temporary: temporaryBundle, host: host, preparing: pending)
        guard applicationAllowed != nil || systemAllowed != Set(0..<64) else { releaseVisibility(); return }
        let allowed = applicationAllowed ?? running.union([host, "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"])
        // The system resolves allow-listed identities through installed application registrations.
        // Refuse a restriction when it could also remove an explicitly unmanaged application.
        let directories = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
        for entry in items where configuration.disposition(for: entry.bundle) == .untouched && !entry.bundle.hasPrefix("com.apple.") {
            guard let app = NSRunningApplication(processIdentifier: entry.pid), let actual = app.bundleURL else { continue }
            let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundle)
            let installed = directories.contains { actual.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }
            if !installed || actual.standardizedFileURL != registered?.standardizedFileURL {
                releaseVisibility()
                message = "\(entry.appName) 的运行副本未被系统正确登记，暂未收起图标，以保持“忽略”的应用原样。请从应用程序目录启动该应用，或将它设为收纳。"
                return
            }
        }
        guard allowed != lastAllowed || systemAllowed != lastSystemItems else { return }
        generation += 1
        let current = generation
        lastAllowed = allowed; lastSystemItems = systemAllowed
        BARVisibilityLease.activate(withBundles: allowed.sorted(), systemItems: systemAllowed.sorted().map { NSNumber(value: $0) }) { [weak self] newLease, error in
            Task { @MainActor in
                guard let self, self.generation == current else { newLease?.invalidate(); return }
                guard let newLease, error == nil else {
                    self.engineFailed = true
                    self.releaseVisibility()
                    self.message = "显隐未生效，已恢复图标：\(error?.localizedDescription ?? "系统服务没有响应")"
                    return
                }
                let old = self.lease; self.lease = newLease; self.acknowledgedAllowed = allowed; self.acknowledgedSystemItems = systemAllowed; old?.invalidate()
                self.presentationChanged?()
                self.reconcilePinnedOrder()
            }
        }
    }

    func releaseVisibility() {
        generation += 1; lease?.invalidate(); lease = nil; lastAllowed = nil; acknowledgedAllowed = nil; lastSystemItems = nil; acknowledgedSystemItems = nil
    }

    func open(_ item: MenuItem, right: Bool = false) {
        guard trusted, !menuIsActive, !capturingImages, !preparingRules else { return }
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
        NativePlacement.releaseInput()
        if let appearanceObserver { DistributedNotificationCenter.default().removeObserver(appearanceObserver) }
        imageTask?.cancel(); imageTask = nil; orderingTask?.cancel(); ruleTask?.cancel()
        scanTimer?.invalidate(); scanTimer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        releaseVisibility()
    }
}
