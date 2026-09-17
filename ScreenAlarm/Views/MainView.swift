import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preview: MultiWindowPreview
    @EnvironmentObject private var equipment: EquipmentMonitor
    @State private var expandedWindow: UInt32?
    @State private var showGeneral = false
    private var monitoring: Bool { preview.groupRunning || equipment.running }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("游戏窗口").font(.title2.bold())
                    Text("已识别 \(preview.visibleWindows.count) 个角色窗口").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(preview.running ? "关闭小窗口" : "显示小窗口") {
                    if !preview.running { preview.selectEVE() }
                    preview.toggle()
                }
                Button(monitoring ? "停止监护" : "开始监护") {
                    preview.toggleProtection(model: model, equipment: equipment)
                }.buttonStyle(.borderedProminent).disabled(equipment.calibrating != nil)
                Button { model.dismissAlarm(); preview.dismissIntelAlarm(); equipment.mute() } label: {
                    Image(systemName: "speaker.slash")
                }.help("静音当前提醒").accessibilityLabel("静音当前提醒")
                Button { showGeneral = true } label: { Image(systemName: "gearshape") }
                    .help("通用设置").accessibilityLabel("通用设置")
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.hasPermission { PermissionNotice() }
                    if preview.visibleWindows.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "rectangle.on.rectangle.slash").font(.largeTitle).foregroundStyle(.secondary)
                            Text("等待游戏窗口").font(.headline)
                            Text("登录 EVE 角色后会自动识别。").foregroundStyle(.secondary)
                            Button("重新识别") { preview.refresh() }.disabled(preview.refreshing)
                        }.frame(maxWidth: .infinity).padding(50)
                    }
                    ForEach(preview.visibleWindows) { target in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 12) {
                            Button { expandedWindow = expandedWindow == target.windowID ? nil : target.windowID } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "display").font(.title2).foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(LocalIntel.characterName(target.title)).font(.headline)
                                        Text(preview.monitoredIDs.contains(target.windowID) ? "监护中" : "点击配置窗口监护").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: expandedWindow == target.windowID ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                                }.padding(.vertical, 18).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button(preview.isPreviewVisible(for: target) ? "关闭小窗口" : "显示小窗口") { preview.togglePreview(for: target) }
                            Button(preview.monitoredIDs.contains(target.windowID) || equipment.isRunning(for: target) ? "停止监护" : "开始监护") {
                                preview.toggleProtection(for: target, model: model, equipment: equipment)
                            }.disabled(equipment.calibrating != nil)
                            }.padding(.horizontal, 18)
                            if expandedWindow == target.windowID {
                                Divider().padding(.horizontal, 18)
                                WindowFeatureDrawers(preview: preview, equipment: equipment, target: target).padding(18)
                            }
                        }.background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if let error = preview.error ?? model.lastError { Text(error).font(.callout).foregroundStyle(.orange) }
                    if let message = equipment.message { Text(message).font(.callout).foregroundStyle(.orange) }
                }.padding(20)
            }
        }
        .sheet(isPresented: $showGeneral) {
            VStack(spacing: 0) {
                HStack { Text("通用设置").font(.title2.bold()); Spacer(); Button("完成") { showGeneral = false } }.padding(20)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("以下设置对所有窗口生效").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 16) {
                            DisclosureGroup {
                                SharedPreviewSettings(preview: preview).padding(.top, 12)
                            } label: { Label("小窗口与快捷键", systemImage: "pip").font(.headline) }
                            Divider()
                            DisclosureGroup {
                                SoundSection().padding(.top, 12)
                            } label: { Label("预警语音", systemImage: "speaker.wave.2").font(.headline) }
                            Divider()
                            DisclosureGroup {
                                VStack(spacing: 16) { ColorSection(); DetectionSection() }.padding(.top, 12)
                            } label: { Label("本地识别规则", systemImage: "viewfinder").font(.headline) }
                            Divider()
                            DisclosureGroup {
                                AutomaticClickSection().padding(.top, 12)
                            } label: { Label("报警后自动点击", systemImage: "cursorarrow.click").font(.headline) }
                            Divider()
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(preview.intel.directory).font(.caption).textSelection(.enabled)
                                    Button("选择目录") { preview.intel.chooseDirectory() }
                                }.padding(.top, 12)
                            } label: { Label("EVE 日志目录", systemImage: "folder").font(.headline) }
                        }
                        .disclosureGroupStyle(FullWidthDisclosureStyle())
                        .padding(18)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                    }.padding(20)
                }
            }.frame(width: 660, height: 620)
        }
        .task {
            while !Task.isCancelled {
                preview.refresh()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
        .onAppear { model.refreshPermission(); preview.refresh(); syncPreviewAlarm() }
        .onChange(of: preview.isLocked) { model.setPreviewInteractionLocked($0) }
        .onReceive(model.$config) { preview.updateMonitoringRules($0) }
        .onChange(of: model.state) { _ in syncPreviewAlarm() }
        .onChange(of: model.config.windowTarget) { _ in syncPreviewAlarm() }
        .onChange(of: model.config.captureMode) { _ in syncPreviewAlarm() }
    }
    private func syncPreviewAlarm() {
        guard !preview.groupRunning else { return }
        preview.updateAlarm(target: model.config.captureMode == .window ? model.config.windowTarget : nil, active: model.state == .triggered)
    }
}

private struct StatusBadge: View { let text: String; let active: Bool; var body: some View { Label(text, systemImage: active ? "dot.radiowaves.left.and.right" : "circle").padding(8).background(active ? Color.red.opacity(0.14) : Color.secondary.opacity(0.12), in: Capsule()) } }
private struct PermissionNotice: View { @EnvironmentObject var model: AppModel; var body: some View { HStack { Image(systemName: "lock.trianglebadge.exclamationmark").font(.title2); VStack(alignment: .leading) { Text("需要屏幕录制权限").bold(); Text("Screen Alarm 需要屏幕录制权限才能监控指定区域或窗口。") }; Spacer(); Button("打开系统设置") { PermissionService.openSystemSettings() }; Button("重新检查") { model.refreshPermission() } }.padding().background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10)) } }

