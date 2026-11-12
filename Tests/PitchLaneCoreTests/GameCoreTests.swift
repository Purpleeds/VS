import XCTest
import PitchLaneCore

final class GameClockTests: XCTestCase {
    func testCountdownPlayPauseResumeFinish() {
        var clock = GameClock(songDuration: 10)
        XCTAssertEqual(clock.phase(at: 0), .notStarted)
        XCTAssertEqual(clock.songTime(at: 0), -3)

        clock.start(at: 100)
        XCTAssertEqual(clock.songTime(at: 100), -3)
        XCTAssertEqual(clock.songTime(at: 101.5), -1.5)
        XCTAssertEqual(clock.phase(at: 101.5), .countdown)
        XCTAssertEqual(clock.countdown(at: 100.2), 3)
        XCTAssertEqual(clock.countdown(at: 101.5), 2)
        XCTAssertEqual(clock.countdown(at: 102.9), 1)
        XCTAssertEqual(clock.phase(at: 103), .playing)
        XCTAssertNil(clock.countdown(at: 103))
        XCTAssertEqual(clock.songTime(at: 104), 1, accuracy: 1e-12)

        clock.pause(at: 104)
        XCTAssertEqual(clock.phase(at: 110), .paused)
        XCTAssertEqual(clock.songTime(at: 110), 1, accuracy: 1e-12)
        XCTAssertNil(clock.countdown(at: 110))
        clock.pause(at: 111)
        XCTAssertEqual(clock.songTime(at: 112), 1, accuracy: 1e-12, "second pause changes nothing")

        clock.resume(at: 110)
        XCTAssertEqual(clock.phase(at: 110.5), .countdown)
        XCTAssertEqual(clock.countdown(at: 110.5), 3)
        XCTAssertEqual(clock.countdown(at: 112.2), 1)
        XCTAssertEqual(clock.songTime(at: 112.9), 1, accuracy: 1e-12, "frozen during the resume countdown")
        XCTAssertEqual(clock.songTime(at: 113.5), 1.5, accuracy: 1e-12)
        XCTAssertEqual(clock.phase(at: 113.5), .playing)

        XCTAssertEqual(clock.endTime, 11.5)
        XCTAssertEqual(clock.phase(at: 113 + 10.5), .finished)
    }

    func testIsAdvancing() {
        var clock = GameClock(songDuration: 5)
        XCTAssertFalse(clock.isAdvancing(at: 0))
        clock.start(at: 10)
        XCTAssertTrue(clock.isAdvancing(at: 10.5), "song time runs during the start countdown")
        clock.pause(at: 11)
        XCTAssertFalse(clock.isAdvancing(at: 12))
        clock.resume(at: 12)
        XCTAssertFalse(clock.isAdvancing(at: 14), "frozen during the resume countdown")
        XCTAssertTrue(clock.isAdvancing(at: 15.1))
    }

    func testAnchorForTheAudioThread() throws {
        var clock = GameClock(songDuration: 5)
        XCTAssertNil(clock.anchor)
        clock.start(at: 10)
        var anchor = try XCTUnwrap(clock.anchor)
        XCTAssertEqual(anchor.time, 10)
        XCTAssertEqual(anchor.songTime, -3)
        clock.pause(at: 12)
        anchor = try XCTUnwrap(clock.anchor)
        XCTAssertEqual(anchor.time, .infinity, "paused: song time never advances")
        XCTAssertEqual(anchor.songTime, -1, accuracy: 1e-12)
        clock.resume(at: 20)
        anchor = try XCTUnwrap(clock.anchor)
        XCTAssertEqual(anchor.time, 23)
    }

    func testResumeWithoutPauseIsIgnored() {
        var clock = GameClock(songDuration: 5)
        clock.start(at: 0)
        clock.resume(at: 4)
        XCTAssertEqual(clock.songTime(at: 4), 1, accuracy: 1e-12)
    }
}

final class StreamClockMapperTests: XCTestCase {
    func testTracksTheLeastDelayedDelivery() throws {
        var mapper = StreamClockMapper()
        XCTAssertNil(mapper.hostTime(forStream: 1))
        mapper.observe(streamTime: 1.00, hostTime: 101.05)
        mapper.observe(streamTime: 1.02, hostTime: 101.06)
        mapper.observe(streamTime: 1.04, hostTime: 101.10)
        let offset = try XCTUnwrap(mapper.offset)
        XCTAssertEqual(offset, 100.04 + 0.002 * 0.02, accuracy: 1e-9)
        XCTAssertEqual(mapper.hostTime(forStream: 2) ?? 0, 2 + offset, accuracy: 1e-12)
    }

