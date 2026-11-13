#if canImport(SwiftUI)
import Foundation
import os
import PitchLaneCore

/// App-wide logger: timestamped rotating file in Application Support (see `LogFileStore`)
/// mirrored to os_log. NEVER log raw audio samples or buffers; log derived, low-rate facts only
/// (e.g. "input route changed", "latency estimate 42 ms"). The os_log mirror is `.private`, so song titles and
/// other user content are redacted from the system log; the app's own log file is only shared by the user.
enum AppLog {
    static let store = LogFileStore(directory: AppPaths.logsDirectory)

    private static let subsystem = Bundle.main.bundleIdentifier ?? "PitchLane"

    static func log(_ level: LogLevel, _ message: String, category: String = "app") {
        store.append(level, category: category, message)
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .private)")
        case .info: logger.info("\(message, privacy: .private)")
        case .warning: logger.warning("\(message, privacy: .private)")
        case .error: logger.error("\(message, privacy: .private)")
        }
    }

    static func debug(_ message: String, category: String = "app") { log(.debug, message, category: category) }
    static func info(_ message: String, category: String = "app") { log(.info, message, category: category) }
    static func warning(_ message: String, category: String = "app") { log(.warning, message, category: category) }
    static func error(_ message: String, category: String = "app") { log(.error, message, category: category) }

    /// Call once at launch.
    static func bootstrap() {
        let status = store.beginSession()
        let build = BuildInfo.current
        info("Session start: PitchLane \(build.display), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)", category: "lifecycle")
        switch status {
        case .endedUncleanly: warning(status.summary, category: "lifecycle")
        default: info(status.summary, category: "lifecycle")
        }
    }

    static func markCleanExit() { store.markClean() }
    static func markRunning() { store.markRunning() }
    static func readAll() -> String { store.readAll() }
    static func clear() {
        store.clear()
        info("Logs cleared by the user", category: "lifecycle")
    }
}
#endif
