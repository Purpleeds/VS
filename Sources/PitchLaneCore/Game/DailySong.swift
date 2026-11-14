import Foundation

/// One built-in song a day, the same for everyone on that calendar day, with bonus experience for the first
/// completed run of it that day. Only built-ins take part, so the pick (and old bonuses) never change when songs are
/// imported or deleted.
public enum DailySong {
    public static let bonusExperience = 50

    /// The song of `date`'s calendar day. Steps through every built-in (7 apart, so it never repeats two days running).
    public static func kind(for date: Date, calendar: Calendar = .current) -> BuiltInKind {
        let kinds = BuiltInKind.allCases
        let day = dayNumber(date, calendar: calendar)
        let count = kinds.count
        let index = ((day * 7 + 3) % count + count) % count
        return kinds[index]
    }

    /// Whether `songID` (any difficulty) is the song of `date`'s day.
    public static func isDailySong(_ songID: String, on date: Date, calendar: Calendar = .current) -> Bool {
        let kind = kind(for: date, calendar: calendar)
        return Difficulty.allCases.contains { BuiltInSongs.id(kind, $0) == songID }
    }

    /// Whether today's song already has a completed run today.
    public static func isDone(records: [GameRecord], on date: Date, calendar: Calendar = .current) -> Bool {
        records.contains { !$0.failed && calendar.isDate($0.date, inSameDayAs: date) && isDailySong($0.songID, on: $0.date, calendar: calendar) }
    }

    /// Ids of the runs that earned the daily bonus: the first completed run of each day's song, on that day.
    public static func bonusRecords(_ records: [GameRecord], calendar: Calendar = .current) -> Set<UUID> {
        var days = Set<Int>()
        var ids = Set<UUID>()
        for record in records where !record.failed && isDailySong(record.songID, on: record.date, calendar: calendar) {
            if days.insert(dayNumber(record.date, calendar: calendar)).inserted { ids.insert(record.id) }
        }
        return ids
    }

    /// Days since 1 January 2024 in `calendar` (negative before).
    static func dayNumber(_ date: Date, calendar: Calendar) -> Int {
        var reference = DateComponents()
        reference.year = 2024
        reference.month = 1
        reference.day = 1
        guard let start = calendar.date(from: reference) else { return 0 }
        return calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
    }
}