    func testCreepsUpWhenDelayGrows() throws {
        var mapper = StreamClockMapper()
        mapper.observe(streamTime: 0, hostTime: 10.01)
        for i in 1...1_000 {
            let stream = Double(i) * 0.01
            mapper.observe(streamTime: stream, hostTime: stream + 10.06) // delay now 50 ms longer
        }
        let offset = try XCTUnwrap(mapper.offset)
        XCTAssertEqual(offset, 10.01 + 0.002 * 10, accuracy: 1e-6)
    }

    func testResetsWhenStreamRestarts() {
        var mapper = StreamClockMapper()
        mapper.observe(streamTime: 30, hostTime: 130.02)
        mapper.observe(streamTime: 0.1, hostTime: 200)
        XCTAssertEqual(mapper.offset ?? 0, 199.9, accuracy: 1e-9)
    }
}

final class FrameRateMeterTests: XCTestCase {
    func testMeasuresFPSAndWorstFrame() {
        var meter = FrameRateMeter()
        for i in 0..<240 { meter.tick(at: Double(i) / 120) }
        XCTAssertEqual(meter.framesPerSecond, 120, accuracy: 0.5)
        XCTAssertEqual(meter.worstFrameInterval, 1.0 / 120, accuracy: 1e-6)
        meter.tick(at: 2 + 0.05)
        XCTAssertEqual(meter.worstFrameInterval, 0.05 + 1.0 / 120, accuracy: 1e-6)
    }
}

final class PitchFoldingTests: XCTestCase {
    func testErrorCents() {
        XCTAssertEqual(PitchFolding.errorCents(sung: 61, target: 60, octaveAgnostic: false), 100, accuracy: 1e-9)
        XCTAssertEqual(PitchFolding.errorCents(sung: 48, target: 60, octaveAgnostic: true), 0, accuracy: 1e-9)
        XCTAssertEqual(PitchFolding.errorCents(sung: 48, target: 60, octaveAgnostic: false), -1_200, accuracy: 1e-9)
        XCTAssertEqual(PitchFolding.errorCents(sung: 59.4, target: 72, octaveAgnostic: true), -60, accuracy: 1e-9)
        XCTAssertEqual(PitchFolding.errorCents(sung: 59.4, target: 72, octaveAgnostic: false), -1_260, accuracy: 1e-9)
    }

    func testFold() {
        XCTAssertEqual(PitchFolding.fold(48.2, toward: 60), 60.2, accuracy: 1e-9)
        XCTAssertEqual(PitchFolding.fold(66.5, toward: 60), 54.5, accuracy: 1e-9)
        XCTAssertEqual(PitchFolding.fold(84, toward: 60), 60, accuracy: 1e-9)
    }
}

final class ScoreKeeperTests: XCTestCase {
    /// A (0-1 s, C4), B (1.5-2.5 s, E4, golden), C (3-3.5 s, G4), freestyle D (4-5 s).
    private let song = Song(id: "t", title: "T", source: .builtIn, notes: [
        SongNote(start: 0, duration: 1, pitch: 60, lyric: "a"),
        SongNote(start: 1.5, duration: 1, pitch: 64, lyric: "b", isGolden: true),
        SongNote(start: 3, duration: 0.5, pitch: 67, lyric: "c"),
        SongNote(start: 4, duration: 1, pitch: 40, lyric: "d", isFreestyle: true),
    ])

    private func target(_ song: Song, at t: Double) -> Double? {
        song.notes.firstIndex { t >= $0.start && t <= $0.end }.map { song.targetPitch(noteAt: $0, time: t) }
    }

    private func play(_ song: Song, _ rules: ScoringRules, sung: (Double) -> Double?) -> ScoreKeeper {
        var keeper = ScoreKeeper(song: song, rules: rules)
        let frames = Int((song.duration + 1) * 100)
        for i in 0..<frames {
            let t = -0.5 + Double(i) * 0.01
            keeper.add(time: t, midi: sung(t))
        }
        keeper.finish()
        return keeper
    }

