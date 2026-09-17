import SwiftUI
import AppKit

struct EquipmentRule: Codable, Identifiable {
    var id = UUID()
    var target: WindowTarget
    var name: String
    var crop: WindowCrop
    var active: [[Double]] = []
    var inactive: [[Double]] = []
    var validated = false
    var ready: Bool { validated && active.count >= 3 && inactive.count >= 1 }
    var calibrationStatus: String {
        if ready { return "已校准 · 待监护" }
        if active.isEmpty && inactive.isEmpty { return "待采样" }
        if active.isEmpty { return "已采关闭 · 待采开启" }
        if inactive.isEmpty { return "已采开启 · 待采关闭" }
        return "两组已采集 · 差异不足，请检查选区"
    }
}

/// Small normalized RGB templates retain the icon as an identity check as well
/// as the surrounding activation indication. Out-of-distribution frames abstain.
enum EquipmentVision {
    static func feature(_ image: CGImage) -> [Double]? {
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let ok = bytes.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard ok else { return nil }
        return stride(from: 0, to: bytes.count, by: 4).flatMap { i in [Double(bytes[i])/255, Double(bytes[i+1])/255, Double(bytes[i+2])/255] }
    }
    // Use only the side/bottom ring. The fixed green overheating marker at
    // twelve o'clock and the colored module icon must not vote for activation.
    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == 3072, b.count == 3072 else { return 1 }
        // Inspect two concentric bands: wider selections put the actual
        // cycle ring further inside the normalized crop. Do not dilute that
        // signal by averaging it with unrelated dark background.
        return [(0.62, 1.0), (0.40, 0.85)].map { lower, upper in
            var total = 0.0, count = 0.0
            for y in 9..<32 { for x in 0..<32 {
                let dx = (Double(x)-15.5)/16, dy = (Double(y)-15.5)/16
                let r = sqrt(dx*dx+dy*dy)
                guard r >= lower, r <= upper else { continue }
                for c in 0..<3 { total += abs(a[(y*32+x)*3+c]-b[(y*32+x)*3+c]); count += 1 }
            } }
            return total / max(1,count)
        }.max() ?? 1
    }

    /// Distribution of ring brightness is independent of the angular position
    /// of the white cycle arc. Exclude the static top marker from this too.
    static func ringProfile(_ pixels: [Double]) -> [Double] {
        guard pixels.count == 3072 else { return [] }
        var values: [Double] = []
        for y in 9..<32 { for x in 0..<32 {
            let dx = (Double(x)-15.5)/16, dy = (Double(y)-15.5)/16
            let r = sqrt(dx*dx+dy*dy)
            if r >= 0.62 && r <= 1 {
                let i = (y*32+x)*3
                values.append(0.2126*pixels[i] + 0.7152*pixels[i+1] + 0.0722*pixels[i+2])
            }
        } }
        return values.sorted()
    }
    static func profileDistance(_ a: [Double], _ b: [Double]) -> Double {
        let left = ringProfile(a), right = ringProfile(b)
        guard !left.isEmpty, left.count == right.count else { return 1 }
        return zip(left,right).reduce(0) { $0 + abs($1.0-$1.1) } / Double(left.count)
    }
    static func iconDistance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == 3072, b.count == 3072 else { return 1 }
        var total = 0.0
        for y in 11..<21 { for x in 11..<21 { for c in 0..<3 {
            total += abs(a[(y*32+x)*3+c] - b[(y*32+x)*3+c])
        } } }
        return total / 300
    }
    static func ringSignals(_ pixels: [Double]) -> (green: Double, white: Double) {
        guard pixels.count == 3072 else { return (0,0) }
        var green = 0.0, white = 0.0, count = 0.0
        for y in 12..<32 { for x in 0..<32 {
            let dx = (Double(x)-15.5)/16, dy = (Double(y)-15.5)/16
            let radius = sqrt(dx*dx+dy*dy)
            guard radius >= 0.4, radius <= 0.9 else { continue }
            let i = (y*32+x)*3, r = pixels[i], g = pixels[i+1], b = pixels[i+2]
            green += max(0,g-(r+b)/2); white += min(r,min(g,b)) > 0.45 ? 1 : 0; count += 1
        } }
        return (green/max(1,count),white/max(1,count))
    }
    static func separable(_ on: [[Double]], _ off: [[Double]]) -> Bool {
        guard on.count >= 3, !off.isEmpty else { return false }
        // An animated cycle can briefly resemble the stopped state. Require
        // clear running examples, not separation of every frame in the cycle.
        return on.filter { a in (off.map { distance(a,$0) }.min() ?? 0) > 0.025 }.count >= 3
    }
    /// Learn activation pixels from the two sample sets instead of letting
    /// moving space backgrounds dominate a whole-ring RGB comparison.
    static func learnedStopped(_ frame: [Double], active: [[Double]], inactive: [[Double]]) -> Bool {
        guard frame.count == 3072, active.count >= 3, !inactive.isEmpty,
              (active + inactive).allSatisfy({ $0.count == 3072 }) else { return false }
        func green(_ p: [Double], _ i: Int) -> Double { max(0,p[i+1]-(p[i]+p[i+2])/2) }
        var pixels: [(Int, Double, Double)] = []
        for y in 12..<32 { for x in 0..<32 {
            let dx = (Double(x)-15.5)/16, dy = (Double(y)-15.5)/16
            let radius = sqrt(dx*dx+dy*dy), i = (y*32+x)*3
            guard radius >= 0.4, radius <= 0.9 else { continue }
            let on = active.reduce(0) { $0+green($1,i) } / Double(active.count)
            let off = inactive.reduce(0) { $0+green($1,i) } / Double(inactive.count)
            if on-off > 0.015 { pixels.append((i,on-off,off)) }
        } }
        guard pixels.count >= 12 else { return false }
        let norm = pixels.reduce(0) { $0+$1.1*$1.1 }
        func score(_ p: [Double]) -> Double {
            pixels.reduce(0) { $0+(green(p,$1.0)-$1.2)*$1.1 } / norm
        }
        let offScores = inactive.map(score), onScores = active.map(score).sorted()
        let maximumOff = offScores.max() ?? 0, minimumOff = offScores.min() ?? 0
        // Only use this extra evidence when the stopped baseline is stable
        // and typical running frames clearly differ from it.
        guard maximumOff-minimumOff < 0.15,
              onScores[onScores.count/2] > maximumOff+0.5 else { return false }
        let value = score(frame)
        return value >= minimumOff-0.15 && value <= maximumOff+0.15
    }
    static func classify(_ frame: [Double], active: [[Double]], inactive: [[Double]]) -> Bool? {
        guard active.count >= 3, !inactive.isEmpty else { return nil }
        guard (active + inactive).map({ iconDistance(frame,$0) }).min() ?? 1 < 0.10 else { return nil }
        let on = active.map { distance(frame,$0) }.min() ?? 1
        let off = inactive.map { distance(frame,$0) }.min() ?? 1
        if off < 0.022 { return false }
        // Background brightness can shift RGB distances even after the green
        // running glow is gone. Use calibrated chroma only when both sample
        // groups cleanly separate, and retain a veto for a visible white arc.
        let signal = ringSignals(frame)
        let stopped = inactive.map(ringSignals), started = active.map(ringSignals)
        let offGreen = stopped.map(\.green).max() ?? 0
        let onGreen = started.map(\.green).min() ?? 0
        let offWhite = stopped.map(\.white).max() ?? 0
        if off < 0.045 && onGreen > offGreen + 0.006 &&
            signal.green < offGreen + 0.003 && signal.white <= offWhite + 0.03 { return false }
        if on < 0.075 && off > on + 0.012 { return true }
        let runningProfile = active.map { profileDistance(frame,$0) }.min() ?? 1
        let stoppedProfile = inactive.map { profileDistance(frame,$0) }.min() ?? 1
        if runningProfile < 0.045 && stoppedProfile > runningProfile + 0.018 { return true }
        if learnedStopped(frame, active: active, inactive: inactive) { return false }
        return nil
    }
}

