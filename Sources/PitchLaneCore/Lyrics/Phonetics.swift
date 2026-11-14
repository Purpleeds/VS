import Foundation

/// Rough pronunciation helpers for the word predictor: a sound key (words that sound alike share it), syllable counts,
/// and a small edit distance. English-oriented; other scripts fall back to exact keys and character counts.
public enum Phonetics {
    /// A rough English sound key (`LyricListenMatcher.phonetic`): silent letters and spellings of the same sound folded
    /// together, vowels after the first letter dropped ("knight" / "night" → "nt"). Nil outside plain a-z.
    public static func soundKey(_ key: String) -> String? {
        LyricListenMatcher.phonetic(key)
    }

    /// Sung syllables in a word: vowel groups for English (a silent final "e" doesn't count, "-le" does), one per
    /// character for other scripts (kana, hangul, hanzi), at least 1.
    public static func syllables(_ word: String) -> Int {
        let key = LyricListenMatcher.key(word)
        guard !key.isEmpty else { return 0 }
        guard key.unicodeScalars.allSatisfy({ $0.isASCII }) else { return max(1, key.count) }
        let letters = Array(key)
        var count = 0
        var previousVowel = false
        for letter in letters {
            let vowel = "aeiouy".contains(letter)
            if vowel, !previousVowel { count += 1 }
            previousVowel = vowel
        }
        if letters.count > 2, letters.last == "e", !"aeiouy".contains(letters[letters.count - 2]),
           !(letters[letters.count - 2] == "l" && letters.count > 3 && !"aeiouy".contains(letters[letters.count - 3])) {
            count -= 1
        }
        return max(1, count)
    }

    /// Levenshtein distance, giving up (returning `limit + 1`) once it must exceed `limit`.
    public static func editDistance(_ a: String, _ b: String, limit: Int = 2) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var best = current[0]
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                best = min(best, current[j])
            }
            if best > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// The key with each one character left out (for finding keys one edit apart, SymSpell style).
    static func deletions(_ key: String) -> [String] {
        let characters = Array(key)
        guard characters.count > 1 else { return [] }
        return characters.indices.map { index in
            var copy = characters
            copy.remove(at: index)
            return String(copy)
        }
    }
}
