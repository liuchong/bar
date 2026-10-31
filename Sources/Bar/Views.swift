import AppKit
import SwiftUI
import BarCore
import UniformTypeIdentifiers

struct DrawerView: View {
    @ObservedObject var model: AppModel
    let items: [DrawerEntry]
    let height: CGFloat
    @State private var dragging: String?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { entry in
                if let item = entry.item {
                    Button { model.open(item) } label: {
                        Group {
                            if let original = model.menuImages[item.id] {
                                Image(nsImage: original.image).interpolation(.high)
                            }
                        }
                        .frame(width: model.iconWidth(item), height: height)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MenuGlyphButtonStyle())
                    .accessibilityLabel(item.appName + "，" + item.label)
                    .help(model.menuImages[item.id] == nil ? "\(item.appName) · 等待菜单栏图像授权或刷新" : item.label)
                    .contextMenu {
                        Button("打开菜单") { model.open(item, right: true) }
                        Divider()
                        Button("不管理") { model.setDisposition(item.bundle, .untouched) }
                        Button("隐藏") { model.setDisposition(item.bundle, .hidden) }
                        Button("始终显示") { model.setDisposition(item.bundle, .pinned) }
                        ForEach(ItemSide.allCases, id: \.self) { side in
                            Button("移到" + side.title) { model.setSide(item.bundle, side) }
                        }
                        Divider()
                        Button("向前移动") { model.move(item.bundle, direction: -1) }
                        Button("向后移动") { model.move(item.bundle, direction: 1) }
                    }
                    .onDrag { dragging = item.bundle; return NSItemProvider(object: item.bundle as NSString) }
                    .onDrop(of: [.text], delegate: DrawerDrop(model: model, target: item.bundle, dragging: $dragging))
                } else {
                    Button { model.requestImageAccess() } label: {
                        Label(model.imageAccess ? "刷新图标图像" : "允许图标图像…", systemImage: model.imageAccess ? "arrow.clockwise" : "lock")
                            .font(.system(size: 12)).padding(.horizontal, 6)
                            .frame(width: entry.width, height: height)
                    }
                    .buttonStyle(MenuGlyphButtonStyle())
                    .help(model.imageAccess ? "重新读取缺失的原菜单栏图像" : "需要屏幕录制权限才能显示原菜单栏图标")
                }
            }
        }.fixedSize()
    }
}

