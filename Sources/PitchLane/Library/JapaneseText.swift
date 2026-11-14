#if canImport(SwiftUI)
import CoreFoundation
import Foundation
import PitchLaneCore

/// The words to draw on each note: the main text (romaji for Japanese songs) and an optional second line
/// (the Japanese original, in "Romaji + Japanese" mode).
struct LyricDisplay: Sendable {
    var primary: [String]
    var secondary: [String]?

    static func plain(_ song: Song) -> LyricDisplay {
        LyricDisplay(primary: song.notes.map(\.displayLyric), secondary: nil)
    }
}

/// Japanese text with the system tokenizer (CFStringTokenizer, Japanese locale), which knows kanji readings.
/// Everything runs on the phone.
enum JapaneseText {
    /// Words of `text`, with a hiragana reading for those written with kanji.
    static func tokens(_ text: String) -> [JapaneseToken] {
        let string = text as NSString
        let length = string.length
        guard length > 0 else { return [] }
        let locale = Locale(identifier: "ja_JP") as CFLocale
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, text as CFString, CFRange(location: 0, length: length), kCFStringTokenizerUnitWord, locale
        )
        var tokens: [JapaneseToken] = []
        var type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while type.rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let word = string.substring(with: NSRange(location: range.location, length: range.length))
            var reading: String?
            if Kana.containsKanji(word),
               let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                let hiragana = Romaji.normalizeLatin(latin).applyingTransform(.latinToHiragana, reverse: false)
                if let hiragana, Kana.containsJapanese(hiragana), !Kana.containsKanji(hiragana) { reading = hiragana }
            }
            tokens.append(JapaneseToken(text: word, reading: reading))
            type = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return tokens
    }

    /// Romaji for a title or phrase ("さくら" → "sakura"); nil when it has no Japanese.
    static func romaji(_ text: String) -> String? {
        guard Kana.containsJapanese(text) else { return nil }
        let tokens = tokens(text)
        let words = tokens.map { token -> String in
            if let particle = JapaneseRomanizer.particles[token.text] { return particle }
            return Romaji.fromKana(token.reading ?? token.text)
        }
        let joined = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    /// The hiragana morae of one lyric line (for fitting lyrics onto notes and matching them to heard words).
    static func morae(_ line: String) -> [String] {
        JapaneseLyrics.morae(of: tokens(line))
    }

    static func songHasJapanese(_ song: Song) -> Bool {
        song.notes.contains { Kana.containsJapanese($0.lyric) }
    }

    /// What the lane shows for each note of `song`.
    static func display(for song: Song, mode: JapaneseLyricsMode) -> LyricDisplay {
        guard songHasJapanese(song), mode != .original else { return .plain(song) }
        var romaji = song.notes.map(\.displayLyric)
        for group in JapaneseRomanizer.lineGroups(for: song) {
            let syllables = group.map { song.notes[$0].displayLyric }
            let line = syllables.joined()
            guard Kana.containsJapanese(line) else { continue }
            let converted = JapaneseRomanizer.romanize(syllables: syllables, tokens: tokens(line))
            for (index, noteIndex) in group.enumerated() where index < converted.count {
                romaji[noteIndex] = converted[index].trimmingCharacters(in: .whitespaces)
            }
        }
        return LyricDisplay(primary: romaji, secondary: mode == .both ? song.notes.map(\.displayLyric) : nil)
    }
}
#endif