private struct ColorSection: View { @EnvironmentObject var model: AppModel; var body: some View { VStack(alignment: .leading, spacing: 10) { Text("颜色规则").font(.headline); FlowLayout(items: model.config.colorRules) { rule in HStack(spacing: 6) { Circle().fill(Color(red: Double(rule.red)/255, green: Double(rule.green)/255, blue: Double(rule.blue)/255)).frame(width: 14, height: 14); Text(rule.hex).font(.system(.body, design: .monospaced)); Button { model.removeColor(rule) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }.padding(.horizontal, 8).padding(.vertical, 5).background(.quaternary, in: Capsule()) }; Button("+ 添加颜色") { RegionSelectionPresenter.selectColor { model.addColor($0) } }; HStack { Text("颜色容差 \(Int(model.config.colorTolerance))").frame(width: 160, alignment: .leading); Slider(value: $model.config.colorTolerance, in: 0...50, step: 1) }; Stepper("最小匹配像素数：\(model.config.minimumMatchingPixels)", value: $model.config.minimumMatchingPixels, in: 1...5000); Text("建议：颜色容差设为 33，最小匹配像素数设为 20。不同设备显示效果可能不同，首次使用请根据实际情况调试。").font(.caption).foregroundStyle(.secondary) } } }


private struct DetectionSection: View { @EnvironmentObject var model: AppModel; var body: some View { VStack(alignment: .leading, spacing: 10) { Text("检测").font(.headline); Picker("检测间隔", selection: $model.config.intervalMilliseconds) { Text("50 ms").tag(50); Text("100 ms").tag(100); Text("200 ms").tag(200); Text("500 ms").tag(500) }.pickerStyle(.segmented); HStack { Stepper("连续确认：\(model.config.requiredHits)", value: $model.config.requiredHits, in: 1...20); Spacer(); Stepper("解除确认：\(model.config.requiredMisses)", value: $model.config.requiredMisses, in: 1...20) } } } }

private struct SoundSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("预警语音").font(.headline)
            Text("预警频道：平缓语气，约 12 秒一次。\n本地进人：急促语气，约 4 秒一次，优先于频道预警。")
            HStack {
                Button("试听频道预警") { model.testIntelVoice() }
                Button("试听本地进人") { model.testAlarm() }
            }
            HStack {
                Text("声音大小 \(Int(model.config.alarmVolume * 100))%").frame(width: 170, alignment: .leading)
                Slider(value: $model.config.alarmVolume, in: 0...1, step: 0.05)
            }
        }
    }
}

private struct AutomaticClickSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("报警后自动点击").font(.headline)
            Toggle("报警存在且鼠标连续 1 分钟未移动时，自动单击左键", isOn: $model.config.automaticClickEnabled)
            Text("每次报警最多点击一次，点击位置为当时的鼠标位置。移动鼠标会重新开始计算 1 分钟。")
                .font(.caption).foregroundStyle(.secondary)
            if model.config.automaticClickEnabled {
                HStack {
                    Label(model.hasAccessibilityPermission ? "辅助功能权限已授权" : "需要辅助功能权限", systemImage: model.hasAccessibilityPermission ? "checkmark.shield.fill" : "hand.raised.fill")
                        .foregroundStyle(model.hasAccessibilityPermission ? .green : .orange)
                    Spacer()
                    if !model.hasAccessibilityPermission {
                        Button("请求权限") { model.requestAccessibilityPermission() }
                        Button("打开系统设置") { PermissionService.openAccessibilitySettings() }
                    }
                    Button("重新检查") { model.refreshPermission() }
                }
            }
        }
    }
}

private struct FlowLayout<Item: Identifiable, Content: View>: View { let items: [Item]; @ViewBuilder let content: (Item) -> Content; var body: some View { LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 8)], alignment: .leading, spacing: 6) { ForEach(items) { content($0) } } } }

private struct WindowFeatureDrawers: View {
    @ObservedObject var preview: MultiWindowPreview
    @ObservedObject var equipment: EquipmentMonitor
    let target: WindowTarget
    @State private var windowOpen = false
    @State private var intelOpen = false
    @State private var equipmentOpen = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisclosureGroup(isExpanded: $windowOpen) {
                WindowSettingsCard(preview: preview, target: target, embedded: true).padding(.top, 10)
            } label: { Label("监控小窗口", systemImage: "pip").font(.headline) }
            Divider()
            DisclosureGroup(isExpanded: $intelOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    CharacterIntelView(intel: preview.intel, title: target.title, monitoring: preview.monitoredIDs.contains(target.windowID))
                    IntelSettingsSection(intel: preview.intel, title: target.title)
                }.padding(.top, 10)
            } label: { Label("预警频道", systemImage: "antenna.radiowaves.left.and.right").font(.headline) }
            Divider()
            DisclosureGroup(isExpanded: $equipmentOpen) {
                EquipmentMonitorSection(monitor: equipment, preview: preview, target: target).padding(.top, 10)
            } label: { Label("装备监控", systemImage: "shield.lefthalf.filled").font(.headline) }
        }.disclosureGroupStyle(FullWidthDisclosureStyle())
    }
}

/// Only the header is a button; controls in expanded content retain their own hit areas.
private struct FullWidthDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.bold()).frame(width: 14)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            .accessibilityHint("点击整行展开或收起")
            if configuration.isExpanded { configuration.content }
        }
    }
}
