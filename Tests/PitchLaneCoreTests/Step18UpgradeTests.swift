import XCTest
import PitchLaneCore

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// 14 November 2026, noon UTC.
private let day0 = Date(timeIntervalSince1970: 1_794_657_600)

private func makeRun(
    _ songID: String, day: Int = 0, grade: Grade = .c, accuracy: Double = 0.5, combo: Int = 5, difficulty: Difficulty = .normal,
    practice: Bool = false, failed: Bool = false, transpose: Int = 0, score: Int = 1_000, minutes: Double = 0
) -> GameRecord {
    GameRecord(
        songID: songID, songTitle: songID, difficulty: difficulty, date: day0.addingTimeInterval(Double(day) * 86_400 + minutes * 60),
        score: score, accuracy: accuracy, grade: grade, maxCombo: combo, practice: practice, speed: practice ? 0.8 : 1,
        failed: failed, transpose: transpose
    )
}

final class DailySongTests: XCTestCase {
    func testOneSongADayThatChangesEveryDayAndCyclesThroughAll() {
        let morning = day0.addingTimeInterval(-11 * 3_600), evening = day0.addingTimeInterval(11 * 3_600)
        XCTAssertEqual(DailySong.kind(for: morning, calendar: utc), DailySong.kind(for: evening, calendar: utc))
        let picks = (0..<BuiltInKind.allCases.count).map { DailySong.kind(for: day0.addingTimeInterval(Double($0) * 86_400), calendar: utc) }
        XCTAssertEqual(Set(picks).count, BuiltInKind.allCases.count)
        for (a, b) in zip(picks, picks.dropFirst()) { XCTAssertNotEqual(a, b) }
        let kind = DailySong.kind(for: day0, calendar: utc)
        for difficulty in Difficulty.allCases {
            XCTAssertTrue(DailySong.isDailySong(BuiltInSongs.id(kind, difficulty), on: day0, calendar: utc))
        }
        XCTAssertFalse(DailySong.isDailySong("my-upload", on: day0, calendar: utc))
    }

    func testTheBonusGoesToTheFirstFinishOfEachDay() {
        let today = BuiltInSongs.id(DailySong.kind(for: day0, calendar: utc), .normal)
        let tomorrowsSong = BuiltInSongs.id(DailySong.kind(for: day0.addingTimeInterval(86_400), calendar: utc), .hard)
        let failed = makeRun(today, failed: true, minutes: 1)
        let first = makeRun(today, minutes: 2)
        let again = makeRun(today, minutes: 3)
        let otherDay = makeRun(today, day: 1) // yesterday's pick isn't today's
        let tomorrow = makeRun(tomorrowsSong, day: 1)
        let bonus = DailySong.bonusRecords([failed, first, again, otherDay, tomorrow], calendar: utc)
        XCTAssertEqual(bonus, Set([first.id, tomorrow.id]))
        XCTAssertFalse(DailySong.isDone(records: [failed], on: day0, calendar: utc))
        XCTAssertTrue(DailySong.isDone(records: [failed, first], on: day0, calendar: utc))

        var history = GameHistory()
        history.add(first)
        // 10 + 50 (accuracy) + 50 bonus.
        XCTAssertEqual(PlayerProgress(history: history, now: day0, calendar: utc).experience, 110)
    }
}

final class AchievementTests: XCTestCase {
    func testBadgesFromTheHistory() {
        XCTAssertTrue(Achievements.earned([], calendar: utc).isEmpty)
        let failed = makeRun("a", failed: true)
        XCTAssertNil(Achievements.earned([failed], calendar: utc)[.firstSong])
        let first = makeRun("a", minutes: 1)
        let practiceA = makeRun("b", grade: .a, practice: true, minutes: 2)
        let fullS = makeRun("c", grade: .s, combo: 120, difficulty: .hard, transpose: -2, minutes: 3)
        let earned = Achievements.earned([failed, first, practiceA, fullS], calendar: utc)
        XCTAssertEqual(earned[.firstSong], first.id)
        XCTAssertEqual(earned[.practice], practiceA.id)
        XCTAssertEqual(earned[.gradeA], fullS.id) // the practice A doesn't count
        XCTAssertEqual(earned[.gradeS], fullS.id)
        XCTAssertEqual(earned[.combo25], fullS.id)
        XCTAssertEqual(earned[.combo100], fullS.id)
        XCTAssertEqual(earned[.hardClear], fullS.id)
        XCTAssertEqual(earned[.ownKey], fullS.id)
        XCTAssertNil(earned[.tenRuns])
        XCTAssertNil(earned[.fiveSongs])
    }