private struct MenuGlyphButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct DrawerDrop: DropDelegate {
    let model: AppModel
    let target: String
    @Binding var dragging: String?
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        var available = model.applications.map(\.id)
        guard let from = available.firstIndex(of: dragging), let to = available.firstIndex(of: target) else { return }
        available.remove(at: from); available.insert(dragging, at: to)
        model.update { $0.order = available; $0.sides[dragging] = $0.side(for: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    var body: some View {
        TabView {
            general.tabItem { Label("通用", systemImage: "gearshape") }
            icons.tabItem { Label("图标", systemImage: "menubar.rectangle") }
        }
        .padding(.top, 8)
        .frame(minWidth: 650, minHeight: 550)
    }
    private var general: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: Brand.applicationIcon).resizable().scaledToFit()
                        .frame(width: 44, height: 44).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Bar").font(.headline)
                        Text("菜单栏图标管理").font(.callout).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 3)
            }
            Section {
                Toggle("登录时启动 Bar", isOn: Binding(get: { model.launchAtLogin }, set: model.setLogin))
                Toggle("暂停图标管理", isOn: Binding(get: { model.paused }, set: model.setPaused))
            }
            Section("展开") {
                Picker("位置", selection: Binding(get: { model.configuration.style }, set: { value in
                    model.update { $0.style = value }
                })) {
                    ForEach(ExpansionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("显隐方式", selection: Binding(get: { model.configuration.behavior }, set: { value in
                    model.update { $0.behavior = value }
                })) {
                    ForEach(ExpansionBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text(behaviorDescription).font(.callout).foregroundStyle(.secondary)
                if model.configuration.behavior == .automatic {
                    delaySlider("靠近后展开", value: model.configuration.hoverDelay, range: 0.1...2) { value in
                        model.update { $0.hoverDelay = value }
                    }
                    delaySlider("离开后收起", value: model.configuration.hideDelay, range: 0.3...10) { value in
                        model.update { $0.hideDelay = value }
                    }
                }
            }
            Section("系统权限") {
                HStack {
                    Label("辅助功能", systemImage: "hand.raised")
                    Spacer()
                    if model.trusted { Text("已允许").foregroundStyle(.secondary) }
                    else { Button("允许…", action: model.requestAccess) }
                }
                HStack {
                    Label("菜单栏图像", systemImage: "menubar.rectangle")
                    Spacer()
                    if model.imageAccess { Text(model.capturingImages ? "正在更新…" : "已允许").foregroundStyle(.secondary) }
                    else { Button("允许屏幕录制…", action: model.requestImageAccess) }
                }
                Text("只读取菜单栏和抽屉所在的窄条图像，用于保留图标外观并自动调整黑白对比度。图像仅在内存中处理。外观随系统变化，无需选择深色或浅色。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("刷新图标") { model.scan(); model.refreshImages(force: true) }
                        .disabled(model.capturingImages)
                    Spacer()
                    Text("Bar · macOS 27.2+").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = model.message ?? model.imageMessage {
                Section { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped)
    }
    private var icons: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索应用", text: $search).textFieldStyle(.roundedBorder)
                Button { model.scan(); model.refreshImages(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .accessibilityLabel("刷新图标")
                    .help("刷新图标").disabled(model.capturingImages)
            }.padding(16)
            if let message = model.message ?? model.imageMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
            }
            HStack {
                Text("常显项目保留原生图标，并按左右分区恢复顺序。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重新整理常显顺序") { model.retryPinnedOrder() }
                    .disabled(model.orderingItems || model.pinned.isEmpty)
            }.padding(.horizontal, 16).padding(.bottom, 8)
            if model.orderingVerified { Text("常显位置与顺序已核对").font(.caption).foregroundStyle(.secondary) }
            if let message = model.orderingMessage { Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            List {
                ForEach(ItemSide.allCases, id: \.self) { side in
                    Section(side.title) {
                        ForEach(filteredApplications.filter { model.configuration.disposition(for: $0.id) != .untouched && model.configuration.side(for: $0.id) == side }, id: \.id) { app in
                            applicationRow(app, managed: true)
                        }
                    }
                }
                Section("不管理") {
                    ForEach(filteredApplications.filter { model.configuration.disposition(for: $0.id) == .untouched }, id: \.id) { app in
                        applicationRow(app, managed: false)
                    }
                }
                Section("系统项目 · 当前保留原样") {
                    ForEach(model.systemItems.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }, id: \.id) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "gearshape").frame(width: 24, height: 24).foregroundStyle(.secondary)
                            Text(item.label).lineLimit(1)
                            Spacer()
                            Text("由 macOS 管理").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                    Text("系统项目目前不参与 Bar 收纳和排序。可在系统设置的“菜单栏”中调整支持的项目；未识别的项目也不会被 Bar 隐藏。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.listStyle(.inset)
            Text("不管理的项目保留系统原生位置，不参与 Bar 排序。左右分区独立排序；“始终显示”仍由 Bar 管理原生位置。“按需收纳”遵循通用页显隐方式，右栏在下方展开以避开右侧原生图标。退出后保留分区、显示规则和顺序。")
                .font(.caption).foregroundStyle(.secondary).padding(16)
        }
    }
    private var filteredApplications: [(id: String, name: String, icon: NSImage?, count: Int)] {
        model.applications.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }
    private func applicationRow(_ app: (id: String, name: String, icon: NSImage?, count: Int), managed: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
                .resizable().scaledToFit().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text(app.count == 0 ? "当前未运行" : "\(app.count) 个菜单栏图标")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if managed {
                Picker("\(app.name) 所在分区", selection: Binding(get: { model.configuration.side(for: app.id) }, set: {
                    model.setSide(app.id, $0)
                })) {
                    ForEach(ItemSide.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 70)
            }
            Picker(app.name, selection: Binding(get: { model.configuration.disposition(for: app.id) }, set: {
                model.setDisposition(app.id, $0)
            })) {
                ForEach(ItemDisposition.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 90)
            if managed {
                HStack(spacing: 8) {
                    Button { model.move(app.id, direction: -1) } label: { Image(systemName: "chevron.up") }
                        .help("向前移动").accessibilityLabel("\(app.name) 向前移动")
                        .disabled(!model.canMove(app.id, direction: -1))
                    Button { model.move(app.id, direction: 1) } label: { Image(systemName: "chevron.down") }
                        .help("向后移动").accessibilityLabel("\(app.name) 向后移动")
                        .disabled(!model.canMove(app.id, direction: 1))
                }.buttonStyle(.borderless)
            }
        }.padding(.vertical, 6)
    }
    private var behaviorDescription: String {
        switch model.configuration.behavior {
        case .manual: "点击菜单栏的 Bar 图标展开，再点一次收起。"
        case .automatic: "鼠标靠近后展开，离开后延时收起。操作菜单时保持展开，也可以点击切换。"
        case .always: "收纳的图标一直展开。切换显隐方式后可以收起。"
        }
    }
    private func delaySlider(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range, step: 0.1)
            Text(String(format: "%.1f 秒", value)).monospacedDigit().frame(width: 55)
        }
    }
}
