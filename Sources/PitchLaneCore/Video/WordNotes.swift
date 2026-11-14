import Foundation

/// Writes a song's notes from its sung words and the singer's pitch (`PitchTrack`, from the separated voice): every
/// word gets a bar under it, at the pitch the singer actually sang, so the lane always has something to sing where
/// there are lyrics and never follows the backing.
///
/// A word sung on one pitch is one note carrying the word. When the singer moves between pitches inside a word
/// (a melisma), the word splits into several notes: the first carries the word, the rest are "~" holds that glide in.
/// A word with no clear pitch takes the nearest sung pitch (within half a second), else the word before's, else the
/// word after's, else the singer's usual pitch, so no word is ever left without a bar.
public enum WordNotes {
    public typealias HeardWord = LyricListenMatcher.HeardWord

    public struct Configuration: Sendable, Equatable {
        /// Shortest note (seconds); words heard shorter are stretched into the gap after them.
        public var minimumNote = 0.12
        /// Pitch moves of at least this many semitones...
        public var splitSemitones = 1.0
        /// ...held for this many frames start a new note inside a word.
        public var splitFrames = 4
        /// Notes inside a word shorter than this merge into a neighbour.
        public var minimumPart = 0.08
        public var maximumPartsPerWord = 6
        /// How far to look for a pitch when a word has none of its own.
        public var searchRadius = 0.5
        /// Glide into a "~" note.
        public var glide = 0.08
        /// A pause this long (or this many words) starts a new lyric line.
        public var lineGap = 0.8
        public var lineWords = 10

        public init() {}
    }

    public struct Result: Sendable, Equatable {
        public var notes: [SongNote]
        public var lineBreaks: [Double]
        /// Words that had no pitch of their own (they borrowed one).
        public var borrowedPitch: Int
    }

    public static func build(words input: [HeardWord], track: PitchTrack, configuration: Configuration = Configuration()) -> Result {
        let words = input
            .filter { $0.time.isFinite && $0.duration.isFinite && $0.time >= 0 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.time < $1.time }
        guard !words.isEmpty else { return Result(notes: [], lineBreaks: [], borrowedPitch: 0) }

        // Each word's span, kept clear of the next word.
        var spans: [(start: Double, end: Double)] = []
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1].time : Double.infinity
            let start = word.time
            var end = min(start + max(0.05, word.duration), next - 0.02)
            if end - start < configuration.minimumNote { end = min(start + configuration.minimumNote, next - 0.01) }
            if end <= start { end = start + 0.05 }
            spans.append((start, end))
        }

        // Pitch parts per word (nil = no pitch of its own).
        var parts: [[(start: Double, end: Double, midi: Double)]?] = []
        for span in spans {
            parts.append(Self.parts(track.voiced(from: span.start, to: span.end), span: span, configuration: configuration))
        }
        // Borrow a pitch for words without one: nearby sung pitch, then the words around them.
        var borrowed = 0
        var pitches: [Double?] = parts.map { $0?.first?.midi }
        for index in words.indices where parts[index] == nil {
            borrowed += 1
            let middle = (spans[index].start + spans[index].end) / 2
            pitches[index] = track.nearestVoiced(to: middle, within: configuration.searchRadius)
        }
        var last: Double?
        for index in words.indices {
            if pitches[index] == nil { pitches[index] = last } else { last = pitches[index] }
        }
        last = nil
        for index in words.indices.reversed() {
            if pitches[index] == nil { pitches[index] = last } else { last = pitches[index] }
        }
        let fallback = track.voicedMedian ?? 60

        var notes: [SongNote] = []
        for (index, word) in words.enumerated() {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = parts[index] ?? [(spans[index].start, spans[index].end, pitches[index] ?? fallback)]
            for (number, piece) in pieces.enumerated() {
                let pitch = Int(min(108, max(24, piece.midi.rounded())))
                let duration = max(0.05, piece.end - piece.start)
                if number == 0 {
                    notes.append(SongNote(start: piece.start, duration: duration, pitch: pitch, lyric: text + " "))
                } else {
                    notes.append(SongNote(start: piece.start, duration: duration, pitch: pitch, lyric: "~",
                                          slidesFromPrevious: true, slideDuration: min(configuration.glide, duration / 2)))
                }
            }
        }

        // Lyric lines at pauses (or every few words).
        var breaks: [Double] = []
        var wordsInLine = 0
        for index in words.indices {
            if index > 0, spans[index].start - spans[index - 1].end >= configuration.lineGap || wordsInLine >= configuration.lineWords {
                breaks.append(spans[index].start)
                wordsInLine = 0
            }
            wordsInLine += 1
        }
        return Result(notes: notes, lineBreaks: breaks, borrowedPitch: borrowed)
    }

    /// Splits a word's voiced frames into steady-pitch parts covering the whole span. Nil with under three frames.
    static func parts(
        _ frames: [(time: Double, midi: Double)], span: (start: Double, end: Double), configuration: Configuration
    ) -> [(start: Double, end: Double, midi: Double)]? {
        guard frames.count >= 3 else { return nil }
        // Light smoothing (median of 5) so a wobble doesn't split a note.
        let values = frames.indices.map { index -> Double in
            let window = frames[max(0, index - 2)...min(frames.count - 1, index + 2)].map(\.midi).sorted()
            return window[window.count / 2]
        }
        var cuts: [Int] = [0]
        var deviating = 0
        for index in 1..<values.count {
            let segment = values[cuts[cuts.count - 1]..<index].sorted()
            let reference = segment[segment.count / 2]
            deviating = abs(values[index] - reference) >= configuration.splitSemitones ? deviating + 1 : 0
            if deviating >= configuration.splitFrames {
                let cut = index - configuration.splitFrames + 1
                if cut > cuts[cuts.count - 1] { cuts.append(cut) }
                deviating = 0
            }
        }
        var ranges: [Range<Int>] = []
        for (number, cut) in cuts.enumerated() {
            ranges.append(cut..<(number + 1 < cuts.count ? cuts[number + 1] : values.count))
        }
        func boundary(_ range: Range<Int>, first: Bool) -> Double {
            first ? (range.lowerBound == 0 ? span.start : frames[range.lowerBound].time) : (range.upperBound >= values.count ? span.end : frames[range.upperBound].time)
        }
        // Merge parts that are too short (or too many) into their neighbour.
        func duration(_ range: Range<Int>) -> Double { boundary(range, first: false) - boundary(range, first: true) }
        while ranges.count > 1 {
            guard let shortest = ranges.indices.min(by: { duration(ranges[$0]) < duration(ranges[$1]) }) else { break }
            if duration(ranges[shortest]) >= configuration.minimumPart, ranges.count <= configuration.maximumPartsPerWord { break }
            let neighbour = shortest == 0 ? 1 : (shortest == ranges.count - 1 ? shortest - 1
                : (duration(ranges[shortest - 1]) <= duration(ranges[shortest + 1]) ? shortest - 1 : shortest + 1))
            let merged = min(ranges[shortest].lowerBound, ranges[neighbour].lowerBound)..<max(ranges[shortest].upperBound, ranges[neighbour].upperBound)
            ranges[min(shortest, neighbour)] = merged
            ranges.remove(at: max(shortest, neighbour))
        }
        return ranges.map { range in
            let sorted = values[range].sorted()
            return (boundary(range, first: true), boundary(range, first: false), sorted[sorted.count / 2])
        }
    }
}
