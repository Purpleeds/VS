import Foundation

public enum NoteRating: String, Codable, CaseIterable, Sendable {
    case perfect
    case great
    case good
    case meh
    case miss

    public var displayName: String {
        switch self {
        case .perfect: return "Perfect"
        case .great: return "Great"
        case .good: return "Good"
        case .meh: return "Meh"
        case .miss: return "Miss"
        }
    }

    /// Fraction of the note sung within tolerance -> rating.
    public init(fraction: Double) {
        switch fraction {
        case 0.9...: self = .perfect
        case 0.75...: self = .great
        case 0.5...: self = .good
        case 0.25...: self = .meh
        default: self = .miss
        }
    }

    public var basePoints: Double {
        switch self {
        case .perfect: return 100
        case .great: return 80
        case .good: return 50
        case .meh: return 20
        case .miss: return 0
        }
    }

    public var keepsCombo: Bool {
        switch self {
        case .perfect, .great, .good: return true
        case .meh, .miss: return false
        }
    }
}

public enum Grade: String, Codable, CaseIterable, Sendable {
    case s = "S"
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case f = "F"

    public init(accuracy: Double) {
        switch accuracy {
        case 0.95...: self = .s
        case 0.85...: self = .a
        case 0.70...: self = .b
        case 0.55...: self = .c
        case 0.40...: self = .d
        default: self = .f
        }
    }
}

public enum PitchFolding {
    /// Sung minus target in cents. Octave-agnostic folds it into -600...600 so any octave counts.
    public static func errorCents(sung: Double, target: Double, octaveAgnostic: Bool) -> Double {
        let cents = (sung - target) * 100
        guard octaveAgnostic else { return cents }
        return cents - 1_200 * (cents / 1_200).rounded()
    }

    /// Moves `sung` by whole octaves to within six semitones of `reference` (for drawing the dot near the notes).
    public static func fold(_ sung: Double, toward reference: Double) -> Double {
        sung - 12 * ((sung - reference) / 12).rounded()
    }
}

public struct ScoringRules: Sendable, Equatable {
    public var difficulty: Difficulty
    public var octaveAgnostic: Bool
    /// Ignore up to this much of each note's start (the attack), capped at 20% of the note.
    public var attackGrace: Double

    public init(difficulty: Difficulty, octaveAgnostic: Bool = true, attackGrace: Double = 0.06) {
        self.difficulty = difficulty
        self.octaveAgnostic = octaveAgnostic
        self.attackGrace = attackGrace
    }

    public var toleranceCents: Double { difficulty.toleranceCents }
}

public struct NoteResult: Sendable, Equatable, Codable {
    /// Index into `Song.notes`.
    public var noteIndex: Int
    public var rating: NoteRating
    /// Fraction of the note's frames that were on pitch.
    public var fraction: Double
    public var points: Int
    public var multiplier: Int
    public var isGolden: Bool
    public var endTime: Double
}

/// Scores a play-through from pitch frames given in song time, in order.
public struct ScoreKeeper: Sendable {
    public let rules: ScoringRules
    private let song: Song
    /// Indices of scored notes, in start order.
    private let scored: [Int]
    private var counted: [Int]
    private var hits: [Int]
    private var done: [Bool]
    private var next = 0

    public private(set) var score = 0
    public private(set) var combo = 0
    public private(set) var maxCombo = 0
    public private(set) var results: [NoteResult] = []
    public private(set) var counts: [NoteRating: Int] = [:]
    /// The most recent frame inside a note: which note, and whether it was on pitch.
    public private(set) var lastEvaluation: (noteIndex: Int, onPitch: Bool, time: Double)?

    private var weightedFraction = 0.0
    private var totalWeight = 0.0

    public init(song: Song, rules: ScoringRules) {
        self.song = song
        self.rules = rules
        scored = song.notes.indices.filter { song.notes[$0].isScored }
        counted = Array(repeating: 0, count: scored.count)
        hits = Array(repeating: 0, count: scored.count)
        done = Array(repeating: false, count: scored.count)
    }

    public var multiplier: Int { min(4, 1 + combo / 10) }
    public var scoredNoteCount: Int { scored.count }
    public var isComplete: Bool { next >= scored.count }

    /// Weighted accuracy over the notes rated so far (0 before any).
    public var accuracy: Double { totalWeight > 0 ? weightedFraction / totalWeight : 0 }

    public var grade: Grade { Grade(accuracy: accuracy) }

    public static func lengthFactor(_ duration: Double) -> Double {
        min(4, max(0.5, duration / 0.5))
    }

    /// Feeds one frame (song time, sung MIDI or nil when unvoiced). Returns notes that finished.
    @discardableResult
    public mutating func add(time: Double, midi: Double?) -> [NoteResult] {
        var finished: [NoteResult] = []
        var k = next
        while k < scored.count {
            let index = scored[k]
            let note = song.notes[index]
            if note.start > time { break }
            if !done[k] {
                if time > note.end {
                    finished.append(finalize(k))
                } else if time >= note.start + min(rules.attackGrace, note.duration * 0.2) {
                    counted[k] += 1
                    var onPitch = false
                    if let midi {
                        let target = song.targetPitch(noteAt: index, time: time)
                        let error = PitchFolding.errorCents(sung: midi, target: target, octaveAgnostic: rules.octaveAgnostic)
                        onPitch = abs(error) <= rules.toleranceCents
                    }
                    if onPitch { hits[k] += 1 }
                    lastEvaluation = (index, onPitch, time)
                }
            }
            k += 1
        }
        while next < scored.count, done[next] { next += 1 }
        return finished
    }

