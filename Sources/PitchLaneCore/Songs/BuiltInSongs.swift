import Foundation

/// Built-in exercises and three original melodies (music and lyrics written for PitchLane), each in
/// Easy / Normal / Hard. Easy: slower, narrower, even rhythm. Hard: faster, wider, ornamented
/// (continuation slides "~", leaps, more golden notes).
public enum BuiltInKind: String, CaseIterable, Sendable, Codable, Identifiable {
    case majorScale
    case minorScale
    case arpeggios
    case intervals
    case longNotes
    case sirens
    case morningLane
    case paperBoats
    case lanternSteps

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .majorScale: return "Major Scale"
        case .minorScale: return "Minor Scale"
        case .arpeggios: return "Arpeggios"
        case .intervals: return "Interval Jumps"
        case .longNotes: return "Long-Note Holds"
        case .sirens: return "Sirens"
        case .morningLane: return "Morning Lane"
        case .paperBoats: return "Paper Boats"
        case .lanternSteps: return "Lantern Steps"
        }
    }

    public var subtitle: String {
        switch self {
        case .majorScale: return "C major, up and down"
        case .minorScale: return "A minor, natural and harmonic"
        case .arpeggios: return "Broken chords"
        case .intervals: return "Leaps from a home note"
        case .longNotes: return "Steady breath and pitch"
        case .sirens: return "Smooth slides"
        case .morningLane: return "Original melody · C major"
        case .paperBoats: return "Original melody · A minor waltz"
        case .lanternSteps: return "Original melody · G major"
        }
    }

    public var isExercise: Bool {
        switch self {
        case .morningLane, .paperBoats, .lanternSteps: return false
        default: return true
        }
    }
}

public enum BuiltInSongs {
    public static func id(_ kind: BuiltInKind, _ difficulty: Difficulty) -> String {
        "builtin.\(kind.rawValue).\(difficulty.rawValue)"
    }

    /// Every built-in song: 9 kinds x 3 difficulties.
    public static let all: [Song] = BuiltInKind.allCases.flatMap { kind in
        Difficulty.allCases.map { song(kind, $0) }
    }

    public static func song(withID id: String) -> Song? {
        all.first { $0.id == id }
    }

    public static func song(_ kind: BuiltInKind, _ difficulty: Difficulty) -> Song {
        let builder: MelodyBuilder
        switch kind {
        case .majorScale: builder = majorScale(difficulty)
        case .minorScale: builder = minorScale(difficulty)
        case .arpeggios: builder = arpeggios(difficulty)
        case .intervals: builder = intervals(difficulty)
        case .longNotes: builder = longNotes(difficulty)
        case .sirens: builder = sirens(difficulty)
        case .morningLane: builder = morningLane(difficulty)
        case .paperBoats: builder = paperBoats(difficulty)
        case .lanternSteps: builder = lanternSteps(difficulty)
        }
        return Song(
            id: id(kind, difficulty),
            title: kind.title,
            artist: kind.isExercise ? "PitchLane Exercises" : "PitchLane Originals",
            source: .builtIn,
            difficulty: difficulty,
            notes: builder.notes,
            lineBreaks: builder.lineBreaks,
            tempo: [TempoSegment(start: 0, beatDuration: builder.secondsPerBeat)]
        )
    }

    // MARK: Exercises

    private static let solfege = ["Do", "Di", "Re", "Ri", "Mi", "Fa", "Fi", "Sol", "Si", "La", "Li", "Ti"]

    /// Movable-do syllable relative to `tonic`.
    private static func syllable(_ pitch: Int, tonic: Int = 60) -> String {
        solfege[((pitch - tonic) % 12 + 12) % 12]
    }

    private static func majorScale(_ difficulty: Difficulty) -> MelodyBuilder {
        let up = [60, 62, 64, 65, 67, 69, 71, 72]
        switch difficulty {
        case .easy:
            var b = MelodyBuilder(bpm: 72)
            for p in up.dropLast() { b.note(p, 1, syllable(p)) }
            b.note(72, 2, "Do", golden: true)
            b.rest(2)
            b.lineBreak()
            for p in up.reversed().dropFirst().dropLast() { b.note(p, 1, syllable(p)) }
            b.note(60, 2, "Do")
            return b
        case .normal:
            var b = MelodyBuilder(bpm: 92)
            for round in 0..<2 {
                for p in up.dropLast() { b.note(p, 1, syllable(p)) }
                b.note(72, 2, "Do", golden: round == 1)
                for p in up.reversed().dropFirst().dropLast() { b.note(p, 1, syllable(p)) }
                b.note(60, 2, "Do")
                b.rest(2)
                b.lineBreak()
            }
            return b
        case .hard:
            var b = MelodyBuilder(bpm: 108)
            // In thirds: C E D F E G F A G B A C B D C
            let thirds = [60, 64, 62, 65, 64, 67, 65, 69, 67, 71, 69, 72, 71, 74, 72]
            for p in thirds { b.note(p, 0.5, syllable(p)) }
            b.note(72, 1.5, "Do", golden: true)
            b.rest(1)
            b.lineBreak()
            for p in up.reversed().dropLast() { b.note(p, 0.5, syllable(p)) }
            b.note(60, 2, "Do", golden: true)
            return b
        }
    }

