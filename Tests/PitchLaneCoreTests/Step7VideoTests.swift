import XCTest
import PitchLaneCore

final class MelodyTranscriberTests: XCTestCase {
    /// 100 frames per second of `midi` (nil = silence) for `seconds`.
    private func feed(_ transcriber: inout MelodyTranscriber, from start: Double, seconds: Double, midi: (Double) -> Double?) -> Double {
        let count = Int((seconds * 100).rounded())
        for i in 0..<count {
            let t = start + Double(i) / 100
            transcriber.add(time: t, midi: midi(t))
        }
        return start + Double(count) / 100
    }

    func testStepsBecomeNotes() {
        var transcriber = MelodyTranscriber()
        var t = 0.0
        t = feed(&transcriber, from: t, seconds: 0.5) { _ in 60.1 }
        t = feed(&transcriber, from: t, seconds: 0.5) { _ in 64 }
        t = feed(&transcriber, from: t, seconds: 0.3) { _ in nil }
        _ = feed(&transcriber, from: t, seconds: 0.6) { _ in 66.9 }
        let notes = transcriber.finish()
        XCTAssertEqual(notes.map(\.pitch), [60, 64, 67])
        XCTAssertEqual(notes[0].start, 0, accuracy: 0.011)
        XCTAssertEqual(notes[1].start, 0.5, accuracy: 0.05)
        XCTAssertEqual(notes[2].start, 1.3, accuracy: 0.011)
        XCTAssertEqual(notes[2].duration, 0.6, accuracy: 0.02)
    }

    func testVibratoStaysOneNote() {
        var transcriber = MelodyTranscriber()
        _ = feed(&transcriber, from: 0, seconds: 2) { t in 62 + 0.45 * sin(2 * .pi * 5.5 * t) }
        let notes = transcriber.finish()
        XCTAssertEqual(notes.map(\.pitch), [62])
        XCTAssertEqual(notes[0].duration, 2, accuracy: 0.02)
    }

    func testBlipsAndShortGapsAreIgnored() {
        var transcriber = MelodyTranscriber()
        // A 2-frame octave glitch and a 40 ms dropout inside one held note.
        _ = feed(&transcriber, from: 0, seconds: 1.5) { t in
            if t >= 0.50 && t < 0.52 { return 69 }
            if t >= 1.0 && t < 1.04 { return nil }
            return 57
        }
        // A 50 ms blip on its own is too short to be a note.
        _ = feed(&transcriber, from: 2, seconds: 0.05) { _ in 70 }
        let notes = transcriber.finish()
        XCTAssertEqual(notes.map(\.pitch), [57])
        XCTAssertEqual(notes[0].duration, 1.5, accuracy: 0.02)
    }

    func testRepeatedNotesWithTinyGapsMergeButRealGapsDoNot() {
        var transcriber = MelodyTranscriber()
        var t = feed(&transcriber, from: 0, seconds: 0.4) { _ in 65 }
        t = feed(&transcriber, from: t, seconds: 0.09) { _ in nil }   // > maxGap, < mergeGap? no: 0.09 > 0.08
        t = feed(&transcriber, from: t, seconds: 0.4) { _ in 65 }
        let notes = transcriber.finish()
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(MelodyTranscriber.lineBreaks(for: notes), [])
        var second = MelodyTranscriber()
        var u = feed(&second, from: 0, seconds: 0.4) { _ in 65 }
        u = feed(&second, from: u, seconds: 1.5) { _ in nil }
        _ = feed(&second, from: u, seconds: 0.4) { _ in 67 }
        let spaced = second.finish()
        XCTAssertEqual(MelodyTranscriber.lineBreaks(for: spaced).count, 1)
    }

    func testGarbageNeverTrapsAndSilenceIsEmpty() {
        var silent = MelodyTranscriber()
        _ = feed(&silent, from: 0, seconds: 3) { _ in nil }
        XCTAssertEqual(silent.finish(), [])
        var junk = MelodyTranscriber()
        var random = SeededRandom(seed: 3)
        for i in 0..<5_000 {
            let r = random.uniform()
            let midi: Double? = r < 0.1 ? nil : (r < 0.15 ? .nan : (r < 0.2 ? 1e9 : 30 + 60 * random.uniform()))
            junk.add(time: Double(i) / 100, midi: midi)
        }
        junk.add(time: .nan, midi: 60)
        for note in junk.finish() {
            XCTAssertTrue(SongLimits.pitchRange.contains(note.pitch))
            XCTAssertGreaterThanOrEqual(note.duration, 0.1 - 1e-9)
        }
    }

