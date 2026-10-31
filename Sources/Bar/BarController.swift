import AppKit
import SwiftUI
import Combine
import BarCore

@MainActor
final class BarController: NSObject, NSWindowDelegate {
    let model: AppModel
    let status: NSStatusItem
    private var panels: [NSPanel] = []
    private var settings: NSWindow?
    private var state = ExpansionState()
    private var behavior: ExpansionBehavior
    private var style: ExpansionStyle
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var contextOpen = false
    private var lastTick = Date.distantPast
    private var screenObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var trackingMenus = 0
    private var drawerAnchor: CGRect?

    init(model: AppModel) {
        self.model = model
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        behavior = model.configuration.behavior; style = model.configuration.style
        super.init()
        state.configure(behavior)
        status.autosaveName = "Bar.Entry"
        if let button = status.button {
            button.image = Brand.menuIcon()
            button.target = self; button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Bar 图标抽屉")
            button.toolTip = "Bar · 点击展开或收起，右键设置"
        }
        model.nativeBarAnchor = { [weak self] in
            guard let button = self?.status.button, let window = button.window,
                  let top = NSScreen.screens.first?.frame.maxY else { return nil }
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        }
        model.presentationChanged = { [weak self] in self?.configurationChanged() }
        model.beforeOpeningItem = { [weak self] in self?.hidePanels() }
        model.imagesDidRefresh = { [weak self] in self?.render() }
        model.$menuImages.sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }.store(in: &subscriptions)
        model.$items.sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }.store(in: &subscriptions)
        model.$trusted.sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }.store(in: &subscriptions)
        model.$paused.sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }.store(in: &subscriptions)
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.drawerAnchor = nil; self?.render(); self?.model.scan() }
            }
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.trackingMenus += 1 }
            })
        menuObservers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in if let self { self.trackingMenus = max(0, self.trackingMenus - 1) } }
            })
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let menu = NSMenu()
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(title: "关于 Bar", action: #selector(aboutAction), keyEquivalent: "")
        aboutItem.target = self; aboutItem.image = Brand.symbol("info.circle")
        appMenu.addItem(aboutItem); appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Bar 设置…", action: #selector(settingsAction), keyEquivalent: ",")
        settingsItem.target = self; settingsItem.image = Brand.symbol("gearshape"); appMenu.addItem(settingsItem); appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Bar", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self; appMenu.addItem(quitItem)
        let root = NSMenuItem(title: "Bar", action: nil, keyEquivalent: ""); root.submenu = appMenu
        menu.addItem(root); NSApp.mainMenu = menu
        render()
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu(); return }
        guard model.trusted, !model.collected.isEmpty else { showSettings(); return }
        if model.configuration.behavior == .always { render(); return }
        state.toggle(model.configuration.behavior); render()
    }

    private func configurationChanged() {
        if behavior != model.configuration.behavior {
            behavior = model.configuration.behavior; state.configure(behavior)
        }
        if style != model.configuration.style { style = model.configuration.style; hidePanels() }
        render()
    }

    func render() {
        let open = state.expanded && model.trusted && !model.paused
        model.setExpanded(open)
        status.button?.image = Brand.menuIcon(expanded: open, paused: model.paused)
        if !open { drawerAnchor = nil }
        guard open, model.visibilitySettled, !model.menuIsActive, settings?.isVisible != true,
              let button = status.button, let window = button.window, !model.collected.isEmpty else { hidePanels(); return }
        let screen = window.screen ?? NSScreen.main!
        let currentAnchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        if drawerAnchor == nil { drawerAnchor = currentAnchor }
        let anchor = drawerAnchor!
        let height = max(24, NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        var groups: [(frame: CGRect, items: [MenuItem])] = []
        if style == .left {
            let ordered = Array(model.collected.reversed())
            var cutout: CGRect?
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
               right.minX > left.maxX {
                cutout = CGRect(x: left.maxX, y: screen.frame.maxY - height,
                                width: right.minX - left.maxX, height: height)
            }
            let placements = DrawerLayout.left(widths: ordered.map(model.iconWidth), screen: screen.frame,
                                               anchor: anchor, cutout: cutout, height: height)
                .sorted { $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY > $1.frame.minY }
            for placement in placements {
                if let last = groups.last, abs(last.frame.maxX - placement.frame.minX) < 1,
                   last.frame.minY == placement.frame.minY {
                    groups[groups.count - 1] = (last.frame.union(placement.frame), last.items + [ordered[placement.index]])
                } else { groups.append((placement.frame, [ordered[placement.index]])) }
            }
        } else {
            var row: [MenuItem] = [], width: CGFloat = 0, y = anchor.minY - height - 2
            let maximum = screen.frame.width - 16
            func appendRow() {
                guard !row.isEmpty else { return }
                let x = max(screen.frame.minX + 8, min(anchor.maxX - width, screen.frame.maxX - width - 8))
                groups.append((CGRect(x: x, y: y, width: width, height: height), row))
                y -= height; row = []; width = 0
            }
            for item in model.collected {
                let next = model.iconWidth(item)
                if width + next > maximum { appendRow() }
                row.append(item); width += next
            }
            appendRow()
        }
        while panels.count < groups.count { panels.append(makePanel()) }
        for (index, panel) in panels.enumerated() {
            guard index < groups.count else { panel.orderOut(nil); continue }
            let group = groups[index]
            let background = panel.contentView as! NSGlassEffectView
            background.cornerRadius = style == .left ? 0 : 6
            panel.hasShadow = style == .below
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let dark = displayID.flatMap { MenuBarImages.backgroundDark[$0] }
            panel.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! }
            panel.setFrame(group.frame, display: true)
            let root = DrawerView(model: model, items: group.items, height: height)
            if let hosting = background.contentView as? NSHostingView<DrawerView> {
                hosting.rootView = root; hosting.frame = background.bounds
            } else {
                let hosting = NSHostingView(rootView: root)
                hosting.frame = background.bounds; hosting.autoresizingMask = [.width, .height]
                background.contentView = hosting
            }
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        let background = NSGlassEffectView()
        background.style = .clear; background.effectIsInteractive = true
        panel.contentView = background
        return panel
    }
    private func hidePanels() { panels.forEach { $0.orderOut(nil) } }

    private func pointerInMenuBar(_ point: NSPoint) -> Bool {
        NSScreen.screens.contains { screen in
            point.x >= screen.frame.minX && point.x <= screen.frame.maxX &&
            point.y >= screen.frame.maxY - max(28, NSStatusBar.system.thickness) && point.y <= screen.frame.maxY
        }
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        if Date().timeIntervalSince(lastTick) >= 0.3 {
            lastTick = Date(); model.pollMenu(pointerInBar: pointerInMenuBar(point))
            if state.expanded && style == .left { model.pollExternalMenus() }
        }
        guard model.trusted, !model.paused else { return }
        var inside = panels.contains { $0.isVisible && $0.frame.insetBy(dx: -6, dy: -6).contains(point) }
        if let window = status.button?.window {
            let region = window.frame.insetBy(dx: -6, dy: -6)
            inside = inside || region.contains(point)
        }
        let previous = state.expanded
        state.tick(now: ProcessInfo.processInfo.systemUptime, inside: inside,
                   interacting: contextOpen || trackingMenus > 0 || model.menuIsActive || model.capturingImages ||
                       (style == .left && model.externalMenuOpen) || settings?.isVisible == true,
                   configuration: model.configuration)
        if previous != state.expanded { render() }
    }

    func showSettings() {
        hidePanels()
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 670, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Bar 设置"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.minSize = NSSize(width: 650, height: 550); window.center(); window.delegate = self
            settings = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
        model.scan()
    }
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.render() }
    }
    private func showContextMenu() {
        let menu = NSMenu()
        add("Bar 设置…", to: menu, action: #selector(settingsAction))
        menu.addItem(.separator())
        add(state.expanded ? "收起" : "展开", to: menu, action: #selector(toggleAction))
            .isEnabled = behavior != .always && model.trusted && !model.paused
        let modes = NSMenu()
        for (index, value) in ExpansionBehavior.allCases.enumerated() {
            let item = add(value.title, to: modes, action: #selector(behaviorAction(_:)))
            item.tag = index; item.state = behavior == value ? .on : .off
        }
        let mode = NSMenuItem(title: "显隐行为", action: nil, keyEquivalent: ""); mode.image = Brand.symbol("cursorarrow.rays"); mode.submenu = modes; menu.addItem(mode)
        let styles = NSMenu()
        for (index, value) in ExpansionStyle.allCases.enumerated() {
            let item = add(value.title, to: styles, action: #selector(styleAction(_:)))
            item.tag = index; item.state = style == value ? .on : .off
        }
        let position = NSMenuItem(title: "展开位置", action: nil, keyEquivalent: ""); position.image = Brand.symbol("menubar.rectangle"); position.submenu = styles; menu.addItem(position)
        add(model.paused ? "恢复管理" : "暂停管理（恢复全部图标）", to: menu, action: #selector(pauseAction))
        menu.addItem(.separator())
        add("退出 Bar", to: menu, action: #selector(quitAction))
        guard let button = status.button else { return }
        contextOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        contextOpen = false
    }
    @discardableResult private func add(_ title: String, to menu: NSMenu, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
        let symbol: String
        switch action {
        case #selector(settingsAction): symbol = "gearshape"
        case #selector(toggleAction): symbol = "tray.2"
        case #selector(pauseAction): symbol = model.paused ? "play.circle" : "pause.circle"
        case #selector(quitAction): symbol = "power"
        default: symbol = "circle"
        }
        item.image = Brand.symbol(symbol); menu.addItem(item); return item
    }
    @objc private func aboutAction() { NSApp.orderFrontStandardAboutPanel(options: [.applicationIcon: Brand.applicationIcon]) }
    @objc private func settingsAction() { showSettings() }
    @objc private func toggleAction() { state.toggle(behavior); render() }
    @objc private func pauseAction() { model.setPaused(!model.paused) }
    @objc private func behaviorAction(_ sender: NSMenuItem) { model.update { $0.behavior = ExpansionBehavior.allCases[sender.tag] } }
    @objc private func styleAction(_ sender: NSMenuItem) { model.update { $0.style = ExpansionStyle.allCases[sender.tag] } }
    @objc private func quitAction() { NSApp.terminate(nil) }
    func shutdown() {
        timer?.invalidate(); hidePanels()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        model.shutdown()
        NSStatusBar.system.removeStatusItem(status)
    }
}
