import XCTest
import PitchLaneCore

final class VoiceFocusTests: XCTestCase {
    private let rate = 16_000.0

    private func sine(_ hz: Double, seconds: Double, amplitude: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    /// A "singer": 220 Hz with eight harmonics falling off as 1/h.
    private func voice(seconds: Double = 2, amplitude: Double = 0.3) -> [Float] {
        let parts = (1...8).map { sine(220 * Double($0), seconds: seconds, amplitude: amplitude / Double($0)) }
        return (0..<parts[0].count).map { i in parts.reduce(Float(0)) { $0 + $1[i] } }
    }

    private func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map { $0 + $1 }
    }

    /// Power of `signal` at `hz` (Goertzel), on the steady middle half.
    private func power(_ signal: [Float], _ hz: Double) -> Double {
        let part = signal[(signal.count / 4)..<(3 * signal.count / 4)]
        let coefficient = 2 * cos(2 * Double.pi * hz / rate)
        var s1 = 0.0, s2 = 0.0
        for x in part {
            let s0 = Double(x) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        return (s1 * s1 + s2 * s2 - coefficient * s1 * s2) / Double(part.count * part.count)
    }

    private func dB(_ after: Double, _ before: Double) -> Double { 10 * log10(max(after, 1e-30) / max(before, 1e-30)) }

    private func track(_ hz: Double?, seconds: Double) -> [VoiceFocus.PitchPoint] {
        (0..<Int(seconds * 100)).map { VoiceFocus.PitchPoint(time: Double($0) / 100, frequency: hz) }
    }

    func testWithoutAPitchTheSoundPassesThroughUnchanged() {
        var random = SeededRandom(seed: 3)
        let input = (0..<20_000).map { _ in Float(random.gaussian() * 0.1) }
        let result = VoiceFocus.apply(input, sampleRate: rate, track: [])
        XCTAssertEqual(result.samples.count, input.count)
        XCTAssertEqual(result.focusedFraction, 0)
        let worst = zip(input, result.samples).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 1e-4)
        // Unvoiced points behave the same as no track.
        let unvoiced = VoiceFocus.apply(input, sampleRate: rate, track: track(nil, seconds: 1.25))
        XCTAssertLessThan(zip(input, unvoiced.samples).map { abs($0 - $1) }.max() ?? 1, 1e-4)
    }

    func testKeepsTheSingerAndTurnsDownWhatIsBetweenTheHarmonics() {
        let singer = voice()
        let keys = sine(311.13, seconds: 2, amplitude: 0.1) // E♭4: not a harmonic of 220 Hz
        let bass = sine(82.4, seconds: 2, amplitude: 0.1) // E2: below the sung note
        let input = mix(mix(singer, keys), bass)
        let result = VoiceFocus.apply(input, sampleRate: rate, track: track(220, seconds: 2))
        XCTAssertGreaterThan(result.focusedFraction, 0.9)
        for harmonic in [220.0, 440, 660, 880] {
            XCTAssertGreaterThan(dB(power(result.samples, harmonic), power(input, harmonic)), -1.5, "harmonic \(harmonic) Hz")
        }
        XCTAssertLessThan(dB(power(result.samples, 311.13), power(input, 311.13)), -10)
        XCTAssertLessThan(dB(power(result.samples, 82.4), power(input, 82.4)), -10)
    }

    func testAPitchAnOctaveTooLowStillKeepsTheSinger() {
        let singer = voice()
        let result = VoiceFocus.apply(singer, sampleRate: rate, track: track(110, seconds: 2))
        for harmonic in [220.0, 440, 660] {
            XCTAssertGreaterThan(dB(power(result.samples, harmonic), power(singer, harmonic)), -1.5, "harmonic \(harmonic) Hz")
        }
    }

    func testTracksTheSungPitchItself() {
        let singer = voice(seconds: 1.5)
        let points = VoiceFocus.pitchTrack(singer, sampleRate: rate).compactMap(\.frequency).sorted()
        XCTAssertGreaterThan(points.count, 80)
        XCTAssertEqual(points[points.count / 2], 220, accuracy: 220 * 0.01)

        let input = mix(singer, sine(311.13, seconds: 1.5, amplitude: 0.04))
        let result = VoiceFocus.apply(input, sampleRate: rate)
        XCTAssertGreaterThan(result.focusedFraction, 0.5)
        XCTAssertLessThan(dB(power(result.samples, 311.13), power(input, 311.13)), -6)
        XCTAssertGreaterThan(dB(power(result.samples, 220), power(input, 220)), -1.5)
    }

