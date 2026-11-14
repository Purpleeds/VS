import Foundation

/// Badges earned by playing, worked out from the play history (nothing extra is stored).
public enum Badge: String, CaseIterable, Codable, Sendable, Identifiable {
    case firstSong
    case tenRuns
    case fiftyRuns
    case gradeA
    case gradeS
    case combo25
    case combo100
    case hardClear
    case fiveSongs
    case allSamples
    case streak3
    case streak7
    case practice
    case ownKey
    case songOfTheDay

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .firstSong: return "First Song"
        case .tenRuns: return "Regular"
        case .fiftyRuns: return "Stage Veteran"
        case .gradeA: return "Top Marks"
        case .gradeS: return "Superstar"
        case .combo25: return "On a Roll"
        case .combo100: return "Unstoppable"
        case .hardClear: return "Hard Mode"
        case .fiveSongs: return "Repertoire"
        case .allSamples: return "Songbook"
        case .streak3: return "Three-Day Streak"
        case .streak7: return "Week Streak"
        case .practice: return "Practice Pays"
        case .ownKey: return "Your Key"
        case .songOfTheDay: return "Daily Singer"
        }
    }

    public var detail: String {
        switch self {
        case .firstSong: return "Finish a song"
        case .tenRuns: return "Finish 10 songs"
        case .fiftyRuns: return "Finish 50 songs"
        case .gradeA: return "Get an A or better"
        case .gradeS: return "Get an S"
        case .combo25: return "Hit a 25-note combo"
        case .combo100: return "Hit a 100-note combo"
        case .hardClear: return "Finish a song on Hard"
        case .fiveSongs: return "Finish 5 different songs"
        case .allSamples: return "Finish every sample song"
        case .streak3: return "Sing 3 days in a row"
        case .streak7: return "Sing 7 days in a row"
        case .practice: return "Finish a practice run"
        case .ownKey: return "Finish a song in another key"
        case .songOfTheDay: return "Sing the song of the day"
        }
    }

    /// SF Symbol.
    public var symbol: String {
        switch self {
        case .firstSong: return "music.mic"
        case .tenRuns: return "music.note.list"
        case .fiftyRuns: return "trophy.fill"
        case .gradeA: return "rosette"
        case .gradeS: return "star.circle.fill"
        case .combo25: return "flame.fill"
        case .combo100: return "bolt.fill"
        case .hardClear: return "mountain.2.fill"
        case .fiveSongs: return "square.stack.3d.up.fill"
        case .allSamples: return "books.vertical.fill"
        case .streak3: return "calendar"
        case .streak7: return "calendar.badge.checkmark"
        case .practice: return "figure.mind.and.body"
        case .ownKey: return "arrow.up.arrow.down"
        case .songOfTheDay: return "sun.max.fill"
        }
    }
}

public enum Achievements {
    /// Every badge earned so far, with the run that earned it (the first one that qualified, in history order).
    public static func earned(_ records: [GameRecord], calendar: Calendar = .current) -> [Badge: UUID] {
        var earned: [Badge: UUID] = [:]
        func award(_ badge: Badge, _ record: GameRecord) {
            if earned[badge] == nil { earned[badge] = record.id }
        }
        var finished = 0
        var songs = Set<String>()
        var samples = Set<BuiltInKind>()
        let sampleKinds = Set(BuiltInKind.allCases.filter { !$0.isOriginal })
        var builtInByID: [String: BuiltInKind] = [:]
        for kind in BuiltInKind.allCases {
            for difficulty in Difficulty.allCases { builtInByID[BuiltInSongs.id(kind, difficulty)] = kind }
        }
        var lastDay: Int?
        var streak = 0
        for record in records {
            // Streaks count any run, finished or not.
            let day = DailySong.dayNumber(record.date, calendar: calendar)
            if day != lastDay {
                streak = (lastDay.map { day == $0 + 1 } ?? false) ? streak + 1 : 1
                lastDay = day
                if streak >= 3 { award(.streak3, record) }
                if streak >= 7 { award(.streak7, record) }
            }
            guard !record.failed else { continue }
            finished += 1
            award(.firstSong, record)
            if finished >= 10 { award(.tenRuns, record) }
            if finished >= 50 { award(.fiftyRuns, record) }
            if record.maxCombo >= 25 { award(.combo25, record) }
            if record.maxCombo >= 100 { award(.combo100, record) }
            let kind = builtInByID[record.songID]
            songs.insert(kind.map { "builtin.\($0.rawValue)" } ?? record.songID)
            if songs.count >= 5 { award(.fiveSongs, record) }
            if let kind, sampleKinds.contains(kind) {
                samples.insert(kind)
                if samples.count == sampleKinds.count { award(.allSamples, record) }
            }
            if record.practice { award(.practice, record) }
            if record.transpose != 0 { award(.ownKey, record) }
            if DailySong.isDailySong(record.songID, on: record.date, calendar: calendar) { award(.songOfTheDay, record) }
            guard !record.practice else { continue }
            if record.grade == .a || record.grade == .s { award(.gradeA, record) }
            if record.grade == .s { award(.gradeS, record) }
            if record.difficulty == .hard { award(.hardClear, record) }
        }
        return earned
    }

    /// Badges in `after` that weren't in `before` (e.g. the history before and after one run), in badge order.
    public static func newlyEarned(before: [GameRecord], after: [GameRecord], calendar: Calendar = .current) -> [Badge] {
        let old = earned(before, calendar: calendar)
        let new = earned(after, calendar: calendar)
        return Badge.allCases.filter { new[$0] != nil && old[$0] == nil }
    }
}