    func testThroughThePitchPipeline() {
        let rate = 48_000.0
        var signal: [Float] = []
        for midi in [57.0, 60, 64] {
            signal += SignalFactory.tone(.sawtooth, midi: midi, duration: 0.5, sampleRate: rate, amplitude: 0.25)
        }
        signal += [Float](repeating: 0, count: Int(0.3 * rate))
        let frames = analyze(signal, sampleRate: rate)
        var transcriber = MelodyTranscriber()
        for frame in frames { transcriber.add(time: frame.time, midi: frame.midi) }
        let notes = transcriber.finish()
        XCTAssertEqual(notes.map(\.pitch), [57, 60, 64])
    }
}

final class VideoSyncPolicyTests: XCTestCase {
    let policy = VideoSyncPolicy()

    func testInSyncDoesNothing() {
        XCTAssertEqual(policy.action(videoTime: 10.01, targetTime: 10, advancing: true, songRate: 1, currentRate: 1), .none)
    }

    func testStartsPlayingAtSongSpeed() {
        XCTAssertEqual(policy.action(videoTime: 10, targetTime: 10, advancing: true, songRate: 0.7, currentRate: 0), .setRate(0.7))
    }

    func testSmallDriftNudgesRate() {
        // Video ahead: slow down a little. Behind: speed up.
        XCTAssertEqual(policy.action(videoTime: 10.1, targetTime: 10, advancing: true, songRate: 1, currentRate: 1), .setRate(0.94))
        XCTAssertEqual(policy.action(videoTime: 9.9, targetTime: 10, advancing: true, songRate: 1, currentRate: 1), .setRate(1.06))
        // Back in sync: return to the base rate.
        XCTAssertEqual(policy.action(videoTime: 10, targetTime: 10, advancing: true, songRate: 1, currentRate: 1.06), .setRate(1))
    }

    func testBigDriftSeeks() {
        XCTAssertEqual(policy.action(videoTime: 3, targetTime: 10, advancing: true, songRate: 1, currentRate: 1), .seek(to: 10))
    }

    func testHoldsWhenNotAdvancingOrOutsideTheVideo() {
        XCTAssertEqual(policy.action(videoTime: 5, targetTime: 5, advancing: false, songRate: 1, currentRate: 1), .pause(at: 5))
        XCTAssertEqual(policy.action(videoTime: 5, targetTime: 5, advancing: false, songRate: 1, currentRate: 0), .none)
        XCTAssertEqual(policy.action(videoTime: 2, targetTime: -2, advancing: true, songRate: 1, currentRate: 0), .pause(at: 0))
        XCTAssertEqual(policy.action(videoTime: 0, targetTime: -2, advancing: true, songRate: 1, currentRate: 0), .none)
        XCTAssertEqual(policy.action(videoTime: 30, targetTime: 31, advancing: true, songRate: 1, currentRate: 1, duration: 30), .pause(at: 30))
    }

    func testVideoTimeFollowsTheBackingOffset() {
        XCTAssertEqual(VideoSyncPolicy.videoTime(forSongTime: 10, offsetMs: 250), 9.75, accuracy: 1e-9)
    }
}

final class ParticleFieldTests: XCTestCase {
    func testCapacityIsFixedAndOldestAreReplaced() {
        var field = ParticleField(capacity: 8)
        field.emit(count: 5, time: 1, midi: 60, now: 0, kind: .spark, life: 10)
        XCTAssertEqual(field.liveCount(at: 0.1), 5)
        field.emit(count: 20, time: 1, midi: 60, now: 0.1, kind: .burst, life: 10)
        XCTAssertEqual(field.liveCount(at: 0.2), 8)
        var kinds = Set<ParticleField.Kind>()
        field.forEachLive(at: 0.2) { particle, _, _ in kinds.insert(particle.kind) }
        XCTAssertEqual(kinds, [.burst])
    }

