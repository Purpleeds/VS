import Foundation

/// Which writing system a song's lyrics use, for romanized display and syllable-by-syllable fitting.
public enum LyricScript: String, Sendable, Equatable, CaseIterable {
    case japanese
    case korean
    case chinese
    case other

    public var languageName: String {
        switch self {
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .chinese: return "Chinese"
        case .other: return ""
        }
    }

    /// What the romanization is called.
    public var romanizationName: String {
        switch self {
        case .japanese: return "romaji"
        case .korean: return "romanization"
        case .chinese: return "pinyin"
        case .other: return ""
        }
    }

    /// The on-device speech recogniser to use when listening for these lyrics.
    public var speechLocaleIdentifier: String? {
        switch self {
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .chinese: return "zh-CN"
        case .other: return nil
        }
    }

    public static func isHangul(_ s: Unicode.Scalar) -> Bool { (0xAC00...0xD7A3).contains(s.value) }
    public static func isHan(_ s: Unicode.Scalar) -> Bool { Kana.isKanji(s) }

    /// Characters sung one per beat and written without spaces between them (kana, Han, Hangul).
    public static func isSyllabic(_ s: Unicode.Scalar) -> Bool { Kana.isKana(s) || isHan(s) || isHangul(s) }

    /// Any kana → Japanese (kanji too); else mostly Hangul → Korean; else Han characters → Chinese.
    public static func detect(_ texts: [String]) -> LyricScript {
        var kana = 0, hangul = 0, han = 0
        for text in texts {
            for s in text.unicodeScalars {
                if Kana.isKana(s) { kana += 1 } else if isHangul(s) { hangul += 1 } else if isHan(s) { han += 1 }
            }
        }
        if kana > 0 { return .japanese }
        if hangul > 0, hangul >= han { return .korean }
        if han > 0 { return .chinese }
        return .other
    }

    public static func detect(_ song: Song) -> LyricScript { detect(song.notes.map(\.lyric)) }

    /// A line split into sung units for Korean (one Hangul syllable each) and Chinese (one character each).
    /// Latin words stay whole; spaces and punctuation are dropped. Japanese needs readings, so the app splits it.
    public static func units(of line: String) -> [String] {
        var out: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty { out.append(word) }
            word = ""
        }
        for s in line.unicodeScalars {
            if isHangul(s) || isHan(s) || Kana.isKana(s) {
                flush()
                out.append(String(Character(s)))
            } else if CharacterSet.alphanumerics.contains(s), !(0x3000...0x303F).contains(s.value), !(0xFF00...0xFF0F).contains(s.value) {
                word.unicodeScalars.append(s)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// A heard word ("사랑해" at 3.0 s for 0.6 s) as timed syllables spread over its duration.
    public static func heardUnits(_ text: String, time: Double, duration: Double) -> [LyricListenMatcher.HeardWord] {
        let pieces = units(of: text)
        guard !pieces.isEmpty else { return [] }
        let step = max(0.05, duration) / Double(pieces.count)
        return pieces.enumerated().map { LyricListenMatcher.HeardWord(text: $1, time: time + Double($0) * step, duration: step) }
    }
}

/// Pinyin per note: each Han character takes its own reading; other text passes through.
public enum ChineseRomanizer {
    /// `readings[i]` is the pinyin of the i-th character of `syllables.joined()` (nil = not a Han character or unknown).
    public static func romanize(syllables: [String], readings: [String?]) -> [String] {
        var offset = 0
        return syllables.map { syllable in
            let characters = Array(syllable)
            defer { offset += characters.count }
            guard syllable.unicodeScalars.contains(where: LyricScript.isHan) else { return syllable }
            var parts: [String] = []
            var latin = ""
            for (k, character) in characters.enumerated() {
                let isHan = character.unicodeScalars.contains(where: LyricScript.isHan)
                if isHan {
                    if !latin.isEmpty { parts.append(latin); latin = "" }
                    let index = offset + k
                    parts.append(index < readings.count ? (readings[index] ?? String(character)) : String(character))
                } else if !character.isWhitespace {
                    latin.append(character)
                }
            }
            if !latin.isEmpty { parts.append(latin) }
            return parts.joined(separator: " ")
        }
    }
}