    func testCountsSongsStreaksAndTheSongbook() {
        // Twinkle on two difficulties counts as one song.
        var records = [
            makeRun(BuiltInSongs.id(.twinkle, .easy)), makeRun(BuiltInSongs.id(.twinkle, .hard), minutes: 1),
            makeRun("x", minutes: 2), makeRun("y", minutes: 3), makeRun("z", minutes: 4),
        ]
        XCTAssertNil(Achievements.earned(records, calendar: utc)[.fiveSongs])
        records.append(makeRun("w", minutes: 5))
        XCTAssertEqual(Achievements.earned(records, calendar: utc)[.fiveSongs], records.last?.id)

        let samples = BuiltInKind.allCases.filter { !$0.isOriginal }.enumerated().map { index, kind in
            makeRun(BuiltInSongs.id(kind, .normal), minutes: Double(index))
        }
        XCTAssertEqual(Achievements.earned(samples, calendar: utc)[.allSamples], samples.last?.id)
        XCTAssertNil(Achievements.earned(Array(samples.dropLast()), calendar: utc)[.allSamples])

        let tenth = (0..<10).map { makeRun("s\($0)", minutes: Double($0)) }
        XCTAssertEqual(Achievements.earned(tenth, calendar: utc)[.tenRuns], tenth.last?.id)

        // Days 0, 1, (gap), 3, 4, 5: the streak of three is earned on day 5.
        let streak = [0, 1, 3, 4, 5].map { makeRun("s", day: $0, failed: $0 == 4) }
        let earned = Achievements.earned(streak, calendar: utc)
        XCTAssertEqual(earned[.streak3], streak.last?.id)
        XCTAssertNil(earned[.streak7])
    }

    func testOnlyTheBadgesOfTheNewRunAreNew() {
        let before = [makeRun("a")]
        let daily = makeRun(BuiltInSongs.id(DailySong.kind(for: day0, calendar: utc), .normal), grade: .a, combo: 30, minutes: 1)
        let new = Achievements.newlyEarned(before: before, after: before + [daily], calendar: utc)
        XCTAssertEqual(new, [.gradeA, .combo25, .songOfTheDay])
        XCTAssertEqual(Achievements.newlyEarned(before: before + [daily], after: before + [daily], calendar: utc), [])
        for badge in Badge.allCases {
            XCTAssertFalse(badge.title.isEmpty)
            XCTAssertFalse(badge.detail.isEmpty)
            XCTAssertFalse(badge.symbol.isEmpty)
        }
    }
}

final class LineReportTests: XCTestCase {
    /// Two lines of three notes (C4), the second sung mostly off pitch.
    private func playedSong(lyrics: [String] = ["Twin", "kle", "star", "up", "a", "bove"], breaks: [Double] = [3])
        -> (song: Song, results: [NoteResult]) {
        let starts = [0.0, 0.8, 1.6, 4.0, 4.8, 5.6]
        let notes = zip(starts, lyrics).map { SongNote(start: $0, duration: 0.6, pitch: 60, lyric: $1) }
        let song = Song(id: "lines", title: "Lines", source: .ultraStar, notes: notes, lineBreaks: breaks)
        var keeper = ScoreKeeper(song: song, rules: ScoringRules(difficulty: .normal))
        var results: [NoteResult] = []
        var t = 0.0
        while t < 7 {
            // First line on pitch; second line on pitch only for the first fifth of each note.
            let note = notes.last { $0.start <= t }
            var midi: Double? = 60
            if let note, note.start >= 3, t - note.start > 0.12 { midi = 66 }
            results += keeper.add(time: t, midi: midi)
            t += 0.01
        }
        results += keeper.finish()
        return (song, results)
    }