struct EquipmentConfirmation {
    private var candidate: Bool?
    private var since = Date.distantPast
    private var last = Date.distantPast
    private var stable: Bool?
    private var uncertainSince: Date?
    mutating func reset() { self = Self() }
    mutating func update(_ value: Bool?, at now: Date) -> String {
        if now.timeIntervalSince(last) > 1 { reset() }
        last = now
        if let value {
            if candidate != value { candidate = value; since = now }
            if now.timeIntervalSince(since) >= 2 {
                stable = value; uncertainSince = nil
                return value ? "已开启" : "未开启"
            }
            if stable == value {
                uncertainSince = nil
                return value ? "已开启" : "未开启"
            }
        } else {
            // One ambiguous animation frame must not discard the confirmed
            // state, sound an alarm, or restart the entire running confirmation.
            candidate = nil
        }
        if uncertainSince == nil { uncertainSince = now }
        if now.timeIntervalSince(uncertainSince!) >= 5 {
            stable = nil
            return "无法确认"
        }
        if stable == true { return "已开启（复核中）" }
        if stable == false { return "未开启" }
        return "确认中"
    }
}

@MainActor
final class EquipmentVoiceAlert {
    private let speech = NSSpeechSynthesizer()
    private var timer: Timer?
    private var text = ""
    init() {
        if let voice = NSSpeechSynthesizer.availableVoices.first(where: { $0.rawValue.contains("Tingting") }) ?? NSSpeechSynthesizer.availableVoices.first(where: {
            (NSSpeechSynthesizer.attributes(forVoice: $0)[.localeIdentifier] as? String)?.hasPrefix("zh") == true
        }) { speech.setVoice(voice) }
        speech.rate = 180
    }
    func setMessage(_ value: String) {
        guard value != text else { return }
        stop(); text = value
        guard !value.isEmpty else { return }
        speak()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.speak() }
        }
    }
    private func speak() { if !speech.isSpeaking && !text.isEmpty { speech.startSpeaking(text) } }
    func stop() { timer?.invalidate(); timer = nil; speech.stopSpeaking(); text = "" }
}

