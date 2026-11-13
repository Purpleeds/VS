#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

/// Loads settings from JSON in Application Support and saves on every change.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            schedulePersist()
        }
    }

    private let store: JSONFileStore<AppSettings>

    init() {
        let store = JSONFileStore<AppSettings>(url: AppPaths.settingsFile)
        self.store = store
        let result = store.loadOrQuarantine()
        let loaded = result.value ?? AppSettings()
        if let problem = result.problem {
            AppLog.error("Settings load failed, using defaults: \(problem)", category: "settings")
        }
        self.settings = loaded
        AppLog.info("Settings loaded (debugOverlay=\(loaded.debugOverlay), accidentals=\(loaded.accidentals.rawValue))", category: "settings")
    }

    private var pendingSave: Task<Void, Never>?

    /// Sliders change settings on every tick: write once the value has settled, not ~100 times per drag.
    private func schedulePersist() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    /// Writes any pending change now (app going to the background).
    func flush() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        persist()
    }

    private func persist() {
        pendingSave = nil
        do {
            try store.save(settings)
            AppLog.info("Settings saved (debugOverlay=\(settings.debugOverlay), accidentals=\(settings.accidentals.rawValue))", category: "settings")
        } catch {
            AppLog.error("Settings save failed: \(error)", category: "settings")
        }
    }
}
#endif
