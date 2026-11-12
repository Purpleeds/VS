#if canImport(SwiftUI)
import Foundation

enum AppPaths {
    /// `Application Support/PitchLane`. All persisted data (settings, songs, logs) lives under here.
    static var supportDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PitchLane", isDirectory: true)
    }

    static var logsDirectory: URL { supportDirectory.appendingPathComponent("Logs", isDirectory: true) }
    static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    static var songsDirectory: URL { supportDirectory.appendingPathComponent("Songs", isDirectory: true) }
    static var personalBestsFile: URL { supportDirectory.appendingPathComponent("personal-bests.json") }
}
#endif