    func testSilenceAndBadSamplesAreSafe() {
        let silent = VoiceFocus.apply([Float](repeating: 0, count: 8_000), sampleRate: rate, track: track(220, seconds: 0.5))
        XCTAssertTrue(silent.samples.allSatisfy { $0 == 0 })
        XCTAssertEqual(silent.focusedFraction, 0)
        var bad = voice(seconds: 0.5)
        bad[100] = .nan
        bad[200] = .infinity
        let result = VoiceFocus.apply(bad, sampleRate: rate, track: track(220, seconds: 0.5))
        XCTAssertEqual(result.samples.count, bad.count)
        XCTAssertTrue(result.samples.allSatisfy(\.isFinite))
        XCTAssertTrue(VoiceFocus.apply([], sampleRate: rate).samples.isEmpty)
        XCTAssertEqual(VoiceFocus.apply([0.5, .nan], sampleRate: 0).samples, [0.5, 0])
    }
}

final class HeardWordPickerTests: XCTestCase {
    typealias Word = LyricListenMatcher.HeardWord
    private let phrases = [
        VocalPrep.Segment(start: 0, end: 2), VocalPrep.Segment(start: 3, end: 5), VocalPrep.Segment(start: 6, end: 8),
    ]

    func testEachPhraseComesFromThePassThatHeardItBest() {
        let focused = [
            Word(text: "hello", time: 0.2, confidence: 0.9), Word(text: "there", time: 0.8, confidence: 0.9),
        ]
        let plain = [
            Word(text: "yellow", time: 0.3, confidence: 0.6),
            Word(text: "how", time: 3.1), Word(text: "are", time: 3.6), Word(text: "you", time: 4.2),
            Word(text: "ghost", time: 10), // over silence
        ]
        let picked = HeardWordPicker.bestPerSegment([focused, plain], segments: phrases)
        XCTAssertEqual(picked.map(\.text), ["hello", "there", "how", "are", "you"])
        XCTAssertEqual(HeardWordPicker.unheard(picked, segments: phrases), [2])
        XCTAssertEqual(HeardWordPicker.unheard(picked, segments: phrases, minDuration: 3), [])
        XCTAssertTrue(HeardWordPicker.bestPerSegment([], segments: phrases).isEmpty)
        XCTAssertTrue(HeardWordPicker.bestPerSegment([focused], segments: []).isEmpty)
    }

    func testConfidentWordsBeatGuessesAndTiesGoToTheFirstPass() {
        let guesses = ["a", "b", "c"].enumerated().map { Word(text: $1, time: Double($0) * 0.5, confidence: 0.1) }
        let sure = [Word(text: "sky", time: 0.2, confidence: 0.95), Word(text: "blue", time: 1, confidence: 0.95)]
        XCTAssertEqual(HeardWordPicker.bestPerSegment([guesses, sure], segments: phrases).map(\.text), ["sky", "blue"])
        let first = [Word(text: "one", time: 0.5)], second = [Word(text: "two", time: 0.5)]
        XCTAssertEqual(HeardWordPicker.bestPerSegment([first, second], segments: phrases).map(\.text), ["one"])
        XCTAssertGreaterThan(HeardWordPicker.score(sure), HeardWordPicker.score(guesses))
    }

    func testWordsJustOutsideAPhraseBelongToTheNearestOne() {
        XCTAssertEqual(HeardWordPicker.segmentIndex(of: Word(text: "x", time: 1, duration: 0.5), in: phrases), 0)
        XCTAssertEqual(HeardWordPicker.segmentIndex(of: Word(text: "x", time: 2.3, duration: 0), in: phrases), 0)
        XCTAssertEqual(HeardWordPicker.segmentIndex(of: Word(text: "x", time: 2.6, duration: 0), in: phrases), 1)
        XCTAssertNil(HeardWordPicker.segmentIndex(of: Word(text: "x", time: 12, duration: 0), in: phrases))
        XCTAssertNil(HeardWordPicker.segmentIndex(of: Word(text: "x", time: 1, duration: 0), in: []))
    }

