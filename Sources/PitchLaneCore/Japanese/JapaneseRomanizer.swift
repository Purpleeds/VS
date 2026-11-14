import Foundation

/// One word from a Japanese tokenizer (the app uses the system tokenizer, which knows kanji readings).
public struct JapaneseToken: Sendable, Equatable {
    public var text: String
    /// Kana reading, for words written with kanji (nil when the text is already kana).
    public var reading: String?

    public init(text: String, reading: String? = nil) {
        self.text = text
        self.reading = reading
    }
}

/// Romaji for the syllables of a lyric line, one per note.
///
/// Kana are converted exactly; kanji take the tokenizer's reading (okurigana are matched off the ends, and a word
/// spread over several notes is shared out by morae); は, へ and を standing alone as words are particles
/// (wa, e, o); っ at the end of one note doubles the consonant that starts the next.
public enum JapaneseRomanizer {
    public static let particles: [String: String] = ["は": "wa", "へ": "e", "を": "o"]

    public static func romanize(syllables: [String], tokens: [JapaneseToken]) -> [String] {
        let characters = syllables.map { Array($0) }
        let line = characters.flatMap { $0 }
        guard !line.isEmpty else { return syllables }
        // Which syllable owns each character of the line.
        var owner: [Int] = []
        for (index, chars) in characters.enumerated() { owner += Array(repeating: index, count: chars.count) }

        // Each character's kana (or text), and whether it is a particle.
        var kana = line.map { String($0) }
        var particle = [String?](repeating: nil, count: line.count)
        var claimed = [Bool](repeating: false, count: line.count)
        var position = 0
        for token in tokens where !token.text.isEmpty {
            let tokenChars = Array(token.text)
            guard let start = find(tokenChars, in: line, from: position) else { continue }
            let end = start + tokenChars.count
            position = end
            if let reading = particles[token.text] {
                particle[start] = reading
                continue
            }
            guard let reading = token.reading.map(Kana.toHiragana), Kana.containsKanji(token.text) else { continue }
            assignReading(reading, toKanjiIn: start..<end, line: line, owner: owner, kana: &kana, claimed: &claimed)
        }

        // Morae per syllable, then romaji with っ/ー resolved across the whole line.
        var units: [(syllable: Int, unit: Romaji.Unit, particle: String?)] = []
        var i = 0
        while i < line.count {
            if claimed[i], kana[i].isEmpty {
                i += 1
                continue
            }
            if let p = particle[i] {
                units.append((owner[i], Romaji.Unit(text: String(line[i]), isKanaMora: true), p))
                i += 1
                continue
            }
            for unit in Romaji.units(of: kana[i]) {
                if unit.isKanaMora, Kana.isCombining(unit.text.unicodeScalars.first!), let last = units.last,
                   last.syllable == owner[i], last.unit.isKanaMora, last.particle == nil, !last.unit.isSokuon, !last.unit.isLongMark {
                    units[units.count - 1].unit.text += unit.text
                } else {
                    units.append((owner[i], unit, nil))
                }
            }
            i += 1
        }
        let plainUnits = units.map(\.unit)
        var romaji = units.map { entry in entry.particle ?? (entry.unit.isKanaMora ? Romaji.mora(entry.unit.text) : entry.unit.text) }
        Romaji.fixSpecials(units: plainUnits, romaji: &romaji)

        var out = [String](repeating: "", count: syllables.count)
        for (index, entry) in units.enumerated() { out[entry.syllable] += romaji[index] }
        // Syllables with nothing Japanese keep their text (spacing included).
        for (index, syllable) in syllables.enumerated() where !Kana.containsJapanese(syllable) {
            out[index] = syllable
        }
        return out
    }

    /// Kanji in `range` share the reading left after matching the word's kana off both ends.
    private static func assignReading(
        _ reading: String, toKanjiIn range: Range<Int>, line: [Character], owner: [Int], kana: inout [String], claimed: inout [Bool]
    ) {
        var readingMorae = Kana.morae(reading)
        var lo = range.lowerBound, hi = range.upperBound
        // Okurigana / leading kana: drop matching morae from the reading.
        while lo < hi, isKanaChar(line[lo]), let first = readingMorae.first, Kana.toHiragana(String(line[lo])) == first {
            readingMorae.removeFirst()
            lo += 1
        }
        while hi > lo, isKanaChar(line[hi - 1]), let last = readingMorae.last, Kana.toHiragana(String(line[hi - 1])) == last {
            readingMorae.removeLast()
            hi -= 1
        }
        let kanjiIndices = (lo..<hi).filter { !isKanaChar(line[$0]) }
        guard !kanjiIndices.isEmpty, !readingMorae.isEmpty else { return }
        // Share the morae out over the kanji, by syllable, in order.
        let groups = Dictionary(grouping: kanjiIndices, by: { owner[$0] }).sorted { $0.key < $1.key }
        var cursor = 0
        var counted = 0
        for (_, indices) in groups {
            counted += indices.count
            let end = groups.last?.value == indices ? readingMorae.count
                : Int((Double(counted) / Double(kanjiIndices.count) * Double(readingMorae.count)).rounded())
            let slice = readingMorae[min(cursor, readingMorae.count)..<max(min(end, readingMorae.count), min(cursor, readingMorae.count))]
            cursor = max(cursor, end)
            for (n, index) in indices.enumerated() {
                kana[index] = n == 0 ? slice.joined() : ""
                claimed[index] = true
            }
        }
    }

    private static func isKanaChar(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { Kana.isKana($0) }
    }

    private static func find(_ needle: [Character], in haystack: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        var start = from
        while start + needle.count <= haystack.count {
            if Array(haystack[start..<(start + needle.count)]) == needle { return start }
            start += 1
        }
        return nil
    }

    /// Note indices per lyric line: split at the song's line breaks, or at silences of a second when it has none.
    public static func lineGroups(for song: Song) -> [[Int]] {
        var groups: [[Int]] = []
        var breaks = song.lineBreaks.sorted()[...]
        for (index, note) in song.notes.enumerated() {
            var split = groups.isEmpty
            if song.lineBreaks.isEmpty, let last = groups.last?.last, note.start - song.notes[last].end >= 1.0 { split = true }
            while let next = breaks.first, next <= note.start + 1e-6 {
                breaks = breaks.dropFirst()
                split = true
            }
            if split { groups.append([index]) } else { groups[groups.count - 1].append(index) }
        }
        return groups
    }
}

/// Japanese lyrics are fitted and matched mora by mora (one sung beat per note), in hiragana.
public enum JapaneseLyrics {
    /// The morae of a tokenized line: kana as written (katakana → hiragana), kanji words by their reading.
    /// Kanji with no reading stay as they are, one unit per word.
    public static func morae(of tokens: [JapaneseToken]) -> [String] {
        tokens.flatMap { token -> [String] in
            if Kana.containsKanji(token.text) {
                guard let reading = token.reading, !reading.isEmpty else { return [token.text] }
                return Kana.morae(Kana.toHiragana(reading))
            }
            return Kana.morae(Kana.toHiragana(token.text))
        }
    }

    /// A heard word ("見て" at 3.0 s for 0.4 s) as timed morae spread over its duration.
    public static func heardMorae(_ tokens: [JapaneseToken], time: Double, duration: Double) -> [LyricListenMatcher.HeardWord] {
        let units = morae(of: tokens)
        guard !units.isEmpty else { return [] }
        let step = max(0.05, duration) / Double(units.count)
        return units.enumerated().map { index, unit in
            LyricListenMatcher.HeardWord(text: unit, time: time + Double(index) * step, duration: step)
        }
    }
}
