import Foundation

/// Japanese script helpers (pure Unicode; no dictionary).
public enum Kana {
    public static func isHiragana(_ s: Unicode.Scalar) -> Bool { (0x3041...0x309F).contains(s.value) }
    public static func isKatakana(_ s: Unicode.Scalar) -> Bool {
        (0x30A0...0x30FF).contains(s.value) || (0x31F0...0x31FF).contains(s.value)
    }
    public static func isKana(_ s: Unicode.Scalar) -> Bool { isHiragana(s) || isKatakana(s) }
    public static func isKanji(_ s: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value)
            || (0xF900...0xFAFF).contains(s.value) || s.value == 0x3005 // 々
    }

    public static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { isKana($0) || isKanji($0) }
    }

    public static func containsKanji(_ text: String) -> Bool { text.unicodeScalars.contains(where: isKanji) }

    /// Katakana to hiragana (ー and other characters unchanged).
    public static func toHiragana(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if (0x30A1...0x30F6).contains(s.value), let h = Unicode.Scalar(s.value - 0x60) {
                scalars.append(h)
            } else {
                scalars.append(s)
            }
        }
        return String(scalars)
    }

    /// Small kana that join the mora before them (ゃ ゅ ょ ぁ ぃ ぅ ぇ ぉ ゎ, and katakana forms).
    static func isCombining(_ s: Unicode.Scalar) -> Bool {
        let small: Set<UInt32> = [0x3083, 0x3085, 0x3087, 0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x308E,
                                  0x30E3, 0x30E5, 0x30E7, 0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30EE]
        return small.contains(s.value)
    }

    /// Splits kana into morae (sung beats): きょ・う・は, が・っ・こ・う, コ・ー・ヒ・ー. Anything that isn't kana
    /// (kanji, letters) stays together as one unit; spaces and punctuation are dropped.
    public static func morae(_ text: String) -> [String] {
        var out: [String] = []
        var other = ""
        func flushOther() {
            if !other.isEmpty { out.append(other) }
            other = ""
        }
        for s in text.unicodeScalars {
            if isKana(s) {
                flushOther()
                if isCombining(s), let last = out.last, let lastScalar = last.unicodeScalars.last, isKana(lastScalar) {
                    out[out.count - 1] = last + String(Character(s))
                } else {
                    out.append(String(Character(s)))
                }
            } else if CharacterSet.whitespacesAndNewlines.contains(s) || CharacterSet.punctuationCharacters.contains(s)
                        || (0x3000...0x303F).contains(s.value) {
                flushOther()
            } else {
                other.unicodeScalars.append(s)
            }
        }
        flushOther()
        return out
    }
}

/// Hepburn romaji for kana (the style karaoke lyrics use: きょう → kyou, がっこう → gakkou, コーヒー → koohii).
public enum Romaji {
    static let table: [UInt32: String] = {
        let pairs: [(String, String)] = [
            ("あ", "a"), ("い", "i"), ("う", "u"), ("え", "e"), ("お", "o"),
            ("か", "ka"), ("き", "ki"), ("く", "ku"), ("け", "ke"), ("こ", "ko"),
            ("さ", "sa"), ("し", "shi"), ("す", "su"), ("せ", "se"), ("そ", "so"),
            ("た", "ta"), ("ち", "chi"), ("つ", "tsu"), ("て", "te"), ("と", "to"),
            ("な", "na"), ("に", "ni"), ("ぬ", "nu"), ("ね", "ne"), ("の", "no"),
            ("は", "ha"), ("ひ", "hi"), ("ふ", "fu"), ("へ", "he"), ("ほ", "ho"),
            ("ま", "ma"), ("み", "mi"), ("む", "mu"), ("め", "me"), ("も", "mo"),
            ("や", "ya"), ("ゆ", "yu"), ("よ", "yo"),
            ("ら", "ra"), ("り", "ri"), ("る", "ru"), ("れ", "re"), ("ろ", "ro"),
            ("わ", "wa"), ("ゐ", "i"), ("ゑ", "e"), ("を", "o"), ("ん", "n"),
            ("が", "ga"), ("ぎ", "gi"), ("ぐ", "gu"), ("げ", "ge"), ("ご", "go"),
            ("ざ", "za"), ("じ", "ji"), ("ず", "zu"), ("ぜ", "ze"), ("ぞ", "zo"),
            ("だ", "da"), ("ぢ", "ji"), ("づ", "zu"), ("で", "de"), ("ど", "do"),
            ("ば", "ba"), ("び", "bi"), ("ぶ", "bu"), ("べ", "be"), ("ぼ", "bo"),
            ("ぱ", "pa"), ("ぴ", "pi"), ("ぷ", "pu"), ("ぺ", "pe"), ("ぽ", "po"),
            ("ゔ", "vu"),
            ("ぁ", "a"), ("ぃ", "i"), ("ぅ", "u"), ("ぇ", "e"), ("ぉ", "o"),
            ("ゃ", "ya"), ("ゅ", "yu"), ("ょ", "yo"), ("ゎ", "wa"),
        ]
        var table: [UInt32: String] = [:]
        for (kana, romaji) in pairs {
            if let s = kana.unicodeScalars.first { table[s.value] = romaji }
        }
        return table
    }()

