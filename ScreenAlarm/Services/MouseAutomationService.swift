import ApplicationServices
import Foundation

@MainActor
final class MouseAutomationService {
    private let idleThreshold: TimeInterval = 60
    private var timer: Timer?
    private var hasClickedForCurrentAlarm = false
    private var onPermissionRequired: (() -> Void)?

    /// Arms one automatic click for the current alarm. The click happens as soon
    /// as the pointer has not moved for a full minute, including time elapsed
    /// before the alarm was raised.
    func arm(onPermissionRequired: @escaping () -> Void) {
        disarm()
        hasClickedForCurrentAlarm = false
        self.onPermissionRequired = onPermissionRequired
        evaluate()

        guard !hasClickedForCurrentAlarm else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func disarm() {
        timer?.invalidate()
        timer = nil
        onPermissionRequired = nil
        hasClickedForCurrentAlarm = false
    }

    private func evaluate() {
        guard !hasClickedForCurrentAlarm, pointerIdleDuration >= idleThreshold else { return }
        guard PermissionService.hasAccessibilityPermission else {
            onPermissionRequired?()
            onPermissionRequired = nil
            return
        }
        guard clickCurrentPointerLocation() else { return }
        hasClickedForCurrentAlarm = true
        timer?.invalidate()
        timer = nil
    }

    private var pointerIdleDuration: TimeInterval {
        let eventTypes: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        return eventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    private func clickCurrentPointerLocation() -> Bool {
        guard let location = CGEvent(source: nil)?.location,
              let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
              let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left) else {
            return false
        }
        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
        return true
    }
}
