import XCTest
import PitchLaneCore

final class VocalPrepTests: XCTestCase {
    let rate = 16_000.0

    /// Quiet noise everywhere, with sung (tone) bursts at the given times.
    private func track(seconds: Double, bursts: [(Double, Double)], noise: Float = 0.002) -> [Float] {
        var random = SeededRandom(seed: 4)
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            var x = noise * Float(random.uniform() - 0.5)
            if bursts.contains(where: { t >= $0.0 && t < $0.1 }) {
                x += 0.2 * Float(sin(2 * Double.pi * 330 * t))
            }
            return x
        }
    }

    func testFindsSungPhrasesJoinsShortGapsAndPads() {
        // Two phrases; the first has a 0.3 s breath inside it (joined), the second is separate.
        let samples = track(seconds: 10, bursts: [(1.0, 2.0), (2.3, 3.0), (5.0, 6.5)])
        let segments = VocalPrep.segments(VocalPrep.voiceBand(samples, sampleRate: rate), sampleRate: rate)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0.8, accuracy: 0.06)
        XCTAssertEqual(segments[0].end, 3.2, accuracy: 0.06)
        XCTAssertEqual(segments[1].start, 4.8, accuracy: 0.06)
        XCTAssertEqual(segments[1].end, 6.7, accuracy: 0.06)
        XCTAssertTrue(VocalPrep.contains(segments, 2.15))
        XCTAssertFalse(VocalPrep.contains(segments, 4.0))
        XCTAssertFalse(VocalPrep.contains(segments, 9))
    }

    func testLongPhrasesAreSplitAndBlipsDropped() {
        // 50 s of singing with a slight dip at 25 s, and a 0.1 s blip.
        var samples = track(seconds: 60, bursts: [(2, 52), (55, 55.1)])
        for i in Int(25 * rate)..<Int(25.1 * rate) { samples[i] *= 0.2 }
        let segments = VocalPrep.segments(VocalPrep.voiceBand(samples, sampleRate: rate), sampleRate: rate)
        XCTAssertGreaterThanOrEqual(segments.count, 3)
        XCTAssertTrue(segments.allSatisfy { $0.duration <= 20 + 1e-9 })
        XCTAssertFalse(segments.contains { $0.start > 54 }, "blip dropped")
        for (a, b) in zip(segments, segments.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 1e-9) }
    }

    func testPrepareSilencesGapsAndLevelsPhrases() {
        // A loud phrase and a quiet phrase come out at the same loudness, with silence between.
        var samples = track(seconds: 6, bursts: [(1, 2), (4, 5)])
        for i in Int(4 * rate)..<Int(5 * rate) { samples[i] *= 0.1 }
        let prepared = VocalPrep.prepare(samples, sampleRate: rate)
        XCTAssertEqual(prepared.segments.count, 2)
        func rms(_ a: Double, _ b: Double) -> Double { SignalFactory.rms(prepared.samples[Int(a * rate)..<Int(b * rate)]) }
        XCTAssertEqual(rms(1.2, 1.8), rms(4.2, 4.8), accuracy: 0.02)
        XCTAssertEqual(rms(2.6, 3.6), 0)
        XCTAssertLessThanOrEqual(prepared.samples.map { abs($0) }.max() ?? 0, 0.96)
    }

    func testVoiceBandRemovesRumbleAndHiss() {
        let low = SignalFactory.sine(frequency: 40, duration: 1, sampleRate: rate)
        let high = SignalFactory.sine(frequency: 7_000, duration: 1, sampleRate: rate)
        let voice = SignalFactory.sine(frequency: 440, duration: 1, sampleRate: rate)
        func kept(_ x: [Float]) -> Double {
            SignalFactory.rms(VocalPrep.voiceBand(x, sampleRate: rate)[8_000...]) / SignalFactory.rms(x[8_000...])
        }
        XCTAssertLessThan(kept(low), 0.1)
        XCTAssertLessThan(kept(high), 0.2)
        XCTAssertGreaterThan(kept(voice), 0.9)
    }

    func testSilenceAndGarbage() {
        XCTAssertTrue(VocalPrep.segments([Float](repeating: 0, count: 16_000), sampleRate: rate).isEmpty)
        XCTAssertTrue(VocalPrep.segments([], sampleRate: rate).isEmpty)
        XCTAssertTrue(VocalPrep.prepare([.nan, .infinity, 1, -1], sampleRate: rate).samples.allSatisfy(\.isFinite))
    }
}
