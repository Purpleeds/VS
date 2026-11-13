#if canImport(SwiftUI)
import Foundation
import SwiftUI
import PitchLaneCore

/// Per-route latency calibration, persisted as JSON in Application Support.
@MainActor
final class LatencyStore: ObservableObject {
    @Published private(set) var profiles = LatencyProfiles()
    private let store = JSONFileStore<LatencyProfiles>(url: AppPaths.latencyFile)

    init() {
        let loaded = store.loadOrQuarantine()
        profiles = loaded.value ?? LatencyProfiles()
        if let problem = loaded.problem {
            AppLog.error("Latency profiles unreadable, starting fresh: \(problem)", category: "latency")
        }
    }

    func setCalibration(_ milliseconds: Double, for route: AudioRouteKind) {
        var updated = profiles
        updated.setCalibration(milliseconds, for: route)
        save(updated, "calibration \(route.rawValue) = \(String(format: "%.1f", milliseconds)) ms")
    }

    func setNudge(_ milliseconds: Double, for route: AudioRouteKind) {
        var updated = profiles
        updated.setNudge(milliseconds, for: route)
        save(updated, "nudge \(route.rawValue) = \(String(format: "%.0f", milliseconds)) ms")
    }

    func reset(_ route: AudioRouteKind) {
        var updated = profiles
        updated.reset(route)
        save(updated, "reset \(route.rawValue)")
    }

    func resetAll() {
        save(LatencyProfiles(), "reset all routes")
    }

    private func save(_ updated: LatencyProfiles, _ what: String) {
        profiles = updated
        do {
            try store.save(updated)
            AppLog.info("Latency \(what)", category: "latency")
        } catch {
            AppLog.error("Saving latency profiles failed: \(error)", category: "latency")
        }
    }
}
#endif
