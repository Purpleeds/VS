import XCTest
import PitchLaneCore

final class VocalRangeTests: XCTestCase {
    func testRangeTextAndSpan() {
        let range = VocalRange(low: 55, high: 72)
        XCTAssertEqual(range.text(accidentals: .sharps), "G3–C5")
        XCTAssertEqual(range.spanText, "1 octave + 5 semitones")
        XCTAssertEqual(VocalRange(low: 48, high: 72).spanText, "2 octaves")
        XCTAssertEqual(VocalRange(low: 60, high: 60).spanText, "0 semitones")
        XCTAssertEqual(VocalRange(low: 72, high: 55), range, "low/high are normalised")
        XCTAssertTrue(range.contains(60))
        XCTAssertFalse(range.contains(73))
    }

    func testNoteHoldDetectorLocksAfterOneSecond() {
        var detector = NoteHoldDetector()
        var locked: Double?
        for i in 0..<130 where locked == nil {
            locked = detector.add(time: Double(i) * 0.01, midi: 57.1 + 0.2 * sin(Double(i) * 0.5))
        }
        XCTAssertNotNil(locked)
        XCTAssertEqual(locked ?? 0, 57.1, accuracy: 0.2)
        XCTAssertEqual(detector.progress, 0, "resets after locking")
    }

    func testProgressGrowsAndResetsOnChangeOrGap() {
        var detector = NoteHoldDetector()
        for i in 0..<50 { _ = detector.add(time: Double(i) * 0.01, midi: 60) }
        XCTAssertEqual(detector.progress, 0.49, accuracy: 0.02)
        _ = detector.add(time: 0.5, midi: 64) // a different note restarts the run
        XCTAssertEqual(detector.progress, 0, accuracy: 1e-9)
        for i in 51..<70 { _ = detector.add(time: Double(i) * 0.01, midi: 64) }
        XCTAssertGreaterThan(detector.progress, 0.15)
        // 0.3 s of silence drops it.
        for i in 70..<100 { _ = detector.add(time: Double(i) * 0.01, midi: nil) }
        XCTAssertEqual(detector.progress, 0)
        XCTAssertNil(detector.current)
    }

    func testShortDropoutDoesNotBreakTheRun() {
        var detector = NoteHoldDetector()
        var locked: Double?
        for i in 0..<120 where locked == nil {
            let missing = (40..<43).contains(i)
            locked = detector.add(time: Double(i) * 0.01, midi: missing ? nil : 62)
        }
        XCTAssertEqual(locked ?? 0, 62, accuracy: 1e-9)
    }

    func testVibratoStillLocks() {
        var detector = NoteHoldDetector()
        var locked: Double?
        for i in 0..<150 where locked == nil {
            let t = Double(i) * 0.01
            locked = detector.add(time: t, midi: 64 + 0.5 * sin(2 * Double.pi * 5 * t))
        }
        XCTAssertEqual(locked ?? 0, 64, accuracy: 0.4)
    }

    private func feed(_ flow: inout RangeTestFlow, from start: Double, seconds: Double, midi: Double?) -> (end: Double, events: [RangeTestEvent]) {
        var events: [RangeTestEvent] = []
        var t = start
        let end = start + seconds
        while t < end {
            if let event = flow.add(time: t, midi: midi) { events.append(event) }
            t += 0.01
        }
        return (end, events)
    }

    func testRangeTestFlow() {
        var flow = RangeTestFlow()
        XCTAssertEqual(flow.stage, .low)
        var (t, events) = feed(&flow, from: 0, seconds: 1.3, midi: 48.2)
        XCTAssertEqual(events, [.lockedLow(48)])
        XCTAssertEqual(flow.stage, .release)

        // Still singing: no progress until the singer stops for 0.6 s.
        var more = feed(&flow, from: t, seconds: 0.5, midi: 48)
        t = more.end
        XCTAssertEqual(flow.stage, .release)
        more = feed(&flow, from: t, seconds: 0.8, midi: nil)
        t = more.end
        XCTAssertEqual(flow.stage, .high)

        more = feed(&flow, from: t, seconds: 1.3, midi: 71.9)
        XCTAssertEqual(more.events, [.finished(VocalRange(low: 48, high: 72))])
        XCTAssertEqual(flow.stage, .done(VocalRange(low: 48, high: 72)))
        XCTAssertEqual(flow.low, 48)
        XCTAssertEqual(flow.high, 72)
    }