    private static func minorScale(_ difficulty: Difficulty) -> MelodyBuilder {
        let natural = [57, 59, 60, 62, 64, 65, 67, 69]
        let harmonic = [57, 59, 60, 62, 64, 65, 68, 69]
        switch difficulty {
        case .easy:
            var b = MelodyBuilder(bpm: 72)
            for p in natural.dropLast() { b.note(p, 1, syllable(p, tonic: 60)) }
            b.note(69, 2, "La", golden: true)
            b.rest(2)
            b.lineBreak()
            for p in natural.reversed().dropFirst().dropLast() { b.note(p, 1, syllable(p, tonic: 60)) }
            b.note(57, 2, "La")
            return b
        case .normal:
            var b = MelodyBuilder(bpm: 92)
            for p in natural.dropLast() { b.note(p, 1, syllable(p, tonic: 60)) }
            b.note(69, 2, "La")
            for p in natural.reversed().dropFirst().dropLast() { b.note(p, 1, syllable(p, tonic: 60)) }
            b.note(57, 2, "La", golden: true)
            return b
        case .hard:
            var b = MelodyBuilder(bpm: 104)
            for p in harmonic.dropLast() { b.note(p, 0.5, syllable(p, tonic: 60)) }
            b.note(69, 1.5, "La", golden: true)
            b.rest(0.5)
            for p in harmonic.reversed().dropFirst().dropLast() { b.note(p, 0.5, syllable(p, tonic: 60)) }
            b.note(57, 1, "La")
            b.rest(1)
            b.lineBreak()
            for p in harmonic { b.note(p, 0.5, syllable(p, tonic: 60)) }
            for p in harmonic.reversed().dropFirst().dropLast() { b.note(p, 0.5, syllable(p, tonic: 60)) }
            b.note(57, 2, "La", golden: true)
            return b
        }
    }

    private static func arpeggios(_ difficulty: Difficulty) -> MelodyBuilder {
        switch difficulty {
        case .easy:
            var b = MelodyBuilder(bpm: 72)
            for p in [60, 64, 67, 72, 67, 64] { b.note(p, 1, syllable(p)) }
            b.note(60, 2, "Do")
            b.rest(2)
            b.lineBreak()
            for p in [60, 64, 67, 72] { b.note(p, 1, syllable(p)) }
            b.note(72, 2, "Do", golden: true)
            return b
        case .normal:
            var b = MelodyBuilder(bpm: 92)
            let chords = [[60, 64, 67, 72], [60, 65, 69, 72], [59, 62, 67, 71], [60, 64, 67, 72]]
            for (i, chord) in chords.enumerated() {
                for p in chord { b.note(p, 1, syllable(p)) }
                for p in chord.reversed().dropFirst().dropLast() { b.note(p, 1, syllable(p)) }
                b.note(chord[0], 2, syllable(chord[0]), golden: i == chords.count - 1)
                b.rest(1)
                b.lineBreak()
            }
            return b
        case .hard:
            var b = MelodyBuilder(bpm: 112)
            let chords = [
                [60, 64, 67, 71, 72], // Cmaj7
                [57, 60, 64, 67, 69], // Am7
                [62, 65, 69, 72, 74], // Dm7
                [55, 59, 62, 65, 67], // G7
            ]
            for chord in chords {
                for p in chord { b.note(p, 0.5, "ah") }
                for p in chord.reversed().dropFirst().dropLast() { b.note(p, 0.5, "ah") }
                b.rest(0.5)
                b.lineBreak()
            }
            b.note(60, 3, "ah", golden: true)
            return b
        }
    }

