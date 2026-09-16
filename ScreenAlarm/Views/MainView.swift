import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preview: MultiWindowPreview
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { VStack(alignment: .leading) { Text("Screen Alarm").font(.largeTitle.bold()); Text("平安生产，财源滚滚").foregroundStyle(.secondary) }; Spacer(); StatusBadge(text: model.statusText, active: model.isMonitoring) }
                if !model.hasPermission { PermissionNotice() }
                MultiWindowPreviewSection(preview: preview)
                IntelSettingsSection(intel: preview.intel)
                Divider(); ColorSection(); Divider(); DetectionSection(); Divider(); SoundSection(); Divider(); AutomaticClickSection()
                if let error = model.lastError { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Button("关闭报警") { model.dismissAlarm(); preview.dismissIntelAlarm() }.buttonStyle(.bordered).controlSize(.large).disabled(model.state != .triggered && preview.yellowIDs.isEmpty)
                    Button(preview.groupRunning ? "停止全部监控" : "开始全部监控") { preview.toggleAllMonitoring(model: model) }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                }.padding(.top, 4)
            }.padding(24)
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

private struct SoundSection: View { @EnvironmentObject var model: AppModel; var body: some View { VStack(alignment: .leading, spacing: 8) { Text("报警声音").font(.headline); Text("当前：\(model.config.alarmSoundPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Default Alarm")"); HStack { Button("选择声音") { model.chooseSound() }; Button("试听") { model.testAlarm() }; if model.config.alarmSoundPath != nil { Button("恢复默认", role: .destructive) { model.config.alarmSoundPath = nil } } }; HStack { Text("声音大小 \(Int(model.config.alarmVolume * 100))%").frame(width: 170, alignment: .leading); Slider(value: $model.config.alarmVolume, in: 0...1, step: 0.05) } } } }

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
