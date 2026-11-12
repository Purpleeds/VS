import XCTest
import PitchLaneCore

final class PitchDetectorTests: XCTestCase {
    private let sampleRates: [Double] = [44_100, 48_000]

    // MARK: Accuracy

    func testSinesAcrossVoiceRangeWithinFiveCents() {
        var targets = (36...83).map { Double($0) + 0.37 }
        targets += [36.0, 60.0, 84.0]
        for rate in sampleRates {
            for midi in targets {
                let frames = analyze(SignalFactory.tone(midi: midi, duration: 0.25, sampleRate: rate), sampleRate: rate)
                XCTAssertGreaterThan(frames.count, 15)
                for frame in frames {
                    guard let hz = frame.frequency else {
                        XCTFail("unvoiced frame at \(rate) Hz, MIDI \(midi), t=\(frame.time), reason \(String(describing: frame.unvoicedReason))")
                        break
                    }
                    let error = cents(hz, from: midi)
                    XCTAssertLessThanOrEqual(abs(error), 5, "\(rate) Hz, MIDI \(midi): \(error) cents")
                }
            }
        }
    }

    func testHarmonicRichWaveformsHaveNoOctaveErrors() {
        for rate in sampleRates {
            for waveform in [Waveform.sawtooth, .square] {
                for note in stride(from: 36, through: 84, by: 2) {
                    let midi = Double(note) + 0.21
                    let frames = analyze(
                        SignalFactory.tone(waveform, midi: midi, duration: 0.25, sampleRate: rate, amplitude: 0.25),
                        sampleRate: rate
                    )
                    let voiced = frames.compactMap(\.frequency)
                    XCTAssertGreaterThanOrEqual(Double(voiced.count), 0.95 * Double(frames.count), "\(waveform) \(midi) @ \(rate)")
                    for hz in voiced {
                        let error = cents(hz, from: midi)
                        XCTAssertLessThanOrEqual(abs(error), 10, "\(waveform) \(midi) @ \(rate): \(error) cents")
                    }
                }
            }
        }
    }

    func testVibratoIsTrackedNotSmoothedAway() {
        for rate in sampleRates {
            for center in [57.0, 69.0] { // A3, A4
                let depth = 0.5 // semitones, i.e. +/-50 cents
                let signal = SignalFactory.tone(duration: 2, sampleRate: rate) { t in
                    center + depth * sin(2 * Double.pi * 5 * t)
                }
                let frames = Array(analyze(signal, sampleRate: rate).dropFirst(10))
                let voiced = frames.compactMap(\.midi)
                XCTAssertGreaterThanOrEqual(Double(voiced.count), 0.98 * Double(frames.count))
                let peakToPeak = ((voiced.max() ?? 0) - (voiced.min() ?? 0)) * 100
                XCTAssertGreaterThanOrEqual(peakToPeak, 80, "vibrato flattened at \(rate), \(center)")
                XCTAssertLessThanOrEqual(peakToPeak, 120)
                let mean = voiced.reduce(0, +) / Double(max(1, voiced.count))
                XCTAssertEqual(mean, center, accuracy: 0.05)
                for frame in frames {
                    guard let raw = frame.rawFrequency else { continue }
                    let expected = center + depth * sin(2 * Double.pi * 5 * frame.time)
                    XCTAssertLessThanOrEqual(abs(cents(raw, from: expected)), 15, "raw at t=\(frame.time)")
                }
            }
        }
    }

    func testOctaveGlideUpAndDownIsFollowed() {
        let low = 45.0 // A2
        let up: (Double) -> Double = { t in min(low + 12, max(low, low + 12 * (t - 0.25) / 1.5)) }
        let down: (Double) -> Double = { t in min(low + 12, max(low, low + 12 - 12 * (t - 0.25) / 1.5)) }
        for rate in sampleRates {
            for path in [up, down] {
                let frames = Array(analyze(SignalFactory.tone(duration: 2, sampleRate: rate, midiAt: path), sampleRate: rate).dropFirst(5))
                let voiced = frames.filter(\.isVoiced)
                XCTAssertGreaterThanOrEqual(Double(voiced.count), 0.97 * Double(frames.count))
                for frame in voiced {
                    // The 5-frame median lags by two hops (20 ms).
                    let expected = path(frame.time - 0.02)
                    XCTAssertLessThanOrEqual(abs((frame.midi! - expected) * 100), 25, "t=\(frame.time) @ \(rate)")
                    if let raw = frame.rawFrequency {
                        XCTAssertLessThanOrEqual(abs(cents(raw, from: path(frame.time))), 25)
                    }
                }
            }
        }
    }

