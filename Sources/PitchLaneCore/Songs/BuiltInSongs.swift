import Foundation

/// Built-in songs: well-known public-domain songs (melodies and lyrics out of copyright) and three original
/// melodies written for PitchLane, each in Easy / Normal / Hard. Easy: slower. Hard: faster, with held-vowel
/// slides ("~") at the ends of lines. Never add copyrighted songs or lyrics here.
public enum BuiltInKind: String, CaseIterable, Sendable, Codable, Identifiable {
    case twinkle
    case happyBirthday
    case odeToJoy
    case jingleBells
    case maryLamb
    case rowYourBoat
    case areYouSleeping
    case morningLane
    case paperBoats
    case lanternSteps

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .twinkle: return "Twinkle, Twinkle, Little Star"
        case .happyBirthday: return "Happy Birthday to You"
        case .odeToJoy: return "Ode to Joy"
        case .jingleBells: return "Jingle Bells"
        case .maryLamb: return "Mary Had a Little Lamb"
        case .rowYourBoat: return "Row, Row, Row Your Boat"
        case .areYouSleeping: return "Are You Sleeping"
        case .morningLane: return "Morning Lane"
        case .paperBoats: return "Paper Boats"
        case .lanternSteps: return "Lantern Steps"
        }
    }

    public var subtitle: String {
        switch self {
        case .twinkle: return "Traditional · public domain"
        case .happyBirthday: return "Hill sisters · public domain"
        case .odeToJoy: return "Beethoven, words by Schiller (German) · public domain"
        case .jingleBells: return "James Lord Pierpont, 1857 · public domain"
        case .maryLamb: return "Sarah Josepha Hale, 1830 · public domain"
        case .rowYourBoat: return "Traditional · public domain"
        case .areYouSleeping: return "Traditional (Frère Jacques) · public domain"
        case .morningLane: return "Original melody · C major"
        case .paperBoats: return "Original melody · A minor waltz"
        case .lanternSteps: return "Original melody · G major"
        }
    }

    /// Written for PitchLane (as opposed to a public-domain song).
    public var isOriginal: Bool {
        switch self {
        case .morningLane, .paperBoats, .lanternSteps: return true
        default: return false
        }
    }
}

public enum BuiltInSongs {
    public static func id(_ kind: BuiltInKind, _ difficulty: Difficulty) -> String {
        "builtin.\(kind.rawValue).\(difficulty.rawValue)"
    }

    /// Every built-in song: every kind x 3 difficulties.
    public static let all: [Song] = BuiltInKind.allCases.flatMap { kind in
        Difficulty.allCases.map { song(kind, $0) }
    }

    public static func song(withID id: String) -> Song? {
        all.first { $0.id == id }
    }

    public static func song(_ kind: BuiltInKind, _ difficulty: Difficulty) -> Song {
        let builder: MelodyBuilder
        switch kind {
        case .twinkle: builder = classic(twinkle, bpm: 100, difficulty)
        case .happyBirthday: builder = classic(happyBirthday, bpm: 100, difficulty)
        case .odeToJoy: builder = classic(odeToJoy, bpm: 100, difficulty)
        case .jingleBells: builder = classic(jingleBells, bpm: 120, difficulty)
        case .maryLamb: builder = classic(maryLamb, bpm: 110, difficulty)
        case .rowYourBoat: builder = classic(rowYourBoat, bpm: 100, difficulty)
        case .areYouSleeping: builder = classic(areYouSleeping, bpm: 100, difficulty)
        case .morningLane: builder = morningLane(difficulty)
        case .paperBoats: builder = paperBoats(difficulty)
        case .lanternSteps: builder = lanternSteps(difficulty)
        }
        return Song(
            id: id(kind, difficulty),
            title: kind.title,
            artist: kind.isOriginal ? "PitchLane Originals" : "Public domain",
            source: .builtIn,
            difficulty: difficulty,
            notes: builder.notes,
            lineBreaks: builder.lineBreaks,
            tempo: [TempoSegment(start: 0, beatDuration: builder.secondsPerBeat)]
        )
    }

    // MARK: Public-domain songs

    /// One written melody, played slower on Easy and faster on Hard, where the last long note of each line also
    /// gets a held-vowel slide.
    private static func classic(_ phrases: [String], bpm: Double, _ difficulty: Difficulty) -> MelodyBuilder {
        let tempo: Double
        switch difficulty {
        case .easy: tempo = bpm * 0.8
        case .normal: tempo = bpm
        case .hard: tempo = bpm * 1.2
        }
        var b = MelodyBuilder(bpm: tempo)
        for phrase in phrases {
            b.phrase(difficulty == .hard ? holdLastNote(phrase) : phrase)
        }
        return b
    }

    /// Splits the last sung note of 1.5 beats or more into the note and a half-beat "~" continuation.
    private static func holdLastNote(_ phrase: String) -> String {
        var tokens = phrase.split(separator: " ").map(String.init)
        guard let index = tokens.lastIndex(where: { !$0.hasPrefix("r:") }) else { return phrase }
        let parts = tokens[index].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[2] != "~" else { return phrase }
        let golden = parts[1].hasSuffix("*")
        guard let beats = Double(parts[1].replacingOccurrences(of: "*", with: "")), beats >= 1.5 else { return phrase }
        let first = String(format: "%g", beats - 0.5) + (golden ? "*" : "")
        tokens[index] = "\(parts[0]):\(first):\(parts[2])"
        tokens.insert("\(parts[0]):.5:~", at: index + 1)
        return tokens.joined(separator: " ")
    }