    func testHighMustBeAboveLow() {
        var flow = RangeTestFlow()
        var (t, _) = feed(&flow, from: 0, seconds: 1.3, midi: 60)
        t = feed(&flow, from: t, seconds: 0.8, midi: nil).end
        let result = feed(&flow, from: t, seconds: 1.3, midi: 62)
        XCTAssertEqual(result.events, [.highTooLow(sung: 62, low: 60)])
        XCTAssertEqual(flow.stage, .high, "stays on the high note so the singer can try again")
    }

    func testRedoHighKeepsLow() {
        var flow = RangeTestFlow()
        var (t, _) = feed(&flow, from: 0, seconds: 1.3, midi: 50)
        t = feed(&flow, from: t, seconds: 0.8, midi: nil).end
        _ = feed(&flow, from: t, seconds: 1.3, midi: 70)
        flow.redoHigh()
        XCTAssertEqual(flow.stage, .high)
        XCTAssertEqual(flow.low, 50)
        XCTAssertNil(flow.high)
        flow.restart()
        XCTAssertEqual(flow.stage, .low)
        XCTAssertNil(flow.low)
    }
}

final class TransposerTests: XCTestCase {
    private func song(_ pitches: [Int]) -> Song {
        Song(id: "t", title: "T", source: .builtIn, notes: pitches.enumerated().map {
            SongNote(start: Double($0.offset), duration: 0.8, pitch: $0.element, lyric: "la")
        })
    }

    func testTransposedShiftsPitchesOnly() {
        let original = song([60, 64, 67])
        let up = original.transposed(by: 5)
        XCTAssertEqual(up.notes.map(\.pitch), [65, 69, 72])
        XCTAssertEqual(up.notes.map(\.start), original.notes.map(\.start))
        XCTAssertEqual(original.transposed(by: 0), original)
        XCTAssertEqual(song([2]).transposed(by: -12).notes[0].pitch, 0, "clamped to MIDI 0")
        XCTAssertEqual(song([125]).transposed(by: 12).notes[0].pitch, 127)
    }

    func testFitAndBestShift() {
        let tenor = VocalRange(low: 48, high: 69) // C3-A4
        let high = song([60, 72, 79, 81]) // up to A5
        XCTAssertEqual(SongTransposer.fit(of: high, in: tenor), .outside(below: 0, above: 3))
        XCTAssertEqual(SongTransposer.fit(of: high, shift: -12, in: tenor), .fits)
        XCTAssertEqual(SongTransposer.bestShift(for: high, in: tenor), -12, "the only shift that fits")
        let low = song([36, 40, 43])
        XCTAssertEqual(SongTransposer.fit(of: low, in: tenor), .outside(below: 3, above: 0))
        XCTAssertEqual(SongTransposer.bestShift(for: low, in: tenor), 12)
        XCTAssertEqual(SongTransposer.bestShift(for: song([55, 60]), in: tenor), 0, "already fits")
    }

    func testBestShiftWhenNothingFitsPicksFewestOutside() {
        let narrow = VocalRange(low: 60, high: 64)
        let wide = song([50, 56, 62, 70])
        let shift = SongTransposer.bestShift(for: wide, in: narrow) ?? 99
        let outside = SongTransposer.notesOutside(wide, shift: shift, range: narrow)
        for other in -24...24 {
            XCTAssertLessThanOrEqual(outside, SongTransposer.notesOutside(wide, shift: other, range: narrow))
        }
    }

    func testBestShiftNeedsAnOddSemitoneSometimes() {
        let range = VocalRange(low: 50, high: 62)
        let s = song([55, 61, 64]) // 9 semitone span, top 64 -> must go down 2..., bottom 55 allows -5
        let shift = SongTransposer.bestShift(for: s, in: range)
        XCTAssertEqual(SongTransposer.fit(of: s, shift: shift ?? 0, in: range), .fits)
        XCTAssertNotEqual((shift ?? 0) % 12, 0)
        XCTAssertNil(SongTransposer.bestShift(for: Song(id: "e", title: "E", source: .builtIn, notes: []), in: range))
    }

