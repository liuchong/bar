import AppKit
import BarCore
import BarNative
import Combine
import ServiceManagement
import OSLog

struct NativeOrderingPlan {
    let left: [MenuItem]
    let right: [MenuItem]
    let preservedIDs: Set<String>
    var items: [MenuItem] { left + right }
    func preservesOrder(of previous: NativeOrderingPlan) -> Bool {
        func keys(_ items: [MenuItem]) -> [String] { items.map { "\($0.id):\($0.pid)" } }
        func isSubsequence(_ current: [String], of old: [String]) -> Bool {
            var rest = current[...]
            for value in old where rest.first == value { rest = rest.dropFirst() }
            return rest.isEmpty
        }
        return preservedIDs.isSubset(of: previous.preservedIDs) &&
            isSubsequence(keys(left), of: keys(previous.left)) &&
            isSubsequence(keys(right.filter { !preservedIDs.contains($0.id) }),
                          of: keys(previous.right.filter { !previous.preservedIDs.contains($0.id) }))
    }
    func signature(revision: Int) -> String {
        func key(_ item: MenuItem) -> String { "\(item.id):\(item.pid)" }
        let managedLeft = left.map(key).joined(separator: "|")
        let managedRight = right.filter { !preservedIDs.contains($0.id) }.map(key).joined(separator: "|")
        let preserved = right.filter { preservedIDs.contains($0.id) }.map(key).sorted().joined(separator: "|")
        return "\(revision):L[\(managedLeft)]R[\(managedRight)]P[\(preserved)]"
    }
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
    private var preparedBundles = Set<String>()
    private var cleanMenuImages: [String: MenuBarImage] = [:]
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
    private var unplacedRetryAt: [String: Date] = [:]
    private var unplacedAttempts: [String: Int] = [:]
    private var notificationRevealState = NotificationRevealState()
    private var notificationWakeTask: Task<Void, Never>?
    private var notificationCaptureTask: Task<Void, Never>?
    private var ruleTask: Task<Void, Never>?
    private var rulePreparationMessage: String?
    private var preparationBundle: String?
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
    private let lookupWorker = DispatchQueue(label: "bar.accessibility.lookup", qos: .userInitiated)
    private let actionWorker = DispatchQueue(label: "bar.menu-actions", qos: .userInitiated)
    private var scanning = false
    private var scanAgain = false
    private var workspaceRevision = 0
    private var workspaceTask: Task<Void, Never>?
    private var orderingWakeTask: Task<Void, Never>?
    private var orderingNotBefore = Date.distantPast
    private var discoveryTopology = ""
    private var stopping = false
    private var appearanceObserver: NSObjectProtocol?
    private var lease: BARVisibilityLease?
    private var lastAllowed: Set<String>?
    private var generation = 0
    private var scanTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var menuItem: MenuItem?
    private var openingTask: Task<Void, Never>?
    private var menuPresentation: MenuPresentation?
    private var menuStarted = Date.distantPast
    private var menuSeen = false
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

    private var activeNotificationBundles: Set<String> {
        notificationRevealState.activeBundles(now: ProcessInfo.processInfo.systemUptime, configuration: configuration)
    }

    var nativePreservedItems: [MenuItem] {
        let notified = activeNotificationBundles
        return items.filter { item in
            let mode = configuration.disposition(for: item.bundle)
            return mode == .untouched || mode == .pinned || preparing.contains(item.bundle) ||
                unplaced.contains(item.bundle) || notified.contains(item.bundle)
        }
    }