    private static func intervals(_ difficulty: Difficulty) -> MelodyBuilder {
        let pairs: [(Int, Int)]
        let beats: Double
        let gap: Double
        var b: MelodyBuilder
        switch difficulty {
        case .easy:
            b = MelodyBuilder(bpm: 72)
            pairs = [(60, 64), (60, 65), (60, 67), (60, 69)]
            beats = 2
            gap = 1
        case .normal:
            b = MelodyBuilder(bpm: 88)
            pairs = [(60, 64), (60, 67), (60, 69), (60, 72), (72, 67), (67, 60)]
            beats = 1
            gap = 1
        case .hard:
            b = MelodyBuilder(bpm: 104)
            pairs = [(60, 72), (62, 71), (64, 72), (55, 67), (57, 65), (59, 69), (60, 71), (72, 60)]
            beats = 1
            gap = 0.5
        }
        for (i, pair) in pairs.enumerated() {
            let last = i == pairs.count - 1
            b.note(pair.0, beats, syllable(pair.0))
            b.note(pair.1, last ? beats * 2 : beats, syllable(pair.1), golden: last)
            b.rest(gap)
            if i % 2 == 1 { b.lineBreak() }
        }
        return b
    }

    private static func longNotes(_ difficulty: Difficulty) -> MelodyBuilder {
        var b = MelodyBuilder(bpm: 60) // one beat = one second
        let holds: [Int]
        let length: Double
        let vowel: String
        switch difficulty {
        case .easy:
            holds = [64, 67, 62, 60]
            length = 3
            vowel = "ah"
        case .normal:
            holds = [64, 67, 69, 62, 60]
            length = 5
            vowel = "oo"
        case .hard:
            holds = [67, 71, 69, 64, 72, 60]
            length = 6
            vowel = "ee"
        }
        for (i, pitch) in holds.enumerated() {
            let golden = difficulty == .hard ? i >= holds.count - 2 : i == holds.count - 1
            b.note(pitch, length, vowel, golden: golden)
            b.rest(2)
            b.lineBreak()
        }
        return b
    }

    private static func sirens(_ difficulty: Difficulty) -> MelodyBuilder {
        var b = MelodyBuilder(bpm: 60)
        switch difficulty {
        case .easy:
            for (low, high) in [(60, 67), (62, 69)] {
                b.note(low, 1, "oo")
                b.glide(to: high, 2, "wee")
                b.glide(to: low, 2, "oo", golden: low == 62)
                b.rest(2)
                b.lineBreak()
            }
        case .normal:
            for (low, high) in [(60, 72), (55, 67)] {
                b.note(low, 1, "oo")
                b.glide(to: high, 2, "wee")
                b.glide(to: low, 2, "oo")
                b.rest(1.5)
                b.lineBreak()
            }
            b.note(60, 1, "oo")
            b.glide(to: 64, 1, "wee")
            b.glide(to: 67, 1, "")
            b.glide(to: 72, 1, "")
            b.glide(to: 60, 3, "oo", golden: true)
        case .hard:
            b.note(60, 0.5, "oo")
            b.glide(to: 79, 2, "wee")
            b.glide(to: 60, 2, "oo")
            b.rest(1)
            b.lineBreak()
            b.note(60, 0.5, "oo")
            for p in [64, 60, 67, 60, 72, 60] { b.glide(to: p, 0.75, "") }
            b.rest(1)
            b.lineBreak()
            b.note(55, 0.5, "oo")
            b.glide(to: 74, 2, "wee", golden: true)
            b.glide(to: 55, 2, "oo", golden: true)
        }
        return b
    }

    // MARK: Original melodies

    private static func morningLane(_ difficulty: Difficulty) -> MelodyBuilder {
        switch difficulty {
        case .easy:
            var b = MelodyBuilder(bpm: 76)
            b.phrase("G4:1:Fol A4:1:low G4:1:the E4:1:mor G4:1:ning G4:2:lane r:1")
            b.phrase("A4:1:down G4:1:where E4:1:the D4:1:ri E4:1:ver C4:2:bends r:1")
            b.phrase("E4:1:hum F4:1:ming G4:1:a A4:1:tune G4:1:of F4:1:my E4:2:own r:1")
            b.phrase("D4:1:till E4:1:the F4:1:long D4:1:day C4:3*:ends")
            return b
        case .normal:
            var b = MelodyBuilder(bpm: 92)
            b.phrase("G4:1:Fol A4:.5:low G4:.5:the E4:1:mor G4:1:ning C5:2:lane r:2")
            b.phrase("A4:1:down G4:.5:where E4:.5:the D4:1:ri E4:1:ver C4:2:bends r:2")
            b.phrase("E4:.5:hum F4:.5:ming G4:1:a A4:1:tune G4:.5:of F4:.5:my E4:2:own r:2")
            b.phrase("D4:1:till E4:1:the F4:1:long D4:1:day C4:3*:ends r:1")
            return b
        case .hard:
            var b = MelodyBuilder(bpm: 108)
            b.phrase("G4:1:Fol A4:.5:low G4:.5:the E4:1:mor G4:1:ning C5:1*:lane D5:.5:~ C5:.5:~ r:2")
            b.phrase("A4:1:down G4:.5:where E4:.5:the D4:1:ri E4:1:ver C4:1:bends D4:.5:~ C4:.5:~ r:2")
            b.phrase("E4:.5:hum F4:.5:ming G4:1:a C5:1:tune B4:.5:of A4:.5:my G4:1:own E4:1:~ r:2")
            b.phrase("D4:1:till E4:.5:the F4:.5:~ A4:1:long B4:1:day C5:3*:ends r:1")
            return b
        }
    }

