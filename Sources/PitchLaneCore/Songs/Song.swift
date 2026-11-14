import Foundation

/// Arrangement level for built-in songs and, from step 3, the scoring tolerance.
public enum Difficulty: String, Codable, Sendable, CaseIterable, Identifiable {
    case easy
    case normal
    case hard

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .easy: return "Easy"
        case .normal: return "Normal"
        case .hard: return "Hard"
        }
    }

    /// How far off (in cents) a sung frame may be and still count as on the note.
    public var toleranceCents: Double {
        switch self {
        case .easy: return 100
        case .normal: return 50
        case .hard: return 25
        }
    }
}

public enum SongSource: String, Codable, Sendable {
    case builtIn
    case ultraStar
    case midi
    /// Notes transcribed from the singing in an imported video.
    case video
}

/// Bounds every song must stay inside (importers and `song.json` decoding enforce them), so nothing downstream
/// (durations, click track, guide synth, graphs) ever sees absurd values.
public enum SongLimits {
    public static let maximumNotes = 20_000
    /// Notes start within a day either side of zero.
    public static let maximumAbsoluteStart: Double = 86_400
    public static let maximumNoteDuration: Double = 600
    public static let pitchRange: ClosedRange<Int> = 0...127
    /// Click intervals shorter than this (over 1200 BPM) are ignored.
    public static let minimumBeatDuration: Double = 0.05
    public static let maximumTextLength = 200

    public static func isSensible(start: Double, duration: Double) -> Bool {
        start.isFinite && duration.isFinite && abs(start) <= maximumAbsoluteStart
            && duration >= 0 && duration <= maximumNoteDuration
    }

    /// Titles and artists are clipped to a displayable length.
    public static func clip(_ text: String) -> String {
        text.count <= maximumTextLength ? text : String(text.prefix(maximumTextLength)) + "…"
    }
}

public struct SongNote: Codable, Sendable, Equatable, Hashable {
    /// Seconds from the start of the song (and of its backing audio, before `Song.offsetMs`).
    public var start: Double
    public var duration: Double
    /// MIDI note number (C4 = 60).
    public var pitch: Int
    /// Syllable as written (may carry leading/trailing spaces marking word boundaries).
    public var lyric: String
    /// Worth double.
    public var isGolden: Bool
    /// Shown but not scored (UltraStar "F" / rap notes).
    public var isFreestyle: Bool
    /// The pitch glides in from the previous note's pitch instead of jumping.
    public var slidesFromPrevious: Bool
    /// Length of that glide at the start of the note; nil = the whole note glides (siren style).
    public var slideDuration: Double?

    public init(
        start: Double,
        duration: Double,
        pitch: Int,
        lyric: String = "",
        isGolden: Bool = false,
        isFreestyle: Bool = false,
        slidesFromPrevious: Bool = false,
        slideDuration: Double? = nil
    ) {
        self.start = start
        self.duration = duration
        self.pitch = pitch
        self.lyric = lyric
        self.isGolden = isGolden
        self.isFreestyle = isFreestyle
        self.slidesFromPrevious = slidesFromPrevious
        self.slideDuration = slideDuration
    }

    public var end: Double { start + duration }
    public var isScored: Bool { !isFreestyle }
    /// Lyric without the word-boundary spaces, for display.
    public var displayLyric: String { lyric.trimmingCharacters(in: .whitespaces) }

    private enum CodingKeys: String, CodingKey {
        case start, duration, pitch, lyric, isGolden, isFreestyle, slidesFromPrevious, slideDuration
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        duration = try c.decode(Double.self, forKey: .duration)
        pitch = try c.decode(Int.self, forKey: .pitch)
        lyric = try c.decodeIfPresent(String.self, forKey: .lyric) ?? ""
        isGolden = try c.decodeIfPresent(Bool.self, forKey: .isGolden) ?? false
        isFreestyle = try c.decodeIfPresent(Bool.self, forKey: .isFreestyle) ?? false
        slidesFromPrevious = try c.decodeIfPresent(Bool.self, forKey: .slidesFromPrevious) ?? false
        slideDuration = try c.decodeIfPresent(Double.self, forKey: .slideDuration)
        guard SongLimits.isSensible(start: start, duration: duration) else {
            throw DecodingError.dataCorruptedError(forKey: .start, in: c, debugDescription: "note start/duration out of range")
        }
        guard SongLimits.pitchRange.contains(pitch) else {
            throw DecodingError.dataCorruptedError(forKey: .pitch, in: c, debugDescription: "pitch \(pitch) outside MIDI range")
        }
        if let slide = slideDuration, !slide.isFinite || slide < 0 { slideDuration = nil }
    }
}

