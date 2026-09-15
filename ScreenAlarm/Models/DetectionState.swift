import Foundation

enum DetectionState: String { case idle = "IDLE", detecting = "DETECTING", triggered = "TRIGGERED" }

struct DebugInfo {
    var fps: Double = 0
    var matchingPixels = 0
    var matchingColorHex: String?
    var topTemplateSimilarity: Double = 0
    var hitFrames = 0
    var missFrames = 0
}
