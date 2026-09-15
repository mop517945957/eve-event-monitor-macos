import Foundation

final class SettingsStore {
    private let key = "screenAlarm.config.v1"
    func load() -> DetectionConfig {
        guard let data = UserDefaults.standard.data(forKey: key), let config = try? JSONDecoder().decode(DetectionConfig.self, from: data) else { return DetectionConfig() }
        return config
    }
    func save(_ config: DetectionConfig) { UserDefaults.standard.set(try? JSONEncoder().encode(config), forKey: key) }
}