    private static func paperBoats(_ difficulty: Difficulty) -> MelodyBuilder {
        switch difficulty {
        case .easy:
            var b = MelodyBuilder(bpm: 84)
            b.phrase("A3:1:Pa C4:1:per E4:1:boats D4:1:on C4:1:a D4:1:rain E4:1:y A3:3:street r:2")
            b.phrase("E4:1:car E4:1:ry D4:1:my C4:1:wish D4:1:es E4:1:down D4:1:to C4:1:the A3:3:sea r:2")
            b.phrase("E4:1:one D4:1:goes C4:1:left D4:1:and C4:1:one B3:1:goes A3:3:right r:2")
            b.phrase("C4:1:both D4:1:will E4:1:find D4:1:the C4:1:morn B3:1:ing A3:3*:light")
            return b
        case .normal:
            var b = MelodyBuilder(bpm: 100)
            b.phrase("A3:1:Pa C4:1:per E4:1:boats D4:.5:on C4:.5:a D4:1:rain E4:1:y A3:3:street r:3")
            b.phrase("E4:1:car G4:1:ry A4:1:my G4:.5:wish E4:.5:es D4:1:down C4:.5:to D4:.5:the E4:3:sea r:3")
            b.phrase("A4:1:one G4:1:goes E4:1:left D4:1:and C4:1:one D4:1:goes E4:3:right r:3")
            b.phrase("C4:1:both D4:1:will E4:1:find G4:1:the E4:.5:morn D4:.5:ing A3:3*:light r:1")
            return b
        case .hard:
            var b = MelodyBuilder(bpm: 116)
            b.phrase("A3:.5:Pa B3:.5:~ C4:1:per E4:1:boats A4:.5:on G4:.5:a F4:1:rain E4:1:y A3:3:street r:3")
            b.phrase("E4:1:car G4:1:ry A4:1:my C5:.5:wish B4:.5:es A4:1:down G4:.5:to F4:.5:the E4:2*:sea D4:1:~ r:3")
            b.phrase("A4:1:one B4:1:goes C5:1:left B4:1:and A4:1:one G#4:1:goes A4:3:right r:3")
            b.phrase("C5:1:both B4:1:will A4:1:find E4:1:the G4:.5:morn F4:.5:ing E4:1*:light A3:2*:~ r:1")
            return b
        }
    }

    private static func lanternSteps(_ difficulty: Difficulty) -> MelodyBuilder {
        switch difficulty {
        case .easy:
            var b = MelodyBuilder(bpm: 88)
            b.phrase("D4:1:Lan E4:1:terns G4:1:glow A4:1:on G4:1:the A4:1:old G4:1:stone E4:2:steps r:1")
            b.phrase("D4:1:light E4:1:ing G4:1:up A4:1:as B4:1:the A4:1:eve G4:1:ning E4:2:falls r:1")
            b.phrase("G4:1:climb A4:1:a G4:1:lit E4:1:tle D4:1:high E4:1:er D4:2:now r:1")
            b.phrase("E4:1:hear G4:1:the A4:1:whole A4:1:town G4:3*:sing")
            return b
        case .normal:
            var b = MelodyBuilder(bpm: 104)
            b.phrase("D4:.5:Lan E4:.5:terns G4:1:glow A4:.5:on G4:.5:the B4:1:old A4:1:stone G4:2:steps r:1")
            b.phrase("D4:.5:light E4:.5:ing G4:1:up A4:.5:as B4:.5:the D5:1:eve B4:1:ning A4:2:falls r:1")
            b.phrase("G4:.5:climb A4:.5:a B4:1:lit A4:.5:tle G4:.5:high E4:1:er D4:2:now r:1")
            b.phrase("E4:1:hear G4:1:the A4:1:whole B4:1:town G4:3*:sing r:1")
            return b
        case .hard:
            var b = MelodyBuilder(bpm: 120)
            b.phrase("D4:.5:Lan E4:.5:terns G4:.5:glow A4:.5:~ B4:.5:on A4:.5:the D5:1:old B4:1:stone G4:1.5*:steps A4:.5:~ r:1")
            b.phrase("D4:.5:light E4:.5:ing G4:1:up A4:.5:as B4:.5:the E5:1:eve D5:1:ning B4:1:falls A4:1:~ r:1")
            b.phrase("G4:.5:climb A4:.5:a B4:.5:lit D5:.5:tle B4:.5:high A4:.5:er G4:1:now E4:1:~ r:1")
            b.phrase("E4:.5:hear G4:.5:the A4:1:whole B4:1:town D5:2*:sing G4:2*:~")
            return b
        }
    }
}