@MainActor
final class EquipmentMonitor: ObservableObject {
    @Published private(set) var rules: [EquipmentRule] = []
    @Published private(set) var states: [UUID: String] = [:]
    @Published private(set) var images: [UUID: NSImage] = [:]
    @Published private(set) var running = false
    @Published private(set) var calibrating: UUID?
    @Published var message: String?
    private var captures: [UUID: ScreenCaptureService] = [:]
    private var activeRuleIDs: Set<UUID> = []
    private var captureTokens: [UUID: UUID] = [:]
    private var confirmations: [UUID: EquipmentConfirmation] = [:]
    private var lastFrames: [UUID: Date] = [:]
    private var timer: Timer?
    private let sound = EquipmentVoiceAlert()
    private var muted: Set<UUID> = []
    private var calibration: (id: UUID, active: Bool, start: Date, samples: [[Double]])?
    private var editor: WindowCropEditor?
    private var selectionCapture: ScreenCaptureService?
    private var selectionToken = UUID()
    private var generation = UUID()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "equipment.rules.v1"), let saved = try? JSONDecoder().decode([EquipmentRule].self, from: data) { rules = saved.map { rule in var updated = rule; updated.validated = EquipmentVision.separable(rule.active, rule.inactive); return updated } }
    }
    private func save() { defaults.set(try? JSONEncoder().encode(rules), forKey: "equipment.rules.v1") }
    func add(target: WindowTarget, name: String) {
        guard !running, calibrating == nil else { return }
        selectionCapture?.stop(); editor?.cancel()
        let token = UUID(); selectionToken = token
        let capture = ScreenCaptureService(); selectionCapture = capture
        var received = false
        capture.onImage = { [weak self] image in
            Task { @MainActor in
                guard let self, self.selectionToken == token, !received else { return }
                received = true; self.selectionCapture?.stop(); self.selectionCapture = nil
                self.editor = WindowCropEditor(image: image, title: "紧贴单个圆形装备外缘框选正方形，包含光圈") { [weak self] crop in
                    guard let self else { return }
                    if let crop {
                        self.rules.append(EquipmentRule(target: target, name: name.isEmpty ? "常开装备" : name, crop: crop)); self.save()
                    }
                    self.editor = nil
                }
                self.editor?.show()
            }
        }
        Task {
            do { try await capture.start(window: target, crop: nil) }
            catch { if selectionToken == token { message = error.localizedDescription; selectionCapture = nil } }
        }
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if selectionToken == token, !received { capture.stop(); selectionCapture = nil; message = "未取得新画面，请显示游戏窗口后重试。" }
        }
    }
    func remove(_ id: UUID) {
        guard !running, calibrating == nil else { return }
        rules.removeAll { $0.id == id }; states[id] = nil; images[id] = nil; save()
    }
    func calibrate(_ rule: EquipmentRule, active: Bool) {
        guard !running, calibrating == nil else { return }
        stop()
        calibrating = rule.id
        calibration = (rule.id, active, Date(), [])
        message = "正在采集\(active ? "开启" : "关闭")样本（6 秒），关闭时保持静止即可；开启时让光圈正常循环。请勿移动按钮。"
        begin(rule)
        let token = generation
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard generation == token, let sample = calibration else { return }
            captures[rule.id]?.stop(); captures.removeAll(); calibrating = nil; calibration = nil
            guard sample.samples.count >= (sample.active ? 3 : 1), let index = rules.firstIndex(where: { $0.id == rule.id }) else { message = "采集失败：新画面不足，请显示游戏窗口后重试。"; return }
            if active { rules[index].active = sample.samples } else { rules[index].inactive = sample.samples }
            rules[index].validated = EquipmentVision.separable(rules[index].active, rules[index].inactive)
            save()
            message = rules[index].ready ? "样本已保存，可以开始监护。请先实际开关装备验证。" : "需要开启、关闭两组可区分样本；若均已采集，请重新框选完整按钮并重新采样。"
        }
    }
    func start(targets: [WindowTarget]? = nil, adding: Bool = false) {
        let eligible = rules.filter { rule in targets == nil || targets!.contains { $0.title == rule.target.title && $0.bundleIdentifier == rule.target.bundleIdentifier } }
        guard !eligible.isEmpty else { message = nil; return }
        guard eligible.allSatisfy(\.ready), calibrating == nil else { message = "请检查各装备的采样状态；两组已采集但差异不足的项目，需要调整选区或重采。"; return }
        if !adding { stop() }
        running = true; message = nil
        let pending = eligible.filter { !activeRuleIDs.contains($0.id) }
        activeRuleIDs.formUnion(pending.map(\.id))
        for rule in pending { states[rule.id] = "等待新画面"; lastFrames[rule.id] = Date(); begin(rule) }
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkFreshness() }
        } }
    }
    func isRunning(for target: WindowTarget) -> Bool {
        rules.contains { $0.target.title == target.title && $0.target.bundleIdentifier == target.bundleIdentifier && activeRuleIDs.contains($0.id) }
    }
    func stop(for target: WindowTarget) {
        for rule in rules where rule.target.title == target.title && rule.target.bundleIdentifier == target.bundleIdentifier {
            captureTokens[rule.id] = nil
            captures.removeValue(forKey: rule.id)?.stop()
            activeRuleIDs.remove(rule.id); confirmations[rule.id] = nil
            lastFrames[rule.id] = nil; states[rule.id] = nil; muted.remove(rule.id)
        }
        if activeRuleIDs.isEmpty { stop() } else { updateSound() }
    }
    func stop() {
        generation = UUID(); timer?.invalidate(); timer = nil
        for capture in captures.values { capture.stop() }
        captures.removeAll(); captureTokens.removeAll(); activeRuleIDs.removeAll(); confirmations.removeAll(); lastFrames.removeAll()
        running = false; calibration = nil; calibrating = nil; states.removeAll(); muted.removeAll()
        sound.stop()
    }
    func mute() { muted = Set(rules.filter { states[$0.id] != "已开启" }.map(\.id)); updateSound() }
    private func begin(_ rule: EquipmentRule) {
        let capture = ScreenCaptureService(); captures[rule.id] = capture
        let token = generation
        let sessionToken = UUID(); captureTokens[rule.id] = sessionToken
        let gate = ThumbnailDeliveryGate()
        var lastImage: CGImage?
        let deliver: (CGImage) -> Void = { [weak self] image in
            guard let permit = gate.acquire() else { return }
            Task { @MainActor [weak self, permit] in
                defer { withExtendedLifetime(permit) {} }
                guard let self, self.generation == token, self.captureTokens[rule.id] == sessionToken else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastFrames[rule.id] ?? .distantPast) >= 0.18 else { return }
                self.lastFrames[rule.id] = now
                self.images[rule.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                guard let feature = EquipmentVision.feature(image) else { return }
                if self.calibration?.id == rule.id {
                    self.calibration?.samples.append(feature)
                } else if self.running {
                    let value = EquipmentVision.classify(feature, active: rule.active, inactive: rule.inactive)
                    var confirmation = self.confirmations[rule.id] ?? EquipmentConfirmation()
                    self.states[rule.id] = confirmation.update(value, at: now)
                    self.confirmations[rule.id] = confirmation
                    if self.states[rule.id] == "已开启" { self.muted.remove(rule.id) }
                    self.updateSound()
                }
            }
        }
        capture.onImage = { image in lastImage = image; deliver(image) }
        capture.onFrameUnchanged = { if let image = lastImage { deliver(image) } }
        capture.onCaptureStopped = { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == token, self.captureTokens[rule.id] == sessionToken else { return }
                self.states[rule.id] = "采集失效"; self.message = error.localizedDescription
                self.confirmations[rule.id] = nil; self.updateSound()
            }
        }
        Task {
            do { try await capture.start(window: rule.target, crop: rule.crop, framesPerSecond: 5); if generation != token || captureTokens[rule.id] != sessionToken { capture.stop() } }
            catch { guard generation == token, captureTokens[rule.id] == sessionToken else { capture.stop(); return }; states[rule.id] = "采集失效"; message = error.localizedDescription; updateSound() }
        }
    }
    private func checkFreshness() {
        for rule in rules where activeRuleIDs.contains(rule.id) && Date().timeIntervalSince(lastFrames[rule.id] ?? .distantPast) > 3 {
            states[rule.id] = "画面未更新"; confirmations[rule.id] = nil
        }
        updateSound()
    }
    static func voiceMessage(for states: [String]) -> String {
        var parts: [String] = []
        if states.contains("未开启") { parts.append("装备未开启，请检查") }
        if states.contains("无法确认") { parts.append("装备状态无法确认，请检查") }
        if states.contains("采集失效") || states.contains("画面未更新") { parts.append("装备监护画面异常，请检查") }
        return parts.joined(separator: "。")
    }
    private func updateSound() {
        let warnings = running ? rules.filter { !muted.contains($0.id) }.compactMap { states[$0.id] } : []
        sound.setMessage(Self.voiceMessage(for: warnings))
    }

}

