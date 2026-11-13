import Foundation

/// One timed lyric line from an LRC file.
public struct LyricLine: Sendable, Equatable {
    public struct Word: Sendable, Equatable {
        /// Word start from enhanced LRC (`<mm:ss.xx>word`); nil when the line only has a line time.
        public var time: Double?
        public var text: String

        public init(time: Double?, text: String) {
            self.time = time
            self.text = text
        }
    }

    /// Seconds from the start of the recording.
    public var time: Double
    public var text: String
    public var words: [Word]

    public init(time: Double, text: String, words: [Word]) {
        self.time = time
        self.text = text
        self.words = words
    }
}

/// Parses LRC synced lyrics: `[mm:ss.xx]text`, several time tags per line, `[offset:±ms]`, metadata tags,
/// and enhanced word tags `<mm:ss.xx>`. Never traps; lines it can't read are skipped.
public enum LRCParser {
    public static func parse(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var offset = 0.0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(rawLine).trimmingCharacters(in: .whitespaces)[...]
            var times: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let time = timestamp(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:") {
                    // Positive offset = lyrics come earlier.
                    offset = (Double(tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)) ?? 0) / 1_000
                }
            }
            guard !times.isEmpty else { continue }
            let words = parseWords(rest)
            let plain = words.map(\.text).joined(separator: " ")
            for time in times {
                let shifted = time - offset
                guard shifted.isFinite, abs(shifted) <= SongLimits.maximumAbsoluteStart else { continue }
                // Word times move with the line.
                let movedWords = words.map { LyricLine.Word(time: $0.time.map { $0 - offset + (time - times[0]) }, text: $0.text) }
                lines.append(LyricLine(time: max(0, shifted), text: plain, words: movedWords))
            }
        }
        return lines.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    /// The words of a line, splitting on spaces, keeping `<time>` tags of enhanced LRC.
    private static func parseWords(_ text: Substring) -> [LyricLine.Word] {
        var words: [LyricLine.Word] = []
        var pendingTime: Double?
        var rest = text
        while !rest.isEmpty {
            if rest.first == "<", let close = rest.firstIndex(of: ">"), let time = timestamp(rest[rest.index(after: rest.startIndex)..<close]) {
                pendingTime = time
                rest = rest[rest.index(after: close)...]
                continue
            }
            let end = rest.firstIndex { $0 == " " || $0 == "<" || $0 == "\t" } ?? rest.endIndex
            let word = rest[rest.startIndex..<end]
            if !word.isEmpty {
                words.append(LyricLine.Word(time: pendingTime, text: String(word)))
                pendingTime = nil
            }
            rest = rest[end...]
            if rest.first == " " || rest.first == "\t" { rest = rest.dropFirst() }
        }
        return words
    }

    /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx`, `mm:ss:xx` -> seconds.
    static func timestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0].trimmingCharacters(in: .whitespaces)), minutes >= 0, minutes < 100_000 else { return nil }
        var seconds: Double
        if parts.count == 3 {
            guard let whole = Int(parts[1]), let hundredths = Int(parts[2]) else { return nil }
            seconds = Double(whole) + Double(hundredths) / pow(10, Double(parts[2].count))
        } else {
            guard let value = Double(parts[1]), value >= 0, value < 60 else { return nil }
            seconds = value
        }
        return Double(minutes) * 60 + seconds
    }
}
