import Foundation

/// Turns a spoken request ("play Happy Birthday please") into a search, and finds the song it most likely means.
public enum VoiceQuery {
    public struct Candidate: Sendable, Equatable {
        public var id: String
        public var title: String
        public var artist: String

        public init(id: String, title: String, artist: String = "") {
            self.id = id
            self.title = title
            self.artist = artist
        }
    }

    private static let leadingPhrases = [
        "can you play", "could you play", "i want to sing", "i wanna sing", "let me sing", "search for", "look for",
        "look up", "find me", "play me", "play", "sing", "open", "find", "search", "start",
    ]
    private static let fillers: Set<String> = ["the", "a", "an", "song", "please", "by", "called", "track", "now"]

    /// The spoken words without request phrases, ready for the search field.
    public static func clean(_ spoken: String) -> String {
        var text = spoken.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lower = text.lowercased()
        for phrase in leadingPhrases where lower.hasPrefix(phrase + " ") {
            text = String(text.dropFirst(phrase.count + 1))
            break
        }
        for suffix in [" please", " now", " for me"] where text.lowercased().hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        if text.lowercased().hasPrefix("the song ") { text = String(text.dropFirst("the song ".count)) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Lower-case, accent-free word tokens without filler words.
    public static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !fillers.contains($0) }
    }

    /// The song the query clearly means (score >= 0.6 and ahead of the runner-up by 0.15), or nil.
    public static func bestMatch(for query: String, in candidates: [Candidate]) -> (id: String, score: Double)? {
        let scored = candidates.map { ($0.id, score(query: query, candidate: $0)) }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= 0.6 else { return nil }
        if scored.count > 1, best.1 - scored[1].1 < 0.15 { return nil }
        return best
    }

    /// 0...1: how much of the query the song covers, and how much of the title the query covers.
    public static func score(query: String, candidate: Candidate) -> Double {
        let q = tokens(query)
        let title = tokens(candidate.title)
        let all = title + tokens(candidate.artist)
        guard !q.isEmpty, !title.isEmpty else { return 0 }
        let queryHits = q.filter { word in all.contains { similar(word, $0) } }.count
        let titleHits = title.filter { word in q.contains { similar(word, $0) } }.count
        return 0.7 * Double(queryHits) / Double(q.count) + 0.3 * Double(titleHits) / Double(title.count)
    }

    /// Equal, or (for longer words) one edit apart, so small mishearings still match.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(Array(a), Array(b), limit: 1) <= 1
    }

    private static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        var previous = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if (current.min() ?? 0) > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