    // MARK: Things that must be unvoiced

    func testSilenceIsUnvoiced() {
        for rate in sampleRates {
            let frames = analyze([Float](repeating: 0, count: Int(rate)), sampleRate: rate)
            XCTAssertFalse(frames.isEmpty)
            XCTAssertTrue(frames.allSatisfy { !$0.isVoiced && $0.unvoicedReason == .belowNoiseGate })
        }
    }

    func testWhiteNoiseIsUnvoicedAtAnyLevel() {
        for rate in sampleRates {
            for sigma in [0.001, 0.05, 0.3] {
                let frames = analyze(SignalFactory.whiteNoise(duration: 2, sampleRate: rate, sigma: sigma), sampleRate: rate)
                XCTAssertEqual(frames.filter(\.isVoiced).count, 0, "white noise sigma \(sigma) @ \(rate)")
                XCTAssertLessThan(frames.map(\.confidence).max() ?? 1, 0.5)
            }
        }
    }

    func testFanLikeNoiseIsUnvoiced() {
        for amplitude in [0.003, 0.03, 0.3] {
            let frames = analyze(SignalFactory.fanNoise(duration: 3, sampleRate: 48_000, amplitude: amplitude), sampleRate: 48_000)
            XCTAssertEqual(frames.filter(\.isVoiced).count, 0, "fan noise amplitude \(amplitude)")
        }
    }

    func testWhistleAboveRangeIsUnvoicedNotFoldedDown() {
        for rate in sampleRates {
            for hz in [1_500.0, 2_000.0, 2_600.0] {
                let frames = analyze(SignalFactory.sine(frequency: hz, duration: 0.3, sampleRate: rate), sampleRate: rate)
                XCTAssertEqual(frames.filter(\.isVoiced).count, 0, "whistle \(hz) @ \(rate)")
                let outOfRange = frames.filter { $0.unvoicedReason == .outOfRange }.count
                XCTAssertGreaterThanOrEqual(Double(outOfRange), 0.9 * Double(frames.count))
            }
        }
    }

    // MARK: Configuration

    func testFrequencyRangeIsConfigurable() {
        let narrow = PitchPipelineConfiguration(detector: PitchDetectorConfiguration(minFrequency: 100, maxFrequency: 500))
        XCTAssertLessThan(narrow.detector.frameLength, PitchDetectorConfiguration.voice.frameLength)

        let inRange = analyze(SignalFactory.sine(frequency: 300, duration: 0.3, sampleRate: 48_000), sampleRate: 48_000, configuration: narrow)
        XCTAssertTrue(inRange.allSatisfy(\.isVoiced))
        XCTAssertEqual(inRange.last?.frequency ?? 0, 300, accuracy: 300 * 0.003)

        let below = analyze(SignalFactory.sine(frequency: 80, duration: 0.3, sampleRate: 48_000), sampleRate: 48_000, configuration: narrow)
        XCTAssertEqual(below.filter(\.isVoiced).count, 0)

        let above = analyze(SignalFactory.sine(frequency: 700, duration: 0.3, sampleRate: 48_000), sampleRate: 48_000, configuration: narrow)
        XCTAssertEqual(above.filter(\.isVoiced).count, 0)
    }

    func testDefaultVoiceRangeIsC2ToC6() {
        let config = PitchDetectorConfiguration.voice
        XCTAssertEqual(PitchMath.midi(fromFrequency: config.minFrequency), 36, accuracy: 0.001)
        XCTAssertEqual(PitchMath.midi(fromFrequency: config.maxFrequency), 84, accuracy: 0.001)
        XCTAssertEqual(config.sampleRate, 16_000)
    }

