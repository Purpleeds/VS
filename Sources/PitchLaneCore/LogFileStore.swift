import Foundation

public enum LogLevel: String, Sendable, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

/// How the previous app session ended, judged at launch.
public enum PreviousSessionStatus: Sendable, Equatable {
    /// No session state on disk.
    case firstLaunch
    /// The app reached the background (or was explicitly marked clean) before the process ended.
    case endedCleanly
    /// The state file still said "running": crash, or killed while in the foreground.
    case endedUncleanly

    public var summary: String {
        switch self {
        case .firstLaunch: return "first launch (no previous session)"
        case .endedCleanly: return "previous session ended cleanly"
        case .endedUncleanly: return "previous session did NOT end cleanly (crash or killed in foreground)"
        }
    }
}

/// Timestamped line log in a directory, with rotation. Foundation only; the app adds the os_log mirror.
///
/// Files: `pitchlane.log` (current session), `pitchlane.previous.log` (previous session),
/// `session.state` ("running" / "clean").
/// Size cap: when the current file exceeds `maxBytes`, the oldest half is dropped, so the previous
/// session file is never touched mid-session.
/// Never pass raw audio (or anything derived sample-by-sample) to this log.
public final class LogFileStore: @unchecked Sendable {
    public static let currentFileName = "pitchlane.log"
    public static let previousFileName = "pitchlane.previous.log"
    public static let stateFileName = "session.state"
    public static let defaultMaxBytes = 1_000_000

    static let runningMarker = "running"
    static let cleanMarker = "clean"

    public let directory: URL
    public let maxBytes: Int

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let formatter: DateFormatter
    private var currentSize = 0
    private var lastErrorStorage: String?

    public init(
        directory: URL,
        maxBytes: Int = LogFileStore.defaultMaxBytes,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.maxBytes = max(maxBytes, 1024)
        self.now = now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        self.formatter = formatter
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.currentSize = (try? Data(contentsOf: directory.appendingPathComponent(Self.currentFileName)))?.count ?? 0
    }

    public var currentURL: URL { directory.appendingPathComponent(Self.currentFileName) }
    public var previousURL: URL { directory.appendingPathComponent(Self.previousFileName) }
    private var stateURL: URL { directory.appendingPathComponent(Self.stateFileName) }

    /// The most recent I/O error the store swallowed (logging must never crash the app).
    public var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return lastErrorStorage
    }

    /// Call once at launch. Reads how the last session ended, rotates current -> previous,
    /// starts a fresh current file, and marks this session as running.
    @discardableResult
    public func beginSession() -> PreviousSessionStatus {
        lock.lock(); defer { lock.unlock() }

        let status: PreviousSessionStatus
        if let state = readStateLocked() {
            status = (state == Self.cleanMarker) ? .endedCleanly : .endedUncleanly
        } else {
            status = .firstLaunch
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: currentURL.path) {
            try? fileManager.removeItem(at: previousURL)
            do {
                try fileManager.moveItem(at: currentURL, to: previousURL)
            } catch {
                lastErrorStorage = "rotate failed: \(error)"
            }
        }
        _ = fileManager.createFile(atPath: currentURL.path, contents: Data())
        currentSize = 0
        writeStateLocked(Self.runningMarker)
        return status
    }

    /// Mark the session as having ended cleanly (call when the app goes to the background).
    public func markClean() {
        lock.lock(); defer { lock.unlock() }
        writeStateLocked(Self.cleanMarker)
    }

    /// Mark the session as running again (call when the app returns to the foreground).
    public func markRunning() {
        lock.lock(); defer { lock.unlock() }
        writeStateLocked(Self.runningMarker)
    }

    public func append(_ level: LogLevel, category: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        let flat = message
            .replacingOccurrences(of: "\r\n", with: " | ")
            .replacingOccurrences(of: "\n", with: " | ")
        let line = "\(formatter.string(from: now())) [\(level.rawValue)] [\(category)] \(flat)\n"
        appendLocked(Data(line.utf8))
    }

    /// Previous session followed by current session, with headers. Used by the Logs screen.
    public func readAll() -> String {
        lock.lock(); defer { lock.unlock() }
        var text = ""
        if let previous = readTextLocked(previousURL), !previous.isEmpty {
            text += "===== PREVIOUS SESSION =====\n" + previous
            if !text.hasSuffix("\n") { text += "\n" }
        }
        text += "===== CURRENT SESSION =====\n"
        text += readTextLocked(currentURL) ?? ""
        return text
    }

    // MARK: - Private (lock must be held)

    private func appendLocked(_ data: Data) {
        let fileManager = FileManager.default
        do {
            if !fileManager.fileExists(atPath: currentURL.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                _ = fileManager.createFile(atPath: currentURL.path, contents: Data())
                currentSize = 0
            }
            let handle = try FileHandle(forWritingTo: currentURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            currentSize += data.count
        } catch {
            lastErrorStorage = "append failed: \(error)"
            return
        }
        if currentSize > maxBytes {
            trimLocked()
        }
    }

    private func trimLocked() {
        guard let data = try? Data(contentsOf: currentURL) else { return }
        let keep = maxBytes / 2
        guard data.count > keep else { return }
        var tail = data.suffix(keep)
        if let newline = tail.firstIndex(of: 0x0A) {
            tail = tail[tail.index(after: newline)...]
        }
        var output = Data("--- log truncated at \(formatter.string(from: now())): oldest lines dropped to stay under \(maxBytes) bytes ---\n".utf8)
        output.append(tail)
        do {
            try output.write(to: currentURL, options: .atomic)
            currentSize = output.count
        } catch {
            lastErrorStorage = "trim failed: \(error)"
        }
    }

    private func readStateLocked() -> String? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeStateLocked(_ marker: String) {
        do {
            try Data(marker.utf8).write(to: stateURL, options: .atomic)
        } catch {
            lastErrorStorage = "state write failed: \(error)"
        }
    }

    private func readTextLocked(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
