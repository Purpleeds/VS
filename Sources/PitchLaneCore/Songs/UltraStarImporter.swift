import Foundation

/// Imports UltraStar `.txt` songs.
///
/// Supported: `#TITLE`, `#ARTIST`, `#MP3` / `#AUDIO`, `#BPM` (comma or dot decimals), `#GAP` (ms),
/// `#RELATIVE`; note lines `:` normal, `*` golden, `F` freestyle, `R`/`G` rap (imported as freestyle);
/// `-` line breaks; `E` end; duets (`P1`/`P2`) import player 1 only. A `~` syllable continues the previous
/// syllable and is imported as a short slide. Timing: beat = 60 / (BPM x 4) s, start = GAP + beat x n.
/// Pitch 0 = C4 (MIDI 60). Unknown `#` headers are ignored; anything else unexpected is an error with
/// its line number.
public enum UltraStarImporter {
    public struct Result: Sendable, Equatable {
        public var song: Song
        /// The `#AUDIO` / `#MP3` file name the song expects, if any.
        public var audioReference: String?
        public var warnings: [String]
    }

    /// Glide length used for `~` continuation notes.
    public static let continuationSlide = 0.12

    public static func parse(data: Data, id: String = UUID().uuidString, fallbackTitle: String = "Untitled") throws -> Result {
        try parse(text: TextDecoding.decode(data), id: id, fallbackTitle: fallbackTitle)
    }