    func testFrameOutputFields() throws {
        let frames = analyze(SignalFactory.tone(midi: 66.2, duration: 0.2, sampleRate: 48_000), sampleRate: 48_000)
        let frame = try XCTUnwrap(frames.last)
        XCTAssertEqual(frame.nearestNote, 66)
        XCTAssertEqual(frame.noteName, "F♯4")
        XCTAssertEqual(frame.cents ?? 0, 20, accuracy: 3)
        XCTAssertEqual(frame.midi ?? 0, 66.2, accuracy: 0.03)
        XCTAssertGreaterThan(frame.confidence, 0.95)
        XCTAssertEqual(frame.rms, 0.3 / 2.0.squareRoot(), accuracy: 0.02)
        XCTAssertEqual(frame.levelDBFS, PitchMath.decibels(fromLinear: frame.rms))
        XCTAssertNil(frame.unvoicedReason)

        var flats = PitchPipelineConfiguration()
        flats.accidentals = .flats
        let flatFrames = analyze(SignalFactory.tone(midi: 70, duration: 0.2, sampleRate: 48_000), sampleRate: 48_000, configuration: flats)
        XCTAssertEqual(flatFrames.last?.noteName, "B♭4")
    }

    func testFramesArriveEveryTenMilliseconds() {
        let pipeline = PitchPipeline(inputSampleRate: 48_000)
        XCTAssertEqual(pipeline.framesPerSecond, 100, accuracy: 0.001)
        let frames = pipeline.process(SignalFactory.tone(midi: 60, duration: 1, sampleRate: 48_000))
        XCTAssertEqual(Double(frames.count), (1 - pipeline.windowDuration) * 100, accuracy: 2)
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(b.time - a.time, 0.01, accuracy: 1e-9)
        }
    }

    func testChunkedInputMatchesSingleBuffer() {
        let signal = SignalFactory.tone(.sawtooth, duration: 0.8, sampleRate: 44_100) { t in 50 + 6 * t }
        let whole = analyze(signal, sampleRate: 44_100)
        let pipeline = PitchPipeline(inputSampleRate: 44_100)
        var chunked: [PitchFrame] = []
        var index = 0
        var random = SeededRandom(seed: 9)
        while index < signal.count {
            let size = min(signal.count - index, 1 + Int(random.next() % 2_000))
            chunked += pipeline.process(Array(signal[index..<(index + size)]))
            index += size
        }
        XCTAssertEqual(whole, chunked)
    }

    // MARK: Speed

    func testSpeed() {
        let rate = 48_000.0
        let seconds = 10.0
        var signal = SignalFactory.tone(.sawtooth, duration: seconds, sampleRate: rate, amplitude: 0.2) { t in
            48 + 24 * (t / seconds)
        }
        let noise = SignalFactory.whiteNoise(duration: seconds, sampleRate: rate, sigma: 0.01)
        for i in signal.indices { signal[i] += noise[i] }

        let pipeline = PitchPipeline(inputSampleRate: rate)
        let start = ContinuousClock.now
        var frameCount = 0
        signal.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = min(1_024, buffer.count - offset)
                pipeline.process(UnsafeBufferPointer(rebasing: buffer[offset..<(offset + n)])) { _ in frameCount += 1 }
                offset += n
            }
        }
        let elapsed = ContinuousClock.now - start
        let total = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let perFrameMs = total / Double(max(1, frameCount)) * 1_000
        let analysisMs = pipeline.timing.averageSeconds * 1_000
        print("PitchPipeline speed: \(frameCount) frames, \(perFrameMs) ms/frame total, \(analysisMs) ms/frame analysis, max \(pipeline.timing.maxSeconds * 1_000) ms, realtime factor \(total / seconds)")
        XCTAssertGreaterThan(frameCount, 990)
        #if DEBUG
        let budgetMs = 10.0 // real-time budget per 10 ms hop; unoptimised build
        #else
        let budgetMs = 1.0
        #endif
        XCTAssertLessThan(perFrameMs, budgetMs)
        XCTAssertLessThan(analysisMs, budgetMs)
    }
}
