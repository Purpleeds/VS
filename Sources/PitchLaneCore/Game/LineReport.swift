import Foundation

/// How well each line of a song was sung in one run, and the weakest line worth practising.
public struct LineReport: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        /// Song seconds from the line's first note start to its last note end.
        public var start: Double
        public var end: Double
        /// The line's words ("" when the song has none).
        public var text: String
        /// 0...1, weighted by note length, over the notes that were scored.
        public var accuracy: Double
        public var scoredNotes: Int
    }

    /// Lines with at least one scored note, in song order.
    public var lines: [Line]

    /// Accuracy below this marks a line worth practising.
    public static let practiceBelow = 0.85
    /// Lines with fewer scored notes don't count (one missed note isn't a weak line).
    public static let minimumNotes = 3

    /// `results` index into `song.notes` (a full run, not a loop section).
    public init(song: Song, results: [NoteResult]) {
        let notes = song.notes
        guard !notes.isEmpty else {
            lines = []
            return
        }
        let breaks = song.lineBreaks.isEmpty ? MelodyTranscriber.lineBreaks(for: notes) : song.lineBreaks
        // Line number of each note: how many breaks are at or before its start.
        var lineOf = [Int](repeating: 0, count: notes.count)
        var b = 0
        let order = notes.indices.sorted { notes[$0].start < notes[$1].start }
        for index in order {
            while b < breaks.count, breaks[b] <= notes[index].start + 1e-6 { b += 1 }
            lineOf[index] = b
        }
        var fraction: [Int: (weighted: Double, weight: Double, count: Int)] = [:]
        for result in results where result.noteIndex >= 0 && result.noteIndex < notes.count {
            let note = notes[result.noteIndex]
            let weight = max(0.05, note.duration)
            var entry = fraction[lineOf[result.noteIndex]] ?? (0, 0, 0)
            entry.weighted += min(1, max(0, result.fraction)) * weight
            entry.weight += weight
            entry.count += 1
            fraction[lineOf[result.noteIndex]] = entry
        }
        var membersByLine: [Int: [SongNote]] = [:]
        for index in order { membersByLine[lineOf[index], default: []].append(notes[index]) }
        var built: [Line] = []
        for line in fraction.keys.sorted() {
            guard let entry = fraction[line], entry.weight > 0, let members = membersByLine[line], let first = members.first else { continue }
            let end = members.map(\.end).max() ?? first.end
            built.append(Line(start: first.start, end: end, text: Self.text(of: members), accuracy: entry.weighted / entry.weight, scoredNotes: entry.count))
        }
        lines = built
    }

    /// The weakest line with enough notes and accuracy under `practiceBelow`; nil if every line went well.
    public var toughest: Line? {
        lines.filter { $0.scoredNotes >= Self.minimumNotes && $0.accuracy < Self.practiceBelow }.min { $0.accuracy < $1.accuracy }
    }

    /// A practice run that loops `line` (a second and a half of run-up, half a second after) at 80 % speed,
    /// with no failing.
    public static func practice(for line: Line) -> PracticeOptions {
        let start = max(0, line.start - 1.5)
        let end = max(line.end + 0.5, start + PracticeOptions.minimumLoopLength)
        return PracticeOptions(speed: 0.8, loopStart: start, loopEnd: end, noFail: true)
    }

    /// Words of the notes, with the song's own word spacing when it has any (UltraStar-style syllables), else
    /// one word per note. Long lines are shortened.
    static func text(of notes: [SongNote]) -> String {
        let lyrics = notes.map(\.lyric).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != "~" }
        guard !lyrics.isEmpty else { return "" }
        let spaced = lyrics.contains { $0.hasPrefix(" ") || $0.hasSuffix(" ") }
        let joined = spaced ? lyrics.joined() : lyrics.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        let words = joined.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > 60 ? String(words.prefix(57)) + "…" : words
    }
}