    func testShiftText() {
        XCTAssertEqual(SongTransposer.shiftText(0), "No shift")
        XCTAssertEqual(SongTransposer.shiftText(12), "+1 octave")
        XCTAssertEqual(SongTransposer.shiftText(-24), "-2 octaves")
        XCTAssertEqual(SongTransposer.shiftText(-5), "-5 semitones")
        XCTAssertEqual(SongTransposer.shiftText(1), "+1 semitone")
    }

    func testSectionAndExcerpt() {
        var notes = (0..<8).map { SongNote(start: Double($0), duration: 0.8, pitch: 60 + $0, lyric: "n\($0)") }
        notes[3].slidesFromPrevious = true
        let full = Song(id: "s", title: "S", source: .builtIn, notes: notes, lineBreaks: [2.5, 5.5])
        let section = full.section(from: 3, to: 6)
        XCTAssertEqual(section.originalIndices, [3, 4, 5])
        XCTAssertEqual(section.song.notes.map(\.lyric), ["n3", "n4", "n5"])
        XCTAssertFalse(section.song.notes[0].slidesFromPrevious, "a slide from outside the section becomes a plain note")
        XCTAssertEqual(section.song.lineBreaks, [5.5])

        let excerpt = full.excerpt(from: 3, duration: 2.5)
        XCTAssertEqual(excerpt.notes.map(\.lyric), ["n3", "n4", "n5"])
        XCTAssertEqual(excerpt.notes[0].start, 0.2, accuracy: 1e-9)
        XCTAssertEqual(excerpt.notes[1].start, 1.2, accuracy: 1e-9)
        XCTAssertTrue(excerpt.lineBreaks.isEmpty)
    }

    func testPhraseRanges() {
        let notes = [0.0, 1, 2, 5, 6, 9].map { SongNote(start: $0, duration: 0.8, pitch: 60) }
        let withBreaks = Song(id: "p", title: "P", source: .builtIn, notes: notes, lineBreaks: [3.5, 7.5])
        let phrases = withBreaks.phraseRanges(pad: 0)
        XCTAssertEqual(phrases.count, 3)
        XCTAssertEqual(phrases[0].lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(phrases[0].upperBound, 2.8, accuracy: 1e-9)
        XCTAssertEqual(phrases[1].lowerBound, 5, accuracy: 1e-9)
        XCTAssertEqual(phrases[1].upperBound, 6.8, accuracy: 1e-9)
        XCTAssertEqual(phrases[2].lowerBound, 9, accuracy: 1e-9)
        XCTAssertEqual(phrases[2].upperBound, 9.8, accuracy: 1e-9)

        let noBreaks = Song(id: "q", title: "Q", source: .builtIn, notes: notes)
        XCTAssertEqual(noBreaks.phraseRanges(pad: 0).count, 3, "split at pauses of a second or more")
        XCTAssertEqual(Song(id: "e", title: "E", source: .builtIn, notes: []).phraseRanges(), [])
        XCTAssertEqual(BuiltInSongs.song(.morningLane, .normal).phraseRanges().count, 4)
    }
}

final class PracticeOptionsTests: XCTestCase {
    func testSpeedClampedAndPracticeFlag() {
        XCTAssertFalse(PracticeOptions.normal.isPractice)
        XCTAssertEqual(PracticeOptions(speed: 0.2).speed, 0.5)
        XCTAssertEqual(PracticeOptions(speed: 3).speed, 1)
        XCTAssertTrue(PracticeOptions(speed: 0.75).isPractice)
        XCTAssertTrue(PracticeOptions(noFail: true).isPractice)
        XCTAssertEqual(PracticeOptions(speed: 0.75).speedText, "75%")
    }

    func testLoopNeedsMinimumLength() {
        XCTAssertNil(PracticeOptions(loopStart: 1, loopEnd: 2).loop)
        XCTAssertEqual(PracticeOptions(loopStart: 1, loopEnd: 9).loop, 1...9)
        XCTAssertNil(PracticeOptions(loopStart: 1, loopEnd: nil).loop)
        XCTAssertTrue(PracticeOptions(loopStart: 0, loopEnd: 10).isPractice)
    }

    func testCodableAndHashable() throws {
        let options = PracticeOptions(speed: 0.6, loopStart: 2, loopEnd: 10, noFail: true)
        XCTAssertEqual(try JSONDecoder().decode(PracticeOptions.self, from: JSONEncoder().encode(options)), options)
        XCTAssertEqual(Set([options, options]).count, 1)
    }

