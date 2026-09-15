import SwiftUI

struct WindowPickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选择监控窗口").font(.title2.bold())
            Text("将只捕获这个窗口的内容；即使它被其他窗口遮挡或不在前台，监控仍会继续。窗口关闭、最小化或重启后请重新选择。").font(.callout).foregroundStyle(.secondary)

            if model.selectableWindows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "macwindow").font(.largeTitle).foregroundStyle(.secondary)
                    Text("未找到可监控窗口").font(.headline)
                    Text("请先打开目标程序窗口，然后点击刷新。")
                        .foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.selectableWindows) { window in
                    Button {
                        model.setWindow(window)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(window.applicationName).fontWeight(.semibold)
                            Text(window.title.isEmpty ? "未命名窗口" : window.title)
                                .lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 280)
            }

            HStack {
                Button("刷新列表") { model.presentWindowPicker() }
                Spacer()
                Button("取消") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }
}
