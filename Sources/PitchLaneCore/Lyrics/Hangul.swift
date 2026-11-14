import Foundation

/// Revised Romanization of Korean, one result per sung syllable, with the sound changes karaoke romanization
/// shows across syllables: liaison (있어 → i-sseo, 읽어 → il-geo), nasalization (합니다 → ham-ni-da,
/// 국물 → gung-mul) and ㄹ rules (신라 → sil-la, 심리 → sim-ni).
public enum Hangul {
    static let initials = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"]
    static let medials = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we", "wi",
                          "yu", "eu", "ui", "i"]
    /// Final consonant as pronounced at the end of a syllable.
    static let finals = ["", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l", "m", "p", "p", "t", "t",
                         "ng", "t", "t", "k", "t", "p", "t"]
    /// When the next syllable starts with silent ㅇ: what stays, and what carries over as the next onset.
    static let liaison: [Int: (stay: String, move: String)] = [
        1: ("", "g"), 2: ("", "kk"), 3: ("k", "s"), 4: ("", "n"), 5: ("n", "j"), 6: ("n", ""), 7: ("", "d"), 8: ("", "r"),
        9: ("l", "g"), 10: ("l", "m"), 11: ("l", "b"), 12: ("l", "s"), 13: ("l", "t"), 14: ("l", "p"), 15: ("", "r"),
        16: ("", "m"), 17: ("", "b"), 18: ("p", "s"), 19: ("", "s"), 20: ("", "ss"), 22: ("", "j"), 23: ("", "ch"),
        24: ("", "k"), 25: ("", "t"), 26: ("", "p"), 27: ("", ""),
    ]
    static let kType: Set<Int> = [1, 2, 3, 9, 24]
    static let tType: Set<Int> = [7, 19, 20, 22, 23, 25, 27]
    static let pType: Set<Int> = [14, 17, 18, 26]

    struct Block {
        var initial: Int
        var medial: Int
        var final: Int
    }

    static func block(_ s: Unicode.Scalar) -> Block? {
        guard LyricScript.isHangul(s) else { return nil }
        let code = Int(s.value) - 0xAC00
        return Block(initial: code / 588, medial: (code % 588) / 28, final: code % 28)
    }

    /// Romanization of a whole phrase.
    public static func romanize(_ text: String) -> String {
        romanize(syllables: text.map(String.init)).joined()
    }

    /// One romanized string per syllable string (each usually a single Hangul block); sound changes look across
    /// syllable boundaries, so pass a whole line.
    public static func romanize(syllables: [String]) -> [String] {
        // Flatten the line to scalars, remembering which syllable each belongs to.
        var scalars: [(owner: Int, scalar: Unicode.Scalar)] = []
        for (index, syllable) in syllables.enumerated() {
            for s in syllable.unicodeScalars { scalars.append((index, s)) }
        }
        var out = [String](repeating: "", count: syllables.count)
        var carried: String?   // onset carried over from the previous block's final
        for (i, entry) in scalars.enumerated() {
            guard let b = block(entry.scalar) else {
                carried = nil
                out[entry.owner] += String(Character(entry.scalar))
                continue
            }
            let next = i + 1 < scalars.count ? block(scalars[i + 1].scalar) : nil
            var onset = initials[b.initial]
            if let carried {
                onset = carried
            } else if b.initial == 5 {
                // ㄹ at the start of a syllable: "l" after ㄴ/ㄹ (handled by the previous block), "n" after other finals.
                onset = "r"
            }
            carried = nil
            var coda = finals[b.final]
            if let next, b.final != 0 {
                switch next.initial {
                case 11 where b.final != 21:
                    // Silent ㅇ next: the final moves over (ㅇ final stays as ng).
                    let split = liaison[b.final] ?? ("", "")
                    coda = split.stay
                    carried = split.move
                case 2, 6:
                    // ㄴ/ㅁ next: nasalization; ㄹ + ㄴ sounds ll (설날 seol-lal).
                    if kType.contains(b.final) { coda = "ng" } else if tType.contains(b.final) { coda = "n" } else if pType.contains(b.final) { coda = "m" }
                    if b.final == 8, next.initial == 2 { carried = "l" }
                case 5:
                    // ㄹ next: after ㄴ or ㄹ both sound l (신라 sil-la); after ㅁ/ㅇ it sounds n (심리 sim-ni).
                    if b.final == 4 || b.final == 8 {
                        coda = "l"
                        carried = "l"
                    } else if b.final == 16 || b.final == 21 {
                        carried = "n"
                    } else if kType.contains(b.final) {
                        coda = "ng"
                        carried = "n"
                    } else if pType.contains(b.final) {
                        coda = "m"
                        carried = "n"
                    }
                default:
                    break
                }
            }
            out[entry.owner] += onset + medials[b.medial] + coda
        }
        return out
    }
}
