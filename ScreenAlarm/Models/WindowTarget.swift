import Foundation
import CoreGraphics

/// A persistent description of the window selected for direct capture.
/// Window IDs are recreated after an app relaunch, so the owning app metadata
/// is retained as a fallback when resolving a current SCWindow instance.
struct WindowTarget: Codable, Equatable, Identifiable {
    var windowID: UInt32
    var applicationPID: Int32
    var bundleIdentifier: String?
    var applicationName: String
    var title: String
    /// The frame at selection time, in the global screen coordinate system.
    /// It is only used to translate the user's region selection into a
    /// normalized crop; capture itself remains independent of this position.
    var frameX: Double
    var frameY: Double
    var frameWidth: Double
    var frameHeight: Double

    var id: UInt32 { windowID }
    var displayName: String {
        title.isEmpty ? applicationName : "\(applicationName) · \(title)"
    }

    var frame: CGRect { CGRect(x: frameX, y: frameY, width: frameWidth, height: frameHeight) }

    private enum CodingKeys: String, CodingKey {
        case windowID, applicationPID, bundleIdentifier, applicationName, title, frameX, frameY, frameWidth, frameHeight
    }

    init(windowID: UInt32, applicationPID: Int32, bundleIdentifier: String?, applicationName: String, title: String, frameX: Double, frameY: Double, frameWidth: Double, frameHeight: Double) {
        self.windowID = windowID
        self.applicationPID = applicationPID
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
        self.frameX = frameX
        self.frameY = frameY
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        windowID = try values.decode(UInt32.self, forKey: .windowID)
        applicationPID = try values.decode(Int32.self, forKey: .applicationPID)
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        applicationName = try values.decode(String.self, forKey: .applicationName)
        title = try values.decode(String.self, forKey: .title)
        frameX = try values.decodeIfPresent(Double.self, forKey: .frameX) ?? 0
        frameY = try values.decodeIfPresent(Double.self, forKey: .frameY) ?? 0
        frameWidth = try values.decodeIfPresent(Double.self, forKey: .frameWidth) ?? 0
        frameHeight = try values.decodeIfPresent(Double.self, forKey: .frameHeight) ?? 0
    }
}

/// A rectangle inside the bound window, expressed as 0...1 values with a
/// top-left origin. It stays attached to the same part of the window when the
/// window moves between displays or Spaces.
struct WindowCrop: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}
