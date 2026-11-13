import Foundation

/// Persists one Codable value as a JSON file (atomic writes, sorted keys; pretty-printed unless `compact`).
/// This is the app's only persistence mechanism (no SwiftData / Core Data).
public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    public let url: URL
    public let compact: Bool

    public init(url: URL, compact: Bool = false) {
        self.url = url
        self.compact = compact
    }

    /// Returns nil when the file does not exist. Throws when it exists but cannot be decoded.
    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    /// Loads the value; if the file exists but can't be decoded, moves it aside as
    /// `<name>.corrupt-<timestamp>.json` (keeping the newest two) so the next save can't overwrite the only copy.
    /// Returns the value (nil if missing or corrupt) and, for a corrupt file, the error and where it was moved.
    public func loadOrQuarantine(now: Date = Date()) -> (value: Value?, problem: String?) {
        do {
            return (try load(), nil)
        } catch {
            let moved = quarantine(now: now)
            let place = moved.map { " (kept as \($0.lastPathComponent))" } ?? ""
            return (nil, "\(url.lastPathComponent) couldn't be read: \(error)\(place)")
        }
    }

    /// Moves the current file aside and returns its new location.
    @discardableResult
    public func quarantine(now: Date = Date()) -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let stamp = Int(now.timeIntervalSince1970)
        let target = directory.appendingPathComponent("\(base).corrupt-\(stamp).json")
        try? fileManager.removeItem(at: target)
        do {
            try fileManager.moveItem(at: url, to: target)
        } catch {
            return nil
        }
        // Keep only the newest two quarantined copies.
        let prefix = "\(base).corrupt-"
        let old = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
            .sorted { lhs, rhs in
                let l = Int(lhs.dropFirst(prefix.count).prefix { $0.isNumber }) ?? 0
                let r = Int(rhs.dropFirst(prefix.count).prefix { $0.isNumber }) ?? 0
                return l > r
            }
        for name in old.dropFirst(2) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        return target
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
