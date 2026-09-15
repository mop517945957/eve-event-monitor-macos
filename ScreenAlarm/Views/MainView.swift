import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { VStack(alignment: .leading) { Text("Screen Alarm").font(.largeTitle.bold()); Text("平安生产，财源滚滚").foregroundStyle(.secondary) }; Spacer(); StatusBadge(text: model.statusText, active: model.isMonitoring) }
                if !model.hasPermission { PermissionNotice() }
                MonitorSourceSection()
                Divider(); ColorSection(); Divider(); TemplateSection(); Divider(); DetectionSection(); Divider(); SoundSection()
                if let error = model.lastError { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Button("关闭报警") { model.dismissAlarm() }.buttonStyle(.bordered).controlSize(.large).disabled(model.state != .triggered)
                    Button(model.isMonitoring ? "停止监控" : "开始监控") { model.toggleMonitoring() }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                }.padding(.top, 4)
            }.padding(24)
        }
        .onAppear { model.refreshPermission() }
        .sheet(isPresented: $model.isWindowPickerPresented) { WindowPickerView().environmentObject(model) }
    }
}

private struct StatusBadge: View { let text: String; let active: Bool; var body: some View { Label(text, systemImage: active ? "dot.radiowaves.left.and.right" : "circle").padding(8).background(active ? Color.red.opacity(0.14) : Color.secondary.opacity(0.12), in: Capsule()) } }
private struct PermissionNotice: View { @EnvironmentObject var model: AppModel; var body: some View { HStack { Image(systemName: "lock.trianglebadge.exclamationmark").font(.title2); VStack(alignment: .leading) { Text("需要屏幕录制权限").bold(); Text("Screen Alarm 需要屏幕录制权限才能监控指定区域或窗口。") }; Spacer(); Button("打开系统设置") { PermissionService.openSystemSettings() }; Button("重新检查") { model.refreshPermission() } }.padding().background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10)) } }

private struct MonitorSourceSection: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("监控来源").font(.headline)
            if model.config.captureMode == .window, let target = model.config.windowTarget {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已绑定窗口：\(target.displayName)")
                    Text(model.config.windowCrop == nil ? "尚未选择窗口内区域" : "已选择窗口内监控区域")
                        .foregroundStyle(model.config.windowCrop == nil ? .orange : .secondary)
                    Text("仅监控此窗口内的框选内容；被遮挡或不在前台时仍可检测。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let region = model.config.region {
                VStack(alignment: .leading, spacing: 4) {
                    Text("区域：\(Int(region.width)) × \(Int(region.height)) 点 · 显示器 \(region.displayID)")
                    Text("已在独立悬浮窗口中实时放大预览").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("尚未选择监控区域或窗口").foregroundStyle(.secondary)
            }
            HStack {
                if model.lastPreview != nil { Button("显示预览窗口") { model.showRegionPreview() } }
                Button("选择监控区域") { RegionSelectionPresenter.selectRegion { model.setRegion($0) } }
                Button("选择监控窗口") { model.presentWindowPicker() }
                if model.config.captureMode == .window, model.config.windowTarget != nil {
                    Button("选择窗口内区域") { model.selectWindowCrop() }
                }
                if model.isLoadingWindows { ProgressView().controlSize(.small) }
            }
            Text("区域模式仅分析屏幕框选画面；窗口模式请先绑定窗口，再框选窗口内部区域。区域会跟随窗口移动，适合跨桌面和后台监控。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ColorSection: View { @EnvironmentObject var model: AppModel; var body: some View { VStack(alignment: .leading, spacing: 10) { Text("颜色规则").font(.headline); FlowLayout(items: model.config.colorRules) { rule in HStack(spacing: 6) { Circle().fill(Color(red: Double(rule.red)/255, green: Double(rule.green)/255, blue: Double(rule.blue)/255)).frame(width: 14, height: 14); Text(rule.hex).font(.system(.body, design: .monospaced)); Button { model.removeColor(rule) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }.padding(.horizontal, 8).padding(.vertical, 5).background(.quaternary, in: Capsule()) }; Button("+ 添加颜色") { RegionSelectionPresenter.selectColor { model.addColor($0) } }; HStack { Text("颜色容差 \(Int(model.config.colorTolerance))").frame(width: 160, alignment: .leading); Slider(value: $model.config.colorTolerance, in: 0...50, step: 1) }; Stepper("最小匹配像素数：\(model.config.minimumMatchingPixels)", value: $model.config.minimumMatchingPixels, in: 1...5000); Text("建议：颜色容差设为 33，最小匹配像素数设为 20。不同设备显示效果可能不同，首次使用请根据实际情况调试。").font(.caption).foregroundStyle(.secondary) } } }

private struct TemplateSection: View { @EnvironmentObject var model: AppModel; var body: some View { VStack(alignment: .leading, spacing: 10) { Text("固定样式 / 图标").font(.headline); HStack(alignment: .top) { ForEach(model.config.templateRules) { rule in VStack { if let image = TemplateStore.shared.image(for: rule) { Image(nsImage: NSImage(cgImage: image, size: NSSize(width: rule.width, height: rule.height))).resizable().scaledToFit().frame(width: 70, height: 48) }; Button(role: .destructive) { model.removeTemplate(rule) } label: { Image(systemName: "trash") }.buttonStyle(.borderless) } }; VStack(alignment: .leading, spacing: 6) { Button("截取红色图标") { RegionSelectionPresenter.selectTemplate { model.addTemplate($0) } }; Button("截取黄色图标") { RegionSelectionPresenter.selectTemplate { model.addTemplate($0) } } } }; HStack { Text("样式匹配度 \(Int(model.config.templateSimilarity * 100))%").frame(width: 160, alignment: .leading); Slider(value: $model.config.templateSimilarity, in: 0.5...1, step: 0.01) }; Text("框住单个 16×16 左右图标，并保留 1–2 像素边缘。模板识别不会因灰色文字或边线持续报警。").font(.caption).foregroundStyle(.secondary) } } }

private struct DetectionSection: View { @EnvironmentObject var model: AppModel; var body: some View { VStack(alignment: .leading, spacing: 10) { Text("检测").font(.headline); Picker("检测间隔", selection: $model.config.intervalMilliseconds) { Text("50 ms").tag(50); Text("100 ms").tag(100); Text("200 ms").tag(200); Text("500 ms").tag(500) }.pickerStyle(.segmented); HStack { Stepper("连续确认：\(model.config.requiredHits)", value: $model.config.requiredHits, in: 1...20); Spacer(); Stepper("解除确认：\(model.config.requiredMisses)", value: $model.config.requiredMisses, in: 1...20) } } } }

private struct SoundSection: View { @EnvironmentObject var model: AppModel; var body: some View { VStack(alignment: .leading, spacing: 8) { Text("报警声音").font(.headline); Text("当前：\(model.config.alarmSoundPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Default Alarm")"); HStack { Button("选择声音") { model.chooseSound() }; Button("试听") { model.testAlarm() }; if model.config.alarmSoundPath != nil { Button("恢复默认", role: .destructive) { model.config.alarmSoundPath = nil } } }; HStack { Text("声音大小 \(Int(model.config.alarmVolume * 100))%").frame(width: 170, alignment: .leading); Slider(value: $model.config.alarmVolume, in: 0...1, step: 0.05) } } } }

private struct FlowLayout<Item: Identifiable, Content: View>: View { let items: [Item]; @ViewBuilder let content: (Item) -> Content; var body: some View { LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 8)], alignment: .leading, spacing: 6) { ForEach(items) { content($0) } } } }