    func testHealthMeter() {
        var health = HealthMeter()
        XCTAssertEqual(health.value, 1)
        health.apply(.perfect)
        XCTAssertEqual(health.value, 1, "capped")
        for _ in 0..<8 { health.apply(.miss) }
        XCTAssertEqual(health.value, 1 - 8 * 0.12, accuracy: 1e-9)
        XCTAssertFalse(health.isFailed)
        health.apply(.miss)
        XCTAssertTrue(health.isFailed)
        health.apply(.perfect)
        XCTAssertFalse(health.isFailed, "recovers")
        health.reset()
        XCTAssertEqual(health.value, 1)

        var off = HealthMeter(enabled: false)
        for _ in 0..<20 { off.apply(.miss) }
        XCTAssertFalse(off.isFailed)
        XCTAssertEqual(off.value, 1)
    }
}

final class HoldDrillTests: XCTestCase {
    private func drill(target: Int? = 60, duration: Double = 6, midi: (Double) -> Double?) -> HoldDrillResult {
        var drill = HoldDrill(target: target, duration: duration)
        var t = 0.0
        while !drill.isComplete {
            drill.add(time: t, midi: midi(t))
            t += 0.01
        }
        return drill.result()
    }

    func testPerfectlySteadyNote() {
        let result = drill { _ in 60 }
        XCTAssertEqual(result.score, 100, accuracy: 1e-9)
        XCTAssertEqual(result.rating, .rockSteady)
        XCTAssertEqual(result.wobbleCents, 0, accuracy: 1e-9)
        XCTAssertEqual(result.offsetFromTargetCents ?? 99, 0, accuracy: 1e-9)
        XCTAssertEqual(result.voicedFraction, 1, accuracy: 1e-9)
    }

    func testWobbleLowersScore() {
        // +/-20 cents sine wobble: RMS about 14 cents.
        let wobbly = drill { 60 + 0.2 * sin(2 * Double.pi * 3 * $0) }
        XCTAssertEqual(wobbly.wobbleCents, 14.1, accuracy: 1.5)
        XCTAssertEqual(wobbly.maxDeviationCents, 20, accuracy: 1)
        XCTAssertGreaterThan(wobbly.score, 55)
        XCTAssertLessThan(wobbly.score, 80)
        let wild = drill { 60 + 0.6 * sin(2 * Double.pi * 3 * $0) }
        XCTAssertLessThan(wild.score, 15)
        XCTAssertEqual(wild.rating, .unsteady)
        XCTAssertGreaterThan(wobbly.score, wild.score)
    }

    func testStedinessIsIndependentOfBeingOffTarget() {
        let flat = drill { _ in 59.7 }
        XCTAssertEqual(flat.score, 100, accuracy: 1e-9, "steady but 30 cents flat is still steady")
        XCTAssertEqual(flat.offsetFromTargetCents ?? 0, -30, accuracy: 1e-6)
        let free = drill(target: nil) { _ in 63.3 }
        XCTAssertNil(free.offsetFromTargetCents)
        XCTAssertEqual(free.score, 100, accuracy: 1e-9)
    }

    func testDriftIsReported() {
        let rising = drill { 60 + 0.05 * $0 }
        XCTAssertEqual(rising.driftCentsPerSecond, 5, accuracy: 0.3)
        XCTAssertGreaterThan(rising.score, 80, "slow drift is only a little wobble")
    }

    func testSettleTimeIsNotScored() {
        let result = drill { $0 < 0.6 ? 57 + 3 * $0 : 60 }
        XCTAssertEqual(result.score, 100, accuracy: 1e-9)
        XCTAssertEqual(result.points.first?.cents ?? 0, -300, accuracy: 1e-6, "but the graph shows it")
    }

    func testSilenceCountsAgainstTheScore() {
        let half = drill { $0 > 3.4 ? nil : 60 }
        XCTAssertEqual(half.voicedFraction, 0.5, accuracy: 0.1)
        XCTAssertEqual(half.score, 50, accuracy: 10)
        let none = drill { _ in nil }
        XCTAssertEqual(none.score, 0)
        XCTAssertEqual(none.rating, .unsteady)
        XCTAssertTrue(none.points.allSatisfy { $0.cents == nil })
    }

