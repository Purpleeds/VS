import XCTest
import PitchLaneCore

/// Regression tests for the step 6 review fixes: bad input never traps, corrupt files never wipe data,
/// and the pitch engine stays unvoiced when unsure.
final class SongLimitsTests: XCTestCase {
    private func ultraStarError(_ text: String) -> SongImportError? {
        do {
            _ = try UltraStarImporter.parse(text: text, id: "x")
            return nil
        } catch {
            return error as? SongImportError
        }
    }

    func testHugeGapAndStartBeatsAreRejectedNotTrapped() {
        XCTAssertNotNil(ultraStarError("#BPM:120\n#GAP:1e30\n: 0 4 0 la\nE\n"))
        XCTAssertNotNil(ultraStarError("#BPM:1\n: 9000000000000000000 1 0 la\nE\n"))
    }

    func testPitchNearIntMaxIsRejected() {
        XCTAssertEqual(ultraStarError("#BPM:120\n: 0 4 9223372036854775807 la\nE\n")?.line, 2)
        XCTAssertEqual(ultraStarError("#BPM:120\n: 0 4 99999 la\nE\n")?.line, 2)
    }

    func testAbsurdTempoIsRejected() {
        XCTAssertEqual(ultraStarError("#BPM:1e308\n: 0 4 0 la\n: 8 4 2 la\nE\n")?.line, 1)
        XCTAssertEqual(ultraStarError("#BPM:999999999\n: 0 4 0 la\nE\n")?.line, 1)
    }

    func testDuetBothSingersSectionIsKept() throws {
        let result = try UltraStarImporter.parse(text: "#BPM:300\nP1\n: 0 4 0 a\nP3\n: 8 4 0 both\nP2\n: 16 4 0 b\nE\n", id: "d")
        XCTAssertEqual(result.song.notes.map(\.displayLyric), ["a", "both"])
    }

    func testNotesBeforeTheSongStartWarn() throws {
        let result = try UltraStarImporter.parse(text: "#BPM:300\n: -400 4 0 early\n: 0 4 0 la\nE\n", id: "n")
        XCTAssertTrue(result.warnings.contains { $0.contains("before the song") })
    }

    func testDurationTextIsTotal() {
        let summary = SongSummary(noteCount: 1, scoredNoteCount: 1, goldenCount: 0, pitchRange: 60...60, duration: 1e27, hasBackingAudio: false)
        XCTAssertEqual(summary.durationText, "–")
        let nan = SongSummary(noteCount: 1, scoredNoteCount: 1, goldenCount: 0, pitchRange: 60...60, duration: .nan, hasBackingAudio: false)
        XCTAssertEqual(nan.durationText, "–")
    }

    func testClickTimesIgnoreTinyBeatsAndAreCapped() {
        let tiny = Song(id: "t", title: "t", source: .ultraStar, notes: [SongNote(start: 0, duration: 1, pitch: 60)],
                        tempo: [TempoSegment(start: 0, beatDuration: 6e-307)])
        XCTAssertEqual(tiny.clickTimes(from: 0, to: 0.5), [])
        let normal = Song(id: "n", title: "n", source: .ultraStar, notes: [SongNote(start: 0, duration: 1, pitch: 60)],
                          tempo: [TempoSegment(start: 0, beatDuration: 0.05)])
        XCTAssertEqual(normal.clickTimes(from: 0, to: 1_000).count, 1_024)
        XCTAssertEqual(normal.clickTimes(from: .nan, to: 1), [])
    }

