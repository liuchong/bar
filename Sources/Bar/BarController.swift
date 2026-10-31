import AppKit
import SwiftUI
import Combine
import BarCore

@MainActor
final class BarController: NSObject, NSWindowDelegate {
    let model: AppModel
    let status: NSStatusItem
    private let panel: NSPanel
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

    init(model: AppModel) {
        self.model = model
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        behavior = model.configuration.behavior; style = model.configuration.style
        super.init()
        state.configure(behavior)
        status.autosaveName = "Bar.Entry"
        if let button = status.button {
            button.image = NSImage(systemSymbolName: "tray.2", accessibilityDescription: "Bar")
            button.target = self; button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Bar 图标抽屉")
            button.toolTip = "Bar · 点击展开或收起，右键设置"
        }
        panel.isFloatingPanel = true; panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let background = NSVisualEffectView()
        background.material = .popover; background.blendingMode = .behindWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 14; background.layer?.masksToBounds = true
        let content = NSHostingView(rootView: DrawerView(model: model, openSettings: { [weak self] in self?.showSettings() }))
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor), content.bottomAnchor.constraint(equalTo: background.bottomAnchor)])
        panel.contentView = background
        model.presentationChanged = { [weak self] in self?.configurationChanged() }
        model.beforeOpeningItem = { [weak self] in self?.panel.orderOut(nil) }
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
                Task { @MainActor in self?.render(); self?.model.scan() }
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
        render()
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu(); return }
        guard model.trusted else { showSettings(); return }
        if model.configuration.behavior == .always { render(); return }
        state.toggle(model.configuration.behavior); render()
    }

    private func configurationChanged() {
        if behavior != model.configuration.behavior {
            behavior = model.configuration.behavior; state.configure(behavior)
        }
        if style != model.configuration.style { style = model.configuration.style; panel.orderOut(nil) }
        render()
    }

    func render() {
        let open = state.expanded && model.trusted && !model.paused
        model.setExpanded(open)
        status.button?.image = NSImage(systemSymbolName: model.paused ? "pause.circle" : (open ? "tray.2.fill" : "tray.2"), accessibilityDescription: "Bar")
        guard open, style == .below, !model.menuIsActive, settings?.isVisible != true,
              let button = status.button, let window = button.window else { panel.orderOut(nil); return }
        let screen = window.screen ?? NSScreen.main!
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let width = min(max(240, CGFloat(model.collected.count) * 46 + 62), min(800, screen.visibleFrame.width - 24))
        let x = max(screen.visibleFrame.minX + 8, min(anchor.maxX - width, screen.visibleFrame.maxX - width - 8))
        panel.setFrame(CGRect(x: x, y: anchor.minY - 62, width: width, height: 56), display: true)
        panel.orderFrontRegardless()
    }

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
        var inside = panel.isVisible && panel.frame.insetBy(dx: -8, dy: -8).contains(point)
        if let window = status.button?.window {
            var region = window.frame.insetBy(dx: -6, dy: -6)
            if state.expanded && style == .left, let screen = window.screen {
                region.origin.x = screen.frame.minX; region.size.width = window.frame.maxX - screen.frame.minX + 6
            }
            inside = inside || region.contains(point)
        }
        let previous = state.expanded
        state.tick(now: ProcessInfo.processInfo.systemUptime, inside: inside,
                   interacting: contextOpen || trackingMenus > 0 || model.menuIsActive ||
                       (style == .left && model.externalMenuOpen) || settings?.isVisible == true,
                   configuration: model.configuration)
        if previous != state.expanded { render() }
    }

    func showSettings() {
        panel.orderOut(nil)
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Bar 设置"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.minSize = NSSize(width: 700, height: 660); window.center(); window.delegate = self
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
        let mode = NSMenuItem(title: "显隐行为", action: nil, keyEquivalent: ""); mode.submenu = modes; menu.addItem(mode)
        let styles = NSMenu()
        for (index, value) in ExpansionStyle.allCases.enumerated() {
            let item = add(value.title, to: styles, action: #selector(styleAction(_:)))
            item.tag = index; item.state = style == value ? .on : .off
        }
        let position = NSMenuItem(title: "展开位置", action: nil, keyEquivalent: ""); position.submenu = styles; menu.addItem(position)
        add(model.paused ? "恢复管理" : "暂停管理（恢复全部图标）", to: menu, action: #selector(pauseAction))
        menu.addItem(.separator())
        add("退出 Bar", to: menu, action: #selector(quitAction))
        guard let button = status.button else { return }
        contextOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        contextOpen = false
    }
    @discardableResult private func add(_ title: String, to menu: NSMenu, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
    }
    @objc private func settingsAction() { showSettings() }
    @objc private func toggleAction() { state.toggle(behavior); render() }
    @objc private func pauseAction() { model.setPaused(!model.paused) }
    @objc private func behaviorAction(_ sender: NSMenuItem) { model.update { $0.behavior = ExpansionBehavior.allCases[sender.tag] } }
    @objc private func styleAction(_ sender: NSMenuItem) { model.update { $0.style = ExpansionStyle.allCases[sender.tag] } }
    @objc private func quitAction() { NSApp.terminate(nil) }
    func shutdown() {
        timer?.invalidate(); panel.orderOut(nil)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        model.shutdown()
        NSStatusBar.system.removeStatusItem(status)
    }
}
