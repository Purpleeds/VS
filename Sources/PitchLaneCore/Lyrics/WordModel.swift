import Foundation

/// What the word predictor (`WordPredictor`) has learned on this phone:
/// - **words to know**: names, slang or unusual words the user typed in;
/// - **which words follow which** (a word and word-pair count model) from lyrics the user added and lines they
///   corrected;
/// - **the recogniser's habits**: what it heard → what it should have been, from corrections and from lyrics matched
///   against what was heard ("beyond say" → "Beyoncé").
/// Saved as `word-model.json` in Application Support and never sent anywhere. Words are stored as
/// `LyricListenMatcher.key`s (lower case, letters and digits), with the user's spelling kept separately.
public struct WordModel: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let maxUnigrams = 20_000
    public static let maxBigrams = 60_000
    public static let maxConfusions = 6_000
    public static let maxCustomWords = 500

    public var version: Int
    /// Words to know, as typed (unique by key, newest first).
    public private(set) var customWords: [String]
    public private(set) var unigrams: [String: Int]
    /// "previous next" (keys joined by a space) → count.
    public private(set) var bigrams: [String: Int]
    /// Heard (1-3 words, keys joined by spaces) → intended (same) → count.
    public private(set) var confusions: [String: [String: Int]]
    /// Key → the spelling to show ("dont" → "don't", "beyonce" → "Beyoncé").
    public private(set) var spellings: [String: String]
    public private(set) var unigramTotal: Int
    public private(set) var lyricsLearned: Int
    public private(set) var correctionsLearned: Int

    public init() {
        version = Self.currentVersion
        customWords = []
        unigrams = [:]
        bigrams = [:]
        confusions = [:]
        spellings = [:]
        unigramTotal = 0
        lyricsLearned = 0
        correctionsLearned = 0
    }

    private enum CodingKeys: String, CodingKey {
        case version, customWords, unigrams, bigrams, confusions, spellings, lyricsLearned, correctionsLearned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        version = c.lenient(Int.self, forKey: .version) ?? Self.currentVersion
        let custom = (try? c.decodeIfPresent([Lossy<String>].self, forKey: .customWords)) ?? nil
        setCustomWords((custom ?? []).compactMap(\.value))
        unigrams = Self.positive(c.lenient([String: Int].self, forKey: .unigrams) ?? [:])
        bigrams = Self.positive(c.lenient([String: Int].self, forKey: .bigrams) ?? [:])
        confusions = (c.lenient([String: [String: Int]].self, forKey: .confusions) ?? [:])
            .mapValues(Self.positive).filter { !$0.key.isEmpty && !$0.value.isEmpty }
        spellings = (c.lenient([String: String].self, forKey: .spellings) ?? [:]).filter { !$0.key.isEmpty && !$0.value.isEmpty && $0.value.count <= 60 }
        lyricsLearned = max(0, c.lenient(Int.self, forKey: .lyricsLearned) ?? 0)
        correctionsLearned = max(0, c.lenient(Int.self, forKey: .correctionsLearned) ?? 0)
        prune()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(customWords, forKey: .customWords)
        try c.encode(unigrams, forKey: .unigrams)
        try c.encode(bigrams, forKey: .bigrams)
        try c.encode(confusions, forKey: .confusions)
        try c.encode(spellings, forKey: .spellings)
        try c.encode(lyricsLearned, forKey: .lyricsLearned)
        try c.encode(correctionsLearned, forKey: .correctionsLearned)
    }

    private static func positive(_ counts: [String: Int]) -> [String: Int] {
        counts.filter { !$0.key.isEmpty && $0.key.count <= 120 && $0.value > 0 }.mapValues { min($0, 1_000_000) }
    }

    /// Nothing learned and no words to know.
    public var isEmpty: Bool { customWords.isEmpty && unigrams.isEmpty && confusions.isEmpty }

    // MARK: Queries

    public func count(_ key: String) -> Int { unigrams[key] ?? 0 }

    public func count(_ previous: String, _ next: String) -> Int { bigrams[previous + " " + next] ?? 0 }

    /// What `heard` (a key, or keys joined by spaces) was corrected to before, with counts.
    public func corrections(of heard: String) -> [String: Int] { confusions[heard] ?? [:] }

    /// The spelling to show for a key: the user's own, else the key.
    public func spelling(of key: String) -> String {
        if let custom = customWords.first(where: { Self.phraseKey($0) == key }) { return custom }
        return spellings[key] ?? key
    }

    /// Keys of a phrase, joined by spaces ("New York" → "new york").
    public static func phraseKey(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).map { LyricListenMatcher.key(String($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Learning

    /// Learns which words follow which from lines of lyrics (each line a list of words). Counts as one lyric text.
    public mutating func learn(lines: [[String]], weight: Int = 1) {
        let added = addNgrams(lines, weight: max(1, weight))
        if added > 0 { lyricsLearned += 1 }
        prune()
    }

    /// Learns that the recogniser heard `heard` where `intended` was sung (each a word or short phrase).
    public mutating func learnCorrections(_ pairs: [(heard: String, intended: String)]) {
        for pair in pairs {
            let heard = Self.phraseKey(pair.heard), intended = Self.phraseKey(pair.intended)
            guard !heard.isEmpty, !intended.isEmpty, heard != intended,
                  heard.split(separator: " ").count <= 3, intended.split(separator: " ").count <= 3 else { continue }
            confusions[heard, default: [:]][intended, default: 0] += 1
            correctionsLearned += 1
            rememberSpellings(pair.intended)
        }
        prune()
    }

    /// Learns from words the user corrected by hand (a line, or a whole transcript before and after): every changed
    /// stretch is a correction, and the corrected words around each change (three either side) count twice towards
    /// which words follow which. Unchanged stretches teach nothing.
    public mutating func learnEdit(heard: [String], corrected: [String]) {
        guard !corrected.isEmpty else { return }
        let alignment = WordAlignment.align(heard, corrected)
        var pairs: [(heard: String, intended: String)] = []
        var windows: [Range<Int>] = []
        for block in alignment.blocks {
            if !block.aRange.isEmpty, !block.bRange.isEmpty, block.aRange.count <= 3, block.bRange.count <= 3 {
                pairs.append((block.aRange.map { heard[$0] }.joined(separator: " "), block.bRange.map { corrected[$0] }.joined(separator: " ")))
            }
            guard !block.bRange.isEmpty else { continue }
            let window = max(0, block.bRange.lowerBound - 3)..<min(corrected.count, block.bRange.upperBound + 3)
            if let last = windows.last, window.lowerBound <= last.upperBound {
                windows[windows.count - 1] = last.lowerBound..<max(last.upperBound, window.upperBound)
            } else {
                windows.append(window)
            }
        }
        learnCorrections(pairs)
        _ = addNgrams(windows.map { Array(corrected[$0]) }, weight: 2)
        prune()
    }

    // MARK: Words to know

    /// Replaces the list (unique by key, at most `maxCustomWords`).
    public mutating func setCustomWords(_ words: [String]) {
        var seen = Set<String>()
        customWords = Array(words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 60 && seen.insert(Self.phraseKey($0)).inserted && !Self.phraseKey($0).isEmpty }
            .prefix(Self.maxCustomWords))
    }

    /// Adds a word or short phrase to know (first in the list). False if it's empty or already there.
    @discardableResult
    public mutating func addCustomWord(_ word: String) -> Bool {
        let key = Self.phraseKey(word)
        guard !key.isEmpty, !customWords.contains(where: { Self.phraseKey($0) == key }) else { return false }
        setCustomWords([word] + customWords)
        return customWords.contains { Self.phraseKey($0) == key }
    }

    public mutating func removeCustomWord(_ word: String) {
        let key = Self.phraseKey(word)
        customWords.removeAll { Self.phraseKey($0) == key }
    }

    /// Forgets everything learned (counts and habits), keeping the words to know.
    public mutating func forgetLearned() {
        let custom = customWords
        self = WordModel()
        customWords = custom
    }

    // MARK: Internals

    /// Adds word and word-pair counts; returns how many words were counted.
    private mutating func addNgrams(_ lines: [[String]], weight: Int) -> Int {
        var added = 0
        for line in lines {
            let words = line.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            let keys = words.map(LyricListenMatcher.key)
            var previous: String?
            for (word, key) in zip(words, keys) where !key.isEmpty {
                unigrams[key, default: 0] += weight
                unigramTotal += weight
                added += 1
                rememberSpelling(word, key: key, lineStart: previous == nil)
                if let previous { bigrams[previous + " " + key, default: 0] += weight }
                previous = key
            }
        }
        return added
    }

    private mutating func rememberSpellings(_ phrase: String) {
        for word in phrase.split(whereSeparator: \.isWhitespace).map(String.init) {
            rememberSpelling(word, key: LyricListenMatcher.key(word), lineStart: false)
        }
    }

    /// Keeps a spelling that says more than the key (capitals, apostrophes, accents), trimmed of edge punctuation.
    /// A capital at the start of a line says nothing (every line starts with one), so it is dropped there.
    private mutating func rememberSpelling(_ word: String, key: String, lineStart: Bool) {
        guard !key.isEmpty else { return }
        var trimmed = word.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’")).union(.whitespaces))
        if lineStart, let first = trimmed.first, first.isUppercase, trimmed.dropFirst().allSatisfy({ !$0.isUppercase }) {
            if spellings[key] != nil { return } // a mid-line spelling seen before wins
            trimmed = first.lowercased() + trimmed.dropFirst()
        }
        guard !trimmed.isEmpty, trimmed.count <= 60, trimmed != key else { return }
        spellings[key] = trimmed
    }

    /// Keeps the model inside its size limits (the most frequent entries survive).
    mutating func prune() {
        if unigrams.count > Self.maxUnigrams {
            unigrams = Dictionary(uniqueKeysWithValues: unigrams.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(Self.maxUnigrams).map { ($0.key, $0.value) })
        }
        unigramTotal = unigrams.values.reduce(0, +)
        if bigrams.count > Self.maxBigrams {
            bigrams = Dictionary(uniqueKeysWithValues: bigrams.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(Self.maxBigrams).map { ($0.key, $0.value) })
        }
        let pairs = confusions.reduce(0) { $0 + $1.value.count }
        if pairs > Self.maxConfusions {
            var flat: [(heard: String, intended: String, count: Int)] = []
            for (heard, targets) in confusions { for (intended, count) in targets { flat.append((heard, intended, count)) } }
            flat.sort { $0.count > $1.count || ($0.count == $1.count && ($0.heard, $0.intended) < ($1.heard, $1.intended)) }
            var kept: [String: [String: Int]] = [:]
            for entry in flat.prefix(Self.maxConfusions) { kept[entry.heard, default: [:]][entry.intended] = entry.count }
            confusions = kept
        }
        // Spellings only for words still known.
        if spellings.count > unigrams.count {
            var known = Set(unigrams.keys)
            for targets in confusions.values {
                for intended in targets.keys { known.formUnion(intended.split(separator: " ").map(String.init)) }
            }
            spellings = spellings.filter { known.contains($0.key) }
        }
    }
}
