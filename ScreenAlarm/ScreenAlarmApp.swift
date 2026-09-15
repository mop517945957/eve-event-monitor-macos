import SwiftUI

@main
struct ScreenAlarmApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Screen Alarm") {
            MainView().environmentObject(model)
                .frame(minWidth: 680, minHeight: 690)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(model.isMonitoring ? "停止监控" : "开始监控") { model.toggleMonitoring() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("关闭报警") { model.dismissAlarm() }.disabled(model.state != .triggered)
                Button("打开设置") { NSApp.activate(ignoringOtherApps: true) }
            }
        }
        MenuBarExtra("Screen Alarm", systemImage: model.isMonitoring ? "eye.fill" : "eye") {
            Text(model.statusText)
            Divider()
            Button(model.isMonitoring ? "停止监控" : "开始监控") { model.toggleMonitoring() }
            Button("关闭报警") { model.dismissAlarm() }.disabled(model.state != .triggered)
            Button("打开设置") { NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button("退出") { NSApp.terminate(nil) }
        }
    }
}
