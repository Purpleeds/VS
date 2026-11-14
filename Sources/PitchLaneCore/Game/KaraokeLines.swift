import Foundation

/// One lyric line for the karaoke strip under the lane: its words (one piece per sung note, with the spacing that
/// goes before it) and when each is sung.
public struct KaraokeLine: Sendable, Equatable {
    public struct Piece: Sendable, Equatable {
        /// Text to draw, including a leading space when a new word starts here (never at the start of the line).
        public var text: String
        public var noteIndex: Int
        public var start: Double
        /// End of the note, or of the last held ("~") / wordless note that follows it.
        public var end: Double
    }

    public var start: Double
    public var end: Double
    public var pieces: [Piece]

    public var text: String { pieces.map(\.text).joined() }
}

public enum KaraokeLines {
    /// Lines of `song`, using `display` (one text per note, e.g. romaji) for what is shown and the notes' own
    /// lyrics for word spacing: the song's spaces when it has any (UltraStar syllables, fitted words), none for
    /// Japanese, otherwise a space between notes. Held ("~") and wordless notes extend the piece before them.
    /// Lines split at the song's line breaks (or at long pauses when it has none).
    public static func build(song: Song, display: [String]) -> [KaraokeLine] {
        let notes = song.notes
        guard !notes.isEmpty else { return [] }
        let texts = display.count == notes.count ? display : notes.map(\.displayLyric)
        let raw = notes.map(\.lyric)
        let spaced = raw.contains { $0.hasPrefix(" ") || $0.hasSuffix(" ") }
        let japanese = LyricScript.detect(raw) == .japanese
        let breaks = song.lineBreaks.isEmpty ? MelodyTranscriber.lineBreaks(for: notes) : song.lineBreaks
        var lines: [KaraokeLine] = []
        var pieces: [KaraokeLine.Piece] = []
        var nextBreak = 0
        var previousRaw = ""
        func close() {
            if let first = pieces.first, let last = pieces.last {
                lines.append(KaraokeLine(start: first.start, end: last.end, pieces: pieces))
            }
            pieces = []
        }
        for (index, note) in notes.enumerated() {
            var crossed = false
            while nextBreak < breaks.count, breaks[nextBreak] <= note.start + 1e-6 {
                nextBreak += 1
                crossed = true
            }
            if crossed { close() }
            let shown = texts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if shown.isEmpty || shown == "~" {
                if !pieces.isEmpty { pieces[pieces.count - 1].end = max(pieces[pieces.count - 1].end, note.end) }
                continue
            }
            var text = shown
            if !pieces.isEmpty {
                let space: Bool
                if japanese {
                    space = false
                } else if spaced {
                    space = raw[index].hasPrefix(" ") || previousRaw.hasSuffix(" ")
                } else {
                    space = true
                }
                if space { text = " " + text }
            }
            pieces.append(KaraokeLine.Piece(text: text, noteIndex: index, start: note.start, end: note.end))
            previousRaw = raw[index]
        }
        close()
        return lines
    }

    /// The line to show at `time`: the first one that hasn't finished (it stays up `hold` seconds after its last
    /// word, unless the next line starts within `switchAhead` seconds), as long as it starts within `preview`
    /// seconds. Nil in long gaps and after the last line.
    public static func current(
        _ lines: [KaraokeLine], at time: Double, hold: Double = 0.4, switchAhead: Double = 0.5, preview: Double = 3
    ) -> Int? {
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].end + hold <= time { lo = mid + 1 } else { hi = mid }
        }
        if lo + 1 < lines.count, time >= lines[lo].end, lines[lo + 1].start - time <= switchAhead { lo += 1 }
        guard lo < lines.count, lines[lo].start - time <= preview else { return nil }
        return lo
    }

    /// How much of `piece` has been sung at `time` (0...1).
    public static func progress(of piece: KaraokeLine.Piece, at time: Double) -> Double {
        guard piece.end > piece.start else { return time >= piece.start ? 1 : 0 }
        return min(1, max(0, (time - piece.start) / (piece.end - piece.start)))
    }
}
