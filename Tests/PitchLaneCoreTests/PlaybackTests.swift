import XCTest
import PitchLaneCore

final class GuideToneRendererTests: XCTestCase {
    private let rate = 48_000.0

    private func render(_ renderer: GuideToneRenderer, from start: Double, seconds: Double, chunk: Int = 512,
                        advancing: Bool = true, volume: Float = 1) -> [Float] {
        let total = Int(seconds * rate)
        var out = [Float](repeating: 0, count: total)
        var offset = 0
        out.withUnsafeMutableBufferPointer { buffer in
            while offset < total {
                let n = min(chunk, total - offset)
                renderer.render(into: buffer.baseAddress! + offset, frameCount: n, sampleRate: rate,
                                songTime: start + Double(offset) / rate, advancing: advancing, volume: volume)
                offset += n
            }
        }
        return out
    }

    private func rms(_ x: ArraySlice<Float>) -> Double { SignalFactory.rms(x) }
    private func index(_ t: Double) -> Int { Int(t * rate) }

    private func song(_ notes: [SongNote]) -> Song {
        Song(id: "g", title: "G", source: .builtIn, notes: notes)
    }

    func testPlaysTheNotePitch() {
        let renderer = GuideToneRenderer(song: song([SongNote(start: 0.2, duration: 1, pitch: 69)]))
        let audio = render(renderer, from: 0, seconds: 1.5)
        let frames = analyze(audio, sampleRate: rate).filter { $0.time > 0.35 && $0.time < 1.1 }
        XCTAssertFalse(frames.isEmpty)
        for frame in frames {
            XCTAssertEqual(frame.midi ?? 0, 69, accuracy: 0.05, "t=\(frame.time)")
        }
    }

    func testSilentOutsideNotesAndSoftAttack() {
        let renderer = GuideToneRenderer(song: song([SongNote(start: 0.5, duration: 0.5, pitch: 60)]))
        let audio = render(renderer, from: 0, seconds: 1.5)
        XCTAssertLessThan(rms(audio[0..<index(0.45)]), 1e-6)
        XCTAssertLessThan(rms(audio[index(1.1)...]), 1e-6)
        let steady = rms(audio[index(0.7)..<index(0.8)])
        XCTAssertGreaterThan(steady, 0.1)
        XCTAssertLessThan(rms(audio[index(0.5)..<index(0.505)]), steady * 0.5, "attack should be gentle")
    }

