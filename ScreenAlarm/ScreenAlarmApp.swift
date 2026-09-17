import SwiftUI

@main
struct ScreenAlarmApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var preview = MultiWindowPreview()
    @StateObject private var equipment = EquipmentMonitor()

    var body: some Scene {
        WindowGroup("Screen Alarm") {
            MainView().environmentObject(model).environmentObject(preview).environmentObject(equipment)
                .frame(minWidth: 680, minHeight: 690)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button((preview.groupRunning || equipment.running) ? "停止监护" : "开始监护") { preview.toggleProtection(model: model, equipment: equipment) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("静音当前提醒") { model.dismissAlarm(); preview.dismissIntelAlarm(); equipment.mute() }
                Button("打开设置") { NSApp.activate(ignoringOtherApps: true) }
            }
        }
        MenuBarExtra {
            Text(model.statusText)
            Text(equipment.running ? "装备监护：运行中" : "装备监护：未开启")
            Divider()
            Button((preview.groupRunning || equipment.running) ? "停止监护" : "开始监护") { preview.toggleProtection(model: model, equipment: equipment) }
            Button("静音当前提醒") { model.dismissAlarm(); preview.dismissIntelAlarm(); equipment.mute() }
            Button("打开设置") { NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button(preview.running ? "关闭多窗口预览" : "开启多窗口预览") { preview.toggle() }
            Button("显示全部预览") { preview.showPreviews() }
            Button(preview.isLocked ? "解锁预览" : "锁定预览（点击穿透）") { preview.toggleLock() }
            Divider()
            Button("退出") { NSApp.terminate(nil) }
        } label: {
            Image(nsImage: (model.isMonitoring || equipment.running) ? MonitoringStatusIcon.running : MonitoringStatusIcon.stopped)
                .renderingMode(.original)
                .accessibilityLabel("Screen Alarm：" + model.statusText)
        }
    }
}

/// Use an original-color image so the menu bar does not turn the running icon white.
private enum MonitoringStatusIcon {
    static let stopped = make(color: .white)
    static let running = make(color: .systemGreen)

    private static func make(color: NSColor) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let symbol = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil)!
        let image = NSImage(size: size, flipped: false) { bounds in
            let ratio = min(bounds.width / symbol.size.width, bounds.height / symbol.size.height)
            let rect = NSRect(x: (bounds.width - symbol.size.width * ratio) / 2,
                              y: (bounds.height - symbol.size.height * ratio) / 2,
                              width: symbol.size.width * ratio, height: symbol.size.height * ratio)
            symbol.draw(in: rect)
            color.setFill()
            bounds.fill(using: .sourceIn)
            return true
        }
        image.isTemplate = false
        return image
    }
}