    func testOctaveSlipIsNotWobbleWhenAgnostic() {
        let slipped = drill { $0 > 3 ? 72 : 60 }
        XCTAssertEqual(slipped.score, 100, accuracy: 1e-9)
        var strict = HoldDrill(target: 60, duration: 6, octaveAgnostic: false)
        var t = 0.0
        while !strict.isComplete { strict.add(time: t, midi: t > 3 ? 72 : 60); t += 0.01 }
        XCTAssertLessThan(strict.result().score, 10)
    }

    func testCompletionAndOrdering() {
        var drill = HoldDrill(target: nil, duration: 3)
        drill.add(time: 1, midi: 60)
        drill.add(time: 0.5, midi: 61) // out of order: ignored
        XCTAssertEqual(drill.elapsed, 1)
        XCTAssertFalse(drill.isComplete)
        drill.add(time: 3.01, midi: 60)
        XCTAssertTrue(drill.isComplete)
        drill.add(time: 4, midi: 60)
        XCTAssertEqual(drill.elapsed, 3.01)
    }

    func testRatingThresholds() {
        XCTAssertEqual(SteadinessRating(score: 95), .rockSteady)
        XCTAssertEqual(SteadinessRating(score: 80), .steady)
        XCTAssertEqual(SteadinessRating(score: 60), .wobbly)
        XCTAssertEqual(SteadinessRating(score: 20), .unsteady)
    }
}

final class GameHistoryTests: XCTestCase {
    private func record(_ song: String, accuracy: Double, day: Double, practice: Bool = false, failed: Bool = false, score: Int = 100) -> GameRecord {
        GameRecord(songID: song, songTitle: song.uppercased(), difficulty: .normal, date: Date(timeIntervalSince1970: day * 86_400),
                   score: score, accuracy: accuracy, grade: Grade(accuracy: accuracy), maxCombo: 3, practice: practice, failed: failed)
    }

    func testSummariesAndTrend() {
        var history = GameHistory()
        history.add(record("a", accuracy: 0.5, day: 1, score: 300))
        history.add(record("b", accuracy: 0.9, day: 2, score: 900))
        history.add(record("a", accuracy: 0.7, day: 3, score: 500))
        history.add(record("a", accuracy: 0.99, day: 4, practice: true, score: 9_999))
        history.add(record("a", accuracy: 0.1, day: 5, failed: true, score: 50))

        let summaries = history.songSummaries
        XCTAssertEqual(summaries.map(\.songID), ["a", "b"], "most recent first")
        let a = summaries[0]
        XCTAssertEqual(a.plays, 4)
        XCTAssertEqual(a.bestScore, 500, "practice and failed runs don't set bests")
        XCTAssertEqual(a.bestAccuracy, 0.7, accuracy: 1e-9)

        XCTAssertEqual(history.trend(songID: "a").map(\.accuracy), [0.5, 0.7])
        XCTAssertEqual(history.trend(songID: "a", includePractice: true).count, 3, "failed runs stay out")
        XCTAssertEqual(history.trend().count, 3)
        XCTAssertEqual(history.records(forSong: "a").count, 4)
    }

    func testCapAndRemoval() {
        var history = GameHistory()
        for i in 0..<(GameHistory.maxRecords + 25) { history.add(record("a", accuracy: 0.5, day: Double(i))) }
        XCTAssertEqual(history.records.count, GameHistory.maxRecords)
        XCTAssertEqual(history.records.first?.date, Date(timeIntervalSince1970: 25 * 86_400))
        history.add(record("b", accuracy: 0.5, day: 9_999))
        history.removeAll(songID: "a")
        XCTAssertEqual(history.songSummaries.map(\.songID), ["b"])
        history.removeAll()
        XCTAssertTrue(history.records.isEmpty)
    }

    func testImprovementAndMovingAverage() {
        var history = GameHistory()
        for (i, a) in [0.4, 0.5, 0.6, 0.6, 0.7, 0.8, 0.8, 0.9, 0.9, 0.95].enumerated() {
            history.add(record("a", accuracy: a, day: Double(i)))
        }
        let trend = history.trend(songID: "a")
        XCTAssertEqual(GameHistory.improvement(in: trend, window: 5) ?? 0, 0.87 - 0.56, accuracy: 1e-9)
        XCTAssertNil(GameHistory.improvement(in: Array(trend.prefix(1))))
        XCTAssertNil(GameHistory.improvement(in: Array(trend.prefix(3)), window: 5), "needs an earlier window")

        XCTAssertEqual(GameHistory.movingAverage([1, 2, 3, 4, 5], window: 3), [1.5, 2, 3, 4, 4.5])
        XCTAssertEqual(GameHistory.movingAverage([5], window: 3), [5])
    }

