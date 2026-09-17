import AppKit

@main
struct EquipmentMonitorTests {
    @MainActor static func main() {
        let t = Date(timeIntervalSince1970: 100)
        var state = EquipmentConfirmation()
        precondition(state.update(false, at: t) == "确认中")
        for i in 1...9 { precondition(state.update(false, at: t.addingTimeInterval(Double(i)*0.2)) == "确认中") }
        precondition(state.update(false, at: t.addingTimeInterval(2)) == "未开启")
        precondition(state.update(nil, at: t.addingTimeInterval(2.2)) == "未开启")
        precondition(state.update(true, at: t.addingTimeInterval(2.4)) == "未开启")
        precondition(state.update(true, at: t.addingTimeInterval(5)) == "确认中", "A stale gap must reset confirmation")
        for i in 1...10 { _ = state.update(true, at: t.addingTimeInterval(5 + Double(i)*0.2)) }
        precondition(state.update(true, at: t.addingTimeInterval(7.2)) == "已开启")
        // A full minute of running-cycle ambiguity must not raise an alert.
        for i in 1...300 {
            let result = state.update(i % 3 == 0 ? nil : true, at: t.addingTimeInterval(7.2 + Double(i)*0.2))
            precondition(result.hasPrefix("已开启"), "Transient animation ambiguity must not alert")
        }
        for i in 1...9 {
            precondition(state.update(false, at: t.addingTimeInterval(67.2 + Double(i)*0.2)).hasPrefix("已开启"))
        }
        for i in 10...12 { _ = state.update(false, at: t.addingTimeInterval(67.2 + Double(i)*0.2)) }
        precondition(state.update(false, at: t.addingTimeInterval(69.8)) == "未开启", "Real sustained stop still alerts")
        state.reset()
        for i in 0...24 { precondition(state.update(nil, at: t.addingTimeInterval(Double(i)*0.2)) == "确认中") }
        precondition(state.update(nil, at: t.addingTimeInterval(5.2)) == "无法确认", "Sustained uncertainty must not silently pass")
        precondition(EquipmentMonitor.voiceMessage(for: ["未开启"]) == "装备未开启，请检查")
        precondition(EquipmentMonitor.voiceMessage(for: ["无法确认"]) == "装备状态无法确认，请检查")
        precondition(EquipmentMonitor.voiceMessage(for: ["已开启", "已开启（复核中）"]).isEmpty)
        let on = Array(repeating: Array(repeating: 0.6, count: 3072), count: 10)
        let off = Array(repeating: Array(repeating: 0.3, count: 3072), count: 10)
        precondition(EquipmentVision.separable(on, off))
        precondition(!EquipmentVision.separable(on, on))
        precondition(!EquipmentVision.separable([], off))
        precondition(EquipmentVision.classify(on[0], active: on, inactive: off) == true)
        precondition(EquipmentVision.classify(off[0], active: on, inactive: off) == false)
        precondition(EquipmentVision.classify(Array(repeating: 0, count: 3072), active: on, inactive: off) == nil)
        precondition(EquipmentVision.classify(Array(repeating: 0.45, count: 3072), active: on, inactive: off) == nil)
        // Current user's saved selections: both calibration sets already
        // exist, including a padded crop that the old fixed annulus rejected.
        if let samplePath = CommandLine.arguments.dropFirst().first,
           let data = try? Data(contentsOf: URL(fileURLWithPath: samplePath)),
           let saved = try? JSONDecoder().decode([EquipmentRule].self, from: data) {
            if saved.count > 1 {
                let image = NSImage(contentsOfFile: "tests/fixtures/equipment/stopped-ui.png")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
                let frame = EquipmentVision.feature(image.cropping(to: CGRect(x:46,y:41,width:76,height:96))!)!
                precondition(EquipmentVision.classify(frame,active:saved[1].active,inactive:saved[1].inactive) == false, "User-confirmed stopped screenshot must classify as stopped")
                var confirmation = EquipmentConfirmation()
                for i in 0...11 { _ = confirmation.update(false, at: t.addingTimeInterval(Double(i)*0.2)) }
                precondition(confirmation.update(false, at: t.addingTimeInterval(2.4)) == "未开启")
                print("PASS: reported stopped screenshot and saved calibration reproduce 未开启")
            }
            for (index, rule) in saved.enumerated() {
                if let image = NSImage(contentsOfFile: "/tmp/equipment-live-\(index).png")?.cgImage(forProposedRect: nil, context: nil, hints: nil), let feature = EquipmentVision.feature(image) {
                    precondition(EquipmentVision.classify(feature,active:rule.active,inactive:rule.inactive) == false, "Live user-confirmed stopped equipment must classify as stopped")
                    print("PASS: live stopped equipment", index)
                }
            }
            for var rule in saved {
                precondition(!rule.active.isEmpty && !rule.inactive.isEmpty)
                rule.validated = EquipmentVision.separable(rule.active,rule.inactive)
                precondition(rule.ready, "Saved padded crop must calibrate")
                precondition(rule.calibrationStatus == "已校准 · 待监护")
                precondition(rule.inactive.allSatisfy { EquipmentVision.classify($0,active:rule.active,inactive:rule.inactive) == false })
                print("PASS: saved crop calibration,", rule.active.count, "on frames,", rule.inactive.count, "off frames")
            }
        }
        let target = WindowTarget(windowID: 1, applicationPID: 1, bundleIdentifier: nil, applicationName: "EVE", title: "EVE - Test", frameX: 0, frameY: 0, frameWidth: 100, frameHeight: 100)
        var rule = EquipmentRule(target: target, name: "维修器", crop: WindowCrop(x: 0.5,y: 0.5,width: 0.1,height: 0.1))
        precondition(rule.calibrationStatus == "待采样")
        rule.inactive = off
        precondition(rule.calibrationStatus == "已采关闭 · 待采开启")
        rule.active = off
        precondition(rule.calibrationStatus.contains("差异不足"))
        rule.active = on; rule.inactive = off; rule.validated = true
        let data = try! JSONEncoder().encode([rule])
        let defaults = UserDefaults(suiteName: "EquipmentTests-\(UUID())")!
        defaults.set(data, forKey: "equipment.rules.v1")
        let model = EquipmentMonitor(defaults: defaults)
        precondition(model.rules.count == 1 && model.rules[0].ready)
        precondition(!model.running, "Persisted settings must never auto-arm")
        model.stop()
        precondition(model.states.isEmpty)
        defaults.removeObject(forKey: "equipment.rules.v1")
        print("PASS: confirmation timing, stale-gap reset, unknown handling, template separation, classification, persistence, safe startup")
    }
}
