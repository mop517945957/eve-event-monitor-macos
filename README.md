# EVE 事件监测（macOS）

EVE 事件监测是一款完全本地运行的 macOS 13+ 屏幕事件监测工具。它可以监控指定的屏幕区域或应用窗口，在目标颜色达到设定比例或识别到保存的图像模板时发出警报。软件不包含网络请求、服务器、截图历史或上传功能。

EVE Event Monitor is a fully local macOS 13+ SwiftUI app that watches a selected screen region or application window. It alarms when a configured target colour occupies enough pixels or when a saved image template is found. No network code, server, screenshot history, or upload is used.

## Download

Download the latest Apple Silicon installer from [GitHub Releases](https://github.com/mop517945957/eve-event-monitor-macos/releases/latest).

## Open and build

1. Open `ScreenAlarm.xcodeproj` in Xcode 15 or newer.
2. Select the **ScreenAlarm** scheme and an Apple Silicon (or Intel) Mac destination.
3. Build and run (`⌘R`).

Command line build (requires full Xcode, not Command Line Tools):

```sh
xcodebuild -project ScreenAlarm.xcodeproj -scheme ScreenAlarm -configuration Debug build
```

## Permission

The first capture attempt requests **Screen Recording** permission. If it is denied, open **System Settings → Privacy & Security → Screen Recording**, enable Screen Alarm, then restart the app. The app intentionally has no network entitlement.

## Implemented

- Region selection per display, Retina-aware point-to-pixel cropping
- Multi-colour picker with RGB/HEX magnifier and tolerance/area threshold
- ScreenCaptureKit capture pipeline, configurable 50–500 ms detection cadence
- Consecutive-hit/release state machine preventing duplicate alarms
- Default or user-selected WAV/MP3/M4A sound with test playback
- Template capture, persistent PNG templates, fixed-scale sampled template matching
- Settings persistence in UserDefaults and Application Support
- Menu-bar controls, background operation, permission UI, and collapsible debug data

## Deliberate first-version limits

- Template matching is fixed-size and fixed-scale; it does not recognize rotated or scaled templates.
- Template matching uses a fast sampled RGB comparison rather than OpenCV; very large templates can require a longer interval.
- Captured previews are shown after the first live frame, not retained as screenshot history.
