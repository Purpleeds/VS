import Foundation

/// One lyrics match from LRCLIB (lrclib.net, a free, open database of synced lyrics).
public struct LyricsCandidate: Sendable, Equatable, Identifiable, Decodable {
    public var id: Int
    public var trackName: String
    public var artistName: String
    public var albumName: String?
    /// Seconds.
    public var duration: Double?
    public var instrumental: Bool
    public var plainLyrics: String?
    public var syncedLyrics: String?

    public init(
        id: Int, trackName: String, artistName: String, albumName: String? = nil, duration: Double? = nil,
        instrumental: Bool = false, plainLyrics: String? = nil, syncedLyrics: String? = nil
    ) {
        self.id = id
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.instrumental = instrumental
        self.plainLyrics = plainLyrics
        self.syncedLyrics = syncedLyrics
    }

    private enum CodingKeys: String, CodingKey {
        case id, trackName, artistName, albumName, duration, instrumental, plainLyrics, syncedLyrics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        trackName = SongLimits.clip(c.lenient(String.self, forKey: .trackName) ?? "Unknown")
        artistName = SongLimits.clip(c.lenient(String.self, forKey: .artistName) ?? "")
        albumName = c.lenient(String.self, forKey: .albumName).map(SongLimits.clip)
        duration = c.lenient(Double.self, forKey: .duration).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        instrumental = c.lenient(Bool.self, forKey: .instrumental) ?? false
        plainLyrics = c.lenient(String.self, forKey: .plainLyrics).flatMap { $0.isEmpty ? nil : $0 }
        syncedLyrics = c.lenient(String.self, forKey: .syncedLyrics).flatMap { $0.isEmpty ? nil : $0 }
    }

    public var hasSyncedLyrics: Bool { syncedLyrics != nil }
    public var hasLyrics: Bool { syncedLyrics != nil || plainLyrics != nil }

    /// e.g. "Track · Artist".
    public var credit: String {
        artistName.isEmpty ? trackName : "\(trackName) · \(artistName)"
    }
}

/// Builds LRCLIB requests and reads their answers. The app does the networking; only the typed or spoken song name
/// is sent.
public enum LyricsSearch {
    public static let host = "lrclib.net"

    /// `GET https://lrclib.net/api/search?q=...`
    public static func searchURL(query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/search"
        components.queryItems = [URLQueryItem(name: "q", value: String(trimmed.prefix(200)))]
        return components.url
    }

    /// Decodes a search response, skipping entries it can't read, dropping instrumentals and entries without lyrics,
    /// and ranking synced ones first, then by how close their length is to `songDuration`.
    public static func decode(_ data: Data, songDuration: Double? = nil) throws -> [LyricsCandidate] {
        let entries = try JSONDecoder().decode([Lossy<LyricsCandidate>].self, from: data)
        let usable = entries.compactMap(\.value).filter { !$0.instrumental && $0.hasLyrics }
        return rank(usable, songDuration: songDuration)
    }

    public static func rank(_ candidates: [LyricsCandidate], songDuration: Double?) -> [LyricsCandidate] {
        func distance(_ candidate: LyricsCandidate) -> Double {
            guard let songDuration, songDuration > 0, let duration = candidate.duration else { return 1e9 }
            return abs(duration - songDuration)
        }
        return candidates.enumerated().sorted { a, b in
            if a.element.hasSyncedLyrics != b.element.hasSyncedLyrics { return a.element.hasSyncedLyrics }
            let da = distance(a.element), db = distance(b.element)
            if abs(da - db) > 2 { return da < db }
            return a.offset < b.offset
        }.map(\.element)
    }
}