    private static let twinkle = [
        "C4:1:Twin C4:1:kle G4:1:twin G4:1:kle A4:1:lit A4:1:tle G4:2:star,",
        "F4:1:how F4:1:I E4:1:won E4:1:der D4:1:what D4:1:you C4:2:are.",
        "G4:1:Up G4:1:a F4:1:bove F4:1:the E4:1:world E4:1:so D4:2:high,",
        "G4:1:like G4:1:a F4:1:dia F4:1:mond E4:1:in E4:1:the D4:2:sky.",
        "C4:1:Twin C4:1:kle G4:1:twin G4:1:kle A4:1:lit A4:1:tle G4:2*:star,",
        "F4:1:how F4:1:I E4:1:won E4:1:der D4:1:what D4:1:you C4:2*:are.",
    ]

    private static let happyBirthday = [
        "G4:.75:Hap G4:.25:py A4:1:birth G4:1:day C5:1:to B4:2:you, r:1",
        "G4:.75:hap G4:.25:py A4:1:birth G4:1:day D5:1:to C5:2:you, r:1",
        "G4:.75:hap G4:.25:py G5:1*:birth E5:1:day C5:1:dear B4:1:friend, A4:2:~ r:1",
        "F5:.75:hap F5:.25:py E5:1:birth C5:1:day D5:1:to C5:3*:you!",
    ]

    private static let odeToJoy = [
        "E4:1:Freu E4:1:de F4:1:schö G4:1:ner G4:1:Göt F4:1:ter E4:1:fun D4:1:ken,",
        "C4:1:Toch C4:1:ter D4:1:aus E4:1:E E4:1.5:ly D4:.5:si D4:2:um,",
        "E4:1:wir E4:1:be F4:1:tre G4:1:ten G4:1:feu F4:1:er E4:1:trun D4:1:ken,",
        "C4:1:Himm C4:1:li D4:1:sche, E4:1:dein D4:1.5:Hei C4:.5:lig C4:2*:tum!",
    ]

    private static let jingleBells = [
        "E4:1:Jin E4:1:gle E4:2:bells, E4:1:jin E4:1:gle E4:2:bells,",
        "E4:1:jin G4:1:gle C4:1.5:all D4:.5:the E4:4*:way.",
        "F4:1:Oh F4:1:what F4:1.5:fun F4:.5:it F4:1:is E4:1:to E4:1:ride E4:.5:in E4:.5:a E4:1:one D4:1:horse D4:1:o E4:1:pen D4:2:sleigh, G4:2*:hey!",
        "E4:1:Jin E4:1:gle E4:2:bells, E4:1:jin E4:1:gle E4:2:bells, E4:1:jin G4:1:gle C4:1.5:all D4:.5:the E4:4:way.",
        "F4:1:Oh F4:1:what F4:1.5:fun F4:.5:it F4:1:is E4:1:to E4:1:ride E4:.5:in E4:.5:a G4:1:one G4:1:horse F4:1:o D4:1:pen C4:4*:sleigh!",
    ]

    private static let maryLamb = [
        "E4:1:Ma D4:1:ry C4:1:had D4:1:a E4:1:lit E4:1:tle E4:2:lamb,",
        "D4:1:lit D4:1:tle D4:2:lamb, E4:1:lit G4:1:tle G4:2:lamb,",
        "E4:1:Ma D4:1:ry C4:1:had D4:1:a E4:1:lit E4:1:tle E4:1:lamb, E4:1:its",
        "D4:1:fleece D4:1:was E4:1:white D4:1:as C4:4*:snow.",
    ]

    private static let rowYourBoat = [
        "C4:1.5:Row, C4:1.5:row, C4:1:row D4:.5:your E4:1.5:boat",
        "E4:1:gent D4:.5:ly E4:1:down F4:.5:the G4:3:stream.",
        "C5:.5:Mer C5:.5:ri C5:.5:ly, G4:.5:mer G4:.5:ri G4:.5:ly, E4:.5:mer E4:.5:ri E4:.5:ly, C4:.5:mer C4:.5:ri C4:.5:ly,",
        "G4:1:life F4:.5:is E4:1:but D4:.5:a C4:3*:dream.",
    ]

    private static let areYouSleeping = [
        "C4:1:Are D4:1:you E4:1:sleep C4:1:ing, C4:1:are D4:1:you E4:1:sleep C4:1:ing,",
        "E4:1:Bro F4:1:ther G4:2:John? E4:1:Bro F4:1:ther G4:2:John?",
        "G4:.5:Morn A4:.5:ing G4:.5:bells F4:.5:are E4:1:ring C4:1:ing, G4:.5:morn A4:.5:ing G4:.5:bells F4:.5:are E4:1:ring C4:1:ing,",
        "C4:1:Ding G3:1:dang C4:2:dong, C4:1:ding G3:1:dang C4:2*:dong.",
    ]

    // MARK: Originals

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
