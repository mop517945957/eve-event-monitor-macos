import SwiftUI
import AppKit
import ScreenCaptureKit
import CoreImage
import ApplicationServices
import Carbon

/// Each acquired slot owns the semaphore until it has returned the slot.
/// A queued frame must not depend on the stream's weak lifetime to signal it.
final class ThumbnailDeliveryGate {
    private let semaphore = DispatchSemaphore(value: 1)
    func acquire() -> ThumbnailDeliveryPermit? {
        guard semaphore.wait(timeout: .now()) == .success else { return nil }
        return ThumbnailDeliveryPermit(semaphore: semaphore)
    }
}

final class ThumbnailDeliveryPermit {
    private let semaphore: DispatchSemaphore
    fileprivate init(semaphore: DispatchSemaphore) { self.semaphore = semaphore }
    deinit { semaphore.signal() }
}

/// Preview capture is deliberately separate from the full-resolution detector.
private final class ThumbnailStream: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CGImage) -> Void)?
    var onError: ((String) -> Void)?
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private let queue = DispatchQueue(label: "ScreenAlarm.thumbnail", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let delivery = ThumbnailDeliveryGate()

    func start(window: SCWindow, frameRate: Int) async throws {
        let config = SCStreamConfiguration()
        let scale = min(1, 640 / max(1, window.frame.width))
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(frameRate))
        config.queueDepth = 2
        config.showsCursor = false
        let capture = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = capture
        configuration = config
        try await capture.startCapture()
    }

    func setFrameRate(_ frameRate: Int) async throws {
        guard let configuration, let stream else { return }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(frameRate))
        try await stream.updateConfiguration(configuration)
    }

    func stop() {
        let old = stream
        stream = nil
        if let old { Task { try? await old.stopCapture() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer,
              let permit = delivery.acquire() else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(ci, from: ci.extent) else { return }
        DispatchQueue.main.async { [weak self, permit] in
            // Even if self is already gone, release after this queued frame is retired.
            defer { withExtendedLifetime(permit) {} }
            self?.onFrame?(image)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) }
    }
}

/// RegisterHotKey works while another app is active and reports conflicts instead of swallowing keys.
private final class PreviewHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x45564550 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<PreviewHotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak owner] in owner?.onPress?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(key: UInt32, modifiers: UInt32) -> Bool {
        guard handler != nil else { return false }
        var next: EventHotKeyRef?
        let result = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x45564550, id: 1), GetApplicationEventTarget(), 0, &next)
        guard result == noErr else { return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = next
        return true
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct WindowMonitorHits {
    private(set) var triggered = false
    private var hits = 0
    private var misses = 0
    mutating func advance(hit: Bool, requiredHits: Int, requiredMisses: Int) {
        if hit {
            hits += 1; misses = 0
            if hits >= requiredHits { triggered = true }
        } else {
            misses += 1; hits = 0
            if misses >= requiredMisses { triggered = false }
        }
    }
}

@MainActor
private final class WindowMonitorSession {
    let target: WindowTarget
    var config: DetectionConfig
    private let capture = ScreenCaptureService()
    private let gate = ThumbnailDeliveryGate()
    private var hits = WindowMonitorHits()
    private var lastDetection = Date.distantPast
    private var stopped = false
    private var crop: WindowCrop?
    private var recovery: Task<Void, Never>?
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var onRecovered: (() -> Void)?
    var triggered: Bool { hits.triggered }
    init(target: WindowTarget, config: DetectionConfig) {
        self.target = target; self.config = config
        let gate = self.gate
        capture.onImage = { [weak self] image in
            guard let permit = gate.acquire() else { return }
            Task { @MainActor [weak self, permit] in
                defer { withExtendedLifetime(permit) {} }
                guard let self, !self.stopped else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastDetection) * 1000 >= Double(self.config.intervalMilliseconds) else { return }
                self.lastDetection = now
                let result = ColorDetectionService.match(in: image, rules: self.config.colorRules, tolerance: self.config.colorTolerance, minimum: self.config.minimumMatchingPixels)
                let previous = self.hits.triggered
                self.hits.advance(hit: result.isMatch, requiredHits: self.config.requiredHits, requiredMisses: self.config.requiredMisses)
                if previous != self.hits.triggered { self.onChange?() }
            }
        }
        capture.onCaptureStopped = { [weak self] error in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.scheduleRecovery(error)
            }
        }
    }
    func start(crop: WindowCrop) async throws {
        self.crop = crop
        do {
            try await capture.start(window: target, crop: crop)
            if stopped { capture.stop() }
        } catch { scheduleRecovery(error) }
    }
    private func scheduleRecovery(_ error: Error) {
        guard !stopped, recovery == nil, let crop else { return }
        onError?("采集中断，正在自动重连：" + error.localizedDescription)
        recovery = Task { [weak self] in
            defer { self?.recovery = nil }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard let self, !self.stopped else { return }
                do {
                    try await self.capture.start(window: self.target, crop: crop)
                    guard !self.stopped, !Task.isCancelled else { self.capture.stop(); return }
                    self.onRecovered?()
                    return
                } catch { self.onError?("采集中断，正在自动重连：" + error.localizedDescription) }
            }
        }
    }
    func stop() {
        stopped = true
        recovery?.cancel(); recovery = nil
        capture.stop()
    }
}

@MainActor
private final class PreviewLockNotice {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "")
    private var dismissal: Task<Void, Never>?
    init() {
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true; panel.isOpaque = false; panel.backgroundColor = .clear
        let background = NSVisualEffectView()
        background.material = .hudWindow; background.blendingMode = .behindWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 12
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.alignment = .center; label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: background.centerXAnchor), label.centerYAnchor.constraint(equalTo: background.centerYAnchor)])
        panel.contentView = background
    }
    func show(locked: Bool, alarm: Bool = false) {
        dismissal?.cancel()
        label.stringValue = locked ? "🔒 已锁定 · 鼠标点击穿透" : (alarm ? "🔔 检测到报警 · 已自动解锁" : "🔓 已解锁 · 可点击和拖动")
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let screen { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 170, y: screen.visibleFrame.maxY - 85)) }
        panel.orderFrontRegardless()
        dismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_500_000_000) } catch { return }
            self?.panel.orderOut(nil)
        }
    }
}

