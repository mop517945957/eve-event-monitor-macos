import CoreGraphics
import AppKit

enum PermissionService {
    static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }
    static func request() { _ = CGRequestScreenCaptureAccess() }
    static func openSystemSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
}

