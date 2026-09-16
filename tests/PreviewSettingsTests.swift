import AppKit

@main
struct PreviewSettingsTests {
    @MainActor static func main() {
        // A dropped/error frame returns its slot; only one queued frame is permitted.
        let delivery = ThumbnailDeliveryGate()
        var permit = delivery.acquire()
        precondition(permit != nil && delivery.acquire() == nil)
        permit = nil
        precondition(delivery.acquire() != nil)
        // Hold callbacks pending while destroying the owner, matching the crash lifecycle.
        let consumer = DispatchQueue(label: "preview.regression.consumer")
        consumer.suspend()
        let group = DispatchGroup()
        for _ in 0..<10000 {
            autoreleasepool {
                var owner: ThumbnailDeliveryGate? = ThumbnailDeliveryGate()
                weak var releasedOwner = owner
                let pending = owner!.acquire()!
                group.enter()
                consumer.async { [pending] in
                    withExtendedLifetime(pending) {}
                    group.leave()
                }
                owner = nil
                precondition(releasedOwner == nil)
            }
        }
        consumer.resume()
        precondition(group.wait(timeout: .now() + 10) == .success)
        consumer.sync {} // Wait for closure captures to be released, not only group.leave().
        print("PASS: 10000 owner-destroyed pending frames, balanced release, delivery backpressure")
        var firstWindow = WindowMonitorHits()
        var secondWindow = WindowMonitorHits()
        firstWindow.advance(hit: true, requiredHits: 2, requiredMisses: 2)
        secondWindow.advance(hit: true, requiredHits: 2, requiredMisses: 2)
        precondition(!firstWindow.triggered && !secondWindow.triggered)
        firstWindow.advance(hit: true, requiredHits: 2, requiredMisses: 2)
        precondition(firstWindow.triggered && !secondWindow.triggered)
        secondWindow.advance(hit: true, requiredHits: 2, requiredMisses: 2)
        firstWindow.advance(hit: false, requiredHits: 2, requiredMisses: 2)
        precondition(firstWindow.triggered && secondWindow.triggered)
        firstWindow.advance(hit: false, requiredHits: 2, requiredMisses: 2)
        precondition(!firstWindow.triggered && secondWindow.triggered)
        print("PASS: independent simultaneous-window alarm thresholds and release")
        let suite = "ScreenAlarm.preview.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func target(_ id: UInt32, title: String, name: String = "EVE", bundle: String = "com.ccpgames.eveonline") -> WindowTarget {
            WindowTarget(windowID: id, applicationPID: 42, bundleIdentifier: bundle,
                         applicationName: name, title: title, frameX: 0, frameY: 0, frameWidth: 800, frameHeight: 600)
        }
        let pilot = target(1, title: "EVE - Pilot One")
        let other = target(2, title: "EVE - Pilot Two")
        let duringSwitch = MultiWindowPreview.retainingLiveWindows(discovered: [], previous: [pilot, other, pilot], livePIDs: [42])
        precondition(Set(duringSwitch.map(\.windowID)) == [1, 2] && duringSwitch.count == 2)
        let afterSwitch = MultiWindowPreview.retainingLiveWindows(discovered: [pilot], previous: duringSwitch, livePIDs: [42])
        precondition(afterSwitch.count == 2)
        precondition(MultiWindowPreview.retainingLiveWindows(discovered: [], previous: duringSwitch, livePIDs: []).isEmpty)
        print("PASS: Space transition retains live windows, return deduplicates, process exit removes")
        let browser = target(3, title: "Website preview", name: "Safari", bundle: "com.apple.Safari")
        precondition(MultiWindowPreview.isEVE(pilot))
        precondition(!MultiWindowPreview.isEVE(browser))
        precondition(!MultiWindowPreview.isEVE(target(4, title: "")))
        precondition(!MultiWindowPreview.isEVE(target(5, title: "EVE启动器", name: "eve-online")))
        precondition(!MultiWindowPreview.isEVE(target(6, title: "EVE - ")))
        precondition(!MultiWindowPreview.isEVE(target(7, title: "EVE - Fake", name: "Safari", bundle: "com.apple.Safari")))
        let manager = MultiWindowPreview(defaults: defaults, enableHotkey: false)
        precondition(!manager.running && manager.alwaysOnTop)
        precondition(manager.frameRate == 30 && !manager.isLocked)
        manager.toggleLock(); precondition(manager.isLocked)
        manager.updateAlarm(target: pilot, active: true); precondition(!manager.isLocked)
        manager.toggleLock(); precondition(!manager.isLocked)
        manager.updateAlarm(target: pilot, active: false); precondition(!manager.isLocked)
        manager.toggleLock(); precondition(manager.isLocked)
        manager.toggleLock(); precondition(!manager.isLocked)
        manager.setFrameRate(60)
        precondition(MultiWindowPreview(defaults: defaults, enableHotkey: false).frameRate == 60)
        manager.setFrameRate(999); precondition(manager.frameRate == 60)
        print("PASS: lock toggle, alarm unlock, alarm lock prevention, no auto relock, FPS persistence")
        manager.select(pilot, enabled: true)
        precondition(manager.isSelected(pilot) && !manager.isSelected(other))
        manager.alwaysOnTop = false
        manager.previewWidth = 480
        manager.previewHeight = 270
        manager.applyPreviewSize()
        manager.opacity = 0.55
        let restored = MultiWindowPreview(defaults: defaults, enableHotkey: false)
        precondition(restored.isSelected(pilot) && !restored.alwaysOnTop && !restored.running)
        precondition(restored.opacity == 0.55)
        precondition(restored.previewWidth == 480 && restored.previewHeight == 270)
        restored.previewWidth = -10; restored.previewHeight = 99999
        restored.applyPreviewSize()
        precondition(restored.previewWidth == 64 && restored.previewHeight == 2160)
        let pilotCrop = WindowCrop(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        manager.setSize(width: 700, height: 400, for: pilot)
        manager.setOpacity(0.35, for: pilot)
        manager.setCrop(pilotCrop, for: pilot)
        manager.setSize(width: 240, height: 160, for: other)
        manager.setOpacity(0.9, for: other)
        let perWindow = MultiWindowPreview(defaults: defaults, enableHotkey: false)
        precondition(perWindow.settings(for: pilot).width == 700)
        precondition(perWindow.settings(for: pilot).height == 400)
        precondition(perWindow.settings(for: pilot).opacity == 0.35)
        precondition(perWindow.settings(for: pilot).crop == pilotCrop)
        precondition(perWindow.settings(for: other).width == 240)
        precondition(perWindow.settings(for: other).opacity == 0.9)
        precondition(perWindow.settings(for: other).crop == nil)
        precondition(perWindow.settings(for: target(99, title: pilot.title)).crop == pilotCrop)
        print("PASS: independent per-window size, opacity, crop, persistence and restart identity")
        print("PASS: game-only window filtering, saved size, size limits")
        // A character keeps its selection when the OS creates a new window ID.
        precondition(restored.isSelected(target(99, title: pilot.title)))
        restored.select(pilot, enabled: false)
        precondition(!MultiWindowPreview(defaults: defaults, enableHotkey: false).isSelected(pilot))
        // Empty titles must not accidentally map unrelated windows to one layout.
        precondition(manager.key(for: target(8, title: "")) != manager.key(for: target(9, title: "")))
        let gameFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        precondition(WindowActivationMatch.index(title: "EVE - Pilot", frame: gameFrame, candidates: [ActivationWindowDescription(title: "", frame: gameFrame)]) == 0)
        precondition(WindowActivationMatch.index(title: "EVE - Pilot", frame: gameFrame, candidates: [ActivationWindowDescription(title: " EVE - Pilot ", frame: nil)]) == 0)
        precondition(WindowActivationMatch.index(title: "EVE - Pilot", frame: gameFrame, candidates: [ActivationWindowDescription(title: "", frame: gameFrame), ActivationWindowDescription(title: "", frame: gameFrame)]) == nil)
        precondition(WindowActivationMatch.index(title: "EVE - Pilot", frame: gameFrame, candidates: []) == nil)
        print("PASS: missing AX titles, whitespace, ambiguous geometry, missing windows")
        let original = NSRect(x: 100, y: 200, width: 320, height: 180)
        let enlarged = PreviewGeometry.resized(original, dx: 100, dy: 50, edges: [.right, .top])
        precondition(enlarged == NSRect(x: 100, y: 200, width: 420, height: 230))
        let shrunk = PreviewGeometry.resized(original, dx: 1000, dy: 1000, edges: [.left, .bottom])
        precondition(shrunk.size == PreviewGeometry.minimumSize)
        precondition(shrunk.maxX == original.maxX && shrunk.maxY == original.maxY)
        let horizontal = PreviewGeometry.resized(original, dx: -100, dy: 80, edges: .left)
        precondition(horizontal.height == original.height && horizontal.width == 420)
        precondition(horizontal.maxX == original.maxX)
        let fitted = WindowCropGeometry.imageRect(imageSize: NSSize(width: 1600, height: 900), bounds: NSRect(x: 0, y: 0, width: 800, height: 600))
        precondition(fitted == NSRect(x: 0, y: 75, width: 800, height: 450))
        let crop = WindowCropGeometry.crop(start: NSPoint(x: 200, y: 187.5), end: NSPoint(x: 600, y: 412.5), imageRect: fitted)!
        precondition(crop == WindowCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let reverse = WindowCropGeometry.crop(start: NSPoint(x: 600, y: 412.5), end: NSPoint(x: 200, y: 187.5), imageRect: fitted)
        precondition(reverse == crop)
        precondition(WindowCropGeometry.crop(start: NSPoint(x: 10, y: 10), end: NSPoint(x: 600, y: 400), imageRect: fitted) == nil)
        let clipped = WindowCropGeometry.crop(start: NSPoint(x: 400, y: 300), end: NSPoint(x: 1000, y: 800), imageRect: fitted)!
        precondition(clipped == WindowCrop(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        print("PASS: window crop letterboxing, top-left coordinates, reverse drag, margins, clipping")
        print("PASS: free resize, opposite-edge anchors, minimum size, opacity persistence")
        print("PASS: EVE filtering, isolated selections, settings restore, restart identity, deselection, unnamed-window identity")
    }
}