    public static func parse(text: String, id: String = UUID().uuidString, fallbackTitle: String = "Untitled") throws -> Result {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        var headers: [String: String] = [:]
        var bpm: Double?
        var gapMs = 0.0
        var relative = false
        var rawNotes: [RawNote] = []
        var rawBreaks: [Double] = []
        var lineStart = 0.0
        var skippingPlayer = false
        var sawDuet = false

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            var line = Substring(rawLine)
            if index == 0, line.first == "\u{FEFF}" { line = line.dropFirst() }
            if line.allSatisfy(\.isWhitespace) { continue }
            line = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let type = line.first else { continue }

            switch type {
            case "#":
                guard let colon = line.firstIndex(of: ":") else {
                    throw SongImportError(line: lineNumber, "header needs a colon, like #TITLE:My Song")
                }
                let key = line[line.index(after: line.startIndex)..<colon].trimmingCharacters(in: .whitespaces).uppercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
                switch key {
                case "BPM":
                    guard let value = number(from: value), value > 0, value.isFinite else {
                        throw SongImportError(line: lineNumber, "#BPM must be a positive number, got \"\(value)\"")
                    }
                    bpm = value
                case "GAP":
                    guard let value = number(from: value), value.isFinite else {
                        throw SongImportError(line: lineNumber, "#GAP must be a number of milliseconds, got \"\(value)\"")
                    }
                    gapMs = value
                case "RELATIVE":
                    relative = ["YES", "TRUE", "1"].contains(value.uppercased())
                default:
                    break
                }

            case "E":
                return try makeResult(
                    headers: headers, bpm: bpm, gapMs: gapMs, rawNotes: rawNotes, rawBreaks: rawBreaks,
                    sawDuet: sawDuet, id: id, fallbackTitle: fallbackTitle
                )

            case "P":
                let digits = line.dropFirst().trimmingCharacters(in: .whitespaces)
                guard let player = Int(digits) else {
                    throw SongImportError(line: lineNumber, "duet marker should be P1 or P2, got \"\(line)\"")
                }
                sawDuet = true
                skippingPlayer = player != 1

            case ":", "*", "F", "R", "G":
                if skippingPlayer { continue }
                var scanner = LineScanner(line.dropFirst())
                guard let start = scanner.integer(), let length = scanner.integer(), let pitch = scanner.integer() else {
                    throw SongImportError(line: lineNumber, "note needs start, length and pitch, like \": 12 4 5 la\"")
                }
                guard length > 0 else {
                    throw SongImportError(line: lineNumber, "note length must be greater than 0")
                }
                rawNotes.append(RawNote(
                    type: type, beat: lineStart + Double(start), length: Double(length), pitch: pitch,
                    text: scanner.remainderAfterOneSpace()
                ))

            case "-":
                if skippingPlayer { continue }
                var scanner = LineScanner(line.dropFirst())
                guard let first = scanner.integer() else {
                    throw SongImportError(line: lineNumber, "line break needs a beat number, like \"- 24\"")
                }
                let second = scanner.integer()
                rawBreaks.append(lineStart + Double(first))
                if relative { lineStart += Double(second ?? first) }

            case "B":
                throw SongImportError(line: lineNumber, "BPM changes (B lines) aren't supported")

            default:
                throw SongImportError(line: lineNumber, "unknown line type \"\(type)\"")
            }
        }
        return try makeResult(
            headers: headers, bpm: bpm, gapMs: gapMs, rawNotes: rawNotes, rawBreaks: rawBreaks,
            sawDuet: sawDuet, id: id, fallbackTitle: fallbackTitle
        )
    }

    private static func makeResult(
        headers: [String: String],
        bpm: Double?,
        gapMs: Double,
        rawNotes: [RawNote],
        rawBreaks: [Double],
        sawDuet: Bool,
        id: String,
        fallbackTitle: String
    ) throws -> Result {
        guard let bpm else {
            throw SongImportError("missing #BPM header")
        }
        guard !rawNotes.isEmpty else {
            throw SongImportError("no notes found")
        }
        let warnings = sawDuet ? ["Duet file: imported player 1 only."] : []
        let beatSeconds = 60 / (bpm * 4)
        let gap = gapMs / 1_000
        let ordered = rawNotes.enumerated().sorted { ($0.element.beat, $0.offset) < ($1.element.beat, $1.offset) }.map(\.element)
        var notes: [SongNote] = []
        notes.reserveCapacity(ordered.count)
        for raw in ordered {
            let start = gap + raw.beat * beatSeconds
            let duration = raw.length * beatSeconds
            let trimmed = raw.text.trimmingCharacters(in: .whitespaces)
            let isContinuation = trimmed.hasPrefix("~") && !notes.isEmpty
            notes.append(SongNote(
                start: start,
                duration: duration,
                pitch: 60 + raw.pitch,
                lyric: isContinuation ? String(trimmed.dropFirst()) : raw.text,
                isGolden: raw.type == "*" || raw.type == "G",
                isFreestyle: raw.type == "F" || raw.type == "R" || raw.type == "G",
                slidesFromPrevious: isContinuation,
                slideDuration: isContinuation ? min(continuationSlide, duration / 2) : nil
            ))
        }
        let song = Song(
            id: id,
            title: headers["TITLE"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle,
            artist: headers["ARTIST"] ?? "",
            source: .ultraStar,
            notes: notes,
            lineBreaks: rawBreaks.map { gap + $0 * beatSeconds },
            tempo: [TempoSegment(start: gap, beatDuration: 60 / bpm)]
        )
        let audio = [headers["AUDIO"], headers["MP3"]].compactMap { $0 }.first { !$0.isEmpty }
        return Result(song: song, audioReference: audio, warnings: warnings)
    }

    /// "300,5" or "300.5" -> 300.5
    static func number(from text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    private struct RawNote {
        var type: Character
        var beat: Double
        var length: Double
        var pitch: Int
        var text: String
    }

    /// Minimal whitespace-separated integer scanner over one line.
    private struct LineScanner {
        private var rest: Substring

        init(_ text: Substring) {
            rest = text
        }

        mutating func integer() -> Int? {
            let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
            var end = trimmed.startIndex
            if end < trimmed.endIndex, trimmed[end] == "-" || trimmed[end] == "+" {
                end = trimmed.index(after: end)
            }
            while end < trimmed.endIndex, trimmed[end].isASCII, trimmed[end].isNumber {
                end = trimmed.index(after: end)
            }
            guard let value = Int(trimmed[trimmed.startIndex..<end]) else { return nil }
            // A number must be followed by whitespace or the end of the line.
            if end < trimmed.endIndex, trimmed[end] != " ", trimmed[end] != "\t" { return nil }
            rest = trimmed[end...]
            return value
        }

        /// The syllable: everything after the single separator space following the pitch.
        mutating func remainderAfterOneSpace() -> String {
            var text = rest
            if let first = text.first, first == " " || first == "\t" {
                text = text.dropFirst()
            }
            return String(text)
        }
    }
}