    func testCleanUpDropsDuplicatesStuckRepeatsAndWordsOverSilence() {
        var words = [
            Word(text: "hello", time: 0.1, confidence: 0.5),
            Word(text: "Hello", time: 0.15, confidence: 0.9), // the same word from another pass
            Word(text: "ghost", time: 9.5),
        ]
        // A recogniser stuck on a held note: ten quick "oh"s.
        words += (0..<10).map { Word(text: "oh", time: 3 + Double($0) * 0.2, duration: 0.1) }
        // A real chant: "na" every half second.
        words += (0..<8).map { Word(text: "na", time: 6 + Double($0) * 0.5, duration: 0.2) }
        let cleaned = HeardWordPicker.clean(words, segments: phrases + [VocalPrep.Segment(start: 8, end: 10)])
        XCTAssertEqual(cleaned.filter { $0.text.lowercased() == "hello" }.count, 1)
        XCTAssertEqual(cleaned.first { $0.text.lowercased() == "hello" }?.confidence, 0.9)
        XCTAssertEqual(cleaned.filter { $0.text == "oh" }.count, 6)
        XCTAssertEqual(cleaned.filter { $0.text == "na" }.count, 8)
        XCTAssertTrue(cleaned.contains { $0.text == "ghost" })
        XCTAssertFalse(HeardWordPicker.clean(words, segments: phrases).contains { $0.text == "ghost" })
        XCTAssertEqual(cleaned.map(\.time), cleaned.map(\.time).sorted())
        XCTAssertTrue(HeardWordPicker.clean([Word(text: " ", time: 1), Word(text: "x", time: .nan)], segments: []).isEmpty)
    }

    func testConfidenceIsSavedAndOldTranscriptsStillLoad() throws {
        let transcript = SongTranscript(language: "en-US", source: "voice", words: [
            Word(text: "hello", time: 1, duration: 0.4, confidence: 0.8), Word(text: "you", time: 2, duration: 0.3),
        ])
        let data = try JSONEncoder().encode(transcript)
        let back = try JSONDecoder().decode(SongTranscript.self, from: data)
        XCTAssertEqual(back.words.map(\.confidence), [0.8, nil])
        let old = #"{"language":"en-US","source":"voice","words":[{"text":"hi","time":1,"duration":0.5}]}"#
        let decoded = try JSONDecoder().decode(SongTranscript.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.words, [Word(text: "hi", time: 1, duration: 0.5)])
        XCTAssertNil(decoded.words[0].confidence)
        XCTAssertNil(Word(text: "x", time: 1, confidence: .nan).confidence)
        XCTAssertEqual(Word(text: "x", time: 1, confidence: 3).confidence, 1)
    }
}

final class SmarterLyricMatchTests: XCTestCase {
    typealias Word = LyricListenMatcher.HeardWord

    func testDistinctiveWordsAnchorTheAlignment() {
        // Only one of the two can be matched in order; the distinctive "tomorrow" should win over "you".
        let result = LyricListenMatcher.match(lyrics: [["you", "tomorrow"]], heard: [
            Word(text: "tomorrow", time: 5), Word(text: "you", time: 6),
        ])
        XCTAssertEqual(result.matchedWords, 1)
        XCTAssertEqual(result.lines[0].words[1].time, 5)
    }

    func testWordsThatSoundAlikeMatch() {
        let result = LyricListenMatcher.match(lyrics: [["Write", "it", "down"], ["Tomorrow", "night"]], heard: [
            Word(text: "right", time: 1), Word(text: "down", time: 2), Word(text: "tomorow", time: 4), Word(text: "knight", time: 5),
        ])
        XCTAssertEqual(result.matchedWords, 4)
        XCTAssertEqual(result.lines[0].words[0].time, 1)
        XCTAssertEqual(result.lines[1].words.map(\.time), [4, 5])
    }

    func testFillersStillMatchButUnrelatedWordsDoNot() {
        let result = LyricListenMatcher.match(lyrics: [["oh", "the", "rain"]], heard: [
            Word(text: "oh", time: 1), Word(text: "the", time: 1.5), Word(text: "train", time: 2),
        ])
        XCTAssertEqual(result.matchedWords, 3)
        let none = LyricListenMatcher.match(lyrics: [["sunshine", "river"]], heard: [Word(text: "mountain", time: 1)])
        XCTAssertEqual(none.matchedWords, 0)
    }
}