    func testNoClicks() {
        let renderer = GuideToneRenderer(song: song([
            SongNote(start: 0.1, duration: 0.3, pitch: 72),
            SongNote(start: 0.45, duration: 0.3, pitch: 76),
            SongNote(start: 0.75, duration: 0.5, pitch: 81, slidesFromPrevious: true),
        ]))
        let audio = render(renderer, from: 0, seconds: 1.4)
        let maxStep = zip(audio, audio.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        XCTAssertLessThan(maxStep, 0.12)
    }

    func testPausingFadesOutQuickly() {
        let renderer = GuideToneRenderer(song: song([SongNote(start: 0, duration: 5, pitch: 64)]))
        _ = render(renderer, from: 0, seconds: 0.5)
        let paused = render(renderer, from: 0.5, seconds: 0.1, advancing: false)
        XCTAssertLessThan(rms(paused[index(0.03)...]), 1e-4)
        let maxStep = zip(paused, paused.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        XCTAssertLessThan(maxStep, 0.12, "no click when pausing")
    }

    func testVolumeZeroIsSilentAndFreestyleIsSkipped() {
        let renderer = GuideToneRenderer(song: song([SongNote(start: 0, duration: 1, pitch: 64)]))
        XCTAssertLessThan(rms(render(renderer, from: 0, seconds: 0.5, volume: 0)[...]), 1e-6)
        let spoken = GuideToneRenderer(song: song([SongNote(start: 0, duration: 1, pitch: 64, isFreestyle: true)]))
        XCTAssertEqual(spoken.noteCount, 0)
        XCTAssertLessThan(rms(render(spoken, from: 0, seconds: 0.5)[...]), 1e-6)
    }

    func testWholeNoteGlideFollowsTheSlide() {
        let renderer = GuideToneRenderer(song: song([
            SongNote(start: 0, duration: 0.5, pitch: 60),
            SongNote(start: 0.5, duration: 2, pitch: 72, slidesFromPrevious: true),
        ]))
        let frames = analyze(render(renderer, from: 0, seconds: 2.6), sampleRate: rate)
        let mid = frames.min { abs($0.time - 1.5) < abs($1.time - 1.5) }
        XCTAssertEqual(mid?.midi ?? 0, 66, accuracy: 0.6)
        let late = frames.filter { $0.time > 2.35 && $0.time < 2.45 }.compactMap(\.midi)
        XCTAssertFalse(late.isEmpty)
        XCTAssertEqual(late.last ?? 0, 72, accuracy: 0.3)
    }

    func testLegatoNotesDoNotDip() {
        let renderer = GuideToneRenderer(song: song([
            SongNote(start: 0, duration: 0.5, pitch: 62),
            SongNote(start: 0.52, duration: 0.5, pitch: 64),
        ]))
        let audio = render(renderer, from: 0, seconds: 1.1)
        let steady = rms(audio[index(0.2)..<index(0.3)])
        XCTAssertGreaterThan(rms(audio[index(0.495)..<index(0.525)]), steady * 0.8)
    }

    func testChunkSizeDoesNotMatter() {
        let notes = [SongNote(start: 0.05, duration: 0.3, pitch: 67), SongNote(start: 0.4, duration: 0.3, pitch: 71, slidesFromPrevious: true)]
        let a = render(GuideToneRenderer(song: song(notes)), from: 0, seconds: 0.8, chunk: 512)
        let b = render(GuideToneRenderer(song: song(notes)), from: 0, seconds: 0.8, chunk: 37)
        XCTAssertEqual(a.count, b.count)
        let maxDiff = zip(a, b).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxDiff, 1e-4)
    }

    func testSeekingBackwardsReplays() {
        let renderer = GuideToneRenderer(song: song([SongNote(start: 0.2, duration: 0.4, pitch: 65)]))
        _ = render(renderer, from: 3, seconds: 0.2)
        let again = render(renderer, from: 0.3, seconds: 0.2)
        XCTAssertGreaterThan(rms(again[index(0.05)...]), 0.1)
    }

    func testPercussiveEnvelopeIsCrisp() {
        let renderer = GuideToneRenderer(song: song([SongNote(start: 0.1, duration: 0.06, pitch: 91)]), envelope: .percussive)
        let audio = render(renderer, from: 0, seconds: 0.3)
        XCTAssertGreaterThan(rms(audio[index(0.105)..<index(0.115)]), 0.1)
        XCTAssertLessThan(rms(audio[index(0.2)...]), 1e-5)
    }
}

final class LatencyTests: XCTestCase {
    func testRouteClassification() {
        XCTAssertEqual(AudioRouteKind.classify(outputPortTypes: ["Speaker"]), .speaker)
        XCTAssertEqual(AudioRouteKind.classify(outputPortTypes: ["Receiver"]), .speaker)
        XCTAssertEqual(AudioRouteKind.classify(outputPortTypes: ["Headphones"]), .wired)
        XCTAssertEqual(AudioRouteKind.classify(outputPortTypes: ["USBAudio"]), .wired)
        XCTAssertEqual(AudioRouteKind.classify(outputPortTypes: ["BluetoothA2DPOutput"]), .bluetooth)
        XCTAssertEqual(AudioRouteKind.classify(outputPortTypes: ["BluetoothLE"]), .bluetooth)
        XCTAssertEqual(AudioRouteKind.classify(outputPortTypes: ["Speaker", "BluetoothHFP"]), .bluetooth)
        XCTAssertEqual(AudioRouteKind.classify(outputPortTypes: ["AirPlay"]), .other)
        XCTAssertEqual(AudioRouteKind.classify(outputPortTypes: []), .other)
    }

    func testProfilesPerRouteAndPersistence() throws {
        var profiles = LatencyProfiles()
        XCTAssertFalse(profiles[.bluetooth].isCalibrated)
        XCTAssertEqual(profiles[.bluetooth].correctionMs, 0)
        profiles.setCalibration(42, for: .bluetooth, at: Date(timeIntervalSince1970: 0))
        profiles.setNudge(-5, for: .bluetooth)
        profiles.setNudge(12, for: .speaker)
        profiles.setNudge(9_999, for: .wired)
        XCTAssertEqual(profiles[.bluetooth].correctionMs, 37)
        XCTAssertEqual(profiles[.speaker].correctionMs, 12)
        XCTAssertEqual(profiles[.wired].nudgeMs, 300, "nudge is clamped")
        XCTAssertTrue(profiles[.bluetooth].isCalibrated)

        let data = try JSONEncoder().encode(profiles)
        XCTAssertEqual(try JSONDecoder().decode(LatencyProfiles.self, from: data), profiles)

        profiles.reset(.bluetooth)
        XCTAssertFalse(profiles[.bluetooth].isCalibrated)
    }

