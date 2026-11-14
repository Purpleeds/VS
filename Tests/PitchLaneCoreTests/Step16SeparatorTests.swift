import XCTest
import PitchLaneCore

final class GuidedSeparatorTests: XCTestCase {
    private let rate = 44_100.0

    private func sine(_ hz: Double, amplitude: Double, seconds: Double, from: Double = 0, to: Double = .infinity) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            guard t >= from, t < to else { return 0 }
            let fade = min(1, (t - from) / 0.01, (to - t) / 0.01)
            return Float(amplitude * fade * sin(2 * Double.pi * hz * t))
        }
    }

    private func add(_ parts: [[Float]]) -> [Float] {
        (0..<parts[0].count).map { i in parts.reduce(Float(0)) { $0 + $1[i] } }
    }

    /// Power at `hz` (Goertzel) between two times.
    private func power(_ signal: [Float], _ hz: Double, _ from: Double, _ to: Double) -> Double {
        let part = signal[Int(from * rate)..<Int(to * rate)]
        let coefficient = 2 * cos(2 * Double.pi * hz / rate)
        var s1 = 0.0, s2 = 0.0
        for x in part {
            let s0 = Double(x) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        return (s1 * s1 + s2 * s2 - coefficient * s1 * s2) / Double(part.count * part.count)
    }

    private func dB(_ a: Double, _ b: Double) -> Double { 10 * log10(max(a, 1e-30) / max(b, 1e-30)) }

    private func run(_ left: [Float], _ right: [Float], guide: VocalGuide?) -> StemSeparator.Output {
        let separator = StemSeparator(sampleRate: rate, guide: guide)
        var out = StemSeparator.Output()
        var i = 0
        func take(_ o: StemSeparator.Output) {
            out.vocalsLeft += o.vocalsLeft
            out.vocalsRight += o.vocalsRight
            out.musicLeft += o.musicLeft
            out.musicRight += o.musicRight
        }
        while i < left.count {
            let end = min(left.count, i + 3_000)
            take(separator.process(left: Array(left[i..<end]), right: Array(right[i..<end])))
            i = end
        }
        take(separator.finish())
        return out
    }

    /// A centred singer (220 Hz, six harmonics) from 1 to 3 s, centred keys (E♭4) all the way, a guitar on the left.
    private func song() -> (left: [Float], right: [Float], guide: VocalGuide) {
        let seconds = 4.0
        let voice = add((1...6).map { sine(220 * Double($0), amplitude: 0.3 / Double($0), seconds: seconds, from: 1, to: 3) })
        let keys = sine(311.13, amplitude: 0.1, seconds: seconds)
        let guitar = sine(523.25, amplitude: 0.1, seconds: seconds)
        let left = add([voice, keys, guitar])
        let right = add([voice, keys])
        let pitch = (0..<400).map { index -> VoiceFocus.PitchPoint in
            let t = Double(index) / 100
            return VoiceFocus.PitchPoint(time: t, frequency: (1...3).contains(t) ? 220 : nil)
        }
        return (left, right, VocalGuide(singing: [VocalPrep.Segment(start: 1, end: 3)], pitch: pitch))
    }

    func testFollowingTheSingerSendsCentredInstrumentsBackToTheMusic() {
        let (left, right, guide) = song()
        let plain = run(left, right, guide: nil)
        let guided = run(left, right, guide: guide)
        XCTAssertEqual(guided.count, left.count)
        // While singing: the keys leave the voice, the voice stays.
        XCTAssertLessThan(dB(power(guided.vocalsLeft, 311.13, 1.5, 2.5), power(plain.vocalsLeft, 311.13, 1.5, 2.5)), -8)
        for harmonic in [220.0, 440, 660] {
            XCTAssertGreaterThan(dB(power(guided.vocalsLeft, harmonic, 1.5, 2.5), power(plain.vocalsLeft, harmonic, 1.5, 2.5)), -1.5)
        }
        XCTAssertGreaterThan(dB(power(guided.musicLeft, 311.13, 1.5, 2.5), power(guided.vocalsLeft, 311.13, 1.5, 2.5)), 6)
        // Nobody singing: the voice is nearly silent, the keys are all music.
        XCTAssertLessThan(dB(power(guided.vocalsLeft, 311.13, 3.3, 3.9), power(plain.vocalsLeft, 311.13, 3.3, 3.9)), -15)
        XCTAssertGreaterThan(dB(power(guided.musicLeft, 311.13, 3.3, 3.9), power(left, 311.13, 3.3, 3.9)), -1.5)
    }

    func testGuidedStemsStillAddUpToTheOriginal() {
        let (left, right, guide) = song()
        let out = run(left, right, guide: guide)
        var worst: Float = 0
        for i in 0..<left.count {
            worst = max(worst, abs(out.vocalsLeft[i] + out.musicLeft[i] - left[i]), abs(out.vocalsRight[i] + out.musicRight[i] - right[i]))
        }
        XCTAssertLessThan(worst, 1e-4)
        XCTAssertTrue(out.vocalsLeft.allSatisfy(\.isFinite))
    }

    func testTheGuideFindsTheSingerAndTheirPitch() {
        let guideRate = 16_000.0
        let voice: [Float] = (0..<Int(3.5 * guideRate)).map { i in
            let t = Double(i) / guideRate
            guard t >= 1, t < 2.5 else { return 0 }
            return Float((1...6).reduce(0.0) { $0 + 0.3 / Double($1) * sin(2 * Double.pi * 220 * Double($1) * t) })
        }
        let guide = VocalGuide.analyze(voice, sampleRate: guideRate)
        XCTAssertEqual(guide.singing.count, 1)
        XCTAssertEqual(guide.singing.first?.start ?? 0, 0.85, accuracy: 0.2)
        XCTAssertEqual(guide.singing.first?.end ?? 0, 2.65, accuracy: 0.2)
        XCTAssertEqual(guide.singingDuration, 1.8, accuracy: 0.3)
        let middle = guide.pitch.filter { $0.time > 1.3 && $0.time < 2.2 }.compactMap(\.frequency).sorted()
        XCTAssertGreaterThan(middle.count, 60)
        XCTAssertEqual(middle[middle.count / 2], 220, accuracy: 2.2)
        XCTAssertTrue(guide.pitch.filter { $0.time < 0.6 || $0.time > 3 }.allSatisfy { $0.frequency == nil })
        XCTAssertGreaterThan(guide.pitchedFraction, 0.5)
        XCTAssertEqual(VocalGuide.analyze([], sampleRate: guideRate), VocalGuide(singing: [], pitch: []))
    }
}

