import Foundation

/// The words PitchLane heard in a song (on-device speech recognition), with when each starts and how long it lasts.
/// Saved as `transcript.json` in the song's folder so it's reused next time; "Listen Again" replaces it and
/// "Edit Heard Words" fixes lines by hand.
public struct SongTranscript: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    /// A run of words between pauses (one line in the editor, one lyric line on the lane).
    public struct Line: Sendable, Equatable, Identifiable {
        public var id: Int { firstWord }
        public var firstWord: Int
        public var wordCount: Int
        public var start: Double
        public var end: Double
        public var text: String
    }

    public var version: Int
    /// Speech recogniser language, e.g. "en-US", "ja-JP".
    public var language: String
    public var createdAt: Date
    /// What was listened to ("voice" for the separated voice stem, "mix" for the full backing).
    public var source: String
    public var words: [LyricListenMatcher.HeardWord]
    /// True once the user has corrected lines by hand.
    public var edited: Bool
    /// What the recogniser heard before the word predictor tidied it (nil when the predictor didn't run), so the
    /// prediction can be redone later with what it has learned since.
    public var rawWords: [LyricListenMatcher.HeardWord]?
    /// Words the word predictor changed.
    public var predictedChanges: Int

    public init(
        language: String, source: String, words: [LyricListenMatcher.HeardWord], createdAt: Date = Date(), edited: Bool = false,
        rawWords: [LyricListenMatcher.HeardWord]? = nil, predictedChanges: Int = 0
    ) {
        version = Self.currentVersion
        self.language = language
        self.source = source
        self.words = Self.clean(words)
        self.createdAt = createdAt
        self.edited = edited
        self.rawWords = rawWords.map(Self.clean)
        self.predictedChanges = max(0, predictedChanges)
    }

    private enum CodingKeys: String, CodingKey { case version, language, createdAt, source, words, edited, rawWords, predictedChanges }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenient(Int.self, forKey: .version) ?? Self.currentVersion
        language = c.lenient(String.self, forKey: .language) ?? "en-US"
        createdAt = c.lenient(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        source = c.lenient(String.self, forKey: .source) ?? "mix"
        let lossy = (try? c.decodeIfPresent([Lossy<LyricListenMatcher.HeardWord>].self, forKey: .words)) ?? nil
        words = Self.clean((lossy ?? []).compactMap(\.value))
        edited = c.lenient(Bool.self, forKey: .edited) ?? false
        let raw = (try? c.decodeIfPresent([Lossy<LyricListenMatcher.HeardWord>].self, forKey: .rawWords)) ?? nil
        rawWords = raw.map { Self.clean($0.compactMap(\.value)) }
        predictedChanges = max(0, c.lenient(Int.self, forKey: .predictedChanges) ?? 0)
    }

    /// Finite, sensible, sorted, non-empty words; durations at least 50 ms and never past the next word's start.
    static func clean(_ words: [LyricListenMatcher.HeardWord]) -> [LyricListenMatcher.HeardWord] {
        let sorted = words
            .filter { $0.time.isFinite && $0.duration.isFinite && $0.time >= 0 && $0.time <= SongLimits.maximumAbsoluteStart }
            .map {
                LyricListenMatcher.HeardWord(
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), time: $0.time,
                    duration: max(0.05, min(10, $0.duration)), confidence: $0.confidence, alternatives: $0.alternatives
                )
            }
            .filter { !$0.text.isEmpty }
            .sorted { $0.time < $1.time }
        return Array(sorted.prefix(SongLimits.maximumNotes))
    }

    public var isEmpty: Bool { words.isEmpty }

    /// Groups words into lines at pauses of `maxGap` seconds, or every `maxWords` words.
    public func lines(maxGap: Double = 0.8, maxWords: Int = 10) -> [Line] {
        var lines: [Line] = []
        for (index, word) in words.enumerated() {
            if var last = lines.last, word.time - last.end < maxGap, last.wordCount < maxWords {
                last.wordCount += 1
                last.end = max(last.end, word.time + word.duration)
                last.text += " " + word.text
                lines[lines.count - 1] = last
            } else {
                lines.append(Line(firstWord: index, wordCount: 1, start: word.time, end: word.time + word.duration, text: word.text))
            }
        }
        return lines
    }

    /// The same words as timed lyric lines (each word keeps its own start time).
    public func lyricLines(maxGap: Double = 0.8, maxWords: Int = 10) -> [LyricLine] {
        Self.lyricLines(from: words, maxGap: maxGap, maxWords: maxWords)
    }

    /// Timed lyric lines from any heard words (e.g. after splitting Japanese words into morae).
    public static func lyricLines(from words: [LyricListenMatcher.HeardWord], maxGap: Double = 0.8, maxWords: Int = 10) -> [LyricLine] {
        SongTranscript(language: "", source: "", words: words).lines(maxGap: maxGap, maxWords: maxWords).map { line in
            let slice = SongTranscript.clean(words)[line.firstWord..<(line.firstWord + line.wordCount)]
            return LyricLine(time: line.start, text: line.text, words: slice.map { LyricLine.Word(time: $0.time, text: $0.text) })
        }
    }

    /// Replaces one line's words with corrected text: the new words share the line's time span evenly.
    /// Empty text removes the line's words.
    public func replacingLine(_ line: Line, with text: String) -> SongTranscript {
        let range = line.firstWord..<min(words.count, line.firstWord + line.wordCount)
        guard !range.isEmpty else { return self }
        let newWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let span = max(0.05, line.end - line.start)
        let step = newWords.isEmpty ? 0 : span / Double(newWords.count)
        let replacement = newWords.enumerated().map { index, word in
            LyricListenMatcher.HeardWord(text: word, time: line.start + Double(index) * step, duration: max(0.05, step * 0.9))
        }
        var copy = self
        copy.words.replaceSubrange(range, with: replacement)
        copy.words = Self.clean(copy.words)
        copy.edited = true
        return copy
    }
}
