import Foundation

/// Predicts the words that were really sung from what the speech recogniser heard. A small statistical model of the
/// kind speech recognisers themselves use (a "noisy channel" with a word-sequence model), run on the phone, one
/// lyric line at a time, and learning from the user (`WordModel`).
///
/// For each heard word, and for two or three heard words that may be one word heard in pieces ("beyond say" for
/// "Beyoncé"), it considers candidates: the word itself, the recogniser's own alternatives, what repeats of the same
/// line heard there, what the user corrected it to before, the words to know, and known words that sound alike.
/// Each candidate is scored on:
/// - **pronunciation**: how close it sounds to what was heard (sound key, spelling) and how sure the recogniser was;
/// - **previous words**: a word and word-pair model from the user's lyrics and corrections plus the rest of this song
///   (every line is judged by the other lines, never by itself);
/// - **the song itself**: lines that repeat, recognised by their words or by their tune (the intervals of the notes
///   sung), vote for each other's words, so a chorus heard right twice fixes the third time;
/// - **speed**: a word can't have many more syllables than notes were sung while it was heard;
/// - **habits and words to know**: corrections the user made before, and the words they listed.
/// The best reading of each line is found with the Viterbi algorithm; a line only changes when the new reading
/// beats the heard one by `Weights.margin`.
public enum WordPredictor {
    public typealias HeardWord = LyricListenMatcher.HeardWord

    /// How much each kind of evidence counts (log-probability units).
    public struct Weights: Sendable, Equatable {
        /// Cost of changing a word, per unit of the recogniser's log-odds that it was right (nothing below 50 %).
        public var keepConfident = 1.5
        /// Per log(1 + times the user corrected this before).
        public var learned = 2.5
        /// Per log(1 + support from repeats of the line).
        public var votes = 1.4
        /// For a word the user listed.
        public var custom = 2.0
        /// Per log-probability from the word-sequence model.
        public var language = 0.5
        /// Added to every word's log-probability (so readings with fewer, longer words aren't favoured just for that).
        public var wordBonus = 3.0
        /// Per syllable too many for the notes sung, and for singing impossibly fast.
        public var rhythm = 1.0
        /// A line changes only when its new reading wins by this much.
        public var margin = 0.3
        /// Confidence assumed when the recogniser gave none.
        public var unknownConfidence = 0.6

        public init() {}
    }

    public struct Result: Sendable, Equatable {
        public var words: [HeardWord]
        /// Heard words replaced (a run-together pair counts as two).
        public var changed: Int

        public init(words: [HeardWord], changed: Int) {
            self.words = words
            self.changed = changed
        }
    }

    /// Heard words longer than this are taken as they are (bounds the work on very long recordings).
    public static let maximumWords = 4_000

    public static func predict(_ input: [HeardWord], notes: [SongNote], model: WordModel, weights: Weights = Weights()) -> Result {
        let heard = input.filter { $0.time.isFinite && $0.duration.isFinite && !LyricListenMatcher.key($0.text).isEmpty }
            .sorted { $0.time < $1.time }
        guard !heard.isEmpty, heard.count <= maximumWords else { return Result(words: input, changed: 0) }
        let context = Context(heard: heard, notes: notes.sorted { $0.start < $1.start }, model: model, weights: weights)
        var output: [HeardWord] = []
        output.reserveCapacity(heard.count)
        var changed = 0
        for line in context.lines.indices {
            let reading = context.bestReading(of: line)
            for choice in reading {
                let covered = context.lines[line][choice.start..<(choice.start + choice.candidate.span)].map { context.slots[$0] }
                if choice.candidate.isHeard {
                    output.append(covered[0].word)
                    continue
                }
                changed += covered.count
                let start = covered[0].word.time
                let end = covered.map { $0.word.time + max(0.05, $0.word.duration) }.max() ?? start + 0.3
                let count = choice.candidate.texts.count
                let step = (end - start) / Double(max(1, count))
                let original = covered.map(\.word.text).joined(separator: " ")
                for (index, text) in choice.candidate.texts.enumerated() {
                    output.append(HeardWord(text: text, time: start + Double(index) * step, duration: max(0.05, step * 0.95),
                                            confidence: 0.6, alternatives: [original]))
                }
            }
        }
        return Result(words: output, changed: changed)
    }

    // MARK: Model

    struct Slot {
        var word: HeardWord
        var key: String
        var sound: String?
        var confidence: Double
    }

    struct Candidate {
        var keys: [String]
        var texts: [String]
        /// Heard words it stands for.
        var span: Int
        /// Everything but the word-sequence model.
        var score: Double
        var isHeard: Bool
    }

