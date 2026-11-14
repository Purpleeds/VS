import Foundation

/// How the Library lists your songs.
public enum LibrarySort: String, Codable, CaseIterable, Sendable, Identifiable {
    case title
    case recentlyPlayed
    case mostPlayed
    case bestScore

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .title: return "Title"
        case .recentlyPlayed: return "Recently Played"
        case .mostPlayed: return "Most Played"
        case .bestScore: return "Best Score"
        }
    }

    /// SF Symbol for the sort menu.
    public var symbol: String {
        switch self {
        case .title: return "textformat"
        case .recentlyPlayed: return "clock"
        case .mostPlayed: return "repeat"
        case .bestScore: return "trophy"
        }
    }

    /// `songs` in this order; ties (and never-played songs, which go last) by title.
    public func sorted(_ songs: [Song], history: GameHistory) -> [Song] {
        var summaries: [String: SongHistorySummary] = [:]
        if self != .title {
            for summary in history.songSummaries { summaries[summary.songID] = summary }
        }
        func byTitle(_ a: Song, _ b: Song) -> Bool {
            let order = a.title.compare(b.title, options: [.caseInsensitive, .diacriticInsensitive, .numeric])
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
        return songs.sorted { a, b in
            switch self {
            case .title:
                return byTitle(a, b)
            case .recentlyPlayed, .mostPlayed, .bestScore:
                let x = summaries[a.id], y = summaries[b.id]
                guard let x, let y else {
                    if x == nil, y == nil { return byTitle(a, b) }
                    return x != nil
                }
                switch self {
                case .recentlyPlayed where x.lastPlayed != y.lastPlayed: return x.lastPlayed > y.lastPlayed
                case .mostPlayed where x.plays != y.plays: return x.plays > y.plays
                case .bestScore where x.bestScore != y.bestScore: return x.bestScore > y.bestScore
                default: return byTitle(a, b)
                }
            }
        }
    }
}