    func testPerfectSinging() {
        let keeper = play(song, ScoringRules(difficulty: .normal)) { self.target(self.song, at: $0) }
        XCTAssertEqual(keeper.scoredNoteCount, 3, "freestyle notes are not scored")
        XCTAssertEqual(keeper.results.map(\.rating), [.perfect, .perfect, .perfect])
        XCTAssertEqual(keeper.results.map(\.fraction), [1, 1, 1])
        // A: 100 x length 2 = 200. B: 100 x 2 x golden 2 = 400. C: 100 x 1 = 100.
        XCTAssertEqual(keeper.results.map(\.points), [200, 400, 100])
        XCTAssertEqual(keeper.score, 700)
        XCTAssertEqual(keeper.combo, 3)
        XCTAssertEqual(keeper.maxCombo, 3)
        XCTAssertEqual(keeper.accuracy, 1, accuracy: 1e-12)
        XCTAssertEqual(keeper.grade, .s)
        XCTAssertEqual(keeper.counts[.perfect], 3)
        XCTAssertTrue(keeper.isComplete)
    }

    func testOctaveAgnosticOption() {
        let lowVoice: (Double) -> Double? = { self.target(self.song, at: $0).map { $0 - 12 } }
        let agnostic = play(song, ScoringRules(difficulty: .hard, octaveAgnostic: true), sung: lowVoice)
        XCTAssertEqual(agnostic.results.map(\.rating), [.perfect, .perfect, .perfect])
        let strict = play(song, ScoringRules(difficulty: .easy, octaveAgnostic: false), sung: lowVoice)
        XCTAssertEqual(strict.results.map(\.rating), [.miss, .miss, .miss])
        XCTAssertEqual(strict.score, 0)
        XCTAssertEqual(strict.combo, 0)
        XCTAssertEqual(strict.grade, .f)
    }

    func testTolerancePerDifficulty() {
        func rating(_ difficulty: Difficulty, offsetCents: Double) -> NoteRating? {
            play(song, ScoringRules(difficulty: difficulty)) { self.target(self.song, at: $0).map { $0 + offsetCents / 100 } }.results.first?.rating
        }
        XCTAssertEqual(rating(.easy, offsetCents: 90), .perfect)
        XCTAssertEqual(rating(.easy, offsetCents: 110), .miss)
        XCTAssertEqual(rating(.normal, offsetCents: -45), .perfect)
        XCTAssertEqual(rating(.normal, offsetCents: 60), .miss)
        XCTAssertEqual(rating(.hard, offsetCents: 20), .perfect)
        XCTAssertEqual(rating(.hard, offsetCents: -30), .miss)
    }

    func testPartialNoteGetsMiddleRatingAndComboRules() {
        // On pitch for the first ~55% of note A, then badly off; silent for B; perfect on C.
        let keeper = play(song, ScoringRules(difficulty: .normal)) { t in
            if t < 0.6 { return 60 }
            if t < 1.2 { return 63 }
            if t > 2.8 { return self.target(self.song, at: t) }
            return nil
        }
        XCTAssertEqual(keeper.results.map(\.rating), [.good, .miss, .perfect])
        XCTAssertEqual(keeper.results[0].fraction, 0.57, accuracy: 0.03)
        XCTAssertEqual(keeper.maxCombo, 1)
        XCTAssertEqual(keeper.combo, 1)
        XCTAssertLessThan(keeper.accuracy, 0.6)
    }

    func testAttackGraceIgnoresTheFirstMoment() {
        let keeper = play(song, ScoringRules(difficulty: .hard)) { t in
            if let note = self.song.notes.first(where: { t >= $0.start && t <= $0.end }), t < note.start + 0.04 {
                return Double(note.pitch) + 2 // scoop in from below... or above
            }
            return self.target(self.song, at: t)
        }
        XCTAssertEqual(keeper.results.map(\.rating), [.perfect, .perfect, .perfect])
    }

    func testMultiplierGrowsWithCombo() {
        let notes = (0..<35).map { SongNote(start: Double($0) * 0.5, duration: 0.4, pitch: 60 + $0 % 5) }
        let long = Song(id: "m", title: "M", source: .builtIn, notes: notes)
        let keeper = play(long, ScoringRules(difficulty: .normal)) { self.target(long, at: $0) }
        XCTAssertEqual(keeper.results.count, 35)
        XCTAssertEqual(keeper.results[0].multiplier, 1)
        XCTAssertEqual(keeper.results[9].multiplier, 1)
        XCTAssertEqual(keeper.results[10].multiplier, 2)
        XCTAssertEqual(keeper.results[20].multiplier, 3)
        XCTAssertEqual(keeper.results[30].multiplier, 4)
        XCTAssertEqual(keeper.multiplier, 4)
        // 0.4 s notes: length factor 0.8 -> 80 points x multiplier.
        XCTAssertEqual(keeper.results[10].points, 160)
        XCTAssertEqual(keeper.maxCombo, 35)
    }