    struct Choice {
        var start: Int
        var candidate: Candidate
    }

    /// Everything worked out once per song.
    struct Context {
        let slots: [Slot]
        let lines: [[Int]]
        let notes: [SongNote]
        let model: WordModel
        let weights: Weights
        /// Sound key (or "~" + a sound key with one letter left out) → word keys.
        private var soundIndex: [String: [String]] = [:]
        /// Words to know: phrase key → words as typed.
        private var customPhrases: [String: [String]] = [:]
        /// Joined sound of each word to know ("newyork" → "nyrk") → phrase keys.
        private var customSounds: [String: [String]] = [:]
        /// How each key was heard in this song (first spelling).
        private var songTexts: [String: String] = [:]
        private var songCounts: [String: Double] = [:]
        private var songPairs: [String: Double] = [:]
        private var songTotal = 0.0
        private var lineCounts: [[String: Double]] = []
        private var linePairs: [[String: Double]] = []
        private var lineTotals: [Double] = []
        /// Per slot: candidate key → (support, how it was heard there).
        private var votes: [[String: (weight: Double, text: String)]] = []
        private let vocabularySize: Double

        init(heard: [HeardWord], notes: [SongNote], model: WordModel, weights: Weights) {
            self.notes = notes
            self.model = model
            self.weights = weights
            let slots = heard.map { word -> Slot in
                let key = LyricListenMatcher.key(word.text)
                return Slot(word: word, key: key, sound: LyricListenMatcher.phonetic(key), confidence: word.confidence ?? weights.unknownConfidence)
            }
            self.slots = slots
            lines = Self.lines(slots)

            // This song's own words, as a word-sequence model (each line's share kept apart, to leave it out).
            lineCounts = Array(repeating: [:], count: lines.count)
            linePairs = Array(repeating: [:], count: lines.count)
            lineTotals = Array(repeating: 0, count: lines.count)
            for (number, line) in lines.enumerated() {
                var previous: String?
                for index in line {
                    let slot = slots[index]
                    let weight = 0.4 + 0.6 * slot.confidence
                    songCounts[slot.key, default: 0] += weight
                    lineCounts[number][slot.key, default: 0] += weight
                    songTotal += weight
                    lineTotals[number] += weight
                    if let previous {
                        songPairs[previous + " " + slot.key, default: 0] += weight
                        linePairs[number][previous + " " + slot.key, default: 0] += weight
                    }
                    previous = slot.key
                    if songTexts[slot.key] == nil { songTexts[slot.key] = slot.word.text }
                }
            }

            // Words to know.
            for phrase in model.customWords {
                let words = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
                let keys = words.map(LyricListenMatcher.key).filter { !$0.isEmpty }
                guard !keys.isEmpty else { continue }
                customPhrases[keys.joined(separator: " ")] = words
                if let sound = LyricListenMatcher.phonetic(keys.joined()) {
                    customSounds[sound, default: []].append(keys.joined(separator: " "))
                }
            }

            // Sound index over every word worth suggesting: learned words, words to know, this song's words.
            var keys = Set(model.unigrams.keys)
            keys.formUnion(songCounts.keys)
            for phrase in customPhrases.keys where !phrase.contains(" ") { keys.insert(phrase) }
            vocabularySize = Double(max(50, keys.count))
            var index: [String: [String]] = [:]
            for key in keys where key.count >= 2 {
                guard let sound = LyricListenMatcher.phonetic(key) else { continue }
                index[sound, default: []].append(key)
                if sound.count >= 3 {
                    for shorter in Phonetics.deletions(sound) { index["~" + shorter, default: []].append(key) }
                }
            }
            soundIndex = index

            // Repeats: lines alike in words or in tune vote for each other's words.
            votes = Array(repeating: [:], count: slots.count)
            let lineKeys = lines.map { $0.map { slots[$0].key } }
            let lineSounds = lines.map { $0.map { slots[$0].sound } }
            let lineSets = lineKeys.map(Set.init)
            let tunes = lines.map { line -> [Int] in
                let start = slots[line[0]].word.time
                let end = line.map { slots[$0].word.time + slots[$0].word.duration }.max() ?? start
                return Self.tune(notes, from: start, to: end)
            }
            for a in lines.indices {
                for b in lines.indices where b != a {
                    let tune = Self.tuneSimilarity(tunes[a], tunes[b])
                    guard !lineSets[a].isDisjoint(with: lineSets[b]) || tune >= 0.75 else { continue }
                    let alignment = WordAlignment.align(keys: lineKeys[a], sounds: lineSounds[a], against: lineKeys[b], againstSounds: lineSounds[b])
                    let matched = alignment.pairs.reduce(0.0) { total, pair in
                        total + (pair.kind == .same ? 1 : (pair.kind == .similar ? 0.7 : 0))
                    }
                    let words = matched / Double(max(lineKeys[a].count, lineKeys[b].count))
                    guard words >= 0.5 || (tune >= 0.75 && words >= 0.25) else { continue }
                    let weight = max(words, 0.5 * words + 0.5 * tune)
                    for pair in alignment.pairs {
                        let target = slots[lines[b][pair.b]]
                        let support = weight * (0.4 + 0.6 * target.confidence)
                        let slot = lines[a][pair.a]
                        let previous = votes[slot][target.key]
                        votes[slot][target.key] = ((previous?.weight ?? 0) + support, previous?.text ?? target.word.text)
                    }
                }
            }
        }

