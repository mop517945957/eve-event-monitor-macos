import AppKit
@main struct EquipmentScopeTests {
    @MainActor static func main() {
        let suite = "EquipmentScope-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func target(_ id: UInt32, _ name: String) -> WindowTarget {
            WindowTarget(windowID: id, applicationPID: -1, bundleIdentifier: "test.equipment", applicationName: "EVE", title: "EVE - " + name, frameX: 0, frameY: 0, frameWidth: 100, frameHeight: 100)
        }
        let a = target(1,"A"), b = target(2,"B")
        var first = EquipmentRule(target:a,name:"修",crop:WindowCrop(x:0,y:0,width:1,height:1))
        first.active = Array(repeating:Array(repeating:0.6,count:3072),count:3)
        first.inactive = [Array(repeating:0.2,count:3072)]; first.validated = true
        var second = first; second.id = UUID(); second.target = b
        defaults.set(try! JSONEncoder().encode([first,second]),forKey:"equipment.rules.v1")
        let previews = MultiWindowPreview(defaults: defaults, enableHotkey: false)
        previews.select(b, enabled: true)
        previews.togglePreview(for: a)
        precondition(previews.isPreviewVisible(for: a) && !previews.isPreviewVisible(for: b), "Single start must not restore other saved selections")
        previews.togglePreview(for: b)
        previews.togglePreview(for: a)
        precondition(!previews.isPreviewVisible(for: a) && previews.isPreviewVisible(for: b))
        previews.toggle()
        let model = EquipmentMonitor(defaults:defaults)
        model.start(targets:[a],adding:true)
        precondition(model.isRunning(for:a) && !model.isRunning(for:b))
        model.start(targets:[b],adding:true)
        precondition(model.isRunning(for:a) && model.isRunning(for:b))
        model.stop(for:a)
        precondition(!model.isRunning(for:a) && model.isRunning(for:b) && model.running)
        precondition(model.states[first.id] == nil && model.states[second.id] != nil)
        model.stop(for:b)
        precondition(!model.running && model.states.isEmpty)
        defaults.removeObject(forKey:"equipment.rules.v1")
        print("PASS: per-window additive start, isolated stop, last-window stop, state isolation")
    }
}