    func testSlidesAreScoredAgainstTheGlide() {
        let slide = Song(id: "s", title: "S", source: .builtIn, notes: [
            SongNote(start: 0, duration: 0.5, pitch: 60),
            SongNote(start: 0.5, duration: 2, pitch: 72, slidesFromPrevious: true),
        ])
        let following = play(slide, ScoringRules(difficulty: .normal)) { self.target(slide, at: $0) }
        XCTAssertEqual(following.results.map(\.rating), [.perfect, .perfect])
        let flat = play(slide, ScoringRules(difficulty: .normal, octaveAgnostic: false)) { t in t <= 0.5 ? 60 : 72 }
        XCTAssertNotEqual(flat.results.last?.rating, .perfect)
    }

    func testFinishRatesUnsungNotesAsMisses() {
        var keeper = ScoreKeeper(song: song, rules: ScoringRules(difficulty: .normal))
        for i in 0..<50 { keeper.add(time: Double(i) * 0.01, midi: 60) }
        XCTAssertTrue(keeper.results.isEmpty, "note A is still going")
        let finished = keeper.finish()
        XCTAssertEqual(finished.count, 3)
        XCTAssertEqual(finished.map(\.rating), [.perfect, .miss, .miss], "a note cut short is rated on what was sung")
        XCTAssertTrue(keeper.finish().isEmpty)
    }

    func testLastEvaluationReportsOnPitch() {
        var keeper = ScoreKeeper(song: song, rules: ScoringRules(difficulty: .normal))
        keeper.add(time: 0.5, midi: 60.1)
        XCTAssertEqual(keeper.lastEvaluation?.noteIndex, 0)
        XCTAssertEqual(keeper.lastEvaluation?.onPitch, true)
        keeper.add(time: 0.6, midi: 62)
        XCTAssertEqual(keeper.lastEvaluation?.onPitch, false)
    }

    func testRatingAndGradeThresholds() {
        XCTAssertEqual(NoteRating(fraction: 1), .perfect)
        XCTAssertEqual(NoteRating(fraction: 0.9), .perfect)
        XCTAssertEqual(NoteRating(fraction: 0.89), .great)
        XCTAssertEqual(NoteRating(fraction: 0.75), .great)
        XCTAssertEqual(NoteRating(fraction: 0.5), .good)
        XCTAssertEqual(NoteRating(fraction: 0.3), .meh)
        XCTAssertEqual(NoteRating(fraction: 0.2), .miss)
        XCTAssertEqual(Grade(accuracy: 0.96), .s)
        XCTAssertEqual(Grade(accuracy: 0.9), .a)
        XCTAssertEqual(Grade(accuracy: 0.7), .b)
        XCTAssertEqual(Grade(accuracy: 0.6), .c)
        XCTAssertEqual(Grade(accuracy: 0.45), .d)
        XCTAssertEqual(Grade(accuracy: 0.1), .f)
        XCTAssertEqual(ScoreKeeper.lengthFactor(0.1), 0.5)
        XCTAssertEqual(ScoreKeeper.lengthFactor(10), 4)
    }

    func testResultAndPersonalBests() throws {
        let keeper = play(song, ScoringRules(difficulty: .normal)) { self.target(self.song, at: $0) }
        let result = keeper.result(songID: "t", songTitle: "T", date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(result.score, 700)
        XCTAssertEqual(result.grade, .s)
        XCTAssertEqual(result.noteCount, 3)
        XCTAssertEqual(result.counts[.perfect], 3)

        var bests = PersonalBests()
        XCTAssertTrue(bests.record(result))
        var worse = result
        worse.score = 500
        XCTAssertFalse(bests.record(worse))
        var better = result
        better.score = 900
        XCTAssertTrue(bests.record(better))
        XCTAssertEqual(bests.best(songID: "t", difficulty: .normal)?.score, 900)
        XCTAssertNil(bests.best(songID: "t", difficulty: .hard))
        var hard = result
        hard.difficulty = .hard
        XCTAssertTrue(bests.record(hard), "difficulties are tracked separately")

        let data = try JSONEncoder().encode(bests)
        XCTAssertEqual(try JSONDecoder().decode(PersonalBests.self, from: data), bests)
        let resultData = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(GameResult.self, from: resultData), result)

        bests.remove(songID: "t")
        XCTAssertTrue(bests.records.isEmpty)
    }

