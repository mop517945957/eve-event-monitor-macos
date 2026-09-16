import Foundation

enum CaptureMode: String, Codable, CaseIterable {
    case region
    case window
}

struct DetectionConfig: Codable {
    var captureMode: CaptureMode = .region
    var region: MonitorRegion?
    var windowTarget: WindowTarget?
    var windowCrop: WindowCrop?
    var colorRules: [ColorRule] = []
    var templateRules: [TemplateRule] = []
    var colorTolerance: Double = 15
    var minimumMatchingPixels: Int = 20
    var templateSimilarity: Double = 0.85
    var intervalMilliseconds: Int = 100
    var requiredHits: Int = 3
    var requiredMisses: Int = 3
    var alarmSoundPath: String?
    var alarmVolume: Double = 0.8
    var automaticClickEnabled: Bool = true

    // Decode older v1 settings without discarding the user's saved rules.
    init() {}

    private enum CodingKeys: String, CodingKey {
        case captureMode, region, windowTarget, windowCrop, colorRules, templateRules, colorTolerance,
             minimumMatchingPixels, templateSimilarity, intervalMilliseconds, requiredHits,
             requiredMisses, alarmSoundPath, alarmVolume, automaticClickEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        captureMode = try values.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? .region
        region = try values.decodeIfPresent(MonitorRegion.self, forKey: .region)
        windowTarget = try values.decodeIfPresent(WindowTarget.self, forKey: .windowTarget)
        windowCrop = try values.decodeIfPresent(WindowCrop.self, forKey: .windowCrop)
        colorRules = try values.decodeIfPresent([ColorRule].self, forKey: .colorRules) ?? []
        templateRules = try values.decodeIfPresent([TemplateRule].self, forKey: .templateRules) ?? []
        colorTolerance = try values.decodeIfPresent(Double.self, forKey: .colorTolerance) ?? 15
        minimumMatchingPixels = try values.decodeIfPresent(Int.self, forKey: .minimumMatchingPixels) ?? 20
        templateSimilarity = try values.decodeIfPresent(Double.self, forKey: .templateSimilarity) ?? 0.85
        intervalMilliseconds = try values.decodeIfPresent(Int.self, forKey: .intervalMilliseconds) ?? 100
        requiredHits = try values.decodeIfPresent(Int.self, forKey: .requiredHits) ?? 3
        requiredMisses = try values.decodeIfPresent(Int.self, forKey: .requiredMisses) ?? 3
        alarmSoundPath = try values.decodeIfPresent(String.self, forKey: .alarmSoundPath)
        alarmVolume = try values.decodeIfPresent(Double.self, forKey: .alarmVolume) ?? 0.8
        automaticClickEnabled = try values.decodeIfPresent(Bool.self, forKey: .automaticClickEnabled) ?? true
    }
}