    func testParticlesExpireAndFall() {
        var field = ParticleField(capacity: 16, gravity: 400)
        field.emit(count: 4, time: 2, midi: 62, now: 1, kind: .golden, speed: 0, life: 0.5)
        XCTAssertEqual(field.liveCount(at: 1.2), 4)
        XCTAssertEqual(field.liveCount(at: 2), 0)
        XCTAssertEqual(field.liveCount(at: 0.5), 0, "not born yet")
        field.forEachLive(at: 1.2) { particle, age, remaining in
            XCTAssertEqual(age, 0.2, accuracy: 1e-9)
            XCTAssertGreaterThan(remaining, 0)
            let offset = field.offset(of: particle, age: age)
            XCTAssertEqual(offset.dx, 0, accuracy: 1e-9)
            XCTAssertEqual(offset.dy, 0.5 * 400 * 0.04, accuracy: 1e-9)
        }
    }

    func testDeterministicAndIgnoresBadInput() {
        var a = ParticleField(capacity: 4, seed: 7)
        var b = ParticleField(capacity: 4, seed: 7)
        a.emit(count: 4, time: 0, midi: 60, now: 0, kind: .spark)
        b.emit(count: 4, time: 0, midi: 60, now: 0, kind: .spark)
        var pa: [ParticleField.Particle] = []
        var pb: [ParticleField.Particle] = []
        a.forEachLive(at: 0.01) { p, _, _ in pa.append(p) }
        b.forEachLive(at: 0.01) { p, _, _ in pb.append(p) }
        XCTAssertEqual(pa, pb)
        a.reset()
        a.emit(count: 3, time: .nan, midi: 60, now: 0, kind: .spark)
        XCTAssertEqual(a.liveCount(at: 0.01), 0)
    }

    func testComboMilestones() {
        XCTAssertEqual(ComboMilestone.crossed(from: 9, to: 10), 10)
        XCTAssertNil(ComboMilestone.crossed(from: 10, to: 11))
        XCTAssertEqual(ComboMilestone.crossed(from: 20, to: 60), 50)
        XCTAssertNil(ComboMilestone.crossed(from: 5, to: 0))
    }
}

final class VideoSongModelTests: XCTestCase {
    func testVideoFileRoundTripsAndOldFilesDecode() throws {
        let song = Song(id: "v", title: "V", source: .video, notes: [SongNote(start: 0, duration: 1, pitch: 60)],
                        backingAudioFile: "backing.m4a", videoFile: "video.mov")
        let decoded = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertEqual(decoded, song)
        let old = try JSONDecoder().decode(Song.self, from: Data(#"{"id":"x","title":"t","notes":[]}"#.utf8))
        XCTAssertNil(old.videoFile)
        XCTAssertNil(song.excerpt(from: 0, duration: 1).videoFile)
    }

    func testShowVideoSettingDefaultsOn() throws {
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).showVideo)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"showVideo":false}"#.utf8)).showVideo)
    }

    func testAttachVideo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PitchLaneTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SongLibraryStore(root: root)
        let song = Song(id: "s", title: "T", source: .video, notes: [SongNote(start: 0, duration: 1, pitch: 60)])
        try store.save(song)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("clip.MOV")
        try Data("one".utf8).write(to: first)
        let attached = try store.attachVideo(from: first, to: song)
        XCTAssertEqual(attached.videoFile, "video.mov")
        let second = root.appendingPathComponent("clip.mp4")
        try Data("two".utf8).write(to: second)
        let replaced = try store.attachVideo(from: second, to: attached)
        XCTAssertEqual(replaced.videoFile, "video.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(for: "s").appendingPathComponent("video.mov").path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.videoURL(for: replaced))), Data("two".utf8))
        XCTAssertEqual(store.loadAll().songs.first?.videoFile, "video.mp4")
        XCTAssertThrowsError(try store.attachVideo(from: root.appendingPathComponent("missing.mov"), to: replaced))
        XCTAssertEqual(store.loadAll().songs.first?.videoFile, "video.mp4")
    }
}
