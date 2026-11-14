#if canImport(SwiftUI)
import CoreFoundation
import Foundation
import PitchLaneCore

/// Romanized lyrics for Japanese (romaji), Korean (Revised Romanization) and Chinese (pinyin) songs, and the
/// syllable-by-syllable units used to fit and match their lyrics. Everything runs on the phone.
enum LyricRomanizer {
    /// What the lane shows for each note of `song`.
    static func display(for song: Song, mode: RomanizedLyricsMode) -> LyricDisplay {
        let script = LyricScript.detect(song)
        guard script != .other, mode != .original else { return .plain(song) }
        var romanized = song.notes.map(\.displayLyric)
        for group in JapaneseRomanizer.lineGroups(for: song) {
            let syllables = group.map { song.notes[$0].displayLyric }
            let line = syllables.joined()
            guard line.unicodeScalars.contains(where: LyricScript.isSyllabic) else { continue }
            let converted: [String]
            switch script {
            case .japanese: converted = JapaneseRomanizer.romanize(syllables: syllables, tokens: JapaneseText.tokens(line))
            case .korean: converted = Hangul.romanize(syllables: syllables)
            case .chinese: converted = ChineseRomanizer.romanize(syllables: syllables, readings: ChineseText.readings(line))
            case .other: converted = syllables
            }
            for (index, noteIndex) in group.enumerated() where index < converted.count {
                romanized[noteIndex] = converted[index].trimmingCharacters(in: .whitespaces)
            }
        }
        return LyricDisplay(primary: romanized, secondary: mode == .both ? song.notes.map(\.displayLyric) : nil)
    }

    /// Romanization of a title or phrase; nil when there is nothing to romanize.
    static func romanize(_ text: String) -> String? {
        switch LyricScript.detect([text]) {
        case .japanese: return JapaneseText.romaji(text)
        case .korean: return Hangul.romanize(text)
        case .chinese:
            let pinyin = ChineseRomanizer.romanize(syllables: text.map(String.init), readings: ChineseText.readings(text))
            return pinyin.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
                .folding(options: .diacriticInsensitive, locale: nil)
        case .other: return nil
        }
    }

    /// A lyric line as sung units: morae (Japanese), syllables (Korean) or characters (Chinese).
    static func units(_ line: String, script: LyricScript) -> [String] {
        switch script {
        case .japanese: return JapaneseText.morae(line)
        case .korean, .chinese: return LyricScript.units(of: line)
        case .other: return line.split(whereSeparator: \.isWhitespace).map(String.init)
        }
    }

    /// Heard words split the same way, each unit timed within its word.
    static func units(_ heard: [LyricListenMatcher.HeardWord], script: LyricScript) -> [LyricListenMatcher.HeardWord] {
        guard script != .other else { return heard }
        return heard.flatMap { word -> [LyricListenMatcher.HeardWord] in
            guard word.text.unicodeScalars.contains(where: LyricScript.isSyllabic) else { return [word] }
            switch script {
            case .japanese: return JapaneseLyrics.heardMorae(JapaneseText.tokens(word.text), time: word.time, duration: word.duration)
            default: return LyricScript.heardUnits(word.text, time: word.time, duration: word.duration)
            }
        }
    }

    /// Whole words that help the speech recogniser (contextual hints).
    static func hintWords(_ text: String, script: LyricScript) -> [String] {
        switch script {
        case .japanese: return JapaneseText.tokens(text).map(\.text).filter { $0.count > 1 }
        case .chinese: return ChineseText.words(text).filter { $0.count > 1 }
        case .korean, .other:
            return text.split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { $0.count > 1 }
        }
    }
}

/// Mandarin pinyin with the system tokenizer (word-level readings, so characters with several readings usually
/// get the right one), falling back to the system's per-character Han → Latin transform.
enum ChineseText {
    /// Pinyin for each character of `line` (nil for anything that isn't a Han character).
    static func readings(_ line: String) -> [String?] {
        let characters = Array(line)
        var readings = [String?](repeating: nil, count: characters.count)
        // UTF-16 offset of each character, to map tokenizer ranges back to characters.
        var offsets: [Int] = []
        var utf16 = 0
        for character in characters {
            offsets.append(utf16)
            utf16 += character.utf16.count
        }
        let string = line as NSString
        if string.length > 0 {
            let locale = Locale(identifier: "zh_Hans") as CFLocale
            let tokenizer = CFStringTokenizerCreate(
                kCFAllocatorDefault, line as CFString, CFRange(location: 0, length: string.length), kCFStringTokenizerUnitWord, locale
            )
            var type = CFStringTokenizerAdvanceToNextToken(tokenizer)
            while type.rawValue != 0 {
                let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                let indices = offsets.indices.filter {
                    offsets[$0] >= range.location && offsets[$0] < range.location + range.length
                        && characters[$0].unicodeScalars.contains(where: LyricScript.isHan)
                }
                if !indices.isEmpty,
                   let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                    let syllables = latin.split(whereSeparator: \.isWhitespace).map(String.init)
                    if syllables.count == indices.count {
                        for (k, index) in indices.enumerated() { readings[index] = syllables[k] }
                    }
                }
                type = CFStringTokenizerAdvanceToNextToken(tokenizer)
            }
        }
        for (index, character) in characters.enumerated() where readings[index] == nil
            && character.unicodeScalars.contains(where: LyricScript.isHan) {
            let latin = String(character).applyingTransform(.mandarinToLatin, reverse: false)
            readings[index] = latin?.trimmingCharacters(in: .whitespaces)
        }
        return readings
    }

    /// Words of a Chinese line (for recogniser hints).
    static func words(_ text: String) -> [String] {
        let string = text as NSString
        guard string.length > 0 else { return [] }
        let locale = Locale(identifier: "zh_Hans") as CFLocale
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, text as CFString, CFRange(location: 0, length: string.length), kCFStringTokenizerUnitWord, locale
        )
        var words: [String] = []
        var type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while type.rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            words.append(string.substring(with: NSRange(location: range.location, length: range.length)))
            type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return words
    }
}
#endif
