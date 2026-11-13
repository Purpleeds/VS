import Foundation

/// One finished (or failed) play-through.
public struct GameRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var songID: String
    public var songTitle: String
    public var difficulty: Difficulty
    public var date: Date
    public var score: Int
    public var accuracy: Double
    public var grade: Grade
    public var maxCombo: Int
    /// Slower, looped or no-fail run: shown in the history, excluded from bests and the main trend.
    public var practice: Bool
    public var speed: Double
    public var failed: Bool
    public var transpose: Int

    public init(
        id: UUID = UUID(), songID: String, songTitle: String, difficulty: Difficulty, date: Date = Date(),
        score: Int, accuracy: Double, grade: Grade, maxCombo: Int, practice: Bool = false, speed: Double = 1,
        failed: Bool = false, transpose: Int = 0
    ) {
        self.id = id
        self.songID = songID
        self.songTitle = songTitle
        self.difficulty = difficulty
        self.date = date
        self.score = score
        self.accuracy = accuracy
        self.grade = grade
        self.maxCombo = maxCombo
        self.practice = practice
        self.speed = speed
        self.failed = failed
        self.transpose = transpose
    }

    public init(result: GameResult, practice: PracticeOptions, failed: Bool, transpose: Int) {
        self.init(
            songID: result.songID, songTitle: result.songTitle, difficulty: result.difficulty, date: result.date,
            score: result.score, accuracy: result.accuracy, grade: result.grade, maxCombo: result.maxCombo,
            practice: practice.isPractice, speed: practice.speed, failed: failed, transpose: transpose
        )
    }
}

public struct TrendPoint: Sendable, Equatable {
    public var date: Date
    public var accuracy: Double
    public var record: GameRecord
}

public struct SongHistorySummary: Sendable, Equatable, Identifiable {
    public var songID: String
    public var title: String
    public var plays: Int
    public var bestScore: Int
    public var bestAccuracy: Double
    public var lastPlayed: Date

    public var id: String { songID }
}

/// Every play-through, newest last, capped. Persisted as JSON.
public struct GameHistory: Codable, Sendable, Equatable {
    public static let maxRecords = 1_000

    public private(set) var records: [GameRecord] = []

    public init() {}

    public mutating func add(_ record: GameRecord) {
        records.append(record)
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }
    }

    public mutating func removeAll(songID: String) {
        records.removeAll { $0.songID == songID }
    }

    public mutating func removeAll() {
        records.removeAll()
    }

    public func records(forSong songID: String) -> [GameRecord] {
        records.filter { $0.songID == songID }
    }

    /// One row per song, most recently played first.
    public var songSummaries: [SongHistorySummary] {
        var byID: [String: SongHistorySummary] = [:]
        for record in records {
            var entry = byID[record.songID] ?? SongHistorySummary(
                songID: record.songID, title: record.songTitle, plays: 0, bestScore: 0, bestAccuracy: 0, lastPlayed: record.date
            )
            entry.plays += 1
            entry.title = record.songTitle
            if !record.practice, !record.failed {
                entry.bestScore = max(entry.bestScore, record.score)
                entry.bestAccuracy = max(entry.bestAccuracy, record.accuracy)
            }
            entry.lastPlayed = max(entry.lastPlayed, record.date)
            byID[record.songID] = entry
        }
        return byID.values.sorted { $0.lastPlayed > $1.lastPlayed }
    }

    /// Accuracy over time for one song (or all), oldest first. By default only full-speed, completed runs.
    public func trend(songID: String? = nil, includePractice: Bool = false, limit: Int = 60) -> [TrendPoint] {
        let points = records
            .filter { songID == nil || $0.songID == songID }
            .filter { includePractice || (!$0.practice && !$0.failed) }
            .map { TrendPoint(date: $0.date, accuracy: $0.accuracy, record: $0) }
        return Array(points.suffix(limit))
    }

    /// Mean accuracy of the last `window` runs minus the `window` before that; nil with fewer than two runs.
    public static func improvement(in points: [TrendPoint], window: Int = 5) -> Double? {
        guard points.count >= 2 else { return nil }
        let recent = points.suffix(window)
        let earlier = points.dropLast(recent.count).suffix(window)
        guard !earlier.isEmpty else { return nil }
        func mean(_ slice: ArraySlice<TrendPoint>) -> Double {
            slice.reduce(0) { $0 + $1.accuracy } / Double(slice.count)
        }
        return mean(recent) - mean(earlier)
    }

    /// Centred moving average of the accuracy values (for a smoothed trend line).
    public static func movingAverage(_ values: [Double], window: Int = 3) -> [Double] {
        guard window > 1, values.count > 1 else { return values }
        return values.indices.map { index in
            let low = max(0, index - window / 2)
            let high = min(values.count - 1, index + window / 2)
            let slice = values[low...high]
            return slice.reduce(0, +) / Double(slice.count)
        }
    }
}
