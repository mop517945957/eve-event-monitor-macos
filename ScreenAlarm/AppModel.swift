import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var config: DetectionConfig { didSet { store.save(config) } }
    @Published var isMonitoring = false
    @Published var state: DetectionState = .idle
    @Published var debug = DebugInfo()
    @Published var lastPreview: NSImage?
    @Published var hasPermission = PermissionService.hasScreenRecordingPermission
    @Published var lastError: String?
    @Published var selectableWindows: [WindowTarget] = []
    @Published var isWindowPickerPresented = false
    @Published var isLoadingWindows = false
    private let store = SettingsStore(), capture = ScreenCaptureService(), alarm = AlarmService()
    private let regionPreview = RegionPreviewWindowController()
    private var lastDetection = Date.distantPast, lastFrame = Date.distantPast, lastPreviewUpdate = Date.distantPast

    init() {
        config = store.load()
        capture.onImage = { [weak self] image in Task { @MainActor in self?.process(image) } }
        capture.onCaptureStopped = { [weak self] error in Task { @MainActor in self?.captureStopped(error) } }
    }
    var statusText: String { isMonitoring ? (state == .triggered ? "已触发报警" : "正在监控") : "未运行" }
    func refreshPermission() { hasPermission = PermissionService.hasScreenRecordingPermission }
    func toggleMonitoring() { isMonitoring ? stopMonitoring() : startMonitoring() }
    func startMonitoring() {
        refreshPermission(); guard hasPermission else { PermissionService.request(); lastError = "请先授予屏幕录制权限。"; return }
        guard hasSelectedSource else { lastError = config.captureMode == .window ? "请先选择监控窗口，并框选窗口内的监控区域。" : "请先选择监控区域。"; return }
        lastError = nil; state = .idle; debug = DebugInfo(); isMonitoring = true
        startCaptureForSelectedSource()
    }
    func stopMonitoring() { isMonitoring = false; capture.stop(); alarm.stop(); state = .idle; debug.hitFrames = 0; debug.missFrames = 0 }
    func process(_ image: CGImage) {
        let now = Date()
        // A selected region provides a live preview before monitoring starts. This only
        // creates an NSImage; colour/template detection still remains disabled.
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
        var top = 0.0
        for rule in config.templateRules { if let template = TemplateStore.shared.image(for: rule) { top = max(top, TemplateMatchingService.bestSimilarity(template: template, in: image, threshold: config.templateSimilarity)) }; if top >= config.templateSimilarity { break } }
        debug.topTemplateSimilarity = top
        advance(hit: colorResult.isMatch || top >= config.templateSimilarity)
    }
    private func advance(hit: Bool) {
        if hit { debug.hitFrames += 1; debug.missFrames = 0; if state != .triggered && debug.hitFrames >= config.requiredHits { state = .triggered; alarm.startRepeating(path: config.alarmSoundPath, interval: 1.0, volume: config.alarmVolume) } else if state == .idle { state = .detecting } }
        else {
            debug.missFrames += 1
            debug.hitFrames = 0
            if state == .triggered && debug.missFrames >= config.requiredMisses {
                // Target is truly gone: automatically clear both the alarm sound and latch.
                alarm.stop()
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
        config.captureMode = .window
        config.windowTarget = target
        config.windowCrop = nil
        isWindowPickerPresented = false
        regionPreview.prepareForNewRegion()
        startCaptureForSelectedSource()
    }
    func selectWindowCrop() {
        guard let target = config.windowTarget else { lastError = "请先选择监控窗口。"; return }
        lastError = nil
        Task {
            do {
                // Refresh the frame immediately before selection, then save a crop
                // relative to that frame so future window moves do not matter.
                let refreshed = try await capture.refreshedTarget(for: target)
                config.windowTarget = refreshed
                RegionSelectionPresenter.selectRegion { [weak self] region in self?.setWindowCrop(from: region, in: refreshed) }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
    func addColor(_ color: ColorRule) { if !config.colorRules.contains(color) { config.colorRules.append(color) } }
    func removeColor(_ color: ColorRule) { config.colorRules.removeAll { $0.id == color.id } }
    func addTemplate(_ image: CGImage) { if let rule = TemplateStore.shared.save(image) { config.templateRules.append(rule) } }
    func removeTemplate(_ rule: TemplateRule) { TemplateStore.shared.delete(rule); config.templateRules.removeAll { $0.id == rule.id } }
    func dismissAlarm() { alarm.stop() }
    func showRegionPreview() { regionPreview.show() }
    func testAlarm() { alarm.playOnce(path: config.alarmSoundPath, volume: config.alarmVolume) }
    func chooseSound() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio]; panel.allowsMultipleSelection = false; if panel.runModal() == .OK { config.alarmSoundPath = panel.url?.path } }

    var hasSelectedSource: Bool {
        switch config.captureMode {
        case .region: return config.region != nil
        case .window: return config.windowTarget != nil && config.windowCrop != nil
        }
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
            state = .idle
        }
    }

    private func setWindowCrop(from region: MonitorRegion, in target: WindowTarget) {
        guard target.frame.width > 0, target.frame.height > 0,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == region.displayID
              }) else {
            lastError = "无法确定窗口内区域，请重新选择监控窗口。"
            return
        }
        let selected = CGRect(
            x: screen.frame.minX + region.x,
            y: screen.frame.minY + region.y,
            width: region.width,
            height: region.height
        )
        let clipped = selected.intersection(target.frame)
        guard clipped.width >= 3, clipped.height >= 3 else {
            lastError = "请在已绑定窗口内部拖拽监控区域。"
            return
        }
        let x = (clipped.minX - target.frame.minX) / target.frame.width
        let y = 1 - (clipped.maxY - target.frame.minY) / target.frame.height
        let width = clipped.width / target.frame.width
        let height = clipped.height / target.frame.height
        config.windowCrop = WindowCrop(x: x, y: y, width: width, height: height)
        regionPreview.prepareForNewRegion()
        startCaptureForSelectedSource()
    }
}