    var pinned: [MenuItem] {
        pinned(using: configuration)
    }
    private func pinned(using configuration: Configuration) -> [MenuItem] {
        let ranks = Dictionary(configuration.sorted(items.map(\.bundle)).enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return items.filter { configuration.disposition(for: $0.bundle) == .pinned }.sorted {
            let a = ranks[$0.bundle] ?? 0, b = ranks[$1.bundle] ?? 0
            return a == b ? $0.id.localizedStandardCompare($1.id) == .orderedAscending : a < b
        }
    }
    func entries(on side: ItemSide) -> [DrawerEntry] {
        let selected = collected.filter { configuration.side(for: $0.bundle) == side && isHiddenForDrawer($0.bundle) }
        let ready = selected.filter { menuImages[$0.id] != nil }
        var entries = ready.map { DrawerEntry(item: $0, width: iconWidth($0)) }
        if ready.count != selected.count { entries.append(DrawerEntry(item: nil, width: 116)) }
        return entries
    }

    private func isHiddenForDrawer(_ bundle: String) -> Bool {
        guard !paused, !engineFailed, !preparing.contains(bundle), !unplaced.contains(bundle),
              bundle != temporaryBundle, !activeNotificationBundles.contains(bundle) else { return false }
        if let number = SystemItemPolicy.identifiers[bundle] {
            return lastSystemItems?.contains(number) == false && acknowledgedSystemItems?.contains(number) == false
        }
        return lastAllowed?.contains(bundle) == false && acknowledgedAllowed?.contains(bundle) == false
    }

    @discardableResult
    func beginVisibilityRequest(allowed: Set<String>, systemItems: Set<Int>) -> Int {
        generation += 1
        lastAllowed = allowed; lastSystemItems = systemItems
        return generation
    }

    /// Publish drawer readiness only after the native service has acknowledged the restriction.
    func acknowledgeVisibility(allowed: Set<String>, systemItems: Set<Int>) {
        acknowledgedAllowed = allowed; acknowledgedSystemItems = systemItems
        presentationChanged?()
    }

    var drawerEntries: [DrawerEntry] { entries(on: .left) + entries(on: .right) }

    func setSide(_ bundle: String, _ side: ItemSide) {
        update { $0.sides[bundle] = side }
    }

    func nativeOrderingPlan(anchor: CGRect, using configuration: Configuration? = nil) -> NativeOrderingPlan {
        let configuration = configuration ?? self.configuration
        let ignored = items.filter {
            $0.bundle != host && configuration.disposition(for: $0.bundle) == .untouched &&
            $0.frame.width > 1 && $0.frame.height > 1 &&
            abs($0.frame.midY - anchor.midY) < max($0.frame.height, anchor.height)
        }.sorted { $0.frame.minX == $1.frame.minX ? $0.id < $1.id : $0.frame.minX < $1.frame.minX }
        let pins = pinned(using: configuration)
        return NativeOrderingPlan(left: pins.filter { configuration.side(for: $0.bundle) == .left },
            right: pins.filter { configuration.side(for: $0.bundle) == .right } + ignored,
            preservedIDs: Set(ignored.map(\.id)))
    }

    func reconcilePinnedOrder() {
        guard !stopping, !paused, trusted, visibilitySettled, !capturingImages, !menuIsActive,
              ownMenusTracking == 0, NSEvent.pressedMouseButtons == 0,
              !preparingRules, orderingTask == nil, let anchor = nativeBarAnchor?() else { return }
        guard Date() >= orderingNotBefore else { wakeOrderingAfterSettling(); return }
        let plan = nativeOrderingPlan(anchor: anchor), revision = orderRevision
        let selected = plan.items
        // Geometry is an outcome of a transaction, not a new request. A failed plan
        // is retried only after membership/rules change or an explicit retry.
        let signature = plan.signature(revision: revision)
        guard signature != checkedOrder else { return }
        checkedOrder = signature
        orderingVerified = false
        orderingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.orderingTask = nil; self.scheduleRulePreparation() }
            let boundary = plan.right
            if boundary.contains(where: { $0.frame.minX < anchor.maxX - 1 }) {
                let moved = await NativePlacement.moveEntry(before: Set(boundary.map(\.bundle)),
                    anchor: { self.nativeBarAnchor?() }, scan: self.freshItems)
                guard !Task.isCancelled else { return }
                guard moved else {
                    self.orderingMessage = "Bar 入口尚未移动到忽略项目左侧。请关闭菜单后点击“重新整理菜单栏顺序”重试。"
                    self.presentationChanged?()
                    return
                }
                // Continue this transaction after moving Bar. Re-entering reconciliation
                // used stale geometry and repeatedly revealed/prepared every collection.
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

    private func wakeOrderingAfterSettling() {
        orderingWakeTask?.cancel()
        let delay = max(0, orderingNotBefore.timeIntervalSinceNow)
        orderingWakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.stopping else { return }
            self.orderingWakeTask = nil
            self.reconcilePinnedOrder()
        }
    }

    private func workspaceChanged() {
        workspaceRevision += 1
        orderingNotBefore = Date().addingTimeInterval(0.8)
        workspaceTask?.cancel()
        workspaceTask = Task { [weak self] in
            // A single launch often creates several helpers. Coalesce those notifications.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, !self.stopping else { return }
            self.workspaceTask = nil
            self.applyVisibility(); self.scan()
        }
    }

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
        scanTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.workspaceChanged() }
            })
        }
    }

    func update(_ change: (inout Configuration) -> Void) {
        var next = configuration
        change(&next); next.normalize()
        do { try store.save(next) }
        catch { message = "无法保存设置：\(error.localizedDescription)"; return }
        let anchor = nativeBarAnchor?()
        let previousPlan = anchor.map { nativeOrderingPlan(anchor: $0) }
        if let orderingTask { orderingTask.cancel(); NativePlacement.releaseInput() }
        if openingTask != nil { openingTask?.cancel(); NativePointer.cancel() }
        configuration = next
        if menuIsActive { finishMenu() }
        if let anchor, let previousPlan, orderingTask == nil, orderingMessage == nil,
           nativeOrderingPlan(anchor: anchor).preservesOrder(of: previousPlan),
           checkedOrder == previousPlan.signature(revision: orderRevision) {
            // Removing a native item or changing only drawer settings cannot
            // invalidate the relative order of the remaining native icons.
            checkedOrder = nativeOrderingPlan(anchor: anchor).signature(revision: orderRevision)
        } else { orderRevision += 1; checkedOrder = "" }
        engineFailed = false
        notificationRevealState.pruneExpired(now: ProcessInfo.processInfo.systemUptime, configuration: configuration)
        scheduleNotificationExpiration()
        applyVisibility()
        presentationChanged?()
        refreshImages()
        reconcilePinnedOrder()
    }

    func setDrawerBackgroundDensity(_ value: Double) {
        var next = configuration
        next.drawerBackgroundDensity = DrawerBackground.normalized(value)
        guard next != configuration else { return }
        do { try store.save(next) }
        catch { message = "无法保存设置：\(error.localizedDescription)"; return }
        configuration = next
        presentationChanged?()
    }

    private func freshItems(_ bundle: String) async -> [MenuItem] {
        let system = SystemItemPolicy.isSystem(bundle)
        let apps = NSWorkspace.shared.runningApplications.filter { system || $0.bundleIdentifier == bundle }
        let inputSourceNames = system ? InputSourceMenu.names() : []
        return await withCheckedContinuation { continuation in
            lookupWorker.async {
                let found = system ? MenuAccessibility.systemItems(apps, inputSourceNames: inputSourceNames).filter { $0.bundle == bundle } : MenuAccessibility.scan(apps)
                continuation.resume(returning: found)
            }
        }
    }

    private func storeCapturedImages(_ captured: [String: MenuBarImage], for candidates: [MenuItem]) {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, image) in captured {
            menuImages[id] = image
            if let item = byID[id], item.label.trimmingCharacters(in: .whitespacesAndNewlines) == item.appName {
                cleanMenuImages[id] = image
            }
        }
    }

    private func scheduleNotificationExpiration() {
        notificationWakeTask?.cancel()
        let now = ProcessInfo.processInfo.systemUptime
        guard let next = notificationRevealState.nextExpiration(after: now) else {
            notificationWakeTask = nil
            return
        }
        let delay = max(0.05, next - now + 0.05)
        notificationWakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.stopping else { return }
            self.notificationWakeTask = nil
            self.notificationRevealState.pruneExpired(now: ProcessInfo.processInfo.systemUptime, configuration: self.configuration)
            self.applyVisibility()
            self.presentationChanged?()
            self.scheduleNotificationExpiration()
        }
    }

    private func captureNotificationImages(for bundles: Set<String>) {
        guard imageAccess, !bundles.isEmpty else { return }
        notificationCaptureTask?.cancel()
        notificationCaptureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.notificationCaptureTask = nil }
            for _ in 0..<40 {
                if self.visibilitySettled && !self.capturingImages && !self.preparingRules { break }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self.imageAccess else { return }
            var candidates: [MenuItem] = []
            for bundle in bundles.sorted() where self.activeNotificationBundles.contains(bundle) {
                candidates += await self.freshItems(bundle)
            }
            guard !Task.isCancelled, !candidates.isEmpty,
                  let captured = try? await MenuBarImages.captureStable(candidates, refresh: self.freshItems),
                  !Task.isCancelled else { return }
            self.storeCapturedImages(captured, for: candidates)
            self.imagesDidRefresh?()
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
        if after == .collected && (before == .untouched || before == .pinned) {
            unplaced.remove(id); unplacedRetryAt.removeValue(forKey: id); unplacedAttempts.removeValue(forKey: id)
            preparing.insert(id)
        }
        if after != .collected {
            preparing.remove(id); unplaced.remove(id)
            unplacedRetryAt.removeValue(forKey: id); unplacedAttempts.removeValue(forKey: id)
            notificationRevealState.clear(id)
        }
        update { $0 = next }
        scheduleRulePreparation()
    }
    private func scheduleRulePreparation() {
        guard initialCaptureComplete, ruleTask == nil, orderingTask == nil, imageTask == nil,
              !preparing.isEmpty, !stopping, !paused, trusted else { return }
        ruleTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.preparationBundle = nil
                self.ruleTask = nil
                if self.imageAccess && self.collected.allSatisfy({ self.menuImages[$0.id] != nil }) { self.imageMessage = nil }
                self.applyVisibility(); self.presentationChanged?(); self.reconcilePinnedOrder()
            }
            try? await Task.sleep(for: .milliseconds(180))
            for _ in 0..<100 {
                if self.ownMenusTracking == 0 && !self.menuIsActive && !self.capturingImages &&
                    self.visibilitySettled { break }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self.ownMenusTracking == 0, !self.menuIsActive, !self.capturingImages,
                  self.visibilitySettled else { return }
            while let id = self.preparing.sorted().first {
                guard !Task.isCancelled, !self.paused else { return }
                guard self.configuration.disposition(for: id) == .collected else { self.preparing.remove(id); continue }
                let request = self.dispositionRequests[id] ?? 0
                // Reveal only this target for capture. Collection preparation never
                // drags an original or restores unrelated collected items.
                self.preparationBundle = id
                self.applyVisibility()
                for _ in 0..<80 {
                    if self.visibilitySettled || Task.isCancelled { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled, self.visibilitySettled else { return }
                // An assertion completion precedes the menu-bar animation. Wait for
                // its AX items to return before treating an empty snapshot as failure.
                var visible = await self.freshItems(id)
                let expected = max(1, self.items.filter { $0.bundle == id }.count)
                for _ in 0..<30 {
                    if !visible.isEmpty, visible.count >= expected,
                       visible.allSatisfy({ self.canOpenOriginal($0) }) { break }
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .milliseconds(50))
                    visible = await self.freshItems(id)
                }
                let fresh = visible
                if !fresh.isEmpty {
                    let refreshedIDs = Set(fresh.map(\.id))
                    self.items = self.items.filter { !refreshedIDs.contains($0.id) } + fresh
                }
                let ready = !fresh.isEmpty && fresh.allSatisfy { self.canOpenOriginal($0) }
                var imagesReady = !self.imageAccess
                if self.imageAccess, let captured = try? await MenuBarImages.captureStable(fresh, refresh: self.freshItems) {
                    self.storeCapturedImages(captured, for: fresh)
                    imagesReady = !fresh.isEmpty && fresh.allSatisfy { captured[$0.id] != nil || self.menuImages[$0.id] != nil }
                }
                guard !Task.isCancelled else { return }
                guard request == (self.dispositionRequests[id] ?? 0) else { continue }
                let missingImages = !imagesReady
                if ready && !missingImages {
                    self.preparedBundles.insert(id)
                    self.unplaced.remove(id)
                    self.unplacedRetryAt.removeValue(forKey: id)
                    self.unplacedAttempts.removeValue(forKey: id)
                    let snapshots = self.items.map {
                        StatusItemSnapshot(id: $0.id, bundle: $0.bundle, pid: $0.pid,
                                           label: $0.label, appName: $0.appName, width: Double($0.frame.width))
                    }
                    _ = self.notificationRevealState.observe(
                        snapshots,
                        preparedBundles: self.preparedBundles,
                        now: ProcessInfo.processInfo.systemUptime,
                        configuration: self.configuration
                    )
                } else {
                    if ready { self.preparedBundles.insert(id) }
                    let attempts = (self.unplacedAttempts[id] ?? 0) + 1
                    self.unplacedAttempts[id] = attempts
                    self.unplacedRetryAt[id] = Date().addingTimeInterval(min(30, Double(attempts) * 3))
                    self.unplaced.insert(id)
                    let name = fresh.first?.appName ?? visible.first?.appName ?? self.items.first(where: { $0.bundle == id })?.appName ?? id
                    self.rulePreparationMessage = missingImages
                        ? "\(name) 的图标图像尚未读取，暂时只保留原生显示。可点击刷新图标重试。"
                        : "\(name) 尚未完成收纳准备，暂时只保留原生显示。关闭菜单后可点击刷新重试。"
                    self.message = self.rulePreparationMessage
                }
                self.preparing.remove(id)
            }
            if self.unplaced.isEmpty, self.message == self.rulePreparationMessage {
                self.message = nil; self.rulePreparationMessage = nil
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
        guard trusted, !stopping else { return }
        guard !scanning else { scanAgain = true; return }
        scanning = true
        let revision = workspaceRevision
        let apps = NSWorkspace.shared.runningApplications
        let inputSourceNames = InputSourceMenu.names()
        worker.async { [weak self] in
            let found = MenuAccessibility.scan(apps)
            let systemItems = MenuAccessibility.systemItems(apps, inputSourceNames: inputSourceNames)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                guard self.trusted, !self.stopping else { return }
                if revision != self.workspaceRevision {
                    self.scanAgain = false; self.scan(); return
                }
                defer { if self.scanAgain { self.scanAgain = false; self.scan() } }
                let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
                let discovered = found + systemItems
                let previous = Dictionary(self.items.map { ($0.id, $0.pid) }, uniquingKeysWith: { a, _ in a })
                let newlyCollected = discovered.filter {
                    previous[$0.id] != $0.pid && self.configuration.disposition(for: $0.bundle) == .collected
                }
                let newBundles = Set(newlyCollected.map(\.bundle))
                self.preparedBundles.subtract(newBundles)
                self.unplaced.subtract(newBundles)
                self.preparing.formUnion(newBundles)
                for bundle in newBundles {
                    self.dispositionRequests[bundle, default: 0] += 1
                    self.unplacedRetryAt.removeValue(forKey: bundle)
                    self.unplacedAttempts.removeValue(forKey: bundle)
                    self.notificationRevealState.clear(bundle)
                }
                let ids = Set(discovered.map(\.id))
                self.items = discovered + self.items.filter { running.contains($0.pid) && !ids.contains($0.id) && self.configuration.disposition(for: $0.bundle) != .untouched }
                self.systemItems = self.items.filter { SystemItemPolicy.isSystem($0.bundle) }
                if self.initialCaptureComplete {
                    let now = Date()
                    for bundle in Set(discovered.map(\.bundle)) where self.configuration.disposition(for: bundle) == .collected {
                        if (!self.preparedBundles.contains(bundle) || self.unplaced.contains(bundle)),
                           !self.preparing.contains(bundle),
                           now >= (self.unplacedRetryAt[bundle] ?? .distantPast) {
                            self.preparing.insert(bundle)
                        }
                    }
                }
                for item in self.items where self.configuration.disposition(for: item.bundle) == .collected {
                    let idle = item.label.trimmingCharacters(in: .whitespacesAndNewlines) == item.appName
                    if idle, let clean = self.cleanMenuImages[item.id],
                       abs((self.menuImages[item.id]?.width ?? 0) - clean.width) >= 1 {
                        self.menuImages[item.id] = clean
                    }
                }
                let snapshots = self.items.map {
                    StatusItemSnapshot(id: $0.id, bundle: $0.bundle, pid: $0.pid,
                                       label: $0.label, appName: $0.appName, width: Double($0.frame.width))
                }
                let triggered = self.notificationRevealState.observe(
                    snapshots,
                    preparedBundles: self.preparedBundles,
                    now: ProcessInfo.processInfo.systemUptime,
                    configuration: self.configuration
                )
                if !triggered.isEmpty {
                    self.scheduleNotificationExpiration()
                    self.captureNotificationImages(for: triggered)
                }
                let topology = self.items.map { "\($0.id):\($0.pid)" }.sorted().joined(separator: "|")
                if topology != self.discoveryTopology {
                    self.discoveryTopology = topology
                    self.orderingNotBefore = Date().addingTimeInterval(0.8)
                    self.wakeOrderingAfterSettling()
                }
                self.refreshImages()
                self.applyVisibility()
                self.reconcilePinnedOrder()
                self.scheduleRulePreparation()
            }
        }
    }

    func refreshManagedItems() {
        applicationMetadata.removeAll(); applicationMetadataAttempts.removeAll()
        unplacedRetryAt.removeAll(); unplacedAttempts.removeAll()
        preparing.formUnion(unplaced); unplaced.removeAll()
        scan(); refreshImages(force: true); scheduleRulePreparation()
    }

    func requestImageAccess() {
        MenuBarImages.requestAccess()
        if imageAuthorization() {
            initialCaptureComplete = false; preparedBundles = []; releaseVisibility()
        }
        refreshImages(force: true)
    }

    func refreshImages(force: Bool = false) {
        let previouslyAuthorized = imageAccess
        imageAccess = imageAuthorization()
        if !previouslyAuthorized && imageAccess {
            initialCaptureComplete = false; preparedBundles = []; releaseVisibility()
        }
        guard !stopping, trusted, !menuIsActive, imageTask == nil, ruleTask == nil, orderingTask == nil else { return }
        if !imageAccess {
            imageMessage = "收纳和隐藏可正常使用。尚未允许屏幕录制，展开后可点击“允许图标图像…”完成授权，再显示原菜单栏图标。"
            // Image permission affects glyphs only. Native placement and visibility must still initialize.
            if initialCaptureComplete { return }
        }
        // Hidden icons keep their last genuine glyph. Sampling them by revealing native items
        // would reflow Bar and the unmodified icons to its right.
        let visible = items.filter { lease == nil || [.untouched, .pinned].contains(configuration.disposition(for: $0.bundle)) }
        let ids = Set(visible.map(\.id))
        guard force || !initialCaptureComplete || ids != requestedImageIDs || Date().timeIntervalSince(imagesCapturedAt) > 60 else { return }
        requestedImageIDs = ids
        capturingImages = true
        imageTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.initialCaptureComplete = true; self.capturingImages = false; self.imageTask = nil
                self.imagesCapturedAt = Date(); self.applyVisibility(); self.imagesDidRefresh?(); self.reconcilePinnedOrder(); self.scheduleRulePreparation()
            }
            do {
                var candidates = visible
                let initialPass = !self.initialCaptureComplete && !self.paused
                if initialPass {
                    candidates = []
                    for bundle in Set(visible.map(\.bundle)).sorted() { candidates += await self.freshItems(bundle) }
                }
                if self.imageAccess {
                    let captured = try await MenuBarImages.captureStable(candidates, refresh: self.freshItems)
                    if Task.isCancelled { return }
                    self.storeCapturedImages(captured, for: candidates)
                }
                if initialPass {
                    let grouped = Dictionary(grouping: candidates, by: \.bundle)
                    for (bundle, bundleItems) in grouped where self.configuration.disposition(for: bundle) == .collected {
                        let ready = !bundleItems.isEmpty && bundleItems.allSatisfy { self.canOpenOriginal($0) }
                        let hasImages = !self.imageAccess || bundleItems.allSatisfy { self.menuImages[$0.id] != nil }
                        if ready && hasImages {
                            self.preparedBundles.insert(bundle)
                            self.preparing.remove(bundle)
                            self.unplaced.remove(bundle)
                        } else {
                            self.preparing.insert(bundle)
                        }
                    }
                    let snapshots = self.items.map {
                        StatusItemSnapshot(id: $0.id, bundle: $0.bundle, pid: $0.pid,
                                           label: $0.label, appName: $0.appName, width: Double($0.frame.width))
                    }
                    _ = self.notificationRevealState.observe(
                        snapshots,
                        preparedBundles: self.preparedBundles,
                        now: ProcessInfo.processInfo.systemUptime,
                        configuration: self.configuration
                    )
                }
                guard self.imageAccess else { return }
                self.imageMessage = self.collected.contains(where: { self.menuImages[$0.id] == nil })
                    ? "部分图标尚无图像。可暂停管理后刷新一次，再恢复管理；刷新不会临时展开原生图标。" : nil
            } catch { self.imageMessage = "无法读取菜单栏图像：\(error.localizedDescription)" }
        }
    }

    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        // Drawer presentation must never start or release a native visibility lease.
        expanded = value
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value {
            openingTask?.cancel(); finishMenu()
            orderingTask?.cancel(); imageTask?.cancel(); ruleTask?.cancel()
            notificationWakeTask?.cancel(); notificationCaptureTask?.cancel()
            NativePlacement.releaseInput()
            checkedOrder = ""; releaseVisibility()
        } else {
            engineFailed = false; initialCaptureComplete = false; preparedBundles = []
            refreshImages(force: true)
        }
    }

    func applyVisibility() {
        guard !stopping, initialCaptureComplete, trusted, engineAvailable, !paused, !engineFailed else { releaseVisibility(); return }
        notificationRevealState.pruneExpired(now: ProcessInfo.processInfo.systemUptime, configuration: configuration)
        let apps = NSWorkspace.shared.runningApplications
        var processes: [String: Set<Int32>] = [:], discovered: [String: Set<Int32>] = [:]
        for app in apps { if let id = app.bundleIdentifier { processes[id, default: []].insert(app.processIdentifier) } }
        for item in items { discovered[item.bundle, default: []].insert(item.pid) }
        let running = Set(processes.keys)
        let missing = VisibilityPolicy.awaitingDiscovery(running: processes, discovered: discovered, configuration: configuration)
        let notified = activeNotificationBundles
        let pending = Set(preparing.filter { !preparedBundles.contains($0) || $0 == preparationBundle })
            .union(unplaced).union(missing).union(notified)
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
        let current = beginVisibilityRequest(allowed: allowed, systemItems: systemAllowed)
        BARVisibilityLease.activate(withBundles: allowed.sorted(), systemItems: systemAllowed.sorted().map { NSNumber(value: $0) }) { [weak self] newLease, error in
            Task { @MainActor in
                guard let self, self.generation == current else { newLease?.invalidate(); return }
                guard let newLease, error == nil else {
                    self.engineFailed = true
                    self.releaseVisibility()
                    self.message = "显隐未生效，已恢复图标：\(error?.localizedDescription ?? "系统服务没有响应")"
                    return
                }
                let old = self.lease; self.lease = newLease; old?.invalidate()
                self.acknowledgeVisibility(allowed: allowed, systemItems: systemAllowed)
                self.reconcilePinnedOrder(); self.scheduleRulePreparation()
            }
        }
    }

    func releaseVisibility() {
        generation += 1; lease?.invalidate(); lease = nil; lastAllowed = nil; acknowledgedAllowed = nil; lastSystemItems = nil; acknowledgedSystemItems = nil
    }

    func open(_ item: MenuItem, right: Bool = false) {
        guard trusted, !paused, !stopping, openingTask == nil else { return }
        if menuIsActive { finishMenu() }
        openingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.openingTask = nil }
            for _ in 0..<80 {
                if !self.capturingImages && !self.preparingRules && !self.orderingItems { break }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            guard !self.capturingImages, !self.preparingRules, !self.orderingItems,
                  self.preparedBundles.contains(item.bundle) else {
                self.message = "\(item.appName) 尚未完成收纳准备，暂时保留原生显示。请点击刷新图标后重试。"
                self.unplaced.insert(item.bundle)
                return
            }
            self.beforeOpeningItem?()
            self.menuItem = item; self.menuSeen = false
            self.temporaryBundle = item.bundle
            self.applyVisibility()
            for _ in 0..<80 {
                if self.visibilitySettled || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self.visibilitySettled else { return }
            var fresh = await self.freshItems(item.bundle).first(where: { $0.id == item.id })
            for _ in 0..<20 {
                if let candidate = fresh, self.canOpenOriginal(candidate) { break }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(50))
                fresh = await self.freshItems(item.bundle).first(where: { $0.id == item.id })
            }
            guard !Task.isCancelled else { return }
            guard let fresh, self.canOpenOriginal(fresh) else {
                self.message = "\(item.appName) 的原生图标尚未恢复到安全位置，请刷新图标后重试。"
                self.finishMenu(); return
            }
            self.menuItem = fresh; self.menuStarted = Date()
            guard !Task.isCancelled else { return }
            let pids = self.presentationPIDs(fresh)
            let baseline = MenuPresentation(pids: pids)
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            self.menuPresentation = baseline
            let error: AXError = await withCheckedContinuation { continuation in
                self.actionWorker.async { continuation.resume(returning: MenuAccessibility.press(fresh, right: right)) }
            }
            guard !Task.isCancelled else { return }
            var responded = await self.waitForPresentation(fresh, baseline: baseline, foreground: foreground)
            if !responded, !Task.isCancelled {
                // Some status items report AX success without dispatching their mouse action.
                // Use the now-visible, freshly located original, preserving the user's pointer.
                if let original = await self.freshItems(item.bundle).first(where: { $0.id == item.id }),
                   !Task.isCancelled, self.canOpenOriginal(original) {
                    let clicked = await NativePointer.click(at: CGPoint(x: original.frame.midX, y: original.frame.midY), right: right)
                    if clicked { responded = await self.waitForPresentation(original, baseline: baseline, foreground: foreground) }
                }
            }
            guard !Task.isCancelled else { return }
            Logger(subsystem: "com.liuchong.bar", category: "MenuAction").notice("Menu action AX=\(error.rawValue) responded=\(responded)")
            if responded { self.menuSeen = true }
            else {
                self.message = "未能打开 \(item.appName) 的菜单。请点击刷新图标后重试。"
                self.finishMenu()
            }
        }
    }

    private func presentationPIDs(_ item: MenuItem) -> Set<pid_t> {
        var result: Set<pid_t> = [item.pid]
        result.formUnion(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").map(\.processIdentifier))
        if SystemItemPolicy.isSystem(item.bundle) {
            result.formUnion(NSWorkspace.shared.runningApplications.filter {
                MenuAccessibility.systemHosts.contains($0.bundleIdentifier ?? "")
            }.map(\.processIdentifier))
        }
        return result
    }

    private func canOpenOriginal(_ item: MenuItem) -> Bool {
        guard let anchor = nativeBarAnchor?() else { return false }
        return StableMenuBar.canInteract(originals: [item.frame], anchor: anchor,
            displays: NSScreen.screens.compactMap { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayBounds($0.uint32Value) }
            })
    }

    private func waitForPresentation(_ item: MenuItem, baseline: MenuPresentation, foreground: pid_t?) async -> Bool {
        for _ in 0..<6 {
            guard !Task.isCancelled else { return false }
            let open: Bool = await withCheckedContinuation { continuation in
                actionWorker.async { continuation.resume(returning: MenuAccessibility.hasOpenMenu(item)) }
            }
            if open || MenuPresentation(pids: presentationPIDs(item)).hasNewPresentation(comparedTo: baseline) { return true }
            if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != foreground,
               front.processIdentifier == item.pid || item.bundle.hasPrefix((front.bundleIdentifier ?? "") + ".") { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    func pollMenu(pointerInBar: Bool) {
        guard let item = menuItem, openingTask == nil else { return }
        // A normal application window completes a click; only a transient menu
        // or popover keeps its original icon temporarily visible.
        let presented = menuPresentation.map { MenuPresentation(pids: presentationPIDs(item)).hasNewTransientPresentation(comparedTo: $0) } == true
        menuSeen = menuSeen || presented
        if !presented && (menuSeen || (Date().timeIntervalSince(menuStarted) > 2 && !pointerInBar)) {
            finishMenu()
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
        menuItem = nil; temporaryBundle = nil; menuPresentation = nil
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
        workspaceTask?.cancel(); orderingWakeTask?.cancel()
        notificationWakeTask?.cancel(); notificationCaptureTask?.cancel()
        openingTask?.cancel()
        NativePlacement.releaseInput()
        if let appearanceObserver { DistributedNotificationCenter.default().removeObserver(appearanceObserver) }
        imageTask?.cancel(); imageTask = nil; orderingTask?.cancel(); ruleTask?.cancel()
        scanTimer?.invalidate(); scanTimer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        releaseVisibility()
    }
}
