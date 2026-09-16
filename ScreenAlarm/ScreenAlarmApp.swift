import SwiftUI

@main
struct ScreenAlarmApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var preview = MultiWindowPreview()

    var body: some Scene {
        WindowGroup("Screen Alarm") {
            MainView().environmentObject(model).environmentObject(preview)
                .frame(minWidth: 680, minHeight: 690)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(preview.groupRunning ? "停止全部监控" : "开始全部监控") { preview.toggleAllMonitoring(model: model) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("关闭报警") { model.dismissAlarm(); preview.dismissIntelAlarm() }.disabled(model.state != .triggered && preview.yellowIDs.isEmpty)
                Button("打开设置") { NSApp.activate(ignoringOtherApps: true) }
            }
        }
        MenuBarExtra {
            Text(model.statusText)
            Divider()
            Button(preview.groupRunning ? "停止全部监控" : "开始全部监控") { preview.toggleAllMonitoring(model: model) }
            Button("关闭报警") { model.dismissAlarm(); preview.dismissIntelAlarm() }.disabled(model.state != .triggered && preview.yellowIDs.isEmpty)
            Button("打开设置") { NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button(preview.running ? "关闭多窗口预览" : "开启多窗口预览") { preview.toggle() }
            Button("显示全部预览") { preview.showPreviews() }
            Button(preview.isLocked ? "解锁预览" : "锁定预览（点击穿透）") { preview.toggleLock() }
            Divider()
            Button("退出") { NSApp.terminate(nil) }
        } label: {
            Image(nsImage: model.isMonitoring ? MonitoringStatusIcon.running : MonitoringStatusIcon.stopped)
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