struct WindowPreviewSettings: Codable, Equatable {
    var width: Int
    var height: Int
    var opacity: Double
    var crop: WindowCrop?
}

@MainActor
final class MultiWindowPreview: ObservableObject {
    @Published private(set) var windows: [WindowTarget] = []
    @Published private(set) var selected: Set<String>
    @Published private(set) var running = false
    @Published private(set) var refreshing = false
    @Published private(set) var groupRunning = false
    @Published private(set) var monitoredIDs: Set<UInt32> = []
    @Published private(set) var alarmIDs: Set<UInt32> = []
    let intel: LocalIntel
    @Published private(set) var yellowIDs: Set<UInt32> = []
    private let yellowSound = AlarmService()
    private var yellowSoundRunning = false
    private var mutedIntelSignature = ""
    private var intelSignature = ""
    private var monitors: [UInt32: WindowMonitorSession] = [:]
    private weak var groupModel: AppModel?
    private var groupGeneration = UUID()
    private var groupStarting = false
    private var lockNotice: PreviewLockNotice?
    private var enableNotices = true

    func isPreviewVisible(for target: WindowTarget) -> Bool { running && isSelected(target) }
    func togglePreview(for target: WindowTarget) {
        if isPreviewVisible(for: target) { select(target, enabled: false) }
        else {
            if !running {
                selected = [key(for: target)]
                defaults.set(Array(selected), forKey: "preview.selected")
                toggle()
            } else { select(target, enabled: true) }
        }
    }
    func toggleProtection(for target: WindowTarget, model: AppModel, equipment: EquipmentMonitor) {
        guard !groupStarting, equipment.calibrating == nil else { return }
        if monitoredIDs.contains(target.windowID) || equipment.isRunning(for: target) {
            monitors.removeValue(forKey: target.windowID)?.stop()
            monitoredIDs.remove(target.windowID)
            equipment.stop(for: target)
            refreshGroupStatus()
            return
        }
        model.refreshPermission()
        guard model.hasPermission else { error = "请先授予屏幕录制权限"; return }
        if !groupRunning { model.stopMonitoring(); groupModel = model; groupRunning = true }
        monitoredIDs.insert(target.windowID)
        if !isPreviewVisible(for: target) { togglePreview(for: target) }
        equipment.start(targets: [target], adding: true)
        if let crop = settings(for: target).crop {
            let monitor = WindowMonitorSession(target: target, config: model.config)
            monitors[target.windowID] = monitor
            monitor.onChange = { [weak self, weak monitor] in
                guard let self, let monitor, self.monitors[target.windowID] === monitor else { return }
                self.refreshGroupStatus()
            }
            monitor.onError = { [weak self, weak monitor] message in
                guard let self, let monitor, self.monitors[target.windowID] === monitor else { return }
                self.error = "\(target.title)：\(message)"; self.refreshGroupStatus()
            }
            Task {
                try? await monitor.start(crop: crop)
                if monitors[target.windowID] !== monitor { monitor.stop() }
            }
        }
        refreshGroupStatus()
    }
    func toggleProtection(model: AppModel, equipment: EquipmentMonitor) {
        guard equipment.calibrating == nil else { return }
        if groupRunning || equipment.running {
            stopAllMonitoring(); equipment.stop()
        } else {
            startAllMonitoring(model: model)
            if !equipment.rules.isEmpty { equipment.start(targets: visibleWindows) }
        }
    }
    func toggleAllMonitoring(model: AppModel) {
        if groupRunning { stopAllMonitoring() } else { startAllMonitoring(model: model) }
    }
    func stopAllMonitoring() {
        groupGeneration = UUID()
        groupStarting = false
        for monitor in monitors.values { monitor.stop() }
        monitors.removeAll(); monitoredIDs = []; alarmIDs = []
        groupRunning = false
        refreshIntelWarnings()
        groupModel?.updateGroupStatus(running: false, triggered: false)
        updateAlarm(target: nil, active: false)
    }
    func startAllMonitoring(model: AppModel) {
        guard !groupRunning else { return }
        model.refreshPermission()
        guard model.hasPermission else { PermissionService.request(); error = "请先授予屏幕录制权限"; return }
        if let target = model.config.windowTarget, let crop = model.config.windowCrop, settings(for: target).crop == nil { setCrop(crop, for: target) }
        model.stopMonitoring()
        groupModel = model
        mutedIntelSignature = ""
        groupRunning = true
        groupStarting = true
        error = nil
        let request = UUID(); groupGeneration = request
        Task {
            do {
                let current = try await ScreenCaptureService().availableWindows()
                guard groupRunning, groupGeneration == request else { return }
                windows = current
                let targets = visibleWindows
                guard !targets.isEmpty else { stopAllMonitoring(); error = "未找到在线角色窗口，请先登录游戏。"; return }
                for target in targets { selected.insert(key(for: target)) }
                defaults.set(Array(selected), forKey: "preview.selected")
                if !running { toggle() } else { refresh(); showPreviews() }
                for target in targets {
                    guard groupRunning, groupGeneration == request else { break }
                    monitoredIDs.insert(target.windowID)
                    guard let crop = settings(for: target).crop else { continue }
                    let monitor = WindowMonitorSession(target: target, config: model.config)
                    monitors[target.windowID] = monitor
                    monitor.onChange = { [weak self] in self?.refreshGroupStatus() }
                    monitor.onError = { [weak self] message in
                        guard let self, self.groupGeneration == request else { return }
                        self.error = "\(target.title)：\(message)"
                        self.refreshGroupStatus()
                    }
                    monitor.onRecovered = { [weak self] in
                        guard let self, self.groupGeneration == request else { return }
                        if self.error?.hasPrefix("\(target.title)：采集中断") == true { self.error = nil }
                        self.refreshGroupStatus()
                    }
                    do { try await monitor.start(crop: crop) }
                    catch { monitor.onError?(error.localizedDescription) }
                    if groupGeneration != request { monitor.stop(); return }
                }
                guard groupGeneration == request else { return }
                groupStarting = false
                refreshGroupStatus()
                if monitoredIDs.isEmpty { groupRunning = false }
            } catch {
                guard groupGeneration == request else { return }
                stopAllMonitoring(); self.error = error.localizedDescription
            }
        }
    }
    func updateMonitoringRules(_ config: DetectionConfig) {
        for monitor in monitors.values { monitor.config = config }
    }
    private func refreshGroupStatus() {
        if !groupStarting && monitoredIDs.isEmpty { groupRunning = false }
        alarmIDs = Set(monitors.filter { $0.value.triggered }.map(\.key))
        groupModel?.updateGroupStatus(running: !monitoredIDs.isEmpty, triggered: !alarmIDs.isEmpty)
        refreshIntelWarnings()
        updateAlarm(target: nil, active: !alarmIDs.isEmpty)
    }
    private func showLockNotice(alarm: Bool = false) {
        guard enableNotices else { return }
        if lockNotice == nil { lockNotice = PreviewLockNotice() }
        lockNotice?.show(locked: isLocked, alarm: alarm)
    }
    @Published private(set) var isLocked = false
    @Published private(set) var frameRate: Int
    @Published private(set) var shortcutKey: UInt32
    @Published private(set) var shortcutModifiers: UInt32
    @Published private(set) var shortcutAvailable = false
    private var hotKey: PreviewHotKey?
    static let keyChoices: [(String, UInt32)] = [("L", UInt32(kVK_ANSI_L)), ("F6", UInt32(kVK_F6)), ("F7", UInt32(kVK_F7)), ("F8", UInt32(kVK_F8)), ("F9", UInt32(kVK_F9)), ("F10", UInt32(kVK_F10)), ("F11", UInt32(kVK_F11)), ("F12", UInt32(kVK_F12))]
    static let modifierChoices: [(String, UInt32)] = [("⌃⌥ Control + Option", UInt32(controlKey | optionKey)), ("⌘⇧ Command + Shift", UInt32(cmdKey | shiftKey)), ("⌃⇧ Control + Shift", UInt32(controlKey | shiftKey)), ("⌘⌥ Command + Option", UInt32(cmdKey | optionKey))]
    func toggleLock() {
        guard !alarmActive && yellowIDs.isEmpty else { error = "报警期间预览保持可点击，报警解除后可再次锁定。"; showLockNotice(alarm: true); return }
        isLocked.toggle()
        showLockNotice()
        for session in sessions.values { session.panel.ignoresMouseEvents = isLocked }
    }
    func configureShortcut(key: UInt32, modifiers: UInt32) {
        guard key != shortcutKey || modifiers != shortcutModifiers || !shortcutAvailable else { return }
        guard let hotKey, hotKey.register(key: key, modifiers: modifiers) else {
            error = "快捷键注册失败或已被占用，请选择其他组合。原快捷键保持不变。"
            return
        }
        shortcutKey = key; shortcutModifiers = modifiers; shortcutAvailable = true
        defaults.set(Int(key), forKey: "preview.shortcutKey")
        defaults.set(Int(modifiers), forKey: "preview.shortcutModifiers")
        error = nil
    }
    func setFrameRate(_ value: Int) {
        guard [10, 15, 30, 60].contains(value) else { return }
        frameRate = value; defaults.set(value, forKey: "preview.frameRate")
        for session in sessions.values {
            Task { [weak self] in
                do { try await session.setFrameRate(value) }
                catch { self?.error = "无法调整预览帧率：\(error.localizedDescription)" }
            }
        }
    }
    @Published var error: String?
    @Published var alwaysOnTop: Bool {
        didSet {
            defaults.set(alwaysOnTop, forKey: "preview.alwaysOnTop")
            for session in sessions.values { session.panel.level = alwaysOnTop ? .floating : .normal }
        }
    }
    @Published var opacity: Double {
        didSet {
            defaults.set(opacity, forKey: "preview.opacity")
            for session in sessions.values { session.panel.alphaValue = opacity }
        }
    }
    @Published var previewWidth: Int
    @Published var previewHeight: Int
    func applyPreviewSize() {
        previewWidth = min(3840, max(64, previewWidth))
        previewHeight = min(2160, max(40, previewHeight))
        defaults.set(previewWidth, forKey: "preview.width")
        defaults.set(previewHeight, forKey: "preview.height")
        for session in sessions.values {
            var frame = session.panel.frame
            frame.origin.y = frame.maxY - CGFloat(previewHeight)
            frame.size = NSSize(width: previewWidth, height: previewHeight)
            session.panel.setFrame(frame, display: true)
        }
    }
    @Published private var windowSettings: [String: WindowPreviewSettings] = [:]
    func settings(for target: WindowTarget) -> WindowPreviewSettings {
        if let saved = windowSettings[key(for: target)] { return saved }
        let frame = defaults.string(forKey: "preview.layout." + key(for: target)).map(NSRectFromString)
        return WindowPreviewSettings(width: Int(frame?.width ?? CGFloat(previewWidth)), height: Int(frame?.height ?? CGFloat(previewHeight)), opacity: opacity)
    }
    private func saveSettings(_ value: WindowPreviewSettings, for target: WindowTarget) {
        windowSettings[key(for: target)] = value
        defaults.set(try? JSONEncoder().encode(windowSettings), forKey: "preview.perWindow.v1")
    }
    func setOpacity(_ value: Double, for target: WindowTarget) {
        var settings = settings(for: target)
        settings.opacity = min(1, max(0.2, value))
        saveSettings(settings, for: target)
        sessions[target.windowID]?.panel.alphaValue = settings.opacity
    }
    func setSize(width: Int, height: Int, for target: WindowTarget) {
        var settings = settings(for: target)
        settings.width = min(3840, max(64, width)); settings.height = min(2160, max(40, height))
        saveSettings(settings, for: target)
        if let panel = sessions[target.windowID]?.panel {
            var frame = panel.frame
            frame.origin.y = frame.maxY - CGFloat(settings.height)
            frame.size = NSSize(width: settings.width, height: settings.height)
            panel.setFrame(frame, display: true)
        }
    }
    func setCrop(_ crop: WindowCrop, for target: WindowTarget) {
        var settings = settings(for: target); settings.crop = crop
        saveSettings(settings, for: target)
    }
    private var sessions: [UInt32: PreviewSession] = [:]
    private var timer: Timer?
    private var generation = 0
    private var alarmTarget: WindowTarget?
    private var alarmActive = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, enableHotkey: Bool = true) {
        self.defaults = defaults
        intel = LocalIntel(defaults: defaults, start: enableHotkey)
        enableNotices = enableHotkey
        let savedFPS = defaults.integer(forKey: "preview.frameRate")
        frameRate = [10, 15, 30, 60].contains(savedFPS) ? savedFPS : 30
        let savedKey = UInt32(clamping: defaults.object(forKey: "preview.shortcutKey") as? Int ?? Int(kVK_ANSI_L))
        let savedModifiers = UInt32(clamping: defaults.object(forKey: "preview.shortcutModifiers") as? Int ?? (controlKey | optionKey))
        shortcutKey = Self.keyChoices.contains(where: { $0.1 == savedKey }) ? savedKey : UInt32(kVK_ANSI_L)
        shortcutModifiers = Self.modifierChoices.contains(where: { $0.1 == savedModifiers }) ? savedModifiers : UInt32(controlKey | optionKey)
        if let data = defaults.data(forKey: "preview.perWindow.v1"),
           let saved = try? JSONDecoder().decode([String: WindowPreviewSettings].self, from: data) { windowSettings = saved }
        previewWidth = min(3840, max(64, defaults.object(forKey: "preview.width") as? Int ?? 320))
        previewHeight = min(2160, max(40, defaults.object(forKey: "preview.height") as? Int ?? 200))
        opacity = min(1, max(0.2, defaults.object(forKey: "preview.opacity") as? Double ?? 1))
        selected = Set(defaults.stringArray(forKey: "preview.selected") ?? [])
        alwaysOnTop = defaults.object(forKey: "preview.alwaysOnTop") as? Bool ?? true
        intel.onChange = { [weak self] in self?.refreshIntelWarnings() }
        if enableHotkey {
            let hotKey = PreviewHotKey()
            self.hotKey = hotKey
            hotKey.onPress = { [weak self] in self?.toggleLock() }
            shortcutAvailable = hotKey.register(key: shortcutKey, modifiers: shortcutModifiers)
            if !shortcutAvailable { error = "锁定快捷键被占用，请选择其他组合；仍可用按钮锁定/解锁。" }
        }
    }

    var visibleWindows: [WindowTarget] {
        windows.filter { Self.isEVE($0) }
    }
    static func isEVE(_ target: WindowTarget) -> Bool {
        let app = target.applicationName.lowercased()
        let bundle = target.bundleIdentifier?.lowercased() ?? ""
        let title = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let isClient = app == "eve" || app == "eve online" || bundle.contains("ccpgames.eve")
        guard isClient, !bundle.contains("launcher"), title.lowercased().hasPrefix("eve - ") else { return false }
        return !title.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func key(for target: WindowTarget) -> String {
        let base = (target.bundleIdentifier ?? target.applicationName) + "|" + target.title
        // Identical unnamed windows have no durable character identity.
        let duplicates = windows.filter { ($0.bundleIdentifier ?? $0.applicationName) == (target.bundleIdentifier ?? target.applicationName) && $0.title == target.title }
        return target.title.isEmpty || duplicates.count > 1 ? base + "|\(target.windowID)" : base
    }
    func isSelected(_ target: WindowTarget) -> Bool { selected.contains(key(for: target)) }
    func select(_ target: WindowTarget, enabled: Bool) {
        let key = key(for: target)
        if enabled { selected.insert(key) } else {
            selected.remove(key)
            sessions.removeValue(forKey: target.windowID)?.close()
        }
        defaults.set(Array(selected), forKey: "preview.selected")
        if running { refresh() }
    }
    func selectEVE() {
        for target in windows where Self.isEVE(target) { selected.insert(key(for: target)) }
        defaults.set(Array(selected), forKey: "preview.selected")
        if running { refresh() }
    }
    func toggle() {
        if running {
            running = false
            generation += 1
            timer?.invalidate(); timer = nil
            for session in sessions.values { session.close() }
            sessions.removeAll()
        } else {
            running = true
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            refresh()
        }
    }
    func showPreviews() { for session in sessions.values { session.panel.orderFrontRegardless() } }
    func updateAlarm(target: WindowTarget?, active: Bool) {
        alarmTarget = target; alarmActive = active
        if active || !yellowIDs.isEmpty {
            let wasLocked = isLocked
            isLocked = false
            if wasLocked { showLockNotice(alarm: true) }
            for session in sessions.values { session.panel.ignoresMouseEvents = false }
        }
        for session in sessions.values { session.setAlarm(matchesAlarm(session.target), yellow: yellowIDs.contains(session.target.windowID)) }
    }
    func dismissIntelAlarm() {
        mutedIntelSignature = intelSignature
        yellowSound.stop(); yellowSoundRunning = false
    }
    private func refreshIntelWarnings() {
        let states = groupRunning ? visibleWindows.filter { monitoredIDs.contains($0.windowID) }.map { ($0, intel.status(for: $0.title)) } : []
        yellowIDs = Set(states.filter { $0.1.nearest != nil }.map { $0.0.windowID })
        intelSignature = states.compactMap { target, status -> String? in
            guard let report = status.nearest else { return nil }
            return "\(target.windowID)|\(report.channel)|\(report.system)|\(report.date.timeIntervalSince1970)"
        }.sorted().joined(separator: ";")
        let soundWanted = !yellowIDs.isEmpty && alarmIDs.isEmpty && intelSignature != mutedIntelSignature
        if soundWanted && !yellowSoundRunning {
            yellowSound.startVoice(.intel, volume: groupModel?.config.alarmVolume ?? 0.8)
            yellowSoundRunning = true
        } else if !soundWanted && yellowSoundRunning {
            yellowSound.stop(); yellowSoundRunning = false
        }
        updateAlarm(target: alarmTarget, active: groupRunning ? !alarmIDs.isEmpty : alarmActive)
    }
    private func matchesAlarm(_ target: WindowTarget) -> Bool {
        if groupRunning { return alarmIDs.contains(target.windowID) }
        guard alarmActive, let alarmTarget else { return false }
        return alarmTarget.windowID == target.windowID ||
            (alarmTarget.bundleIdentifier == target.bundleIdentifier && alarmTarget.title == target.title && !target.title.isEmpty)
    }
    static func retainingLiveWindows(discovered: [WindowTarget], previous: [WindowTarget], livePIDs: Set<Int32>) -> [WindowTarget] {
        var result = discovered
        var ids = Set(discovered.map(\.windowID))
        for target in previous where livePIDs.contains(target.applicationPID) {
            if ids.insert(target.windowID).inserted { result.append(target) }
        }
        return result.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func refresh() {
        guard !refreshing else { return }
        guard PermissionService.hasScreenRecordingPermission else {
            error = "请先授予屏幕录制权限，再刷新窗口。"
            PermissionService.request()
            return
        }
        refreshing = true
        let currentGeneration = generation
        Task {
            defer { refreshing = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard currentGeneration == generation else { return }
                let candidates = content.windows.filter {
                    $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier &&
                    $0.owningApplication != nil && $0.windowLayer == 0 &&
                    $0.frame.width >= 80 && $0.frame.height >= 60
                }
                let discovered = candidates.map { w in
                    let app = w.owningApplication!
                    return WindowTarget(windowID: w.windowID, applicationPID: app.processID,
                        bundleIdentifier: app.bundleIdentifier, applicationName: app.applicationName,
                        title: w.title ?? "", frameX: w.frame.minX, frameY: w.frame.minY,
                        frameWidth: w.frame.width, frameHeight: w.frame.height)
                }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                // A Space transition can temporarily omit a live window. Keep its
                // preview and detector until the owning process actually exits.
                let retained = windows + monitors.values.map(\.target) + sessions.values.map(\.target)
                let livePIDs = Set(retained.compactMap { target -> Int32? in
                    guard let app = NSRunningApplication(processIdentifier: target.applicationPID), !app.isTerminated else { return nil }
                    return target.applicationPID
                })
                windows = Self.retainingLiveWindows(discovered: discovered, previous: retained, livePIDs: livePIDs)
                if groupRunning {
                    let removed = monitoredIDs.filter { id in
                        guard let target = retained.first(where: { $0.windowID == id }) else { return true }
                        return !livePIDs.contains(target.applicationPID)
                    }
                    for id in removed { monitors.removeValue(forKey: id)?.stop(); monitoredIDs.remove(id) }
                    if !removed.isEmpty { refreshGroupStatus(); error = "部分游戏窗口已关闭，已停止对应监控。" }
                }
                guard running else { return }
                let wanted = Set(visibleWindows.filter { isSelected($0) }.map(\.windowID))
                for id in Array(sessions.keys) where !wanted.contains(id) { sessions.removeValue(forKey: id)?.close() }
                for target in windows where wanted.contains(target.windowID) {
                    guard running, currentGeneration == generation else { break }
                    guard isSelected(target) else { continue }
                    if let existing = sessions[target.windowID] {
                        if !existing.failed {
                            existing.setAlarm(matchesAlarm(target), yellow: yellowIDs.contains(target.windowID))
                            continue
                        }
                        // Keep the thumbnail during a transient discovery gap.
                        guard candidates.contains(where: { $0.windowID == target.windowID }) else { continue }
                        sessions.removeValue(forKey: target.windowID)?.close()
                    }
                    guard let source = candidates.first(where: { $0.windowID == target.windowID }) else { continue }
                    let settings = settings(for: target)
                    let session = PreviewSession(target: target, layoutKey: key(for: target), index: sessions.count, alwaysOnTop: alwaysOnTop, initialSize: NSSize(width: settings.width, height: settings.height))
                    sessions[target.windowID] = session
                    session.panel.ignoresMouseEvents = isLocked
                    session.panel.alphaValue = settings.opacity
                    // Preserve the saved position but use this window's explicit dimensions.
                    var frame = session.panel.frame
                    frame.origin.y = frame.maxY - CGFloat(settings.height)
                    frame.size = NSSize(width: settings.width, height: settings.height)
                    session.panel.setFrame(frame, display: true)
                    session.onResize = { [weak self] size in
                        guard let self else { return }
                        var value = self.settings(for: target)
                        value.width = Int(size.width); value.height = Int(size.height)
                        self.saveSettings(value, for: target)
                    }
                    session.onActivated = { [weak self] in self?.error = nil }
                    session.onMessage = { [weak self] message in self?.error = message }
                    session.setAlarm(matchesAlarm(target), yellow: yellowIDs.contains(target.windowID))
                    do { try await session.start(source, frameRate: frameRate) }
                    catch {
                        if sessions[target.windowID] === session {
                            session.showError("捕获失败，稍后自动重试")
                            sessions.removeValue(forKey: target.windowID)?.close()
                            self.error = "\(target.displayName)：\(error.localizedDescription)"
                        }
                    }
                    // Stop may have happened while ScreenCaptureKit was starting.
                    if !running || currentGeneration != generation || !isSelected(target) || sessions[target.windowID] !== session { session.close() }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
private final class PreviewSession: NSObject, NSWindowDelegate {
    let target: WindowTarget
    let panel: NSPanel
    private let capture = ThumbnailStream()
    private let imageView = ClickablePreview()
    var onMessage: ((String) -> Void)?
    var onResize: ((NSSize) -> Void)?
    var onActivated: (() -> Void)?
    private var activationTask: Task<Void, Never>?
    private let layoutKey: String
    private var closed = false
    private(set) var failed = false

    init(target: WindowTarget, layoutKey: String, index: Int, alwaysOnTop: Bool, initialSize: NSSize) {
        self.target = target
        self.layoutKey = "preview.layout." + layoutKey
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let origin = NSPoint(x: screen.minX + 20 + CGFloat(index % 3) * 330, y: screen.maxY - 250 - CGFloat(index / 3) * 230)
        panel = NSPanel(contentRect: NSRect(origin: origin, size: initialSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = target.title.isEmpty ? target.applicationName : target.title
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = alwaysOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.minSize = PreviewGeometry.minimumSize
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.layer?.borderWidth = 3
        imageView.toolTip = "单击切换角色；拖动画面移动；拖动四边或四角缩放；右键隐藏"
        imageView.onClick = { [weak self] in self?.activateTarget() }
        panel.contentView = imageView
        if let value = UserDefaults.standard.string(forKey: self.layoutKey) {
            let frame = NSRectFromString(value)
            if frame.width >= PreviewGeometry.minimumSize.width && frame.height >= PreviewGeometry.minimumSize.height && NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                panel.setFrame(frame, display: false)
            }
        }
        panel.delegate = self
        capture.onFrame = { [weak self] image in
            guard let self, !self.closed else { return }
            self.imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        capture.onError = { [weak self] message in
            self?.failed = true
            self?.showError(message)
        }
    }
    func start(_ window: SCWindow, frameRate: Int) async throws {
        panel.orderFrontRegardless()
        try await capture.start(window: window, frameRate: frameRate)
        if closed { capture.stop() }
    }
    func setFrameRate(_ value: Int) async throws { try await capture.setFrameRate(value) }
    func close() { closed = true; activationTask?.cancel(); capture.stop(); panel.orderOut(nil) }
    func showError(_ message: String) { activationMessage(message); imageView.image = nil }
    func setAlarm(_ active: Bool, yellow: Bool = false) {
        imageView.layer?.borderColor = (active ? NSColor.systemRed : (yellow ? NSColor.systemYellow : NSColor.clear)).cgColor
        panel.title = (active ? "🔴 报警 · " : (yellow ? "🟡 频道预警 · " : "")) + (target.title.isEmpty ? target.applicationName : target.title)
    }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame(); onResize?(panel.frame.size) }
    private func saveFrame() { UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: layoutKey) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { panel.orderOut(nil); return false }

    private func activationMessage(_ message: String) {
        imageView.toolTip = message
        onMessage?("\(target.displayName)：\(message)")
    }
    private func activateTarget() {
        guard PermissionService.hasAccessibilityPermission else {
            PermissionService.requestAccessibility()
            activationMessage("切换窗口需要辅助功能权限，请在系统设置中允许")
            return
        }
        guard let app = NSRunningApplication(processIdentifier: target.applicationPID) else {
            showError("窗口已关闭，请刷新列表"); return
        }
        activationTask?.cancel()
        activationTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Validate the exact process/window before activating; never pick another EVE process.
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard !Task.isCancelled, !closed else { return }
                guard let source = content.windows.first(where: {
                    $0.windowID == target.windowID && $0.owningApplication?.processID == target.applicationPID
                }) else { activationMessage("目标窗口已重建，请刷新窗口列表后重试"); return }
                let gameWindows = content.windows.filter {
                    $0.owningApplication?.processID == target.applicationPID &&
                    ($0.title ?? "").lowercased().hasPrefix("eve - ") && $0.windowLayer == 0
                }
                let element = AXUIElementCreateApplication(target.applicationPID)
                AXUIElementSetMessagingTimeout(element, 0.5)
                var raw: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &raw)
                let axWindows = raw as? [AXUIElement] ?? []
                let descriptions = axWindows.map { window -> ActivationWindowDescription in
                    var title: CFTypeRef?, position: CFTypeRef?, size: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                    AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position)
                    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size)
                    var point = CGPoint.zero, dimensions = CGSize.zero
                    var frame: CGRect?
                    if let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                        if AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) {
                            frame = CGRect(origin: point, size: dimensions)
                        }
                    }
                    return ActivationWindowDescription(title: title as? String ?? "", frame: frame)
                }
                let index = WindowActivationMatch.index(title: source.title ?? target.title, frame: source.frame, candidates: descriptions)
                let window = index.map { axWindows[$0] }
                guard window != nil || gameWindows.count == 1 else {
                    activationMessage("同一进程有多个角色窗口，无法唯一定位目标，请刷新后重试")
                    return
                }
                if let window {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                }
                app.unhide()
                // A single game window can be activated by PID even when EVE omits its AX title.
                // Raising an AX window alone does not request application/Space activation.
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, !closed else { return }
                if let window {
                    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementSetAttributeValue(element, kAXFocusedWindowAttribute as CFString, window)
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                }
                try await Task.sleep(nanoseconds: 850_000_000)
                guard !Task.isCancelled, !closed else { return }
                let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                let isVisible = visible.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowID }
                if app.isActive && isVisible {
                    imageView.toolTip = "单击切换角色；拖动画面移动；拖动边缘缩放"
                    onActivated?()
                } else {
                    activationMessage("macOS 尚未切到目标桌面。请检查系统设置 → 桌面与程序坞 → 调度中心：切换应用时切换到该应用窗口所在的空间。")
                }
            } catch is CancellationError { return }
            catch { activationMessage("切换失败：\(error.localizedDescription)") }
        }
    }

}

