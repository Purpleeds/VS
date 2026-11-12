import XCTest
import PitchLaneCore

final class ResamplerTests: XCTestCase {
    func testOutputLengthMatchesRateRatio() {
        for (input, expected) in [(48_000.0, 16_000), (44_100, 16_000), (16_000, 16_000), (8_000, 16_000)] {
            var resampler = StreamingResampler(inputRate: input)
            let output = resampler.process([Float](repeating: 0.1, count: Int(input)))
            XCTAssertEqual(Double(output.count), Double(expected), accuracy: 2, "\(input)")
        }
    }

    func testChunkingDoesNotChangeOutput() {
        let signal = SignalFactory.whiteNoise(duration: 0.5, sampleRate: 44_100, sigma: 0.2)
        var whole = StreamingResampler(inputRate: 44_100)
        let expected = whole.process(signal)
        var chunked = StreamingResampler(inputRate: 44_100)
        var output: [Float] = []
        var index = 0
        var random = SeededRandom(seed: 3)
        while index < signal.count {
            let size = min(signal.count - index, 1 + Int(random.next() % 700))
            output += chunked.process(Array(signal[index..<(index + size)]))
            index += size
        }
        XCTAssertEqual(output, expected)
    }

    func testPassbandIsPreserved() {
        for rate in [44_100.0, 48_000] {
            for hz in [100.0, 440, 1_000, 3_000] {
                var resampler = StreamingResampler(inputRate: rate)
                let output = resampler.process(SignalFactory.sine(frequency: hz, duration: 0.5, sampleRate: rate, amplitude: 0.5))
                let level = SignalFactory.rms(output[1_000...])
                XCTAssertEqual(level, 0.5 / 2.0.squareRoot(), accuracy: 0.5 / 2.0.squareRoot() * 0.06, "\(hz) Hz @ \(rate)")
            }
        }
    }

    func testAliasingContentIsAttenuated() {
        for rate in [44_100.0, 48_000] {
            for (hz, maxDB) in [(7_900.0, -15.0), (12_000, -30)] {
                var resampler = StreamingResampler(inputRate: rate)
                let output = resampler.process(SignalFactory.sine(frequency: hz, duration: 0.5, sampleRate: rate, amplitude: 0.5))
                let gain = SignalFactory.rms(output[1_000...]) / (0.5 / 2.0.squareRoot())
                XCTAssertLessThan(PitchMath.decibels(fromLinear: gain), maxDB, "\(hz) Hz @ \(rate)")
            }
        }
    }

    func testBiquadLowPassResponse() {
        var filter = Biquad.lowPass(sampleRate: 48_000, cutoff: 1_000, q: 0.707)
        let dc = (0..<2_000).map { _ in filter.process(1) }.last ?? 0
        XCTAssertEqual(dc, 1, accuracy: 1e-3)
        filter.reset()
        let high = SignalFactory.sine(frequency: 10_000, duration: 0.2, sampleRate: 48_000, amplitude: 1).map { filter.process($0) }
        XCTAssertLessThan(SignalFactory.rms(high[2_000...]), 0.05)
    }
}
