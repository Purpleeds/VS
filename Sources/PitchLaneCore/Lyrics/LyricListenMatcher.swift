import Foundation

/// Times lyrics by matching them against words heard in the recording (speech recognition on the song).
///
/// The heard words and the lyric words are aligned in order (dynamic programming, so the most consistent monotonic
/// pairing wins). Distinctive words count most (an exact "tomorrow" or "night" is worth 3, "sky" 2, "the" or "you"
/// 1); near misses and sound-alikes ("tomorow", "knight" for "night", "rite" for "right") count 1-2, so the
/// alignment hangs on the words that are hard to match by accident. Matched lyric words take the heard time;
/// the rest are interpolated between their neighbours. Singing is hard for speech recognition, so even a third
/// of the words matched is plenty to pin every line down.
public enum LyricListenMatcher {
    public struct HeardWord: Sendable, Equatable, Codable {
        public var text: String
        public var time: Double
        public var duration: Double
        /// The recogniser's confidence in the word (0...1), when it gave one.
        public var confidence: Double?
        /// Other things the recogniser (or another listening pass) thought it might be, best first.
        public var alternatives: [String]?

        public init(text: String, time: Double, duration: Double = 0.3, confidence: Double? = nil, alternatives: [String]? = nil) {
            self.text = text
            self.time = time
            self.duration = duration
            self.confidence = confidence.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            self.alternatives = Self.cleanAlternatives(alternatives, besides: text)
        }

        public static let maxAlternatives = 6

        /// Non-empty, different from the word itself, unique, at most `maxAlternatives`; nil when none are left.
        static func cleanAlternatives(_ alternatives: [String]?, besides text: String) -> [String]? {
            guard let alternatives else { return nil }
            var seen: Set<String> = [LyricListenMatcher.key(text)]
            let kept = alternatives
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count <= 60 && seen.insert(LyricListenMatcher.key($0)).inserted }
            return kept.isEmpty ? nil : Array(kept.prefix(maxAlternatives))
        }
    }

    public struct Result: Sendable, Equatable {
        /// Lyric lines with every word timed (line time = its first word).
        public var lines: [LyricLine]
        public var matchedWords: Int
        public var totalWords: Int
        /// Matched words that were heard differently from the lyrics (heard text, lyric text), e.g. ("tomorow",
        /// "tomorrow"): what the word predictor learns the recogniser's habits from.
        public var misheard: [Misheard] = []

        public var matchedFraction: Double { totalWords > 0 ? Double(matchedWords) / Double(totalWords) : 0 }
    }

    public struct Misheard: Sendable, Equatable {
        public var heard: String
        public var lyric: String

        public init(heard: String, lyric: String) {
            self.heard = heard
            self.lyric = lyric
        }
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
        // Sound keys once per word (the table below compares every pair).
        let lyricSounds = words.map { phonetic($0.key) }
        let spokenSounds = spokenKeys.map { phonetic($0) }
        let rows = words.count, cols = spokenKeys.count
        var times = [Double?](repeating: nil, count: rows)
        var matched = 0
        var misheard: [Misheard] = []

        if rows > 0, cols > 0 {
            // score[(i)*(cols+1)+j] = best score aligning the first i lyric words with the first j heard words.
            let width = cols + 1
            var score = [Int32](repeating: 0, count: (rows + 1) * width)
            for i in 1...rows {
                for j in 1...cols {
                    let s = similarity(words[i - 1].key, spokenKeys[j - 1], lyricSounds[i - 1], spokenSounds[j - 1])
                    var best = max(score[(i - 1) * width + j], score[i * width + j - 1])
                    if s > 0 { best = max(best, score[(i - 1) * width + j - 1] + Int32(s)) }
                    score[i * width + j] = best
                }
            }
            var i = rows, j = cols
            while i > 0, j > 0 {
                let s = similarity(words[i - 1].key, spokenKeys[j - 1], lyricSounds[i - 1], spokenSounds[j - 1])
                if s > 0, score[i * width + j] == score[(i - 1) * width + j - 1] + Int32(s) {
                    times[i - 1] = spoken[j - 1].time
                    matched += 1
                    if words[i - 1].key != spokenKeys[j - 1] {
                        misheard.append(Misheard(heard: spoken[j - 1].text, lyric: words[i - 1].text))
                    }
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
        return Result(lines: result, matchedWords: matched, totalWords: words.count, misheard: Array(misheard.reversed()))
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

    /// Score of pairing lyric word `a` with heard word `b` (both `key`s): 0 = different.
    /// Exact: 3 for distinctive words (4+ letters, not a filler), 2 for other words, 1 for fillers ("the", "oh").
    /// Sounds alike (same consonant skeleton): 2 for 3+ sounds ("tomorow"), 1 for two ("knight"/"night").
    /// Near miss (one edit, or a shared 4-letter start): 1.
    static func similarity(_ a: String, _ b: String) -> Int {
        similarity(a, b, phonetic(a), phonetic(b))
    }

    /// Same, with the words' `phonetic` keys already worked out.
    static func similarity(_ a: String, _ b: String, _ soundA: String?, _ soundB: String?) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b {
            if fillers.contains(a) { return 1 }
            return a.count >= 4 && a.unicodeScalars.allSatisfy(\.isASCII) ? 3 : 2
        }
        if a.count >= 3, b.count >= 3, let pa = soundA, let pb = soundB, pa == pb {
            if pa.count >= 3 { return 2 }
            if pa.count == 2, a.count >= 4, b.count >= 4 { return 1 }
        }
        if VoiceQuery.similar(a, b) { return 1 }
        if a.count >= 5, b.count >= 5, a.prefix(4) == b.prefix(4) { return 1 }
        return 0
    }

    /// Short words that turn up everywhere; matching one proves little.
    static let fillers: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "is", "it", "i", "im", "me", "my", "be", "so",
        "oh", "ooh", "ah", "uh", "um", "mm", "yeah", "na", "la", "hey", "do", "no", "we", "you", "your", "for",
    ]

    /// A rough English sound key: silent letters and spellings of the same sound folded together, vowels dropped
    /// after the first letter, doubles collapsed ("knight" and "night" → "nt"; "write", "right" → "rt";
    /// "phone" → "fn"). Nil for words that aren't plain ASCII letters (other scripts match exactly or by edit).
    static func phonetic(_ key: String) -> String? {
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.lowercaseLetters.contains($0) }) else { return nil }
        var w = key
        for (prefix, replacement) in [("kn", "n"), ("wr", "r"), ("wh", "w"), ("gn", "n"), ("ps", "s")] where w.hasPrefix(prefix) {
            w = replacement + w.dropFirst(prefix.count)
        }
        for (from, to) in [("tch", "ch"), ("ph", "f"), ("ck", "k"), ("gh", ""), ("sch", "sk"), ("qu", "kw"), ("x", "ks"), ("z", "s")] {
            w = w.replacingOccurrences(of: from, with: to)
        }
        let letters = Array(w)
        var out: [Character] = []
        for (index, letter) in letters.enumerated() {
            var c = letter
            if c == "c" {
                let next = index + 1 < letters.count ? letters[index + 1] : " "
                c = "eiy".contains(next) ? "s" : "k"
            }
            if c == "q" { c = "k" }
            if c == "y", index > 0 { c = "a" }
            if index > 0, "aeiou".contains(c) { continue }
            if c == "h", index > 0 { continue }
            if let last = out.last, last == c { continue }
            out.append(c)
        }
        return String(out)
    }
}
