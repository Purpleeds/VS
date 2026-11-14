import Foundation

/// Level, experience and day streak from the play history (a bit of game feel for the home screen).
public struct PlayerProgress: Sendable, Equatable {
    public var level: Int
    public var experience: Int
    /// Experience into the current level, and how much the level needs.
    public var levelExperience: Int
    public var levelSize: Int
    /// Days in a row with at least one run, ending today or yesterday.
    public var streakDays: Int
    public var runs: Int
    public var bestGrade: Grade?

    public var levelFraction: Double { levelSize > 0 ? Double(levelExperience) / Double(levelSize) : 0 }

    /// Experience for one run: 10 for singing at all, plus accuracy points, plus bonuses for top grades.
    public static func experience(for record: GameRecord) -> Int {
        let base = 10 + Int((record.accuracy * 100).rounded())
        let bonus: Int
        switch record.grade {
        case .s: bonus = 50
        case .a: bonus = 25
        case .b: bonus = 10
        default: bonus = 0
        }
        return record.failed ? base / 2 : base + bonus
    }

    /// Experience needed to go from `level` to `level + 1` (100, 150, 200, ...).
    public static func levelSize(_ level: Int) -> Int { 100 + 50 * max(0, level - 1) }

    public init(history: GameHistory, now: Date = Date(), calendar: Calendar = .current) {
        let records = history.records
        runs = records.count
        // Plus the song-of-the-day bonus for the first completed run of each day's song.
        experience = records.reduce(0) { $0 + Self.experience(for: $1) }
            + DailySong.bonusRecords(records, calendar: calendar).count * DailySong.bonusExperience
        var level = 1
        var remaining = experience
        while remaining >= Self.levelSize(level), level < 999 {
            remaining -= Self.levelSize(level)
            level += 1
        }
        self.level = level
        levelExperience = remaining
        levelSize = Self.levelSize(level)
        let order: [Grade] = [.s, .a, .b, .c, .d, .f]
        bestGrade = records.filter { !$0.failed }.map(\.grade).min { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }

        let days = Set(records.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) { day = yesterday }
        var streak = 0
        while days.contains(day), streak < 10_000 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        streakDays = streak
    }
}