struct ActivationWindowDescription {
    var title: String
    var frame: CGRect?
}

enum WindowActivationMatch {
    static func index(title: String, frame: CGRect, candidates: [ActivationWindowDescription]) -> Int? {
        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        }
        let names = candidates.indices.filter { !normalized(title).isEmpty && normalized(candidates[$0].title) == normalized(title) }
        if names.count == 1 { return names[0] }
        let pool = names.isEmpty ? Array(candidates.indices) : names
        let geometry = pool.filter {
            guard let other = candidates[$0].frame else { return false }
            return abs(other.minX - frame.minX) < 3 && abs(other.minY - frame.minY) < 3 &&
                abs(other.width - frame.width) < 3 && abs(other.height - frame.height) < 3
        }
        return geometry.count == 1 ? geometry[0] : nil
    }
}

struct PreviewEdges: OptionSet {
    let rawValue: Int
    static let left = PreviewEdges(rawValue: 1)
    static let right = PreviewEdges(rawValue: 2)
    static let bottom = PreviewEdges(rawValue: 4)
    static let top = PreviewEdges(rawValue: 8)
}

enum PreviewGeometry {
    static let minimumSize = NSSize(width: 64, height: 40)
    static func resized(_ original: NSRect, dx: CGFloat, dy: CGFloat, edges: PreviewEdges) -> NSRect {
        var result = original
        if edges.contains(.left) {
            result.origin.x = min(original.maxX - minimumSize.width, original.minX + dx)
            result.size.width = original.maxX - result.minX
        } else if edges.contains(.right) { result.size.width = max(minimumSize.width, original.width + dx) }
        if edges.contains(.bottom) {
            result.origin.y = min(original.maxY - minimumSize.height, original.minY + dy)
            result.size.height = original.maxY - result.minY
        } else if edges.contains(.top) { result.size.height = max(minimumSize.height, original.height + dy) }
        return result
    }
}