struct EquipmentMonitorSection: View {
    @ObservedObject var monitor: EquipmentMonitor
    @ObservedObject var preview: MultiWindowPreview
    var target: WindowTarget? = nil
    private var visibleRules: [EquipmentRule] { monitor.rules.filter { rule in target == nil || (rule.target.title == target?.title && rule.target.bundleIdentifier == target?.bundleIdentifier) } }
    @State private var targetID: UInt32 = 0
    @State private var name = "维修器"
    var body: some View {
        GroupBox("修、抗常开监护") {
            VStack(alignment: .leading, spacing: 10) {
                Text("紧贴单个装备外圈框选正方形，图标居中；不要把两个装备框在一起。识别两侧及下方绿色光晕、白色循环圈，忽略顶部固定绿条。分别关闭、开启装备后采集样本；调整游戏界面布局后请删除并重新设置。采样请在安全位置进行。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if target == nil { Picker("角色", selection: $targetID) {
                        Text("选择角色").tag(UInt32(0))
                        ForEach(preview.visibleWindows) { Text($0.title).tag($0.windowID) }
                    }
                    }
                    TextField("装备名称", text: $name).frame(width: 110)
                    Button("框选装备") { if let target = target ?? preview.visibleWindows.first(where: { $0.windowID == targetID }) { monitor.add(target: target, name: name) } }
                        .disabled((target == nil && targetID == 0) || monitor.running || monitor.calibrating != nil)
                }
                ForEach(visibleRules) { rule in
                    HStack {
                        if let image = monitor.images[rule.id] { Image(nsImage: image).resizable().scaledToFit().frame(width: 48, height: 48) }
                        VStack(alignment: .leading) {
                            Text("\(rule.target.title) · \(rule.name)").bold()
                            Text(monitor.states[rule.id] ?? rule.calibrationStatus)
                            Text("开启 \(rule.active.count) 帧 · 关闭 \(rule.inactive.count) 帧").font(.caption).foregroundStyle(.secondary)
                                .foregroundStyle(monitor.states[rule.id] == "已开启" ? Color.green : Color.orange)
                        }
                        Spacer()
                        Button(rule.inactive.isEmpty ? "采集关闭" : "重采关闭") { monitor.calibrate(rule, active: false) }
                        Button(rule.active.isEmpty ? "采集开启" : "重采开启") { monitor.calibrate(rule, active: true) }
                        Button("删除") { monitor.remove(rule.id) }
                    }.disabled(monitor.running || monitor.calibrating != nil)
                }
                HStack {
                    if target == nil { Button(monitor.running ? "停止装备监护" : "开始装备监护") { if monitor.running { monitor.stop() } else { monitor.start() } }
                        .disabled(monitor.calibrating != nil || monitor.rules.isEmpty)
                    Button("静音当前装备提醒") { monitor.mute() }.disabled(!monitor.running)
                    }
                    if monitor.calibrating != nil { Button("取消采样") { monitor.stop(); monitor.message = nil } }
                }
                Text("停转连续确认 2 秒；短暂识别波动不响铃，持续无法确认 5 秒才提醒；无新画面超过 3 秒提示。通过顶部按钮启停，仅语音提醒（装备未开启）。静音后，装备恢复开启再出现异常会重新提醒。").font(.caption).foregroundStyle(.secondary)
                if target == nil, let message = monitor.message { Text(message).font(.callout).foregroundStyle(.orange) }
            }.padding(6)
        }
    }
}