    func testReplayTraceDownsamplesButKeepsGaps() {
        var trace = ReplayTrace(minimumInterval: 0.02)
        for i in 0..<100 {
            let t = Double(i) * 0.01
            trace.append(time: t, midi: (40..<45).contains(i) ? nil : 60)
        }
        XCTAssertLessThan(trace.points.count, 60)
        XCTAssertTrue(trace.points.contains { $0.midi == nil })
        XCTAssertEqual(trace.points.first?.time, 0)
        trace.append(time: 0.5, midi: 60)
        XCTAssertNotEqual(trace.points.last?.time, 0.5, "time going backwards is ignored")
    }
}

final class LaneViewportTests: XCTestCase {
    private func song(_ notes: [(Double, Double, Int)]) -> Song {
        Song(id: "v", title: "V", source: .builtIn, notes: notes.map { SongNote(start: $0.0, duration: $0.1, pitch: $0.2) })
    }

    func testNoteIndex() {
        let s = song([(0, 1, 60), (2, 4, 62), (3, 0.5, 64), (7, 1, 65)])
        let index = NoteIndex(song: s)
        XCTAssertEqual(index.indices(overlapping: 4, 4.5), [1])
        XCTAssertEqual(index.indices(overlapping: 5, 7.2), [1, 3])
        XCTAssertEqual(index.indices(overlapping: 8.5, 9), [])
        XCTAssertEqual(index.indices(overlapping: -1, 0.5), [0])
        XCTAssertEqual(index.indices(overlapping: 0, 100), [0, 1, 2, 3])
        XCTAssertEqual(NoteIndex(song: song([])).indices(overlapping: 0, 1), [])
    }

    func testNarrowSongFitsWithMinimumSpan() {
        let viewport = LaneViewport(song: song([(0, 1, 60), (1, 1, 64)]))
        XCTAssertFalse(viewport.pans)
        XCTAssertEqual(viewport.fullRange, 56...68)
        XCTAssertEqual(viewport.windowSpan, 12)
        XCTAssertEqual(viewport.targetCenter(at: 0), 62)
        XCTAssertEqual(viewport.range(center: 80), 56...68)
    }

    func testMediumSongFitsWithMargin() {
        let viewport = LaneViewport(song: song([(0, 1, 55), (1, 1, 72)]))
        XCTAssertFalse(viewport.pans)
        XCTAssertEqual(viewport.fullRange, 52...75)
    }

    func testWideSongPansToNearbyNotes() {
        let viewport = LaneViewport(song: song([(0, 1, 40), (5, 1, 60), (10, 1, 80)]))
        XCTAssertTrue(viewport.pans)
        XCTAssertEqual(viewport.fullRange, 37...83)
        XCTAssertEqual(viewport.windowSpan, 26)
        XCTAssertEqual(viewport.targetCenter(at: 0), 50, "clamped so the window stays inside the song range")
        XCTAssertEqual(viewport.targetCenter(at: 4.5), 60)
        XCTAssertEqual(viewport.targetCenter(at: 7), 70)
        XCTAssertEqual(viewport.targetCenter(at: 20), 70)
        XCTAssertEqual(viewport.range(center: 60), 47...73)
    }

    func testSmootherIsFrameRateIndependent() throws {
        var a = ViewportSmoother(timeConstant: 0.6)
        XCTAssertEqual(a.update(target: 60, dt: 0.016), 60, "first update snaps")
        a.update(target: 70, dt: 0.6)
        XCTAssertEqual(try XCTUnwrap(a.value), 60 + 10 * (1 - exp(-1)), accuracy: 1e-9)

        var b = ViewportSmoother(timeConstant: 0.6)
        b.update(target: 60, dt: 0)
        for _ in 0..<72 { b.update(target: 70, dt: 0.6 / 72) }
        XCTAssertEqual(try XCTUnwrap(b.value), try XCTUnwrap(a.value), accuracy: 1e-9)

        for _ in 0..<600 { b.update(target: 70, dt: 1.0 / 120) }
        XCTAssertEqual(try XCTUnwrap(b.value), 70, accuracy: 0.01)
    }
}