    func testFindsTheWeakestLineAndItsPracticeLoop() throws {
        let (song, results) = playedSong()
        let report = LineReport(song: song, results: results)
        XCTAssertEqual(report.lines.count, 2)
        XCTAssertGreaterThan(report.lines[0].accuracy, 0.9)
        XCTAssertLessThan(report.lines[1].accuracy, 0.5)
        XCTAssertEqual(report.lines[0].text, "Twin kle star")
        let toughest = try XCTUnwrap(report.toughest)
        XCTAssertEqual(toughest.text, "up a bove")
        XCTAssertEqual(toughest.start, 4)
        XCTAssertEqual(toughest.end, 6.2, accuracy: 1e-9)
        let practice = LineReport.practice(for: toughest)
        XCTAssertEqual(practice.loop?.lowerBound ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(practice.loop?.upperBound ?? 0, 6.7, accuracy: 1e-9)
        XCTAssertEqual(practice.speed, 0.8)
        XCTAssertTrue(practice.noFail)
    }

    func testSongSpacingIsKeptAndLinesComeFromPausesWithoutBreaks() {
        let (song, results) = playedSong(lyrics: ["Twin", "kle ", "star", "up ", "a", "bove"], breaks: [])
        let report = LineReport(song: song, results: results)
        XCTAssertEqual(report.lines.map(\.text), ["Twinkle star", "up above"])
    }

    func testAGoodRunHasNoToughestLine() {
        let notes = (0..<6).map { SongNote(start: Double($0) * 0.8, duration: 0.6, pitch: 60) }
        let song = Song(id: "good", title: "Good", source: .ultraStar, notes: notes)
        var keeper = ScoreKeeper(song: song, rules: ScoringRules(difficulty: .normal))
        var results: [NoteResult] = []
        for step in 0..<600 { results += keeper.add(time: Double(step) * 0.01, midi: 60) }
        results += keeper.finish()
        XCTAssertNil(LineReport(song: song, results: results).toughest)
        XCTAssertTrue(LineReport(song: Song(id: "e", title: "E", source: .ultraStar, notes: []), results: []).lines.isEmpty)
    }

    func testShortLinesStillGetAFullLoop() throws {
        let notes = [10.0, 10.1, 10.2].map { SongNote(start: $0, duration: 0.1, pitch: 60) }
        let song = Song(id: "short", title: "Short", source: .ultraStar, notes: notes)
        var keeper = ScoreKeeper(song: song, rules: ScoringRules(difficulty: .normal))
        var results: [NoteResult] = []
        for step in 900..<1_100 { results += keeper.add(time: Double(step) * 0.01, midi: 70) }
        results += keeper.finish()
        let line = try XCTUnwrap(LineReport(song: song, results: results).lines.first)
        let loop = LineReport.practice(for: line).loop
        XCTAssertEqual(loop?.lowerBound ?? 0, 8.5, accuracy: 1e-9)
        XCTAssertEqual(loop?.upperBound ?? 0, 11.5, accuracy: 1e-9)
    }
}

final class LibraryOrderTests: XCTestCase {
    private func song(_ id: String, _ title: String) -> Song {
        Song(id: id, title: title, source: .ultraStar, notes: [SongNote(start: 0, duration: 1, pitch: 60)])
    }

    func testSortOrders() {
        let songs = [song("1", "song 10"), song("2", "Song 2"), song("3", "Ápple"), song("4", "banana")]
        var history = GameHistory()
        history.add(makeRun("4", score: 500, minutes: 0))
        history.add(makeRun("2", score: 900, minutes: 1))
        history.add(makeRun("4", score: 700, minutes: 2))
        XCTAssertEqual(LibrarySort.title.sorted(songs, history: history).map(\.id), ["3", "4", "2", "1"])
        XCTAssertEqual(LibrarySort.recentlyPlayed.sorted(songs, history: history).map(\.id), ["4", "2", "3", "1"])
        XCTAssertEqual(LibrarySort.mostPlayed.sorted(songs, history: history).map(\.id), ["4", "2", "3", "1"])
        XCTAssertEqual(LibrarySort.bestScore.sorted(songs, history: history).map(\.id), ["2", "4", "3", "1"])
        XCTAssertEqual(LibrarySort.mostPlayed.sorted(songs, history: GameHistory()).map(\.id), ["3", "4", "2", "1"])
    }

    func testFavouritesAndSortAreSavedSettings() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.favoriteSongs, [])
        XCTAssertEqual(settings.librarySort, .title)
        settings.toggleFavorite("a")
        settings.toggleFavorite(AppSettings.favoriteKey(.twinkle))
        XCTAssertEqual(settings.favoriteSongs, ["builtin.twinkle", "a"])
        XCTAssertTrue(settings.isFavorite("a"))
        settings.toggleFavorite("a")
        XCTAssertFalse(settings.isFavorite("a"))
        settings.librarySort = .bestScore
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.favoriteSongs, ["builtin.twinkle"])
        XCTAssertEqual(back.librarySort, .bestScore)
        let messy = #"{"favoriteSongs":["x",7,"x","",null,"y"],"librarySort":"sideways"}"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(messy.utf8))
        XCTAssertEqual(decoded.favoriteSongs, ["x", "y"])
        XCTAssertEqual(decoded.librarySort, .title)
    }
}