    func testCodableAndRecordFromResult() throws {
        var history = GameHistory()
        let result = GameResult(songID: "s", songTitle: "S", difficulty: .hard, octaveAgnostic: true, score: 10, accuracy: 0.6,
                                grade: .c, maxCombo: 2, counts: [.good: 2], noteCount: 2, date: Date(timeIntervalSince1970: 0))
        history.add(GameRecord(result: result, practice: PracticeOptions(speed: 0.75), failed: true, transpose: -12))
        let decoded = try JSONDecoder().decode(GameHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded, history)
        XCTAssertEqual(decoded.records[0].speed, 0.75)
        XCTAssertTrue(decoded.records[0].practice)
        XCTAssertTrue(decoded.records[0].failed)
        XCTAssertEqual(decoded.records[0].transpose, -12)
    }
}

final class InstrumentModeTests: XCTestCase {
    func testDisplayBounds() {
        XCTAssertEqual(PitchDetectorConfiguration.voice.displayBounds, 36...84)
        XCTAssertEqual(PitchDetectorConfiguration.instrument.displayBounds, 28...96)
    }

    func testConfiguredPipeline() {
        let voice = PitchPipelineConfiguration.configured(instrument: false, noiseGateDBFS: -50, accidentals: .sharps)
        XCTAssertEqual(voice.detector, .voice)
        let instrument = PitchPipelineConfiguration.configured(instrument: true, noiseGateDBFS: -42, accidentals: .flats)
        XCTAssertEqual(instrument.detector, .instrument)
        XCTAssertEqual(instrument.stabilizer.noiseGateDBFS, -42)
        XCTAssertEqual(instrument.accidentals, .flats)
        var settings = AppSettings()
        settings.instrumentMode = true
        settings.noiseGateDBFS = -40
        XCTAssertEqual(settings.pipelineConfiguration().detector, .instrument)
        XCTAssertEqual(settings.pipelineConfiguration().stabilizer.noiseGateDBFS, -40)
    }

    private func instrumentFrames(_ signal: [Float], rate: Double) -> [PitchFrame] {
        analyze(signal, sampleRate: rate, configuration: .configured(instrument: true, noiseGateDBFS: -50, accidentals: .sharps))
    }

    func testLowAndHighInstrumentNotes() {
        for rate in [44_100.0, 48_000] {
            for note in stride(from: 28, through: 91, by: 3) {
                let midi = Double(note) + 0.3
                let frames = instrumentFrames(SignalFactory.tone(midi: midi, duration: 0.45, sampleRate: rate), rate: rate)
                let settled = frames.dropFirst(6)
                XCTAssertFalse(settled.isEmpty)
                for frame in settled {
                    guard let hz = frame.frequency else {
                        XCTFail("unvoiced at MIDI \(midi) @ \(rate), reason \(String(describing: frame.unvoicedReason))")
                        break
                    }
                    XCTAssertLessThanOrEqual(abs(cents(hz, from: midi)), 5, "MIDI \(midi) @ \(rate)")
                }
            }
        }
    }

    func testHarmonicInstrumentTonesHaveNoOctaveErrors() {
        for waveform in [Waveform.sawtooth, .square] {
            for note in stride(from: 28, through: 90, by: 4) {
                let midi = Double(note) + 0.2
                let frames = instrumentFrames(
                    SignalFactory.tone(waveform, midi: midi, duration: 0.45, sampleRate: 48_000, amplitude: 0.25), rate: 48_000
                )
                for frame in frames.dropFirst(6) {
                    guard let hz = frame.frequency else { continue }
                    XCTAssertLessThanOrEqual(abs(cents(hz, from: midi)), 12, "\(waveform) MIDI \(midi)")
                }
                XCTAssertGreaterThan(frames.dropFirst(6).filter(\.isVoiced).count, frames.dropFirst(6).count * 9 / 10, "\(waveform) \(midi)")
            }
        }
    }

