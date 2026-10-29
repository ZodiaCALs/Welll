import Foundation
import WelllCore

enum SettingsStore {
    static let directory = URL(fileURLWithPath: "/Library/Application Support/Welll", isDirectory: true)
    private static var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    static func load() -> WelllSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(WelllSettings.self, from: data) else {
            return WelllSettings()
        }
        return settings.validated()
    }

    static func save(_ settings: WelllSettings) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
        } catch {
            Log.daemon.error("Couldn't save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