        // MARK: Lines and tunes

        /// Heard words grouped into lines at pauses of 0.8 s (or every 12 words).
        static func lines(_ slots: [Slot]) -> [[Int]] {
            var lines: [[Int]] = []
            var current: [Int] = []
            var lastEnd = -Double.infinity
            for (index, slot) in slots.enumerated() {
                if !current.isEmpty, slot.word.time - lastEnd >= 0.8 || current.count >= 12 {
                    lines.append(current)
                    current = []
                }
                current.append(index)
                lastEnd = max(slot.word.time, slot.word.time + slot.word.duration)
            }
            if !current.isEmpty { lines.append(current) }
            return lines
        }

        /// Pitch steps (semitones) between the notes sung from `start` to `end`.
        static func tune(_ notes: [SongNote], from start: Double, to end: Double) -> [Int] {
            let pitches = notes.filter { $0.start >= start - 0.1 && $0.start <= end + 0.1 }.map(\.pitch)
            return zip(pitches, pitches.dropFirst()).map { $1 - $0 }
        }

        /// How alike two tunes are (0...1): the longest in-order run of matching steps (within a semitone) over the
        /// longer tune. Tunes of under two steps don't count.
        static func tuneSimilarity(_ a: [Int], _ b: [Int]) -> Double {
            guard a.count >= 2, b.count >= 2 else { return 0 }
            var previous = [Int](repeating: 0, count: b.count + 1)
            var current = previous
            for x in a {
                for (j, y) in b.enumerated() {
                    current[j + 1] = abs(x - y) <= 1 ? previous[j] + 1 : max(previous[j + 1], current[j])
                }
                swap(&previous, &current)
            }
            return Double(previous[b.count]) / Double(max(a.count, b.count))
        }

        /// Notes that start while `start...end` was being sung.
        func notesSung(from start: Double, to end: Double) -> Int {
            var lo = 0, hi = notes.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if notes[mid].start < start - 0.08 { lo = mid + 1 } else { hi = mid }
            }
            var count = 0
            var index = lo
            while index < notes.count, notes[index].start <= end + 0.08 {
                count += 1
                index += 1
            }
            return count
        }

        // MARK: Word-sequence model

        /// log P(next | previous) from the learned model plus the rest of this song (not line `line` itself),
        /// smoothed towards how common `next` is, and never below -8.
        func logProbability(_ next: String, after previous: String?, line: Int) -> Double {
            let songWeight = 2.0
            func count(_ key: String) -> Double {
                Double(model.count(key)) + songWeight * max(0, (songCounts[key] ?? 0) - (lineCounts[line][key] ?? 0))
            }
            let total = Double(model.unigramTotal) + songWeight * max(0, songTotal - lineTotals[line])
            let unigram = (count(next) + 0.5) / (total + 0.5 * vocabularySize)
            var probability = unigram
            if let previous {
                let before = count(previous)
                if before > 0 {
                    let pair = previous + " " + next
                    let together = Double(model.count(previous, next))
                        + songWeight * max(0, (songPairs[pair] ?? 0) - (linePairs[line][pair] ?? 0))
                    probability = (together + 2 * unigram) / (before + 2)
                }
            }
            return max(-8, log(max(probability, 1e-12)))
        }

        // MARK: Candidates

        /// Words that sound like `sound`: the same sound key (0) or one letter off (1; only when the longer of the
        /// two has four or more sounds, since short keys one letter apart are different words).
        func soundAlikes(_ sound: String) -> [(key: String, distance: Int)] {
            var found: [String: Int] = [:]
            for key in soundIndex[sound] ?? [] { found[key] = 0 }
            if sound.count >= 3 {
                var near = soundIndex["~" + sound] ?? []
                for shorter in Phonetics.deletions(sound) {
                    near += soundIndex[shorter] ?? []
                    near += soundIndex["~" + shorter] ?? []
                }
                for key in near where found[key] == nil {
                    let other = LyricListenMatcher.phonetic(key)?.count ?? 0
                    if max(sound.count, other) >= 4 { found[key] = 1 }
                }
            }
            return found.map { ($0.key, $0.value) }
        }