/// A run of evenly spaced beats (clicks) starting at `start` seconds.
public struct TempoSegment: Codable, Sendable, Equatable, Hashable {
    public var start: Double
    /// Seconds per click (a quarter note for UltraStar/MIDI, the written beat for built-ins).
    public var beatDuration: Double

    public init(start: Double, beatDuration: Double) {
        self.start = start
        self.beatDuration = beatDuration
    }
}

public struct Song: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var title: String
    public var artist: String
    public var source: SongSource
    /// Arrangement level of built-in songs; nil for imports.
    public var difficulty: Difficulty?
    /// Sorted by start.
    public var notes: [SongNote]
    /// Seconds at which a new lyric line starts.
    public var lineBreaks: [Double]
    public var tempo: [TempoSegment]
    /// File name of the backing audio inside the song's folder.
    public var backingAudioFile: String?
    /// Shifts the notes against the backing audio (positive = notes later).
    public var offsetMs: Double
    /// File name of a video inside the song's folder, shown (muted) behind the lane. Its sound is the backing
    /// audio, so it shares the backing's timeline (`offsetMs` included).
    public var videoFile: String?
    /// Where the words came from when they were looked up online (e.g. "LRCLIB: Track · Artist").
    public var lyricsCredit: String?
    /// Separated stems of the backing audio (`StemSeparator`), played together with separate volumes.
    public var vocalsStemFile: String?
    public var musicStemFile: String?

    public var hasStems: Bool { vocalsStemFile != nil && musicStemFile != nil }

    public init(
        id: String,
        title: String,
        artist: String = "",
        source: SongSource,
        difficulty: Difficulty? = nil,
        notes: [SongNote],
        lineBreaks: [Double] = [],
        tempo: [TempoSegment] = [],
        backingAudioFile: String? = nil,
        offsetMs: Double = 0,
        videoFile: String? = nil,
        lyricsCredit: String? = nil,
        vocalsStemFile: String? = nil,
        musicStemFile: String? = nil
    ) {
        self.schemaVersion = Song.currentSchemaVersion
        self.id = id
        self.title = title
        self.artist = artist
        self.source = source
        self.difficulty = difficulty
        self.notes = notes.sorted { $0.start < $1.start }
        self.lineBreaks = lineBreaks.sorted()
        self.tempo = tempo.sorted { $0.start < $1.start }
        self.backingAudioFile = backingAudioFile
        self.offsetMs = offsetMs
        self.videoFile = videoFile
        self.lyricsCredit = lyricsCredit
        self.vocalsStemFile = vocalsStemFile
        self.musicStemFile = musicStemFile
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, artist, source, difficulty, notes, lineBreaks, tempo, backingAudioFile, offsetMs, videoFile, lyricsCredit, vocalsStemFile, musicStemFile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Song.currentSchemaVersion
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        source = (try? c.decodeIfPresent(SongSource.self, forKey: .source)) ?? .ultraStar
        difficulty = try? c.decodeIfPresent(Difficulty.self, forKey: .difficulty)
        notes = try c.decode([SongNote].self, forKey: .notes).sorted { $0.start < $1.start }
        lineBreaks = (try c.decodeIfPresent([Double].self, forKey: .lineBreaks) ?? []).sorted()
        tempo = (try c.decodeIfPresent([TempoSegment].self, forKey: .tempo) ?? [])
            .filter { $0.start.isFinite && $0.beatDuration.isFinite }
        backingAudioFile = try c.decodeIfPresent(String.self, forKey: .backingAudioFile)
        let offset = try c.decodeIfPresent(Double.self, forKey: .offsetMs) ?? 0
        offsetMs = offset.isFinite ? max(-60_000, min(60_000, offset)) : 0
        videoFile = c.lenient(String.self, forKey: .videoFile)
        lyricsCredit = c.lenient(String.self, forKey: .lyricsCredit).map(SongLimits.clip)
        vocalsStemFile = c.lenient(String.self, forKey: .vocalsStemFile)
        musicStemFile = c.lenient(String.self, forKey: .musicStemFile)
        guard notes.count <= SongLimits.maximumNotes * 2 else {
            throw DecodingError.dataCorruptedError(forKey: .notes, in: c, debugDescription: "too many notes (\(notes.count))")
        }
        lineBreaks = lineBreaks.filter(\.isFinite)
    }

    static let maximumClicksPerCall = 1_024

    // MARK: Derived

    public var scoredNotes: [SongNote] { notes.filter(\.isScored) }

    /// Seconds until the last note ends.
    public var duration: Double { notes.map(\.end).max() ?? 0 }

    /// Lowest...highest pitch of the scored notes (all notes if none are scored).
    public var pitchRange: ClosedRange<Int>? {
        let source = scoredNotes.isEmpty ? notes : scoredNotes
        guard let low = source.map(\.pitch).min(), let high = source.map(\.pitch).max() else { return nil }
        return low...high
    }

    public var summary: SongSummary {
        SongSummary(
            noteCount: notes.count,
            scoredNoteCount: scoredNotes.count,
            goldenCount: notes.filter(\.isGolden).count,
            pitchRange: pitchRange,
            duration: duration,
            hasBackingAudio: backingAudioFile != nil
        )
    }

    /// Target pitch (fractional MIDI) of `notes[index]` at song time `time`, following slides.
    public func targetPitch(noteAt index: Int, time: Double) -> Double {
        let note = notes[index]
        guard note.slidesFromPrevious, index > 0 else { return Double(note.pitch) }
        let from = Double(notes[index - 1].pitch)
        let glide = max(0.001, min(note.duration, note.slideDuration ?? note.duration))
        let x = min(1, max(0, (time - note.start) / glide))
        let eased = x * x * (3 - 2 * x)
        return from + (Double(note.pitch) - from) * eased
    }

    /// Click times between `start` and `end` (inclusive start, exclusive end), from the tempo map.
    /// With no tempo map, clicks fall every 0.5 s from 0.
    public func clickTimes(from start: Double, to end: Double) -> [Double] {
        let segments = tempo.isEmpty ? [TempoSegment(start: 0, beatDuration: 0.5)] : tempo
        var times: [Double] = []
        guard start.isFinite, end.isFinite, start < end else { return times }
        for (i, segment) in segments.enumerated()
        where segment.beatDuration.isFinite && segment.beatDuration >= SongLimits.minimumBeatDuration && segment.start.isFinite {
            let segmentEnd = i + 1 < segments.count ? segments[i + 1].start : .infinity
            let from = max(start, segment.start)
            let to = min(end, segmentEnd)
            guard from < to else { continue }
            // Integer beat index, so the loop always advances; capped so a long window can't run away.
            let first = ((from - segment.start) / segment.beatDuration).rounded(.up)
            guard first.isFinite, abs(first) < 1e12 else { continue }
            var k = Int64(first)
            while times.count < Self.maximumClicksPerCall {
                let t = segment.start + Double(k) * segment.beatDuration
                if t >= to { break }
                if t >= from { times.append(t) }
                k += 1
            }
        }
        return times
    }
}