    func testNoiseAndAboveRangeStayUnvoiced() {
        let noise = instrumentFrames(SignalFactory.whiteNoise(duration: 2, sampleRate: 48_000, sigma: 0.2), rate: 48_000)
        XCTAssertEqual(noise.filter(\.isVoiced).count, 0)
        let whistle = instrumentFrames(SignalFactory.sine(frequency: 3_000, duration: 0.3, sampleRate: 48_000), rate: 48_000)
        XCTAssertEqual(whistle.filter(\.isVoiced).count, 0)
    }

    func testVoiceNotesBelowTheVoiceRangeOnlyWorkInInstrumentMode() {
        let low = SignalFactory.tone(midi: 31, duration: 0.5, sampleRate: 48_000) // G1 ~ 49 Hz
        XCTAssertEqual(analyze(low, sampleRate: 48_000).filter(\.isVoiced).count, 0)
        XCTAssertGreaterThan(instrumentFrames(low, rate: 48_000).filter(\.isVoiced).count, 20)
    }

    func testNoiseGateSettingChangesSensitivity() {
        let quiet = SignalFactory.tone(midi: 60, duration: 0.4, sampleRate: 48_000, amplitude: 0.01) // about -43 dBFS
        let sensitive = analyze(quiet, sampleRate: 48_000, configuration: .configured(instrument: false, noiseGateDBFS: -60, accidentals: .sharps))
        let strict = analyze(quiet, sampleRate: 48_000, configuration: .configured(instrument: false, noiseGateDBFS: -35, accidentals: .sharps))
        XCTAssertGreaterThan(sensitive.filter(\.isVoiced).count, 20)
        XCTAssertEqual(strict.filter(\.isVoiced).count, 0)
    }
}

final class PracticeSettingsTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let defaults = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertNil(defaults.vocalRange)
        XCTAssertTrue(defaults.songTranspose.isEmpty)
        XCTAssertEqual(defaults.noiseGateDBFS, -50)
        XCTAssertFalse(defaults.instrumentMode)
        XCTAssertFalse(defaults.showFPS)
        XCTAssertTrue(defaults.failEnabled)

        var settings = AppSettings()
        settings.vocalRange = VocalRange(low: 48, high: 69)
        settings.setTranspose(-12, for: "song")
        settings.noiseGateDBFS = -44
        settings.instrumentMode = true
        settings.showFPS = true
        settings.failEnabled = false
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
        XCTAssertEqual(settings.transpose(for: "song"), -12)
        settings.setTranspose(0, for: "song")
        XCTAssertTrue(settings.songTranspose.isEmpty, "no entry for a zero shift")
        settings.setTranspose(500, for: "x")
        XCTAssertEqual(settings.transpose(for: "x"), 36)
    }

    func testGateIsClamped() throws {
        let loud = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"noiseGateDBFS":-5}"#.utf8))
        XCTAssertEqual(loud.noiseGateDBFS, -30)
        let quiet = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"noiseGateDBFS":-200}"#.utf8))
        XCTAssertEqual(quiet.noiseGateDBFS, -65)
    }
}

final class LoopStartClockTests: XCTestCase {
    func testCountdownEndsAtTheLoopStart() {
        var clock = GameClock(songDuration: 100, rate: 0.5)
        clock.start(at: 10, from: 20)
        XCTAssertEqual(clock.songTime(at: 10), 18.5, accuracy: 1e-12, "3 real seconds at half speed = 1.5 song seconds")
        XCTAssertEqual(clock.countdown(at: 10.2), 3)
        XCTAssertEqual(clock.countdown(at: 12.5), 1)
        XCTAssertEqual(clock.phase(at: 11), .countdown)
        XCTAssertEqual(clock.songTime(at: 13), 20, accuracy: 1e-12)
        XCTAssertNil(clock.countdown(at: 13.1))
        XCTAssertEqual(clock.phase(at: 13.1), .playing)
        XCTAssertEqual(clock.songTime(at: 15), 21, accuracy: 1e-12)
    }

    func testWrappingAtTheLoopEndIsNotACountdown() {
        var clock = GameClock(songDuration: 100)
        clock.start(at: 0, from: 20)
        clock.seek(toSongTime: 19, at: 30)
        XCTAssertEqual(clock.phase(at: 30.5), .playing)
        XCTAssertNil(clock.countdown(at: 30.5))
        XCTAssertEqual(clock.songTime(at: 30.5), 19.5, accuracy: 1e-12)
    }
}
