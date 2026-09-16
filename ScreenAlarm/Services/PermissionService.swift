import CoreGraphics
import AppKit
import ApplicationServices

enum PermissionService {
    static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }
    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }
    static func request() { _ = CGRequestScreenCaptureAccess() }
    static func openSystemSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
