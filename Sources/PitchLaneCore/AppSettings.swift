import Foundation

/// User settings, persisted as JSON. Decoding is forgiving: missing keys fall back to defaults,
/// so adding a setting never invalidates an existing file.
public struct AppSettings: Codable, Equatable, Sendable {
    public var debugOverlay: Bool
    /// Spelling for black-key note names (F♯ vs G♭).
    public var accidentals: Accidentals
    /// Difficulty last chosen in a song's details.
    public var lastDifficulty: Difficulty

    public init(debugOverlay: Bool = false, accidentals: Accidentals = .sharps, lastDifficulty: Difficulty = .normal) {
        self.debugOverlay = debugOverlay
        self.accidentals = accidentals
        self.lastDifficulty = lastDifficulty
    }

    private enum CodingKeys: String, CodingKey {
        case debugOverlay
        case accidentals
        case lastDifficulty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.debugOverlay = try container.decodeIfPresent(Bool.self, forKey: .debugOverlay) ?? false
        self.accidentals = (try? container.decodeIfPresent(Accidentals.self, forKey: .accidentals)) ?? .sharps
        self.lastDifficulty = (try? container.decodeIfPresent(Difficulty.self, forKey: .lastDifficulty)) ?? .normal
    }
}
