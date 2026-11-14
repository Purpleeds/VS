import Foundation

/// Puts lyrics onto a song's existing notes (e.g. notes transcribed from a video).
///
/// Synced lyrics: each line's words go onto the notes that start during that line (word times from enhanced LRC
/// win when present). An automatic offset lines up lyric lines with note onsets, for videos whose intro differs
/// from the recording the lyrics were timed to. Plain lyrics: lines are spread over the song's phrases.
public enum LyricAligner {
    public struct Result: Sendable, Equatable {
        public var song: Song
        public var wordsPlaced: Int
        public var wordsTotal: Int
        public var notesWithWords: Int
        /// Seconds added to the lyric times.
        public var offset: Double
    }

    /// Notes a line may claim start at most this much before the line's time.
    static let lead = 0.2

    public static func apply(lines: [LyricLine], to song: Song, autoOffset: Bool = true) -> Result {
        let textLines = lines.filter { !$0.words.isEmpty }
        var notes = song.notes.map { note -> SongNote in
            var copy = note
            copy.lyric = ""
            return copy
        }
        let starts = notes.map(\.start)
        let offset = autoOffset ? bestOffset(lineStarts: textLines.map(\.time), noteStarts: starts) : 0
        var placed = 0
        var breaks: [Double] = []
        let total = textLines.reduce(0) { $0 + $1.words.count }
        // Line windows run until the next line (blank lines included: they end the previous line).
        for (i, line) in lines.enumerated() where !line.words.isEmpty {
            let from = line.time + offset - lead
            let to = i + 1 < lines.count ? lines[i + 1].time + offset - lead : .infinity
            let indices = notes.indices.filter { notes[$0].start >= from && notes[$0].start < to && !notes[$0].isFreestyle }
            guard !indices.isEmpty else { continue }
            if !breaks.isEmpty || placed > 0 { breaks.append(notes[indices[0]].start) }
            placed += place(line.words, timeOffset: offset, onto: indices, of: &notes)
        }
        var updated = song
        updated.notes = notes
        updated.lineBreaks = breaks
        return Result(song: updated, wordsPlaced: placed, wordsTotal: total,
                      notesWithWords: notes.filter { !$0.lyric.isEmpty }.count, offset: offset)
    }

    /// Plain (untimed) lyrics: one line per phrase of notes, in order.
    public static func applyPlain(_ text: String, to song: Song) -> Result {
        applyPlain(lines: LyricListenMatcher.lines(from: text), to: song)
    }

    /// Plain lyrics already split into lines of words (or of morae, for Japanese).
    public static func applyPlain(lines wordLines: [[String]], to song: Song) -> Result {
        let lines = wordLines.filter { !$0.isEmpty }
        var notes = song.notes.map { note -> SongNote in
            var copy = note
            copy.lyric = ""
            return copy
        }
        let phrases = phrases(of: notes, lineBreaks: song.lineBreaks)
        let total = lines.reduce(0) { $0 + $1.count }
        var placed = 0
        var breaks: [Double] = []
        if !phrases.isEmpty, !lines.isEmpty {
            for (j, phrase) in phrases.enumerated() {
                // Spread lines over phrases: phrase j gets lines [j*L/P, (j+1)*L/P).
                let lo = j * lines.count / phrases.count
                let hi = (j + 1) * lines.count / phrases.count
                guard lo < hi else { continue }
                let lineWords = lines[lo..<hi].flatMap { $0 }.map { LyricLine.Word(time: nil, text: $0) }
                if j > 0, let first = phrase.first { breaks.append(notes[first].start) }
                placed += place(lineWords, timeOffset: 0, onto: phrase, of: &notes)
            }
        }
        var updated = song
        updated.notes = notes
        updated.lineBreaks = breaks
        return Result(song: updated, wordsPlaced: placed, wordsTotal: total,
                      notesWithWords: notes.filter { !$0.lyric.isEmpty }.count, offset: 0)
    }

