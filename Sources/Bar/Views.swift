import AppKit
import SwiftUI
import BarCore
import UniformTypeIdentifiers

struct DrawerView: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    @State private var dragging: String?

    var body: some View {
        HStack(spacing: 6) {
            if model.collected.isEmpty {
                Text("还没有收纳的图标").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 14)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.collected) { item in
                            Button { model.open(item) } label: {
                                Image(nsImage: item.icon).resizable().interpolation(.high)
                                    .scaledToFit().frame(width: 24, height: 24)
                                    .frame(width: 40, height: 40).contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(item.appName + "，" + item.label)
                            .help(item.appName == item.label ? item.appName : "\(item.appName) · \(item.label)")
                            .contextMenu {
                                Button("打开菜单") { model.open(item, right: true) }
                                Divider()
                                Button("不管理") { model.setDisposition(item.bundle, .untouched) }
                                Button("隐藏") { model.setDisposition(item.bundle, .hidden) }
                                Divider()
                                Button("向前移动") { model.move(item.bundle, direction: -1) }
                                Button("向后移动") { model.move(item.bundle, direction: 1) }
                            }
                            .onDrag { dragging = item.bundle; return NSItemProvider(object: item.bundle as NSString) }
                            .onDrop(of: [.text], delegate: DrawerDrop(model: model, target: item.bundle, dragging: $dragging))
                        }
                    }.padding(.horizontal, 4)
                }.scrollIndicators(.hidden)
            }
            Divider().frame(height: 24)
            Button(action: openSettings) { Image(systemName: "slider.horizontal.3").frame(width: 30, height: 36) }
                .buttonStyle(.borderless).help("Bar 设置").accessibilityLabel("Bar 设置")
        }
        .padding(8)
    }
}

struct DrawerDrop: DropDelegate {
    let model: AppModel
    let target: String
    @Binding var dragging: String?
    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        let available = model.applications.map(\.id)
        model.update { $0.move(dragging, before: target, available: available) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "tray.2.fill").font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bar").font(.title2.weight(.semibold))
                    Text("把菜单栏留给常用的图标").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("暂停管理", isOn: Binding(get: { model.paused }, set: { model.setPaused($0) }))
                    .toggleStyle(.switch).fixedSize()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !model.trusted {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "hand.raised.fill").font(.title2).foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("允许读取和操作菜单栏图标").font(.headline)
                                Text("在系统设置的辅助功能中启用 Bar，然后点“刷新”。授权前保持所有图标原样。无需屏幕录制权限。")
                                    .font(.callout).foregroundStyle(.secondary)
                                HStack {
                                    Button("打开辅助功能设置") { model.requestAccess() }
                                    Button("刷新") { model.scan() }
                                }
                            }
                        }.padding(16).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let message = model.message {
                        HStack(alignment: .top) {
                            Text(message).font(.callout).foregroundStyle(.orange)
                            Spacer()
                            Button { model.message = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                        }
                    }
                    GroupBox("展开方式") {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("位置", selection: Binding(get: { model.configuration.style }, set: { value in
                                model.update { $0.style = value }
                            })) {
                                ForEach(ExpansionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented)
                            Picker("行为", selection: Binding(get: { model.configuration.behavior }, set: { value in
                                model.update { $0.behavior = value }
                            })) {
                                ForEach(ExpansionBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented)
                            Text(behaviorDescription).font(.callout).foregroundStyle(.secondary)
                            if model.configuration.behavior == .automatic {
                                delaySlider("靠近后展开", value: model.configuration.hoverDelay, range: 0.1...2) { value in
                                    model.update { $0.hoverDelay = value }
                                }
                                delaySlider("离开后收起", value: model.configuration.hideDelay, range: 0.3...10) { value in
                                    model.update { $0.hideDelay = value }
                                }
                            }
                        }.padding(10)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("图标管理").font(.headline)
                            Spacer()
                            Button { model.scan() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        }
                        Text("收纳：放进抽屉，展开时可用。隐藏：保持隐藏，不放进抽屉。不管理：保持系统原样。相同应用的图标统一设置；系统控制图标保持原样。")
                            .font(.callout).foregroundStyle(.secondary)
                        TextField("搜索应用", text: $search).textFieldStyle(.roundedBorder)
                        if model.applications.isEmpty {
                            ContentUnavailableView(model.trusted ? "尚未发现图标" : "等待辅助功能授权",
                                systemImage: "menubar.rectangle", description: Text("应用运行并显示菜单栏图标后，会出现在这里。"))
                        }
                        ForEach(model.applications.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }, id: \.id) { app in
                            HStack(spacing: 12) {
                                Image(nsImage: app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
                                    .resizable().scaledToFit().frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).lineLimit(1)
                                    Text(app.count == 0 ? "当前未运行或图标不可用" : "\(app.count) 个图标")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Picker(app.name, selection: Binding(get: { model.configuration.disposition(for: app.id) }, set: {
                                    model.setDisposition(app.id, $0)
                                })) {
                                    ForEach(ItemDisposition.allCases, id: \.self) { Text($0.title).tag($0) }
                                }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                                HStack(spacing: 6) {
                                    Button { model.move(app.id, direction: -1) } label: { Image(systemName: "chevron.up") }
                                        .help("向前移动").accessibilityLabel("\(app.name) 向前移动")
                                        .disabled(model.applications.first?.id == app.id)
                                    Button { model.move(app.id, direction: 1) } label: { Image(systemName: "chevron.down") }
                                        .help("向后移动").accessibilityLabel("\(app.name) 向后移动")
                                        .disabled(model.applications.last?.id == app.id)
                                }.buttonStyle(.borderless)
                            }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Text("排序作用于下方抽屉；顶部菜单栏的原生顺序可按住 ⌘ 拖动图标调整。抽屉使用应用图标，点击后打开对应的原生菜单或面板。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("登录时启动 Bar", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                }.padding(24)
            }
            Divider()
            HStack {
                Label(model.engineAvailable ? "macOS 27.2 及以上" : "系统显隐服务不可用", systemImage: model.engineAvailable ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("退出 Bar") { NSApp.terminate(nil) }
            }.padding(14)
        }.frame(minWidth: 680, minHeight: 640)
    }
    private var behaviorDescription: String {
        switch model.configuration.behavior {
        case .manual: "点击菜单栏的 Bar 图标展开，再点一次收起。"
        case .automatic: "鼠标靠近 Bar 图标后展开，离开后延时收起；也可以点击切换。操作菜单时保持展开。"
        case .always: "收纳的图标一直展开。切换到手动或自动显隐后恢复收起功能。"
        }
    }
    private func delaySlider(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range, step: 0.1)
            Text(String(format: "%.1f 秒", value)).monospacedDigit().frame(width: 55)
        }.font(.callout)
    }
}