    static let punctuation: [UInt32: String] = [
        0x3001: ",", 0x3002: ".", 0xFF01: "!", 0xFF1F: "?", 0x3000: " ", 0x300C: "\"", 0x300D: "\"",
        0x300E: "\"", 0x300F: "\"", 0xFF08: "(", 0xFF09: ")", 0x301C: "~", 0xFF5E: "~", 0x30FB: " ",
    ]

    /// Romaji for one mora (with any combining small kana). Unknown text comes back unchanged.
    static func mora(_ unit: String) -> String {
        let scalars = Array(Kana.toHiragana(unit).unicodeScalars)
        guard let first = scalars.first, let base = table[first.value] else { return unit }
        guard scalars.count > 1, let small = table[scalars[1].value] else { return base }
        if ["ya", "yu", "yo"].contains(small), base.hasSuffix("i"), base.count > 1 {
            // きゃ → kya; しゃ → sha; ちゃ → cha; じゃ → ja.
            let stem = String(base.dropLast())
            return ["sh", "ch", "j"].contains(stem) ? stem + String(small.dropFirst()) : stem + small
        }
        // うぃ → wi; ふぁ → fa, てぃ → ti, しぇ → she, ゔぁ → va, くゎ → kwa.
        if base == "u" { return "w" + small }
        let consonant = base.count > 1 && "aiueo".contains(base.last!) ? String(base.dropLast()) : base
        return consonant + small
    }

    /// Romaji for a kana string (katakana included). Kanji and letters pass through.
    public static func fromKana(_ text: String) -> String {
        let units = units(of: text)
        var romaji = units.map { unit -> String in unit.isKanaMora ? mora(unit.text) : unit.text }
        fixSpecials(units: units, romaji: &romaji)
        return romaji.joined()
    }

    /// Strips macrons from a Latin transcription (tōkyō → toukyou) and lowercases it.
    public static func normalizeLatin(_ latin: String) -> String {
        var out = ""
        for c in latin.lowercased() {
            switch c {
            case "ā", "â": out += "aa"
            case "ī", "î": out += "ii"
            case "ū", "û": out += "uu"
            case "ē", "ê": out += "ee"
            case "ō", "ô": out += "ou"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: Units

    struct Unit {
        var text: String
        var isKanaMora: Bool
        var isSokuon: Bool { text == "っ" || text == "ッ" }
        var isLongMark: Bool { text == "ー" }
    }

    /// Morae and pass-through runs, in order, keeping punctuation (converted) so text reads naturally.
    static func units(of text: String) -> [Unit] {
        var out: [Unit] = []
        var other = ""
        func flush() {
            if !other.isEmpty { out.append(Unit(text: other, isKanaMora: false)) }
            other = ""
        }
        for s in text.unicodeScalars {
            if Kana.isKana(s) {
                flush()
                if Kana.isCombining(s), let last = out.last, last.isKanaMora, !last.isSokuon, !last.isLongMark {
                    out[out.count - 1].text += String(Character(s))
                } else {
                    out.append(Unit(text: String(Character(s)), isKanaMora: true))
                }
            } else if let mapped = punctuation[s.value] {
                flush()
                out.append(Unit(text: mapped, isKanaMora: false))
            } else {
                other.unicodeScalars.append(s)
            }
        }
        flush()
        return out
    }

    /// っ doubles the next consonant (っち → tch); ー repeats the previous vowel.
    static func fixSpecials(units: [Unit], romaji: inout [String]) {
        for i in units.indices where units[i].isKanaMora {
            if units[i].isSokuon {
                romaji[i] = i + 1 < romaji.count ? geminate(romaji[i + 1]) : ""
            } else if units[i].isLongMark {
                romaji[i] = i > 0 ? lastVowel(romaji[i - 1]) : ""
            }
        }
    }

    static func geminate(_ next: String) -> String {
        guard let first = next.first, first.isLetter, !"aiueon".contains(first) else { return "" }
        return next.hasPrefix("ch") ? "t" : String(first)
    }

    static func lastVowel(_ previous: String) -> String {
        previous.last { "aiueo".contains($0) }.map(String.init) ?? ""
    }
}
