import Foundation

/// User settings, persisted as JSON. Decoding is forgiving: missing keys fall back to defaults,
/// so adding a setting never invalidates an existing file.
public struct AppSettings: Codable, Equatable, Sendable {
    public var debugOverlay: Bool
    /// Spelling for black-key note names (F♯ vs G♭).
    public var accidentals: Accidentals
    /// Difficulty last chosen in a song's details.
    public var lastDifficulty: Difficulty
    /// Score any octave of the target (default on, so any voice can sing any song).
    public var octaveAgnostic: Bool
    /// Metronome clicks during play.
    public var clickTrack: Bool
    /// Note names (with accidentals) on the lane's note bars.
    public var showNoteNames: Bool

    public init(
        debugOverlay: Bool = false,
        accidentals: Accidentals = .sharps,
        lastDifficulty: Difficulty = .normal,
        octaveAgnostic: Bool = true,
        clickTrack: Bool = false,
        showNoteNames: Bool = false
    ) {
        self.debugOverlay = debugOverlay
        self.accidentals = accidentals
        self.lastDifficulty = lastDifficulty
        self.octaveAgnostic = octaveAgnostic
        self.clickTrack = clickTrack
        self.showNoteNames = showNoteNames
    }

    private enum CodingKeys: String, CodingKey {
        case debugOverlay
        case accidentals
        case lastDifficulty
        case octaveAgnostic
        case clickTrack
        case showNoteNames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.debugOverlay = try container.decodeIfPresent(Bool.self, forKey: .debugOverlay) ?? false
        self.accidentals = (try? container.decodeIfPresent(Accidentals.self, forKey: .accidentals)) ?? .sharps
        self.lastDifficulty = (try? container.decodeIfPresent(Difficulty.self, forKey: .lastDifficulty)) ?? .normal
        self.octaveAgnostic = try container.decodeIfPresent(Bool.self, forKey: .octaveAgnostic) ?? true
        self.clickTrack = try container.decodeIfPresent(Bool.self, forKey: .clickTrack) ?? false
        self.showNoteNames = try container.decodeIfPresent(Bool.self, forKey: .showNoteNames) ?? false
    }
}
