import XCTest
import PitchLaneCore

final class HangulTests: XCTestCase {
    func testSyllablesAndSoundChanges() {
        XCTAssertEqual(Hangul.romanize(syllables: ["사", "랑", "해"]), ["sa", "rang", "hae"])
        XCTAssertEqual(Hangul.romanize(syllables: ["있", "어"]), ["i", "sseo"])        // liaison
        XCTAssertEqual(Hangul.romanize(syllables: ["읽", "어"]), ["il", "geo"])        // double final splits
        XCTAssertEqual(Hangul.romanize(syllables: ["합", "니", "다"]), ["ham", "ni", "da"]) // nasalization
        XCTAssertEqual(Hangul.romanize(syllables: ["국", "물"]), ["gung", "mul"])
        XCTAssertEqual(Hangul.romanize(syllables: ["신", "라"]), ["sil", "la"])        // ㄴ + ㄹ
        XCTAssertEqual(Hangul.romanize(syllables: ["설", "날"]), ["seol", "lal"])      // ㄹ + ㄴ
        XCTAssertEqual(Hangul.romanize(syllables: ["심", "리"]), ["sim", "ni"])        // ㅁ + ㄹ
        XCTAssertEqual(Hangul.romanize(syllables: ["영", "어"]), ["yeong", "eo"])      // ㅇ final stays
        XCTAssertEqual(Hangul.romanize(syllables: ["좋", "아"]), ["jo", "a"])          // silent ㅎ
        XCTAssertEqual(Hangul.romanize("안녕하세요"), "annyeonghaseyo")
        XCTAssertEqual(Hangul.romanize("꽃"), "kkot")
        XCTAssertEqual(Hangul.romanize(syllables: ["Hi ", "너"]), ["Hi ", "neo"])
        XCTAssertEqual(Hangul.romanize(syllables: []), [])
    }
}

final class LyricScriptTests: XCTestCase {
    func testDetection() {
        XCTAssertEqual(LyricScript.detect(["さくら", "空"]), .japanese)
        XCTAssertEqual(LyricScript.detect(["사랑해", "요"]), .korean)
        XCTAssertEqual(LyricScript.detect(["我爱你"]), .chinese)
        XCTAssertEqual(LyricScript.detect(["hello", "Café"]), .other)
        XCTAssertEqual(LyricScript.korean.speechLocaleIdentifier, "ko-KR")
        XCTAssertNil(LyricScript.other.speechLocaleIdentifier)
    }

    func testUnitsAndHeardUnits() {
        XCTAssertEqual(LyricScript.units(of: "사랑해 baby, 我爱你。"), ["사", "랑", "해", "baby", "我", "爱", "你"])
        let heard = LyricScript.heardUnits("你好", time: 2, duration: 0.5)
        XCTAssertEqual(heard.map(\.text), ["你", "好"])
        XCTAssertEqual(heard[1].time, 2.25, accuracy: 1e-9)
        XCTAssertTrue(LyricScript.heardUnits("...", time: 0, duration: 1).isEmpty)
    }

    func testChinesePinyinPerNote() {
        let syllables = ["我", "爱", "你", "ok"]
        let readings: [String?] = ["wǒ", "ài", "nǐ", nil, nil]
        XCTAssertEqual(ChineseRomanizer.romanize(syllables: syllables, readings: readings), ["wǒ", "ài", "nǐ", "ok"])
        XCTAssertEqual(ChineseRomanizer.romanize(syllables: ["你好"], readings: ["nǐ", "hǎo"]), ["nǐ hǎo"])
        XCTAssertEqual(ChineseRomanizer.romanize(syllables: ["你"], readings: []), ["你"])
    }

    func testFittingJoinsSyllablesWithoutSpaces() {
        let song = Song(id: "k", title: "K", source: .video, notes: [SongNote(start: 1, duration: 0.5, pitch: 60)])
        let result = LyricAligner.applyPlain(lines: [["사", "랑"]], to: song)
        XCTAssertEqual(result.song.notes[0].displayLyric, "사랑")
    }
}

final class PlayerProgressTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func record(daysAgo: Int, accuracy: Double, grade: Grade, failed: Bool = false, now: Date) -> GameRecord {
        GameRecord(songID: "s", songTitle: "S", difficulty: .normal, date: now.addingTimeInterval(-Double(daysAgo) * 86_400),
                   score: 1_000, accuracy: accuracy, grade: grade, maxCombo: 5, failed: failed)
    }

    func testLevelsExperienceAndStreak() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var history = GameHistory()
        XCTAssertEqual(PlayerProgress(history: history, now: now, calendar: calendar).level, 1)
        XCTAssertEqual(PlayerProgress(history: history, now: now, calendar: calendar).streakDays, 0)
        // 10 + 90 + 25 (A) = 125 XP; 10 + 50 = 60; failed run halves without a bonus: (10 + 30) / 2 = 20.
        history.add(record(daysAgo: 2, accuracy: 0.9, grade: .a, now: now))
        history.add(record(daysAgo: 1, accuracy: 0.5, grade: .c, now: now))
        history.add(record(daysAgo: 0, accuracy: 0.3, grade: .f, failed: true, now: now))
        let progress = PlayerProgress(history: history, now: now, calendar: calendar)
        XCTAssertEqual(progress.experience, 205)
        XCTAssertEqual(progress.level, 2)            // 100 for level 1, then 105 of 150 into level 2
        XCTAssertEqual(progress.levelExperience, 105)
        XCTAssertEqual(progress.levelSize, 150)
        XCTAssertEqual(progress.streakDays, 3)
        XCTAssertEqual(progress.runs, 3)
        XCTAssertEqual(progress.bestGrade, .a)
        // A gap breaks the streak; a streak that ended yesterday still counts.
        let later = now.addingTimeInterval(86_400)
        XCTAssertEqual(PlayerProgress(history: history, now: later, calendar: calendar).streakDays, 3)
        XCTAssertEqual(PlayerProgress(history: history, now: later.addingTimeInterval(86_400), calendar: calendar).streakDays, 0)
    }
}