    /// Shift (seconds, -12...12) that puts the most lyric line starts just at a note onset. 0 unless clearly better.
    public static func bestOffset(lineStarts: [Double], noteStarts: [Double]) -> Double {
        let lines = lineStarts.filter(\.isFinite)
        let onsets = noteStarts.filter(\.isFinite).sorted()
        guard lines.count >= 3, !onsets.isEmpty else { return 0 }
        /// Lines that land on an onset, and how far off they land in total (ties prefer the tighter fit).
        func score(_ offset: Double) -> (hits: Int, error: Double) {
            var hits = 0
            var error = 0.0
            for start in lines {
                let t = start + offset
                let i = lowerBound(onsets, t - 0.12)
                if i < onsets.count, onsets[i] <= t + 0.3 {
                    hits += 1
                    error += abs(onsets[i] - t)
                }
            }
            return (hits, error)
        }
        let base = score(0).hits
        var best = 0.0
        var bestScore = score(0)
        for step in -240...240 {
            let offset = Double(step) * 0.05
            let s = score(offset)
            let better = s.hits > bestScore.hits
                || (s.hits == bestScore.hits && s.error < bestScore.error - 1e-6)
                || (s.hits == bestScore.hits && abs(s.error - bestScore.error) <= 1e-6 && abs(offset) < abs(best))
            if better {
                bestScore = s
                best = offset
            }
        }
        let needed = max(2, Int((0.15 * Double(lines.count)).rounded(.up)))
        return bestScore.hits >= base + needed ? best : 0
    }

    // MARK: Helpers

    /// Words onto notes (indices in time order). Returns how many words were placed.
    private static func place(_ words: [LyricLine.Word], timeOffset: Double, onto indices: [Int], of notes: inout [SongNote]) -> Int {
        guard !words.isEmpty, !indices.isEmpty else { return 0 }
        if words.contains(where: { $0.time != nil }) {
            // Enhanced LRC: each word to the note starting nearest its time.
            for (k, word) in words.enumerated() {
                let target: Int
                if let time = word.time.map({ $0 + timeOffset }) {
                    target = indices.min { abs(notes[$0].start - time) < abs(notes[$1].start - time) } ?? indices[0]
                } else {
                    target = indices[min(indices.count - 1, k * indices.count / words.count)]
                }
                append(word.text, to: &notes[target])
            }
            return words.count
        }
        let n = indices.count
        let w = words.count
        if n >= w {
            for k in 0..<w { append(words[k].text, to: &notes[indices[k * n / w]]) }
        } else {
            for j in 0..<n {
                for k in (j * w / n)..<((j + 1) * w / n) { append(words[k].text, to: &notes[indices[j]]) }
            }
        }
        return w
    }

    /// Lyric text keeps a trailing space as the word boundary (UltraStar style; `displayLyric` trims it).
    private static func append(_ word: String, to note: inout SongNote) {
        let clean = String(word.prefix(40))
        let current = note.lyric.trimmingCharacters(in: .whitespaces)
        if current.isEmpty {
            note.lyric = clean + " "
        } else if Kana.containsJapanese(clean), let last = current.unicodeScalars.last, Kana.isKana(last) || Kana.isKanji(last) {
            // Japanese morae on one note join without spaces (こ + こ → ここ).
            note.lyric = current + clean + " "
        } else {
            note.lyric = current + " " + clean + " "
        }
    }

    /// Groups of note indices: split at the song's line breaks, or at gaps of half a second.
    static func phrases(of notes: [SongNote], lineBreaks: [Double]) -> [[Int]] {
        var phrases: [[Int]] = []
        var breaks = lineBreaks.sorted()[...]
        for (i, note) in notes.enumerated() where !note.isFreestyle {
            var split = phrases.isEmpty
            if let last = phrases.last?.last, note.start - notes[last].end >= 0.5 { split = true }
            while let next = breaks.first, next <= note.start + 1e-6 {
                breaks = breaks.dropFirst()
                split = true
            }
            if split { phrases.append([i]) } else { phrases[phrases.count - 1].append(i) }
        }
        return phrases
    }

    private static func lowerBound(_ values: [Double], _ x: Double) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