public struct SongSummary: Sendable, Equatable {
    public var noteCount: Int
    public var scoredNoteCount: Int
    public var goldenCount: Int
    public var pitchRange: ClosedRange<Int>?
    public var duration: Double
    public var hasBackingAudio: Bool

    public init(
        noteCount: Int,
        scoredNoteCount: Int,
        goldenCount: Int,
        pitchRange: ClosedRange<Int>?,
        duration: Double,
        hasBackingAudio: Bool
    ) {
        self.noteCount = noteCount
        self.scoredNoteCount = scoredNoteCount
        self.goldenCount = goldenCount
        self.pitchRange = pitchRange
        self.duration = duration
        self.hasBackingAudio = hasBackingAudio
    }

    /// e.g. "C3–G4".
    public func rangeText(accidentals: Accidentals) -> String {
        guard let range = pitchRange else { return "–" }
        let low = NoteNaming.name(forMIDINote: range.lowerBound, accidentals: accidentals)
        let high = NoteNaming.name(forMIDINote: range.upperBound, accidentals: accidentals)
        return low == high ? low : "\(low)–\(high)"
    }

    /// e.g. "1:05".
    public var durationText: String {
        guard duration.isFinite, duration >= 0, duration < 360_000 else { return "–" }
        let total = Int(duration.rounded())
        let seconds = total % 60
        return "\(total / 60):\(seconds < 10 ? "0" : "")\(seconds)"
    }
}

/// A file that couldn't be imported, with where and why.
public struct SongImportError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    /// 1-based line number for text formats.
    public var line: Int?
    /// Byte offset for binary formats.
    public var byteOffset: Int?
    public var message: String

    public init(line: Int? = nil, byteOffset: Int? = nil, _ message: String) {
        self.line = line
        self.byteOffset = byteOffset
        self.message = message
    }

    public var description: String {
        if let line { return "Line \(line): \(message)" }
        if let byteOffset { return "Byte \(byteOffset): \(message)" }
        return message
    }

    public var errorDescription: String? { description }
}

public enum SongSearch {
    /// Every whitespace-separated word of `query` must appear in the title or artist
    /// (case- and accent-insensitive). An empty query matches everything.
    public static func matches(_ song: Song, query: String) -> Bool {
        let haystack = song.title + " " + song.artist
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            haystack.range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
