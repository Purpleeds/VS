import Foundation

/// Keeps only the notes where words are actually sung, so a song PitchLane wrote from a recording never asks the
/// player to hum along to an instrument solo, an intro riff or leftover backing.
///
/// Notes are grouped into phrases (a pause of `gap` seconds starts a new one). A phrase stays if any heard word
/// overlaps it (within `margin`); phrases with no words are dropped. Inside a kept phrase, notes that run on more
/// than `edge` seconds before its first word or after its last word are trimmed (a hummed lead-in or tail).
/// With no heard words at all nothing is dropped: there is nothing to judge by.
public enum SungNoteFilter {
    public struct Result: Sendable, Equatable {
        public var notes: [SongNote]
        public var keptPhrases: Int
        public var removedPhrases: Int
        public var removedNotes: Int
    }

    public struct Configuration: Sendable, Equatable {
        public var gap = 0.6
        public var margin = 0.35
        public var edge = 1.0

        public init() {}
    }

    /// Index ranges of `notes` (sorted by start) that form phrases.
    public static func phrases(_ notes: [SongNote], gap: Double = Configuration().gap) -> [Range<Int>] {
        guard !notes.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        for index in 1..<max(1, notes.count) where notes[index].start - notes[index - 1].end >= gap {
            ranges.append(start..<index)
            start = index
        }
        ranges.append(start..<notes.count)
        return ranges
    }

    public static func keepSung(
        _ input: [SongNote], words: [LyricListenMatcher.HeardWord], configuration: Configuration = Configuration()
    ) -> Result {
        let notes = input.sorted { $0.start < $1.start }
        let spans = words
            .filter { $0.time.isFinite && $0.duration.isFinite && !LyricListenMatcher.key($0.text).isEmpty }
            .map { (start: $0.time, end: $0.time + max(0, $0.duration)) }
            .sorted { $0.start < $1.start }
        let all = phrases(notes, gap: configuration.gap)
        guard !spans.isEmpty, !notes.isEmpty else {
            return Result(notes: notes, keptPhrases: all.count, removedPhrases: 0, removedNotes: 0)
        }
        var kept: [SongNote] = []
        var keptPhrases = 0
        var cursor = 0
        for range in all {
            let lo = notes[range.lowerBound].start - configuration.margin
            let hi = notes[range].map(\.end).max() ?? lo
            let top = hi + configuration.margin
            // Words are sorted by start; skip those that end before this phrase (their ends need not be sorted,
            // so keep the cursor conservative: only move past words that start more than 30 s earlier).
            while cursor < spans.count, spans[cursor].start < lo - 30 { cursor += 1 }
            var first = Double.infinity, last = -Double.infinity
            var index = cursor
            while index < spans.count, spans[index].start <= top {
                let span = spans[index]
                if span.end >= lo {
                    first = min(first, span.start)
                    last = max(last, span.end)
                }
                index += 1
            }
            guard first.isFinite else { continue }
            keptPhrases += 1
            kept += notes[range].filter { note in
                note.end >= first - configuration.edge && note.start <= last + configuration.edge
            }
        }
        return Result(notes: kept, keptPhrases: keptPhrases, removedPhrases: all.count - keptPhrases, removedNotes: notes.count - kept.count)
    }
}
