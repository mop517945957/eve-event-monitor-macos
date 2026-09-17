import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var config: DetectionConfig {
        didSet {
            store.save(config)
            guard config.automaticClickEnabled != oldValue.automaticClickEnabled else { return }
            if config.automaticClickEnabled, state == .triggered {
                armMouseAutomation()
            } else {
                mouseAutomation.disarm()
            }
        }
    }
    @Published var isMonitoring = false
    @Published var state: DetectionState = .idle
    @Published var debug = DebugInfo()
    @Published var lastPreview: NSImage?
    @Published var hasPermission = PermissionService.hasScreenRecordingPermission
    @Published var hasAccessibilityPermission = PermissionService.hasAccessibilityPermission
    @Published var lastError: String?
    @Published var selectableWindows: [WindowTarget] = []
    @Published var isWindowPickerPresented = false
    @Published var isLoadingWindows = false
    private let store = SettingsStore(), capture = ScreenCaptureService(), alarm = AlarmService()
    private let mouseAutomation = MouseAutomationService()
    private let regionPreview = RegionPreviewWindowController()
    private var cropCapture: ScreenCaptureService?
    private var cropEditor: WindowCropEditor?
    private var cropRequest = UUID()
    private var lastDetection = Date.distantPast, lastFrame = Date.distantPast, lastPreviewUpdate = Date.distantPast

    init() {
        config = store.load()
        capture.onImage = { [weak self] image in Task { @MainActor in self?.process(image) } }
        capture.onCaptureStopped = { [weak self] error in Task { @MainActor in self?.captureStopped(error) } }
    }
    var statusText: String { isMonitoring ? (state == .triggered ? "已触发报警" : "正在监控") : "未运行" }
    func refreshPermission() {
        hasPermission = PermissionService.hasScreenRecordingPermission
        hasAccessibilityPermission = PermissionService.hasAccessibilityPermission
    }
    func requestAccessibilityPermission() {
        PermissionService.requestAccessibility()
        refreshPermission()
    }
    func toggleMonitoring() { isMonitoring ? stopMonitoring() : startMonitoring() }
    func startMonitoring() {
        refreshPermission(); guard hasPermission else { PermissionService.request(); lastError = "请先授予屏幕录制权限。"; return }
        guard hasSelectedSource else { lastError = config.captureMode == .window ? "请先选择监控窗口，并框选窗口内的监控区域。" : "请先选择监控区域。"; return }
        lastError = nil; state = .idle; debug = DebugInfo(); isMonitoring = true
        startCaptureForSelectedSource()
    }
    func stopMonitoring() { isMonitoring = false; capture.stop(); alarm.stop(); mouseAutomation.disarm(); state = .idle; debug.hitFrames = 0; debug.missFrames = 0 }
    /// Aggregate independent window detectors into one sound/automatic-click lifecycle.
    func updateGroupStatus(running: Bool, triggered: Bool) {
        isMonitoring = running
        if triggered && state != .triggered {
            state = .triggered
            alarm.startVoice(.local, volume: config.alarmVolume)
            if config.automaticClickEnabled { armMouseAutomation() }
        } else if !triggered {
            if state == .triggered { alarm.stop(); mouseAutomation.disarm() }
            state = .idle
        }
    }
    func process(_ image: CGImage) {
        let now = Date()
        // A selected region provides a live preview before monitoring starts. This only
        // creates an NSImage; colour detection still remains disabled.
        if now.timeIntervalSince(lastPreviewUpdate) >= (1.0 / 15.0) {
            let preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            lastPreview = preview
            regionPreview.update(image: preview)
            lastPreviewUpdate = now
        }
        guard isMonitoring, now.timeIntervalSince(lastDetection) * 1000 >= Double(config.intervalMilliseconds) else { return }
        lastDetection = now; debug.fps = lastFrame == .distantPast ? 0 : 1 / max(0.001, now.timeIntervalSince(lastFrame)); lastFrame = now
        let colorResult = ColorDetectionService.match(in: image, rules: config.colorRules, tolerance: config.colorTolerance, minimum: config.minimumMatchingPixels)
        debug.matchingPixels = colorResult.maximumPixels
        debug.matchingColorHex = colorResult.matchingRule?.hex
        // Legacy template settings are retained for compatibility but no longer evaluated.
        debug.topTemplateSimilarity = 0
        advance(hit: colorResult.isMatch)
    }
    private func advance(hit: Bool) {
        if hit {
            debug.hitFrames += 1
            debug.missFrames = 0
            if state != .triggered && debug.hitFrames >= config.requiredHits {
                state = .triggered
                alarm.startVoice(.local, volume: config.alarmVolume)
                if config.automaticClickEnabled {
                    armMouseAutomation()
                }
            } else if state == .idle {
                state = .detecting
            }
        }
        else {
            debug.missFrames += 1
            debug.hitFrames = 0
            if state == .triggered && debug.missFrames >= config.requiredMisses {
                // Target is truly gone: automatically clear both the alarm sound and latch.
                alarm.stop()
                mouseAutomation.disarm()
                state = .idle
            } else if state == .detecting {
                state = .idle
            }
        }
    }
    func setRegion(_ region: MonitorRegion) {
        config.captureMode = .region
        config.region = region
        regionPreview.prepareForNewRegion()
        refreshPermission()
        guard hasPermission else { lastError = "请先授予屏幕录制权限后才能显示区域预览。"; return }
        // Start a capture stream immediately for the live preview. Detection remains off
        // until the user presses Start Monitoring.
        startCaptureForSelectedSource()
    }
    func presentWindowPicker() {
        refreshPermission()
        guard hasPermission else { lastError = "请先授予屏幕录制权限后才能选择监控窗口。"; return }
        isLoadingWindows = true
        lastError = nil
        Task {
            do {
                selectableWindows = try await capture.availableWindows()
                isLoadingWindows = false
                isWindowPickerPresented = true
            } catch {
                isLoadingWindows = false
                lastError = error.localizedDescription
            }
        }
    }
    func setWindow(_ target: WindowTarget) {
        stopMonitoring()
        cropRequest = UUID()
        isLoadingWindows = false
        cropCapture?.stop(); cropCapture = nil
        cropEditor?.cancel(); cropEditor = nil
        lastPreview = nil
        lastError = nil
        config.captureMode = .window
        config.windowTarget = target
        config.windowCrop = nil
        isWindowPickerPresented = false
        regionPreview.prepareForNewRegion()
    }
    func selectWindowCrop(onSelected: ((WindowCrop) -> Void)? = nil) {
        guard let target = config.windowTarget else { lastError = "请在上方窗口列表中指定监控窗口。"; return }
        stopMonitoring()
        cropEditor?.cancel(); cropEditor = nil
        cropCapture?.stop()
        let request = UUID()
        cropRequest = request
        let snapshot = ScreenCaptureService()
        cropCapture = snapshot
        isLoadingWindows = true
        lastError = nil
        snapshot.onImage = { [weak self] image in
            Task { @MainActor in
                guard let self, self.cropRequest == request, self.cropCapture != nil else { return }
                self.cropCapture?.stop(); self.cropCapture = nil
                self.isLoadingWindows = false
                self.cropEditor = WindowCropEditor(image: image, title: target.displayName) { [weak self] crop in
                    guard let self, self.cropRequest == request else { return }
                    self.cropEditor = nil
                    guard let crop else { return }
                    self.config.captureMode = .window
                    self.config.windowCrop = crop
                    onSelected?(crop)
                    self.regionPreview.prepareForNewRegion()
                    self.startCaptureForSelectedSource()
                }
                self.cropEditor?.show()
            }
        }
        Task {
            do {
                let refreshed = try await snapshot.refreshedTarget(for: target)
                guard cropRequest == request else { snapshot.stop(); return }
                config.windowTarget = refreshed
                try await snapshot.start(window: refreshed, crop: nil)
                if cropRequest != request || cropCapture == nil { snapshot.stop(); return }
                try await Task.sleep(nanoseconds: 8_000_000_000)
                guard cropRequest == request, cropCapture != nil else { return }
                snapshot.stop(); cropCapture = nil; isLoadingWindows = false
                lastError = "未收到窗口画面，请恢复目标窗口后重试。"
            } catch {
                guard cropRequest == request else { snapshot.stop(); return }
                snapshot.stop(); cropCapture = nil; isLoadingWindows = false
                lastError = error.localizedDescription
            }
        }
    }
    func addColor(_ color: ColorRule) { if !config.colorRules.contains(color) { config.colorRules.append(color) } }
    func removeColor(_ color: ColorRule) { config.colorRules.removeAll { $0.id == color.id } }
    func dismissAlarm() { alarm.stop() }
    func setPreviewInteractionLocked(_ locked: Bool) { regionPreview.setInteractionLocked(locked) }
    func showRegionPreview() { regionPreview.show() }
    private let voicePreview = AlarmService()
    func testAlarm() { voicePreview.startVoice(.local, volume: config.alarmVolume, repeating: false) }
    func testIntelVoice() { voicePreview.startVoice(.intel, volume: config.alarmVolume, repeating: false) }
    func chooseSound() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio]; panel.allowsMultipleSelection = false; if panel.runModal() == .OK { config.alarmSoundPath = panel.url?.path } }

    var hasSelectedSource: Bool {
        return config.captureMode == .window && config.windowTarget != nil && config.windowCrop != nil
    }

    private func startCaptureForSelectedSource() {
        let mode = config.captureMode
        let region = config.region
        let windowTarget = config.windowTarget
        let windowCrop = config.windowCrop
        Task {
            do {
                switch mode {
                case .region:
                    guard let region else { return }
                    try await capture.start(region: region)
                case .window:
                    guard let windowTarget else { return }
                    try await capture.start(window: windowTarget, crop: windowCrop)
                }
            } catch {
                captureFailed(error)
            }
        }
    }

    private func captureStopped(_ error: Error) {
        // An externally closed/unavailable source must never leave a stale alarm on.
        captureFailed(error)
    }

    private func captureFailed(_ error: Error) {
        lastError = error.localizedDescription
        if isMonitoring {
            isMonitoring = false
            alarm.stop()
            mouseAutomation.disarm()
            state = .idle
        }
    }

    private func armMouseAutomation() {
        mouseAutomation.arm { [weak self] in
            guard let self else { return }
            self.hasAccessibilityPermission = false
            self.lastError = "自动点击需要辅助功能权限；授权后，报警仍存在且鼠标静止满 1 分钟时会执行一次左键单击。"
            PermissionService.requestAccessibility()
        }
    }

}
