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
                        Button("忽略") { MenuSelection.commit { model.setPlacement(item.bundle, .ignored) } }
                        Button("收纳到抽屉") { MenuSelection.commit { model.setItemDisplay(item.bundle, .hidden) } }
                        Button("菜单栏常显") { MenuSelection.commit { model.setItemDisplay(item.bundle, .shown) } }
                        ForEach(ItemSide.allCases, id: \.self) { side in
                            Button("移到" + side.title) { MenuSelection.commit { model.setSide(item.bundle, side) } }
                        }
                        Divider()
                        Button("向前移动") { MenuSelection.commit { model.move(item.bundle, direction: -1) } }
                        Button("向后移动") { MenuSelection.commit { model.move(item.bundle, direction: 1) } }
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
    @State private var selectedPage = 0
    var body: some View {
        TabView(selection: $selectedPage) {
            general.tabItem { Label("通用", systemImage: "gearshape") }.tag(0)
            icons.tabItem { Label("图标", systemImage: "menubar.rectangle") }.tag(1)
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
                    .help("临时恢复全部图标的原生显示；分区、显示状态和排序规则保留，解除暂停后恢复。")
            }
            Section("图标与抽屉") {
                Text("在“图标”页选择每项常显或收纳，并设置左、右抽屉如何展开。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("管理图标与抽屉…") { selectedPage = 1 }
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
                    Button("刷新图标") { model.refreshManagedItems() }
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
                Button { model.refreshManagedItems() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .accessibilityLabel("刷新图标")
                    .help("刷新图标").disabled(model.capturingImages)
            }.padding(16)
            if let message = model.message ?? model.imageMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
            }
            HStack {
                Text("常显留在菜单栏；收纳放进抽屉。点击 Bar 展开抽屉，再点图标打开菜单。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重新整理菜单栏顺序") { model.retryPinnedOrder() }
                    .disabled(model.orderingItems || model.items.isEmpty)
            }.padding(.horizontal, 16).padding(.bottom, 8)
            if model.orderingVerified { Text("菜单栏分区与顺序已核对").font(.caption).foregroundStyle(.secondary) }
            if let message = model.orderingMessage { Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            List {
                ForEach(ItemSide.allCases, id: \.self) { side in
                    Section(side.title) {
                        drawerSettings(side)
                        ForEach(filteredApplications.filter { !SystemItemPolicy.isSystem($0.id) && model.configuration.placement(for: $0.id) == (side == .left ? .left : .right) }, id: \.id) { app in
                            applicationRow(app)
                        }
                    }
                }
                if ItemSide.allCases.contains(where: { model.configuration.behavior(for: $0) == .automatic }) {
                    Section("悬停延时 · 两栏共用") {
                        delaySlider("靠近后展开", value: model.configuration.hoverDelay, range: 0.1...2) { value in
                            model.update { $0.hoverDelay = value }
                        }
                        delaySlider("离开后收起", value: model.configuration.hideDelay, range: 0.3...10) { value in
                            model.update { $0.hideDelay = value }
                        }
                    }
                }
                Section("忽略") {
                    ForEach(filteredApplications.filter { !SystemItemPolicy.isSystem($0.id) && model.configuration.placement(for: $0.id) == .ignored }, id: \.id) { app in
                        applicationRow(app)
                    }
                }
                Section("系统图标") {
                    Toggle("管理系统图标", isOn: Binding(get: { model.configuration.manageSystemIcons }, set: model.setSystemManagement))
                    Text(model.configuration.manageSystemIcons ? "系统图标按各自规则管理。时钟、控制中心等固定入口保持原样。" : "已停用系统图标管理；下方选择、分区和顺序会保留，重新开启后恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.systemApplications.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }, id: \.id) { app in
                        if SystemItemPolicy.isManageable(app.id) {
                            applicationRow(app, rulesEnabled: model.configuration.manageSystemIcons)
                        } else {
                            HStack(spacing: 10) {
                                Image(systemName: SystemItemPolicy.symbol(app.id)).frame(width: 24, height: 24)
                                Text(app.name); Spacer()
                                Text("系统固定入口").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }
                    }
                }
            }.listStyle(.inset)
            Text("左右栏独立排序。忽略项由系统显示，统一在 Bar 右侧。未检测到图标的应用保留规则，图标出现后自动应用。")
                .font(.caption).foregroundStyle(.secondary).padding(16)
        }
    }
    private var filteredApplications: [(id: String, name: String, icon: NSImage?, count: Int)] {
        model.applications.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }
    private func applicationRow(_ app: (id: String, name: String, icon: NSImage?, count: Int), rulesEnabled: Bool = true) -> some View {
        let collected = model.collected.first { $0.bundle == app.id }
        return HStack(spacing: 10) {
            Group {
                if let collected {
                    Button { model.open(collected) } label: {
                        Image(nsImage: app.icon ?? NSWorkspace.shared.icon(for: .application)).resizable().scaledToFit()
                    }.buttonStyle(.plain).help("打开 \(app.name) 的菜单")
                        .accessibilityLabel("打开 \(app.name) 的菜单")
                } else {
                    Image(nsImage: app.icon ?? NSWorkspace.shared.icon(for: .application)).resizable().scaledToFit()
                        .help(app.icon == nil ? "未找到已安装的应用，管理规则仍保留。" : app.name)
                }
            }.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text(app.count == 0 ? (app.icon == nil ? "未找到应用，规则已保留" : "等待菜单栏图标出现 · 规则已保存") : "\(app.count) 个菜单栏图标")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                SettingsMenuPicker(title: "\(app.name) 分区", choices: ItemPlacement.allCases.map { ($0, $0.title) },
                    selection: model.configuration.placement(for: app.id), onChange: { model.setPlacement(app.id, $0) })
                    .frame(width: 90)
                if model.configuration.placement(for: app.id) == .ignored {
                    Text("系统原样").font(.callout).foregroundStyle(.secondary).frame(width: 120)
                } else {
                    SettingsMenuPicker(title: "\(app.name) 图标去向", choices: ItemDisplay.allCases.map { ($0, $0.title) },
                        selection: model.configuration.display(for: app.id), onChange: { model.setItemDisplay(app.id, $0) })
                        .frame(width: 120)
                }
            }.disabled(!rulesEnabled)
            HStack(spacing: 8) {
                Button { model.move(app.id, direction: -1) } label: { Image(systemName: "chevron.up") }
                    .help("向前移动").accessibilityLabel("\(app.name) 向前移动")
                    .disabled(!rulesEnabled || !model.canMove(app.id, direction: -1))
                Button { model.move(app.id, direction: 1) } label: { Image(systemName: "chevron.down") }
                    .help("向后移动").accessibilityLabel("\(app.name) 向后移动")
                    .disabled(!rulesEnabled || !model.canMove(app.id, direction: 1))
            }.buttonStyle(.borderless)
        }.padding(.vertical, 6).accessibilityElement(children: .contain)
    }
    private func drawerSettings(_ side: ItemSide) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("抽屉开合")
                Spacer()
                SettingsMenuPicker(title: side.title + "抽屉开合", choices: ExpansionBehavior.allCases.map { ($0, $0.title) },
                    selection: model.configuration.behavior(for: side), onChange: { value in
                        model.update { $0.columnBehaviors[side.rawValue] = value }
                    }).frame(width: 210)
            }
            HStack {
                Text("展开位置")
                Spacer()
                if side == .left {
                    SettingsMenuPicker(title: "左栏抽屉位置", choices: ExpansionStyle.allCases.map { ($0, $0.title) },
                        selection: model.configuration.style, onChange: { value in model.update { $0.style = value } })
                        .frame(width: 210)
                } else {
                    Text("菜单栏下方").foregroundStyle(.secondary)
                }
            }
            Text("只控制本栏“收纳到抽屉”的图标，“菜单栏常显”不随抽屉收起。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
    private func delaySlider(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range, step: 0.1)
            Text(String(format: "%.1f 秒", value)).monospacedDigit().frame(width: 55)
        }
    }
}