        /// Worth suggesting: a word to know, a word learned at least twice, or one heard elsewhere in this song.
        func isSuggestible(_ key: String, besides slot: Int?) -> Bool {
            if customPhrases[key] != nil || model.count(key) >= 2 { return true }
            let elsewhere = (songCounts[key] ?? 0) - (slot.map { slots[$0].key == key ? 0.4 + 0.6 * slots[$0].confidence : 0 } ?? 0)
            return elsewhere >= 0.6
        }

        /// How a key is shown: the user's spelling, else how it was heard in this song, else the key.
        func text(for key: String) -> String {
            let spelled = model.spelling(of: key)
            if spelled != key { return spelled }
            return songTexts[key] ?? key
        }

        func candidates(line: Int, start: Int, span: Int) -> [Candidate] {
            let covered = lines[line][start..<(start + span)].map { slots[$0] }
            let spanStart = covered[0].word.time
            let spanEnd = covered.map { $0.word.time + max(0.05, $0.word.duration) }.max() ?? spanStart
            let confidence = covered.reduce(0) { $0 + $1.confidence } / Double(covered.count)
            let phraseKey = covered.map(\.key).joined(separator: " ")
            let learned = model.corrections(of: phraseKey)
            let sung = notes.isEmpty ? nil : notesSung(from: spanStart, to: spanEnd)
            var found: [String: Candidate] = [:]

            func add(_ keys: [String], texts: [String], acoustic: Double, isHeard: Bool = false) {
                let keys = keys.filter { !$0.isEmpty }
                guard !keys.isEmpty, keys.count <= 4 else { return }
                let joined = keys.joined(separator: " ")
                if !isHeard, span == 1, joined == covered[0].key { return }
                var score = acoustic
                if !isHeard {
                    let sure = min(0.98, max(0.02, confidence))
                    score -= weights.keepConfident * max(0, log(sure / (1 - sure)))
                }
                if let times = learned[joined] { score += weights.learned * log(1 + Double(times)) }
                if span == 1, keys.count == 1, let support = votes[lines[line][start]][keys[0]]?.weight {
                    score += weights.votes * log(1 + support)
                }
                if customPhrases[joined] != nil { score += weights.custom }
                // Speed: no more syllables than notes sung (plus one), and nothing faster than ~8 syllables a second.
                let syllables = keys.reduce(0) { $0 + Phonetics.syllables($1) }
                if let sung {
                    let excess = syllables - max(1, sung) - 1
                    if excess > 0 { score -= weights.rhythm * Double(excess) }
                }
                let rate = Double(syllables) / max(0.05, spanEnd - spanStart)
                if syllables >= 2, rate > 8 { score -= weights.rhythm * min(3, rate / 8 - 1) }
                if let existing = found[joined], existing.score >= score { return }
                found[joined] = Candidate(keys: keys, texts: texts, span: span, score: score, isHeard: isHeard)
            }

            func words(_ key: String) -> [String] {
                if let custom = customPhrases[key] { return custom }
                return key.split(separator: " ").map { text(for: String($0)) }
            }

            if span == 1 {
                let slot = covered[0]
                let slotIndex = lines[line][start]
                add([slot.key], texts: [slot.word.text], acoustic: 0, isHeard: true)
                for alternative in slot.word.alternatives ?? [] {
                    let pieces = alternative.split(whereSeparator: \.isWhitespace).map(String.init)
                    add(pieces.map(LyricListenMatcher.key), texts: pieces, acoustic: log(0.5))
                }
                for (key, vote) in votes[slotIndex] where key != slot.key {
                    add([key], texts: [vote.text], acoustic: Self.soundSimilarity(slot, key))
                }
                for (target, _) in learned {
                    add(target.split(separator: " ").map(String.init), texts: words(target), acoustic: log(0.5))
                }
                if let sound = slot.sound {
                    for (key, distance) in soundAlikes(sound) where key != slot.key && isSuggestible(key, besides: slotIndex) {
                        let custom = customPhrases[key] != nil
                        add([key], texts: [text(for: key)], acoustic: log(distance == 0 ? (custom ? 0.4 : 0.35) : (custom ? 0.2 : 0.12)))
                    }
                    for phrase in customSounds[sound] ?? [] {
                        add(phrase.split(separator: " ").map(String.init), texts: words(phrase), acoustic: log(0.4))
                    }
                }
            } else {
                for (target, _) in learned {
                    add(target.split(separator: " ").map(String.init), texts: words(target), acoustic: log(0.5))
                }
                if covered.allSatisfy({ $0.sound != nil }), let sound = LyricListenMatcher.phonetic(covered.map(\.key).joined()) {
                    for phrase in customSounds[sound] ?? [] {
                        add(phrase.split(separator: " ").map(String.init), texts: words(phrase), acoustic: log(0.4))
                    }
                    for (key, distance) in soundAlikes(sound) where customPhrases[key] != nil || model.count(key) >= 2 {
                        let custom = customPhrases[key] != nil
                        add([key], texts: [text(for: key)], acoustic: log(distance == 0 ? (custom ? 0.4 : 0.25) : (custom ? 0.2 : 0.08)))
                    }
                }
            }
            // The ten best, always keeping the heard word itself (so the heard reading stays in the running).
            var best = Array(found.values.sorted { $0.score > $1.score }.prefix(10))
            if let heard = found.values.first(where: \.isHeard), !best.contains(where: \.isHeard) { best.append(heard) }
            return best
        }

