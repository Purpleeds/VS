import Foundation

/// Combines several listening passes over the same song (e.g. the pitch-focused voice and the plain voice) into one
/// set of heard words, phrase by phrase, and tidies the result.
///
/// Each sung phrase (`VocalPrep.Segment`) takes its words from whichever pass heard it best: every word counts
/// 0.3 plus 0.7 × its confidence (0.5 when the recogniser gave none), so hearing more words wins, and confident words
/// win over guesses. Phrases no pass heard anything in are reported (`unheard`) so they can be tried again on their own.
public enum HeardWordPicker {
    public typealias HeardWord = LyricListenMatcher.HeardWord

    /// How strongly a set of words was heard.
    public static func score(_ words: [HeardWord]) -> Double {
        words.reduce(0) { $0 + 0.3 + 0.7 * ($1.confidence ?? 0.5) }
    }

    /// The phrase a word belongs to: the one containing its middle, else the nearest within `tolerance` seconds.
    public static func segmentIndex(of word: HeardWord, in segments: [VocalPrep.Segment], tolerance: Double = 0.5) -> Int? {
        let middle = word.time + max(0, word.duration) / 2
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].end <= middle { lo = mid + 1 } else { hi = mid }
        }
        if lo < segments.count, segments[lo].start <= middle { return lo }
        // Between phrases: the closer neighbour, if close enough.
        var best: (index: Int, distance: Double)?
        for index in [lo - 1, lo] where index >= 0 && index < segments.count {
            let s = segments[index]
            let distance = middle < s.start ? s.start - middle : middle - s.end
            if distance <= tolerance, distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best?.index
    }

    /// Per phrase, the words of the pass that heard it best (ties go to the earlier pass). Words that fall outside
    /// every phrase are dropped: the recogniser was given silence there.
    public static func bestPerSegment(_ passes: [[HeardWord]], segments: [VocalPrep.Segment]) -> [HeardWord] {
        guard !segments.isEmpty else { return [] }
        var picked: [HeardWord] = []
        // grouped[pass][segment] = words
        let grouped = passes.map { words -> [[HeardWord]] in
            var bySegment = [[HeardWord]](repeating: [], count: segments.count)
            for word in words where word.time.isFinite && word.duration.isFinite {
                if let index = segmentIndex(of: word, in: segments) { bySegment[index].append(word) }
            }
            return bySegment
        }
        for index in segments.indices {
            var bestPass: Int?
            var bestScore = 0.0
            for (number, pass) in grouped.enumerated() {
                let s = score(pass[index])
                if s > bestScore {
                    bestPass = number
                    bestScore = s
                }
            }
            guard let bestPass else { continue }
            var words = grouped[bestPass][index]
            // What the other passes heard at the same moments becomes each word's alternatives.
            for (number, pass) in grouped.enumerated() where number != bestPass {
                words = withAlternatives(words, from: pass[index])
            }
            picked += words
        }
        return picked.sorted { $0.time < $1.time }
    }

    /// Adds, to each word, the differently heard words of `others` that overlap it in time (by at least 40 % of the
    /// shorter of the two).
    public static func withAlternatives(_ words: [HeardWord], from others: [HeardWord]) -> [HeardWord] {
        guard !others.isEmpty else { return words }
        return words.map { word in
            let key = LyricListenMatcher.key(word.text)
            let end = word.time + max(0.05, word.duration)
            let overlapping = others.filter { other in
                let otherEnd = other.time + max(0.05, other.duration)
                let overlap = min(end, otherEnd) - max(word.time, other.time)
                let shorter = min(end - word.time, otherEnd - other.time)
                return overlap >= 0.4 * shorter && LyricListenMatcher.key(other.text) != key
            }
            guard !overlapping.isEmpty else { return word }
            return HeardWord(text: word.text, time: word.time, duration: word.duration, confidence: word.confidence,
                             alternatives: (word.alternatives ?? []) + overlapping.map(\.text))
        }
    }

    /// Adds another reading of the same stretch (e.g. a recogniser's second-best transcript) as alternatives:
    /// the two are aligned word by word (`WordAlignment`) and each word that reads differently gets the other one.
    /// Words that run together or split apart become multi-word alternatives ("good night" for "goodnight").
    public static func attachAlternatives(_ words: [HeardWord], alternative: [String]) -> [HeardWord] {
        guard !words.isEmpty, !alternative.isEmpty else { return words }
        let alignment = WordAlignment.align(words.map(\.text), alternative)
        var extra = [[String]](repeating: [], count: words.count)
        for pair in alignment.pairs where pair.kind != .same && pair.a < words.count && pair.b < alternative.count {
            extra[pair.a].append(alternative[pair.b])
        }
        for block in alignment.blocks where block.aRange.count == 1 && block.bRange.count > 1 && block.aRange.lowerBound < words.count {
            extra[block.aRange.lowerBound].append(block.bRange.map { alternative[$0] }.joined(separator: " "))
        }
        return words.enumerated().map { index, word in
            guard !extra[index].isEmpty else { return word }
            return HeardWord(text: word.text, time: word.time, duration: word.duration, confidence: word.confidence,
                             alternatives: (word.alternatives ?? []) + extra[index])
        }
    }

    /// Indices of phrases at least `minDuration` long in which no word was heard.
    public static func unheard(_ words: [HeardWord], segments: [VocalPrep.Segment], minDuration: Double = 0.8) -> [Int] {
        var heard = Set<Int>()
        for word in words {
            if let index = segmentIndex(of: word, in: segments) { heard.insert(index) }
        }
        return segments.indices.filter { !heard.contains($0) && segments[$0].duration >= minDuration }
    }

    /// Final tidy-up: sorted; words outside every sung phrase dropped (when phrases are known); the same word heard
    /// twice at (almost) the same moment kept once (the more confident copy); runs of more than `maxRepeats` identical
    /// words cut back (a recogniser stuck on a held note), unless each repeat has room to be really sung.
    public static func clean(_ words: [HeardWord], segments: [VocalPrep.Segment], maxRepeats: Int = 6) -> [HeardWord] {
        let sorted = words
            .filter { $0.time.isFinite && $0.duration.isFinite && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { segments.isEmpty || segmentIndex(of: $0, in: segments) != nil }
            .sorted { $0.time < $1.time }
        var out: [HeardWord] = []
        var run = 0
        var previous: HeardWord?
        for word in sorted {
            defer { previous = word }
            let key = LyricListenMatcher.key(word.text)
            guard let before = previous, !key.isEmpty, LyricListenMatcher.key(before.text) == key else {
                run = 0
                out.append(word)
                continue
            }
            if word.time - before.time < 0.15, let last = out.last, LyricListenMatcher.key(last.text) == key {
                // Duplicate (overlapping passes): keep the more confident one.
                if (word.confidence ?? 0.5) > (last.confidence ?? 0.5) { out[out.count - 1] = word }
                continue
            }
            run += 1
            if run >= maxRepeats, word.time - before.time < 0.3 { continue }
            out.append(word)
        }
        return out
    }
}
