import Foundation
import CoreGraphics

/// Rectangle in the chosen NSScreen's point coordinate system (origin at lower-left).
struct MonitorRegion: Codable, Equatable {
    var displayID: UInt32
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var displayPointWidth: CGFloat
    var displayPointHeight: CGFloat
    var displayPixelWidth: Int
    var displayPixelHeight: Int
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

