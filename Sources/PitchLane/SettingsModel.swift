#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

/// Loads settings from JSON in Application Support and saves on every change.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
        }
    }

    private let store: JSONFileStore<AppSettings>

    init() {
        let store = JSONFileStore<AppSettings>(url: AppPaths.settingsFile)
        self.store = store
        var loaded = AppSettings()
        do {
            if let existing = try store.load() { loaded = existing }
        } catch {
            AppLog.error("Settings load failed, using defaults: \(error)", category: "settings")
        }
        self.settings = loaded
        AppLog.info("Settings loaded (debugOverlay=\(loaded.debugOverlay), accidentals=\(loaded.accidentals.rawValue))", category: "settings")
    }

    private func persist() {
        do {
            try store.save(settings)
            AppLog.info("Settings saved (debugOverlay=\(settings.debugOverlay), accidentals=\(settings.accidentals.rawValue))", category: "settings")
        } catch {
            AppLog.error("Settings save failed: \(error)", category: "settings")
        }
    }
}
#endif