    func testSongJSONWithOutOfRangeValuesFailsToDecode() {
        func song(_ note: String) -> String { #"{"id":"x","title":"t","notes":["# + note + "]}" }
        let badPitch = song(#"{"start":0,"duration":1,"pitch":100059}"#)
        let badStart = song(#"{"start":1e27,"duration":1,"pitch":60}"#)
        let fine = song(#"{"start":0,"duration":1,"pitch":60}"#)
        XCTAssertThrowsError(try JSONDecoder().decode(Song.self, from: Data(badPitch.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Song.self, from: Data(badStart.utf8)))
        XCTAssertNoThrow(try JSONDecoder().decode(Song.self, from: Data(fine.utf8)))
    }
}

final class MIDIOverlapTests: XCTestCase {
    typealias M = MIDIBytes

    func testDescendingLegatoKeepsLyrics() throws {
        // 64 at 0-480, 62 at 460-940, 60 at 920-1400: each lower note starts under the higher one.
        let parts: [[UInt8]] = [
            M.tempo(0, bpm: 120),
            M.meta(0, type: 0x05, "one"), M.on(0, 64),
            M.meta(460, type: 0x05, "two"), M.on(0, 62),
            M.off(20, 64),
            M.meta(440, type: 0x05, "three"), M.on(0, 60),
            M.off(20, 62),
            M.off(460, 60),
            M.end(),
        ]
        let events = parts.flatMap { $0 }
        let song = try MIDIFile.parse(Data(M.header(format: 0, tracks: 1) + M.track(events))).song(track: 0, id: "l")
        XCTAssertEqual(song.notes.map(\.pitch), [64, 62, 60])
        XCTAssertEqual(song.notes.map(\.lyric), ["one", "two", "three"])
    }

    func testShortTopNoteOfAChordDoesNotHideTheMelody() throws {
        // 72 and 60 start together; 72 lasts 10 ticks, 60 a whole bar.
        let events = M.tempo(0, bpm: 120) + M.on(0, 72) + M.on(0, 60) + M.off(10, 72) + M.off(950, 60) + M.end()
        let song = try MIDIFile.parse(Data(M.header(format: 0, tracks: 1) + M.track(events))).song(track: 0, id: "c")
        XCTAssertEqual(song.notes.map(\.pitch), [60])
        XCTAssertEqual(song.notes[0].duration, 1.0, accuracy: 0.02)
    }

    func testAbsurdTempoEventIsIgnored() throws {
        // FF 51 03 00 00 01: 1 µs per quarter.
        let absurdTempo: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x00, 0x00, 0x01]
        var events: [UInt8] = M.tempo(0, bpm: 120)
        events.append(contentsOf: absurdTempo)
        events.append(contentsOf: M.on(0, 60))
        events.append(contentsOf: M.off(480, 60))
        events.append(contentsOf: M.end())
        let song = try MIDIFile.parse(Data(M.header(format: 0, tracks: 1) + M.track(events))).song(track: 0, id: "t")
        XCTAssertEqual(song.notes[0].duration, 0.5, accuracy: 1e-9)
        XCTAssertTrue(song.tempo.allSatisfy { $0.beatDuration >= 0.05 })
    }
}

final class PersistenceRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PitchLaneTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testCorruptFileIsQuarantinedNotOverwritten() throws {
        let url = directory.appendingPathComponent("history.json")
        try Data("{ not json".utf8).write(to: url)
        let store = JSONFileStore<GameHistory>(url: url)
        let loaded = store.loadOrQuarantine(now: Date(timeIntervalSince1970: 100))
        XCTAssertNil(loaded.value)
        XCTAssertNotNil(loaded.problem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let kept = directory.appendingPathComponent("history.corrupt-100.json")
        XCTAssertEqual(try Data(contentsOf: kept), Data("{ not json".utf8))

        // Only the newest two copies are kept.
        for stamp in [200.0, 300.0] {
            try Data("bad".utf8).write(to: url)
            _ = store.loadOrQuarantine(now: Date(timeIntervalSince1970: stamp))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("corrupt") }.sorted()
        XCTAssertEqual(names, ["history.corrupt-200.json", "history.corrupt-300.json"])
    }

    func testMissingFileIsNotAProblem() {
        let loaded = JSONFileStore<GameHistory>(url: directory.appendingPathComponent("none.json")).loadOrQuarantine()
        XCTAssertNil(loaded.value)
        XCTAssertNil(loaded.problem)
    }

    func testHistorySkipsBadRecordsAndFillsMissingFields() throws {
        let json = #"""
        {"records":[
          {"songID":"a","songTitle":"A","difficulty":"normal","date":0,"score":10,"accuracy":0.5,"grade":"C","maxCombo":1,"practice":false,"speed":1,"failed":false,"transpose":0,"id":"9A0C1E04-3B4A-4F5E-8C6D-7E8F9A0B1C2D"},
          {"songTitle":"no song id"},
          {"songID":"b","difficulty":"impossible","grade":"Z","score":"lots"}
        ]}
        """#
        let history = try JSONDecoder().decode(GameHistory.self, from: Data(json.utf8))
        XCTAssertEqual(history.records.map(\.songID), ["a", "b"])
        XCTAssertEqual(history.records[1].difficulty, .normal)
        XCTAssertEqual(history.records[1].score, 0)
    }

    func testPersonalBestsSkipBadEntries() throws {
        let json = #"{"records":{"a|normal":{"score":5,"accuracy":0.9,"grade":"A","maxCombo":3,"date":0},"b|hard":{"grade":"A"}}}"#
        let bests = try JSONDecoder().decode(PersonalBests.self, from: Data(json.utf8))
        XCTAssertEqual(bests.best(songID: "a", difficulty: .normal)?.score, 5)
        XCTAssertNil(bests.best(songID: "b", difficulty: .hard))
    }

    func testLatencyProfilesReadOldAndNewFormsAndSkipUnknownRoutes() throws {
        let old = #"{"routes":["speaker",{"nudgeMs":10},"carPlay",{"nudgeMs":5},"wired",{"calibrationMs":42,"nudgeMs":0}]}"#
        let profiles = try JSONDecoder().decode(LatencyProfiles.self, from: Data(old.utf8))
        XCTAssertEqual(profiles[.speaker].nudgeMs, 10)
        XCTAssertEqual(profiles[.wired].calibrationMs, 42)

        let data = try JSONEncoder().encode(profiles)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""speaker":{"#), text)
        XCTAssertEqual(try JSONDecoder().decode(LatencyProfiles.self, from: data), profiles)

        let keyed = #"{"routes":{"bluetooth":{"calibrationMs":120,"nudgeMs":"x"},"satellite":{"nudgeMs":1}}}"#
        let fromKeyed = try JSONDecoder().decode(LatencyProfiles.self, from: Data(keyed.utf8))
        XCTAssertEqual(fromKeyed[.bluetooth].calibrationMs, 120)
        XCTAssertEqual(fromKeyed[.bluetooth].nudgeMs, 0)
    }

    func testSettingsSurviveOneWrongField() throws {
        let json = #"{"debugOverlay":true,"clickTrack":"yes","guideVolume":0.3}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.debugOverlay)
        XCTAssertFalse(settings.clickTrack)
        XCTAssertEqual(settings.guideVolume, 0.3, accuracy: 1e-9)
    }

    func testLibraryTrustsTheFolderNotTheIDInsideSongJSON() throws {
        let store = SongLibraryStore(root: directory)
        let song = Song(id: "real-id", title: "T", source: .ultraStar, notes: [SongNote(start: 0, duration: 1, pitch: 60)])
        try store.save(song)
        // Hand-edit the id to point outside the library.
        let url = store.folder(for: "real-id").appendingPathComponent(SongLibraryStore.songFileName)
        var edited = song
        edited.id = "../.."
        try JSONEncoder().encode(edited).write(to: url)
        let loaded = store.loadAll().songs
        XCTAssertEqual(loaded.map(\.id), ["real-id"])
        XCTAssertTrue(store.folder(for: "../..").path.hasPrefix(directory.path))
        XCTAssertThrowsError(try store.save(edited))
    }

    func testFailedBackingCopyKeepsTheOldAudio() throws {
        let store = SongLibraryStore(root: directory)
        let song = Song(id: "s", title: "T", source: .ultraStar, notes: [SongNote(start: 0, duration: 1, pitch: 60)])
        try store.save(song)
        let source = directory.appendingPathComponent("first.mp3")
        try Data("audio".utf8).write(to: source)
        let attached = try store.attachBackingAudio(from: source, to: song)
        XCTAssertThrowsError(try store.attachBackingAudio(from: directory.appendingPathComponent("missing.m4a"), to: attached))
        let backing = try XCTUnwrap(store.backingAudioURL(for: attached))
        XCTAssertEqual(try Data(contentsOf: backing), Data("audio".utf8))
        XCTAssertEqual(store.loadAll().songs.first?.backingAudioFile, "backing.mp3")
        // No staging files left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: store.folder(for: "s").path)
        XCTAssertFalse(names.contains { $0.contains("incoming") }, "\(names)")
    }

    func testUnencodableSongLeavesNoFolder() {
        let store = SongLibraryStore(root: directory)
        let song = Song(id: "nan", title: "T", source: .ultraStar, notes: [SongNote(start: .nan, duration: 1, pitch: 60)])
        XCTAssertThrowsError(try store.save(song, originalFileName: "x.txt", originalData: Data("x".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(for: "nan").path))
    }
}

final class PitchRobustnessTests: XCTestCase {
    func testNotesBelowTheRangeAreUnvoicedNotSnappedToC2() {
        for midi in [35.0, 34.5, 34.0] {
            let frames = analyze(SignalFactory.tone(midi: midi, duration: 0.4, sampleRate: 48_000), sampleRate: 48_000)
            let voiced = frames.filter { $0.frequency != nil }.count
            XCTAssertLessThanOrEqual(Double(voiced), 0.05 * Double(frames.count), "MIDI \(midi): \(voiced) of \(frames.count) voiced")
        }
        let c2 = analyze(SignalFactory.tone(midi: 36, duration: 0.4, sampleRate: 48_000), sampleRate: 48_000)
        XCTAssertEqual(c2.filter { $0.frequency == nil }.count, 0)
    }

    func testOneNaNSampleDoesNotKillDetection() {
        var signal = SignalFactory.tone(midi: 57, duration: 1, sampleRate: 48_000)
        signal[2_000] = .nan
        signal[2_001] = .infinity
        let frames = analyze(signal, sampleRate: 48_000)
        let late = frames.filter { $0.time > 0.5 }
        XCTAssertFalse(late.isEmpty)
        XCTAssertTrue(late.allSatisfy { $0.frequency != nil }, "detection did not recover after a NaN")
    }

    func testHysteresisContinuesButNeverStartsOrMovesANote() {
        let loud = 0.1
        func estimate(_ hz: Double, _ confidence: Double) -> PitchEstimate {
            PitchEstimate(frequency: hz, confidence: confidence, rms: loud)
        }
        var fresh = PitchStabilizer()
        XCTAssertEqual(fresh.process(estimate(220, 0.82)).unvoicedReason, .lowConfidence)

        var stabilizer = PitchStabilizer()
        for _ in 0..<3 { _ = stabilizer.process(estimate(220, 0.95)) }
        XCTAssertNotNil(stabilizer.process(estimate(221, 0.82)).midi)
        XCTAssertEqual(stabilizer.process(estimate(330, 0.82)).unvoicedReason, .lowConfidence)
        XCTAssertEqual(stabilizer.process(estimate(220, 0.70)).unvoicedReason, .lowConfidence)
    }

    func testGuideRateIsChunkSizeIndependent() {
        let song = Song(id: "g", title: "G", source: .builtIn, notes: [
            SongNote(start: 0.05, duration: 0.3, pitch: 67),
            SongNote(start: 0.4, duration: 0.3, pitch: 71, slidesFromPrevious: true),
        ])
        let rate = 48_000.0
        func render(chunk: Int) -> [Float] {
            let renderer = GuideToneRenderer(song: song)
            let total = Int(1.6 * rate)
            var out = [Float](repeating: 0, count: total)
            out.withUnsafeMutableBufferPointer { buffer in
                var offset = 0
                while offset < total {
                    let n = min(chunk, total - offset)
                    renderer.render(into: buffer.baseAddress! + offset, frameCount: n, sampleRate: rate,
                                    songTime: 0.5 * Double(offset) / rate, rate: 0.5, advancing: true, volume: 1)
                    offset += n
                }
            }
            return out
        }
        let a = render(chunk: 1_024)
        let b = render(chunk: 37)
        let maxDiff = zip(a, b).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxDiff, 1e-3)
        // At half speed the second note (song 0.4-0.7 s) sounds at output 0.8-1.4 s.
        XCTAssertGreaterThan(SignalFactory.rms(a[Int(1.2 * rate)..<Int(1.3 * rate)]), 0.05)
    }
}
