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
    /// Guide tone volume 0...1.
    public var guideVolume: Double
    /// Backing track volume 0...1.
    public var backingVolume: Double
    /// The singer's range from the range test (nil = not tested).
    public var vocalRange: VocalRange?
    /// Semitone shift chosen per song id (auto-transpose).
    public var songTranspose: [String: Int]
    /// Frames quieter than this are unvoiced (dBFS). Lower = more sensitive.
    public var noiseGateDBFS: Double
    /// Widen the detector to ~40 Hz - 2 kHz for instruments.
    public var instrumentMode: Bool
    /// Frame-rate counter on the game screen.
    public var showFPS: Bool
    /// Songs end when the energy bar empties (off = never fail).
    public var failEnabled: Bool
    /// Guide tone on for Easy/Normal (default on) and Hard (default off).
    public var guideOnEasyNormal: Bool
    public var guideOnHard: Bool

    public init(
        debugOverlay: Bool = false,
        accidentals: Accidentals = .sharps,
        lastDifficulty: Difficulty = .normal,
        octaveAgnostic: Bool = true,
        clickTrack: Bool = false,
        showNoteNames: Bool = false,
        guideVolume: Double = 0.6,
        backingVolume: Double = 0.8,
        guideOnEasyNormal: Bool = true,
        guideOnHard: Bool = false,
        vocalRange: VocalRange? = nil,
        songTranspose: [String: Int] = [:],
        noiseGateDBFS: Double = -50,
        instrumentMode: Bool = false,
        showFPS: Bool = false,
        failEnabled: Bool = true
    ) {
        self.debugOverlay = debugOverlay
        self.accidentals = accidentals
        self.lastDifficulty = lastDifficulty
        self.octaveAgnostic = octaveAgnostic
        self.clickTrack = clickTrack
        self.showNoteNames = showNoteNames
        self.guideVolume = guideVolume
        self.backingVolume = backingVolume
        self.guideOnEasyNormal = guideOnEasyNormal
        self.guideOnHard = guideOnHard
        self.vocalRange = vocalRange
        self.songTranspose = songTranspose
        self.noiseGateDBFS = noiseGateDBFS
        self.instrumentMode = instrumentMode
        self.showFPS = showFPS
        self.failEnabled = failEnabled
    }

    public static let noiseGateRange: ClosedRange<Double> = -65 ... -30

    /// The pipeline settings these choices imply.
    public func pipelineConfiguration() -> PitchPipelineConfiguration {
        .configured(instrument: instrumentMode, noiseGateDBFS: noiseGateDBFS, accidentals: accidentals)
    }

    public func transpose(for songID: String) -> Int { songTranspose[songID] ?? 0 }

    public mutating func setTranspose(_ semitones: Int, for songID: String) {
        if semitones == 0 { songTranspose[songID] = nil } else { songTranspose[songID] = max(-36, min(36, semitones)) }
    }

    public func guideEnabled(for difficulty: Difficulty) -> Bool {
        difficulty == .hard ? guideOnHard : guideOnEasyNormal
    }

    public mutating func setGuide(_ enabled: Bool, for difficulty: Difficulty) {
        if difficulty == .hard { guideOnHard = enabled } else { guideOnEasyNormal = enabled }
    }

    private enum CodingKeys: String, CodingKey {
        case debugOverlay
        case accidentals
        case lastDifficulty
        case octaveAgnostic
        case clickTrack
        case showNoteNames
        case guideVolume
        case backingVolume
        case guideOnEasyNormal
        case guideOnHard
        case vocalRange
        case songTranspose
        case noiseGateDBFS
        case instrumentMode
        case showFPS
        case failEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.debugOverlay = try container.decodeIfPresent(Bool.self, forKey: .debugOverlay) ?? false
        self.accidentals = (try? container.decodeIfPresent(Accidentals.self, forKey: .accidentals)) ?? .sharps
        self.lastDifficulty = (try? container.decodeIfPresent(Difficulty.self, forKey: .lastDifficulty)) ?? .normal
        self.octaveAgnostic = try container.decodeIfPresent(Bool.self, forKey: .octaveAgnostic) ?? true
        self.clickTrack = try container.decodeIfPresent(Bool.self, forKey: .clickTrack) ?? false
        self.showNoteNames = try container.decodeIfPresent(Bool.self, forKey: .showNoteNames) ?? false
        self.guideVolume = min(1, max(0, try container.decodeIfPresent(Double.self, forKey: .guideVolume) ?? 0.6))
        self.backingVolume = min(1, max(0, try container.decodeIfPresent(Double.self, forKey: .backingVolume) ?? 0.8))
        self.guideOnEasyNormal = try container.decodeIfPresent(Bool.self, forKey: .guideOnEasyNormal) ?? true
        self.guideOnHard = try container.decodeIfPresent(Bool.self, forKey: .guideOnHard) ?? false
        self.vocalRange = try? container.decodeIfPresent(VocalRange.self, forKey: .vocalRange)
        self.songTranspose = (try? container.decodeIfPresent([String: Int].self, forKey: .songTranspose)) ?? [:]
        let gate = try container.decodeIfPresent(Double.self, forKey: .noiseGateDBFS) ?? -50
        self.noiseGateDBFS = min(Self.noiseGateRange.upperBound, max(Self.noiseGateRange.lowerBound, gate))
        self.instrumentMode = try container.decodeIfPresent(Bool.self, forKey: .instrumentMode) ?? false
        self.showFPS = try container.decodeIfPresent(Bool.self, forKey: .showFPS) ?? false
        self.failEnabled = try container.decodeIfPresent(Bool.self, forKey: .failEnabled) ?? true
    }
}