        /// log-likelihood that `key` was heard as `slot` (rough): by sound key when both are English, else by how
        /// many letters (or kana, hangul, hanzi) they share.
        static func soundSimilarity(_ slot: Slot, _ key: String) -> Double {
            if let sound = slot.sound, let other = LyricListenMatcher.phonetic(key) {
                if sound == other { return log(0.35) }
                if max(sound.count, other.count) >= 4, Phonetics.editDistance(sound, other, limit: 1) <= 1 { return log(0.15) }
            }
            let longest = max(1, slot.key.count, key.count)
            let shared = 1 - Double(Phonetics.editDistance(slot.key, key, limit: longest)) / Double(longest)
            return log(max(0.03, 0.3 * shared))
        }

        // MARK: Decoding

        /// The best reading of a line (Viterbi over spans of 1-3 heard words), or the heard words as they are when
        /// nothing beats them by the margin.
        func bestReading(of line: Int) -> [Choice] {
            let count = lines[line].count
            // table[position][span - 1] = candidates for the heard words position..<position + span.
            let table = (0..<count).map { position in
                (1...min(3, count - position)).map { candidates(line: line, start: position, span: $0) }
            }
            var heardReading: [Choice] = []
            var heardScore = 0.0
            var previous: String?
            for position in 0..<count {
                let slot = slots[lines[line][position]]
                let heard = table[position][0].first(where: \.isHeard)
                    ?? Candidate(keys: [slot.key], texts: [slot.word.text], span: 1, score: 0, isHeard: true)
                heardReading.append(Choice(start: position, candidate: heard))
                heardScore += heard.score + weights.language * (logProbability(slot.key, after: previous, line: line) + weights.wordBonus)
                previous = slot.key
            }

            struct Entry {
                var score: Double
                var from: Int
                var fromKey: String
                var choice: Choice?
            }
            let startKey = "\u{1}"
            var best = [[String: Entry]](repeating: [:], count: count + 1)
            best[0][startKey] = Entry(score: 0, from: -1, fromKey: "", choice: nil)
            for position in 0..<count where !best[position].isEmpty {
                for (offset, candidates) in table[position].enumerated() {
                    let span = offset + 1
                    for candidate in candidates {
                        guard let last = candidate.keys.last else { continue }
                        for (key, entry) in best[position] {
                            var language = 0.0
                            var before: String? = key == startKey ? nil : key
                            for word in candidate.keys {
                                language += logProbability(word, after: before, line: line) + weights.wordBonus
                                before = word
                            }
                            let score = entry.score + candidate.score + weights.language * language
                            if let existing = best[position + span][last], existing.score >= score { continue }
                            best[position + span][last] = Entry(score: score, from: position, fromKey: key, choice: Choice(start: position, candidate: candidate))
                        }
                    }
                }
            }
            guard let end = best[count].max(by: { $0.value.score < $1.value.score }), end.value.score - heardScore >= weights.margin else {
                return heardReading
            }
            var reading: [Choice] = []
            var position = count
            var key = end.key
            while position > 0, let entry = best[position][key], let choice = entry.choice {
                reading.append(choice)
                position = entry.from
                key = entry.fromKey
            }
            guard position == 0 else { return heardReading }
            reading.reverse()
            return reading.allSatisfy(\.candidate.isHeard) ? heardReading : reading
        }
    }
}
