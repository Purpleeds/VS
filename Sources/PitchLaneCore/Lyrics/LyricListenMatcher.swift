import Foundation

/// Times lyrics by matching them against words heard in the recording (speech recognition on the song).
///
/// The heard words and the lyric words are aligned in order (dynamic programming, exact matches worth 2, near
/// misses worth 1, so the most consistent monotonic pairing wins). Matched lyric words take the heard time;
/// the rest are interpolated between their neighbours. Singing is hard for speech recognition, so even a third
/// of the words matched is plenty to pin every line down.
public enum LyricListenMatcher {
    public struct HeardWord: Sendable, Equatable {
        public var text: String
        public var time: Double
        public var duration: Double

        public init(text: String, time: Double, duration: Double = 0.3) {
            self.text = text
            self.time = time
            self.duration = duration
        }
    }

    public struct Result: Sendable, Equatable {
        /// Lyric lines with every word timed (line time = its first word).
        public var lines: [LyricLine]
        public var matchedWords: Int
        public var totalWords: Int

        public var matchedFraction: Double { totalWords > 0 ? Double(matchedWords) / Double(totalWords) : 0 }
    }

    static let maximumWords = 1_500
    /// Assumed spacing of words outside the matched stretch.
    static let wordSpacing = 0.35

    /// Splits lyric text into lines of words (blank lines and `[Section]` tags dropped).
    public static func lines(from text: String) -> [[String]] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !($0.hasPrefix("[") && $0.hasSuffix("]")) }
            .map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .filter { !$0.isEmpty }
    }

    public static func match(lyrics: [[String]], heard: [HeardWord]) -> Result {
        var words: [(line: Int, text: String, key: String)] = []
        for (lineIndex, line) in lyrics.enumerated() {
            for word in line where words.count < maximumWords {
                words.append((lineIndex, word, key(word)))
            }
        }
        let spoken = heard.filter { $0.time.isFinite && !key($0.text).isEmpty }.prefix(maximumWords).sorted { $0.time < $1.time }
        let spokenKeys = spoken.map { key($0.text) }
        let rows = words.count, cols = spokenKeys.count
        var times = [Double?](repeating: nil, count: rows)
        var matched = 0

        if rows > 0, cols > 0 {
            // score[(i)*(cols+1)+j] = best score aligning the first i lyric words with the first j heard words.
            let width = cols + 1
            var score = [Int32](repeating: 0, count: (rows + 1) * width)
            for i in 1...rows {
                for j in 1...cols {
                    let s = similarity(words[i - 1].key, spokenKeys[j - 1])
                    var best = max(score[(i - 1) * width + j], score[i * width + j - 1])
                    if s > 0 { best = max(best, score[(i - 1) * width + j - 1] + Int32(s)) }
                    score[i * width + j] = best
                }
            }
            var i = rows, j = cols
            while i > 0, j > 0 {
                let s = similarity(words[i - 1].key, spokenKeys[j - 1])
                if s > 0, score[i * width + j] == score[(i - 1) * width + j - 1] + Int32(s) {
                    times[i - 1] = spoken[j - 1].time
                    matched += 1
                    i -= 1
                    j -= 1
                } else if score[(i - 1) * width + j] >= score[i * width + j - 1] {
                    i -= 1
                } else {
                    j -= 1
                }
            }
        }

        let filled = interpolate(times)
        var result: [LyricLine] = []
        var currentLine = -1
        for (index, word) in words.enumerated() {
            guard let time = filled[index] else { continue }
            let entry = LyricLine.Word(time: time, text: word.text)
            if word.line == currentLine, !result.isEmpty {
                result[result.count - 1].words.append(entry)
                result[result.count - 1].text += " " + word.text
            } else {
                result.append(LyricLine(time: time, text: word.text, words: [entry]))
                currentLine = word.line
            }
        }
        return Result(lines: result, matchedWords: matched, totalWords: words.count)
    }

    /// Fills gaps between known times linearly, extrapolates the ends, and keeps the times non-decreasing.
    static func interpolate(_ times: [Double?]) -> [Double?] {
        let anchors = times.enumerated().compactMap { index, time in time.map { (index, $0) } }
        guard let first = anchors.first, let last = anchors.last else { return times }
        var out = times
        for index in 0..<times.count {
            if out[index] != nil { continue }
            if index < first.0 {
                out[index] = max(0, first.1 - Double(first.0 - index) * wordSpacing)
            } else if index > last.0 {
                out[index] = last.1 + Double(index - last.0) * wordSpacing
            } else if let before = anchors.last(where: { $0.0 < index }), let after = anchors.first(where: { $0.0 > index }) {
                let fraction = Double(index - before.0) / Double(after.0 - before.0)
                out[index] = before.1 + (after.1 - before.1) * fraction
            }
        }
        var floor = -Double.infinity
        for index in out.indices {
            if let t = out[index] {
                floor = max(floor, t)
                out[index] = floor
            }
        }
        return out
    }

    static func key(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// 2 = same word, 1 = near miss (one edit, or a shared 4-letter start), 0 = different.
    static func similarity(_ a: String, _ b: String) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 2 }
        if VoiceQuery.similar(a, b) { return 1 }
        if a.count >= 5, b.count >= 5, a.prefix(4) == b.prefix(4) { return 1 }
        return 0
    }
}