    func testOutputClockAnchor() {
        let anchor = OutputClockAnchor(sampleTime: 96_000, hostSeconds: 500, sampleRate: 48_000)
        XCTAssertEqual(anchor.renderSeconds(atHost: 500), 2, accuracy: 1e-12)
        XCTAssertEqual(anchor.renderSeconds(atHost: 500.25), 2.25, accuracy: 1e-12)
        XCTAssertEqual(anchor.hostSeconds(forRender: 3), 501, accuracy: 1e-12)
        XCTAssertEqual(anchor.hostSeconds(forRender: anchor.renderSeconds(atHost: 512.3)), 512.3, accuracy: 1e-9)
    }

    func testCalibratorOnSyntheticLevels() throws {
        let beeps = LatencyCalibrator.beepTimes(count: 8, interval: 0.6, start: 1)
        XCTAssertEqual(beeps.count, 8)
        XCTAssertEqual(beeps.last ?? 0, 5.2, accuracy: 1e-12)
        var levels: [LatencyCalibrator.Level] = []
        var random = SeededRandom(seed: 11)
        for i in 0..<700 {
            let t = Double(i) * 0.01
            var db = -72 + 4 * (random.uniform() - 0.5)
            for beep in beeps where t >= beep + 0.04 && t < beep + 0.12 { db = -20 }
            levels.append(.init(time: t, dBFS: db))
        }
        let result = try XCTUnwrap(LatencyCalibrator.estimate(beeps: beeps, levels: levels, onsetBias: 0))
        XCTAssertEqual(result.matchedBeats, 8)
        XCTAssertEqual(result.offsetMs, 40, accuracy: 0.5)
        XCTAssertLessThan(result.spreadMs, 1)
        XCTAssertTrue(result.isReliable)
    }

    func testCalibratorRejectsInconsistentOrMissingBeats() {
        let beeps = LatencyCalibrator.beepTimes(count: 8, interval: 0.6, start: 1)
        let silent = (0..<700).map { LatencyCalibrator.Level(time: Double($0) * 0.01, dBFS: -70) }
        XCTAssertNil(LatencyCalibrator.estimate(beeps: beeps, levels: silent, onsetBias: 0))

        var random = SeededRandom(seed: 3)
        let offsets = beeps.map { _ in -0.1 + 0.4 * random.uniform() }
        let messy = (0..<700).map { i -> LatencyCalibrator.Level in
            let t = Double(i) * 0.01
            let loud = zip(beeps, offsets).contains { t >= $0 + $1 && t < $0 + $1 + 0.05 }
            return LatencyCalibrator.Level(time: t, dBFS: loud ? -15 : -70)
        }
        let result = LatencyCalibrator.estimate(beeps: beeps, levels: messy, onsetBias: 0)
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.isReliable ?? true)
    }

    func testCalibratorThroughThePitchPipeline() throws {
        // Claps (decaying noise bursts) 55 ms after each beep, analysed exactly like the mic stream.
        let rate = 48_000.0
        let beeps = LatencyCalibrator.beepTimes(count: 8, interval: 0.6, start: 0.6)
        var audio = SignalFactory.whiteNoise(duration: 6, sampleRate: rate, sigma: 0.0003, seed: 1)
        var random = SeededRandom(seed: 2)
        for beep in beeps {
            let start = Int((beep + 0.055) * rate)
            for k in 0..<Int(0.03 * rate) {
                audio[start + k] += Float(0.3 * random.gaussian() * exp(-Double(k) / (0.006 * rate)))
            }
        }
        let pipeline = PitchPipeline(inputSampleRate: rate)
        let frames = pipeline.process(audio)
        let levels = frames.map { LatencyCalibrator.Level(time: $0.time, dBFS: $0.levelDBFS) }
        let bias = LatencyCalibrator.onsetBias(windowDuration: pipeline.windowDuration, hop: 1 / pipeline.framesPerSecond)
        let result = try XCTUnwrap(LatencyCalibrator.estimate(beeps: beeps, levels: levels, onsetBias: bias))
        XCTAssertEqual(result.matchedBeats, 8)
        XCTAssertEqual(result.offsetMs, 55, accuracy: 8)
        XCTAssertTrue(result.isReliable)
    }
}