private final class ClickablePreview: NSImageView {
    var onClick: (() -> Void)?
    private var startPoint: NSPoint?
    private var startFrame = NSRect.zero
    private var edges: PreviewEdges = []
    private var dragged = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    private func edges(at point: NSPoint) -> PreviewEdges {
        var result: PreviewEdges = []
        if point.x < 7 { result.insert(.left) }
        else if point.x > bounds.width - 7 { result.insert(.right) }
        if point.y < 7 { result.insert(.bottom) }
        else if point.y > bounds.height - 7 { result.insert(.top) }
        return result
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds.insetBy(dx: 7, dy: 7), cursor: .openHand)
        addCursorRect(NSRect(x: 0, y: 0, width: 7, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - 7, y: 0, width: 7, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: 7), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.height - 7, width: bounds.width, height: 7), cursor: .resizeUpDown)
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startPoint = NSEvent.mouseLocation
        startFrame = window.frame
        edges = edges(at: convert(event.locationInWindow, from: nil))
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let startPoint, let window else { return }
        let point = NSEvent.mouseLocation
        let dx = point.x - startPoint.x, dy = point.y - startPoint.y
        guard dragged || abs(dx) + abs(dy) > 3 else { return }
        dragged = true
        let frame = edges.isEmpty ? startFrame.offsetBy(dx: dx, dy: dy) : PreviewGeometry.resized(startFrame, dx: dx, dy: dy, edges: edges)
        window.setFrame(frame, display: true)
        window.invalidateCursorRects(for: self)
    }
    override func mouseUp(with event: NSEvent) {
        guard startPoint != nil else { return }
        startPoint = nil
        if !dragged && edges.isEmpty { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let item = NSMenuItem(title: "隐藏此预览", action: #selector(hidePreview), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func hidePreview() { window?.orderOut(nil) }
}

struct MultiWindowPreviewSection: View {
    @ObservedObject var preview: MultiWindowPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("游戏窗口", systemImage: "rectangle.on.rectangle").font(.headline)
                Spacer()
                Button("刷新") { preview.refresh() }.disabled(preview.refreshing)
                Button("全选预览") { preview.selectEVE() }
                if preview.refreshing { ProgressView().controlSize(.small) }
            }
            Text("展开角色卡片，分别设置监控区域、预览大小和透明度。点击“开始全部监控”恢复所有已设置区域的在线角色；各窗口共用下方颜色规则。")
                .font(.caption).foregroundStyle(.secondary)
            if preview.visibleWindows.isEmpty {
                Text("未找到角色窗口，请登录 EVE 角色后刷新。").foregroundStyle(.secondary)
            }
            if preview.groupRunning { Text("正在监控 \(preview.monitoredIDs.count) 个窗口").font(.caption).foregroundStyle(.secondary) }
            ForEach(preview.visibleWindows) { target in
                WindowSettingsCard(preview: preview, target: target)
            }
            HStack {
                Button(preview.running ? "关闭全部预览" : "开启预览") { preview.toggle() }.buttonStyle(.borderedProminent)
                Button("显示全部预览") { preview.showPreviews() }.disabled(!preview.running)
                Toggle("预览置顶", isOn: $preview.alwaysOnTop).toggleStyle(.checkbox)
                Button("切换权限设置") { PermissionService.openAccessibilitySettings() }
            }
            HStack {
                Text("预览刷新率")
                Picker("预览刷新率", selection: Binding(get: { preview.frameRate }, set: { preview.setFrameRate($0) })) {
                    ForEach([10, 15, 30, 60], id: \.self) { Text("\($0) FPS").tag($0) }
                }.labelsHidden().frame(width: 105)
                Spacer()
                Button(preview.isLocked ? "解锁预览" : "锁定并穿透点击") { preview.toggleLock() }
                Label(preview.isLocked ? "已锁定 · 点击穿透" : "可点击", systemImage: preview.isLocked ? "lock.fill" : "lock.open")
                    .font(.caption).foregroundStyle(preview.isLocked ? .orange : .secondary)
            }
            HStack {
                Text("锁定快捷键")
                Picker("组合键", selection: Binding(get: { preview.shortcutModifiers }, set: { preview.configureShortcut(key: preview.shortcutKey, modifiers: $0) })) {
                    ForEach(MultiWindowPreview.modifierChoices, id: \.1) { Text($0.0).tag($0.1) }
                }.labelsHidden().frame(width: 215)
                Picker("按键", selection: Binding(get: { preview.shortcutKey }, set: { preview.configureShortcut(key: $0, modifiers: preview.shortcutModifiers) })) {
                    ForEach(MultiWindowPreview.keyChoices, id: \.1) { Text($0.0).tag($0.1) }
                }.labelsHidden().frame(width: 80)
                Text(preview.shortcutAvailable ? "全局生效" : "快捷键未启用").font(.caption).foregroundStyle(.secondary)
            }
            Text("锁定后所有角色预览不接收鼠标点击或拖动；报警自动解锁，解除报警后保持可点击。实际刷新率受游戏后台帧率影响，60 FPS 会增加资源占用。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = preview.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(14).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct WindowSettingsCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var preview: MultiWindowPreview
    let target: WindowTarget
    var embedded = false
    @State private var expanded = false
    private var isTarget: Bool { model.config.captureMode == .window && model.config.windowTarget?.windowID == target.windowID }
    private var settings: WindowPreviewSettings { preview.settings(for: target) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !embedded {
            HStack {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 18)
                }.buttonStyle(.plain).accessibilityLabel(expanded ? "收起窗口设置" : "展开窗口设置")
                Toggle(target.title, isOn: Binding(get: { preview.isSelected(target) }, set: { preview.select(target, enabled: $0) }))
                    .toggleStyle(.checkbox).lineLimit(1)
                Spacer()
                if preview.monitoredIDs.contains(target.windowID) || isTarget { Text(preview.monitoredIDs.contains(target.windowID) ? "监控中" : "已选区域").font(.caption).foregroundStyle(.tint) }
                Button(expanded ? "收起" : "设置") { expanded.toggle() }.buttonStyle(.borderless)
            }
            CharacterIntelView(intel: preview.intel, title: target.title, monitoring: preview.monitoredIDs.contains(target.windowID))
            }
            if expanded || embedded {
                Divider()
                HStack {
                    Text("监控区域").frame(width: 85, alignment: .leading)
                    Text(settings.crop == nil ? "未设置" : "已保存窗口内区域").foregroundStyle(.secondary)
                    Spacer()
                    Button(settings.crop == nil ? "选择区域" : "重新框选") {
                        preview.stopAllMonitoring()
                        model.setWindow(target)
                        model.config.windowCrop = settings.crop
                        model.selectWindowCrop { crop in preview.setCrop(crop, for: target) }
                    }.disabled(model.isLoadingWindows)

                }
                HStack {
                    Text("宽度").frame(width: 85, alignment: .leading)
                    Slider(value: Binding(get: { Double(settings.width) }, set: {
                        preview.setSize(width: Int($0.rounded()), height: settings.height, for: target)
                    }), in: 64...3840, step: 1)
                    TextField("宽度", value: Binding(get: { settings.width }, set: {
                        preview.setSize(width: $0, height: settings.height, for: target)
                    }), format: .number.grouping(.never))
                        .frame(width: 70).textFieldStyle(.roundedBorder)
                    Text("点").foregroundStyle(.secondary)
                }
                HStack {
                    Text("高度").frame(width: 85, alignment: .leading)
                    Slider(value: Binding(get: { Double(settings.height) }, set: {
                        preview.setSize(width: settings.width, height: Int($0.rounded()), for: target)
                    }), in: 40...2160, step: 1)
                    TextField("高度", value: Binding(get: { settings.height }, set: {
                        preview.setSize(width: settings.width, height: $0, for: target)
                    }), format: .number.grouping(.never))
                        .frame(width: 70).textFieldStyle(.roundedBorder)
                    Text("点").foregroundStyle(.secondary)
                }
                HStack {
                    Text("透明度 \(Int(((1 - settings.opacity) * 100).rounded()))%").frame(width: 85, alignment: .leading)
                    Slider(value: Binding(get: { 1 - settings.opacity }, set: { preview.setOpacity(1 - $0, for: target) }), in: 0...0.8, step: 0.01)
                    Text("0% 不透明").font(.caption).foregroundStyle(.secondary)
                }
                Text("仅影响此角色；大小和透明度自动保存，拖动预览边缘也可缩放。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if isTarget, let crop = model.config.windowCrop, settings.crop == nil { preview.setCrop(crop, for: target) }
        }
    }
}

struct SharedPreviewSettings: View {
    @ObservedObject var preview: MultiWindowPreview
    var body: some View { VStack(alignment: .leading, spacing: 12) {
        Toggle("预览置顶", isOn: $preview.alwaysOnTop)
            HStack {
                Text("预览刷新率")
                Picker("预览刷新率", selection: Binding(get: { preview.frameRate }, set: { preview.setFrameRate($0) })) {
                    ForEach([10, 15, 30, 60], id: \.self) { Text("\($0) FPS").tag($0) }
                }.labelsHidden().frame(width: 105)
                Spacer()
                Button(preview.isLocked ? "解锁预览" : "锁定并穿透点击") { preview.toggleLock() }
                Label(preview.isLocked ? "已锁定 · 点击穿透" : "可点击", systemImage: preview.isLocked ? "lock.fill" : "lock.open")
                    .font(.caption).foregroundStyle(preview.isLocked ? .orange : .secondary)
            }
            HStack {
                Text("锁定快捷键")
                Picker("组合键", selection: Binding(get: { preview.shortcutModifiers }, set: { preview.configureShortcut(key: preview.shortcutKey, modifiers: $0) })) {
                    ForEach(MultiWindowPreview.modifierChoices, id: \.1) { Text($0.0).tag($0.1) }
                }.labelsHidden().frame(width: 215)
                Picker("按键", selection: Binding(get: { preview.shortcutKey }, set: { preview.configureShortcut(key: $0, modifiers: preview.shortcutModifiers) })) {
                    ForEach(MultiWindowPreview.keyChoices, id: \.1) { Text($0.0).tag($0.1) }
                }.labelsHidden().frame(width: 80)
                Text(preview.shortcutAvailable ? "全局生效" : "快捷键未启用").font(.caption).foregroundStyle(.secondary)
            }
            Text("锁定后所有角色预览不接收鼠标点击或拖动；报警自动解锁，解除报警后保持可点击。实际刷新率受游戏后台帧率影响，60 FPS 会增加资源占用。")
                .font(.caption).foregroundStyle(.secondary)

    } }
}
