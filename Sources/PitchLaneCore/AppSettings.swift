import Foundation

/// User settings, persisted as JSON. Decoding is forgiving: missing keys fall back to defaults,
/// so adding a setting never invalidates an existing file.
public struct AppSettings: Codable, Equatable, Sendable {
    public var debugOverlay: Bool

    public init(debugOverlay: Bool = false) {
        self.debugOverlay = debugOverlay
    }

    private enum CodingKeys: String, CodingKey {
        case debugOverlay
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.debugOverlay = try container.decodeIfPresent(Bool.self, forKey: .debugOverlay) ?? false
    }
}