final class SungNoteFilterTests: XCTestCase {
    typealias Word = LyricListenMatcher.HeardWord

    private func notes(_ starts: [Double]) -> [SongNote] {
        starts.map { SongNote(start: $0, duration: 0.4, pitch: 60) }
    }

    func testPhrasesWithoutWordsAreLeftOut() {
        let sung = notes([1, 1.5, 2])
        let solo = notes([5, 5.5, 6, 6.5])
        let hummedIntoSung = notes(stride(from: 9.0, through: 13.0, by: 0.5).map { $0 })
        let words = [
            Word(text: "hello", time: 1.2), Word(text: "there", time: 1.8),
            Word(text: "sing", time: 11.5), Word(text: "along", time: 12), Word(text: "now", time: 12.5),
        ]
        let result = SungNoteFilter.keepSung((hummedIntoSung + solo + sung).reversed(), words: words)
        XCTAssertEqual(result.keptPhrases, 2)
        XCTAssertEqual(result.removedPhrases, 1)
        XCTAssertEqual(result.removedNotes, 4 + 3)
        XCTAssertEqual(result.notes.map(\.start), [1, 1.5, 2] + stride(from: 10.5, through: 13.0, by: 0.5).map { $0 })
    }

    func testWithoutWordsNothingIsLeftOut() {
        let input = notes([1, 1.5, 5, 5.5])
        XCTAssertEqual(SungNoteFilter.keepSung(input, words: []).notes, input)
        XCTAssertEqual(SungNoteFilter.keepSung(input, words: [Word(text: "!!", time: 1)]).removedNotes, 0)
        XCTAssertEqual(SungNoteFilter.keepSung(input, words: [Word(text: "hi", time: .nan)]).removedNotes, 0)
        XCTAssertEqual(SungNoteFilter.keepSung([], words: [Word(text: "hi", time: 1)]).notes, [])
    }

    func testPhrases() {
        XCTAssertEqual(SungNoteFilter.phrases([]), [])
        XCTAssertEqual(SungNoteFilter.phrases(notes([1])), [0..<1])
        XCTAssertEqual(SungNoteFilter.phrases(notes([1, 1.5, 3, 3.4])), [0..<2, 2..<4])
    }

    func testTheSettingIsOnByDefault() throws {
        XCTAssertTrue(AppSettings().onlySungNotes)
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).onlySungNotes)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"onlySungNotes":false}"#.utf8)).onlySungNotes)
    }
}