    /// Rates every remaining note (call when the song ends or the player quits).
    @discardableResult
    public mutating func finish() -> [NoteResult] {
        var finished: [NoteResult] = []
        for k in scored.indices where !done[k] {
            finished.append(finalize(k))
        }
        next = scored.count
        return finished
    }

    private mutating func finalize(_ k: Int) -> NoteResult {
        let index = scored[k]
        let note = song.notes[index]
        let fraction = counted[k] > 0 ? Double(hits[k]) / Double(counted[k]) : 0
        let rating = NoteRating(fraction: fraction)
        let golden = note.isGolden ? 2.0 : 1.0
        let weight = Self.lengthFactor(note.duration) * golden
        let applied = multiplier
        let points = Int((rating.basePoints * weight * Double(applied)).rounded())
        score += points
        if rating.keepsCombo {
            combo += 1
            maxCombo = max(maxCombo, combo)
        } else {
            combo = 0
        }
        counts[rating, default: 0] += 1
        weightedFraction += fraction * weight
        totalWeight += weight
        done[k] = true
        let result = NoteResult(
            noteIndex: index, rating: rating, fraction: fraction, points: points,
            multiplier: applied, isGolden: note.isGolden, endTime: note.end
        )
        results.append(result)
        return result
    }

    public func result(songID: String, songTitle: String, date: Date = Date()) -> GameResult {
        GameResult(
            songID: songID,
            songTitle: songTitle,
            difficulty: rules.difficulty,
            octaveAgnostic: rules.octaveAgnostic,
            score: score,
            accuracy: accuracy,
            grade: grade,
            maxCombo: maxCombo,
            counts: counts,
            noteCount: scored.count,
            date: date
        )
    }
}

public struct GameResult: Codable, Sendable, Equatable {
    public var songID: String
    public var songTitle: String
    public var difficulty: Difficulty
    public var octaveAgnostic: Bool
    public var score: Int
    public var accuracy: Double
    public var grade: Grade
    public var maxCombo: Int
    public var counts: [NoteRating: Int]
    public var noteCount: Int
    public var date: Date
    /// The run ended because the energy bar emptied.
    public var failed: Bool

    public init(
        songID: String, songTitle: String, difficulty: Difficulty, octaveAgnostic: Bool, score: Int,
        accuracy: Double, grade: Grade, maxCombo: Int, counts: [NoteRating: Int], noteCount: Int, date: Date,
        failed: Bool = false
    ) {
        self.songID = songID
        self.songTitle = songTitle
        self.difficulty = difficulty
        self.octaveAgnostic = octaveAgnostic
        self.score = score
        self.accuracy = accuracy
        self.grade = grade
        self.maxCombo = maxCombo
        self.counts = counts
        self.noteCount = noteCount
        self.date = date
        self.failed = failed
    }
}

public struct PersonalBest: Codable, Sendable, Equatable {
    public var score: Int
    public var accuracy: Double
    public var grade: Grade
    public var maxCombo: Int
    public var date: Date

    public init(score: Int, accuracy: Double, grade: Grade, maxCombo: Int, date: Date) {
        self.score = score
        self.accuracy = accuracy
        self.grade = grade
        self.maxCombo = maxCombo
        self.date = date
    }

    private enum CodingKeys: String, CodingKey { case score, accuracy, grade, maxCombo, date }

    /// Forgiving: the score is required; other fields fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        score = try c.decode(Int.self, forKey: .score)
        let accuracy = c.lenient(Double.self, forKey: .accuracy) ?? 0
        self.accuracy = accuracy.isFinite ? min(1, max(0, accuracy)) : 0
        grade = c.lenient(Grade.self, forKey: .grade) ?? Grade(accuracy: self.accuracy)
        maxCombo = c.lenient(Int.self, forKey: .maxCombo) ?? 0
        date = c.lenient(Date.self, forKey: .date) ?? Date(timeIntervalSince1970: 0)
    }
}

/// Best score per song and difficulty, persisted as JSON.
public struct PersonalBests: Codable, Sendable, Equatable {
    public private(set) var records: [String: PersonalBest] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case records }

    /// Skips unreadable entries instead of failing the whole file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = (try? c.decodeIfPresent([String: Lossy<PersonalBest>].self, forKey: .records)) ?? nil
        records = (lossy ?? [:]).compactMapValues(\.value)
    }

    public static func key(songID: String, difficulty: Difficulty) -> String {
        "\(songID)|\(difficulty.rawValue)"
    }

    public func best(songID: String, difficulty: Difficulty) -> PersonalBest? {
        records[Self.key(songID: songID, difficulty: difficulty)]
    }

    /// Stores the result if it beats the previous best score. Returns true for a new best.
    @discardableResult
    public mutating func record(_ result: GameResult) -> Bool {
        let key = Self.key(songID: result.songID, difficulty: result.difficulty)
        if let existing = records[key], existing.score >= result.score {
            return false
        }
        records[key] = PersonalBest(score: result.score, accuracy: result.accuracy, grade: result.grade, maxCombo: result.maxCombo, date: result.date)
        return true
    }

    public mutating func remove(songID: String) {
        records = records.filter { !$0.key.hasPrefix(songID + "|") }
    }
}

/// Downsampled sung pitch for the results replay graph.
public struct ReplayTrace: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var time: Double
        public var midi: Double?
    }

    public private(set) var points: [Point] = []
    public let minimumInterval: Double

    public init(minimumInterval: Double = 0.02) {
        self.minimumInterval = minimumInterval
    }

    public mutating func append(time: Double, midi: Double?) {
        if let last = points.last {
            if time < last.time { return }
            // Always keep voiced/unvoiced transitions so gaps stay visible.
            if time - last.time < minimumInterval && (last.midi == nil) == (midi == nil) { return }
        }
        points.append(Point(time: time, midi: midi))
    }
}