/// Small helper for writing melodies in beats.
struct MelodyBuilder {
    let secondsPerBeat: Double
    private(set) var notes: [SongNote] = []
    private(set) var lineBreaks: [Double] = []
    private var beat = 0.0
    /// Beat where the most recent note's written length ends.
    private var lastNoteEndBeat = -1.0
    /// Detached notes sound for this fraction of their written length.
    private let articulation = 0.88
    /// Glide length of "~" continuation notes.
    private let continuationGlide = 0.12

    init(bpm: Double) {
        secondsPerBeat = 60 / bpm
    }

    mutating func note(_ pitch: Int, _ beats: Double, _ lyric: String, golden: Bool = false) {
        notes.append(SongNote(
            start: beat * secondsPerBeat,
            duration: beats * secondsPerBeat * articulation,
            pitch: pitch,
            lyric: lyric,
            isGolden: golden
        ))
        beat += beats
        lastNoteEndBeat = beat
    }

    /// A note that glides from the previous pitch over its whole length (siren style).
    mutating func glide(to pitch: Int, _ beats: Double, _ lyric: String, golden: Bool = false) {
        tiePrevious()
        notes.append(SongNote(
            start: beat * secondsPerBeat,
            duration: beats * secondsPerBeat * articulation,
            pitch: pitch,
            lyric: lyric,
            isGolden: golden,
            slidesFromPrevious: true,
            slideDuration: nil
        ))
        beat += beats
        lastNoteEndBeat = beat
    }

    /// Continuation of the previous syllable with a short glide (UltraStar "~").
    mutating func continuation(_ pitch: Int, _ beats: Double, golden: Bool = false) {
        tiePrevious()
        let duration = beats * secondsPerBeat * articulation
        notes.append(SongNote(
            start: beat * secondsPerBeat,
            duration: duration,
            pitch: pitch,
            lyric: "",
            isGolden: golden,
            slidesFromPrevious: true,
            slideDuration: min(continuationGlide, duration / 2)
        ))
        beat += beats
        lastNoteEndBeat = beat
    }

    mutating func rest(_ beats: Double) {
        beat += beats
    }

    mutating func lineBreak() {
        lineBreaks.append(beat * secondsPerBeat)
    }

    /// Tokens "G4:1:Fol" (pitch:beats:syllable), "C4:3*:ends" (golden), "D5:.5:~" (continuation),
    /// "r:2" (rest). Ends with a line break.
    mutating func phrase(_ text: String) {
        for token in text.split(separator: " ") {
            let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.first == "r" {
                rest(Double(parts[1]) ?? 0)
                continue
            }
            precondition(parts.count == 3, "bad melody token \(token)")
            guard let pitch = NoteNaming.midiNote(named: parts[0]) else {
                preconditionFailure("bad pitch in melody token \(token)")
            }
            let golden = parts[1].hasSuffix("*")
            guard let beats = Double(parts[1].replacingOccurrences(of: "*", with: "")) else {
                preconditionFailure("bad length in melody token \(token)")
            }
            if parts[2] == "~" {
                continuation(pitch, beats, golden: golden)
            } else {
                note(pitch, beats, parts[2], golden: golden)
            }
        }
        lineBreak()
    }

    /// Makes the previous note run right up to this one so the slide connects (only when it was written
    /// directly before, with no rest in between).
    private mutating func tiePrevious() {
        guard let last = notes.indices.last, abs(lastNoteEndBeat - beat) < 1e-9 else { return }
        notes[last].duration = beat * secondsPerBeat - notes[last].start
    }
}
