import XCTest
import PitchLaneCore

private typealias Word = LyricListenMatcher.HeardWord

/// A pitch track at 100 frames a second from 0 s, with `midi(t)` (nil = unvoiced) up to `seconds`.
private func track(seconds: Double, _ midi: (Double) -> Double?) -> PitchTrack {
    let times = (0..<Int(seconds * 100)).map { Double($0) / 100 }
    return PitchTrack(times: times, midi: times.map(midi))
}

final class PitchTrackTests: XCTestCase {
    func testFramesNearestPitchAndMedian() {
        let t = track(seconds: 2) { $0 < 1 ? 60 : ($0 < 1.5 ? nil : 67) }
        XCTAssertEqual(t.frameRate, 100, accuracy: 1e-6)
        XCTAssertEqual(t.voiced(from: 0.5, to: 0.6).count, 11)
        XCTAssertTrue(t.voiced(from: 1.1, to: 1.4).isEmpty)
        XCTAssertEqual(t.nearestVoiced(to: 1.2, within: 0.5), 60)
        XCTAssertEqual(t.nearestVoiced(to: 1.4, within: 0.5), 67)
        XCTAssertNil(t.nearestVoiced(to: 1.25, within: 0.1))
        XCTAssertEqual(t.voicedMedian, 60)
        XCTAssertFalse(t.isEmpty)
        XCTAssertTrue(PitchTrack(times: [], midi: []).isEmpty)
        XCTAssertNil(PitchTrack(times: [], midi: []).voicedMedian)
    }

    func testSavedCompactlyAndLoadedLeniently() throws {
        let t = PitchTrack(frameRate: 100, start: 0.03, midi: [60.25, 0, 61.5, .nan, -3])
        XCTAssertEqual(t.midi, [60.25, 0, 61.5, 0, 0])
        let data = try JSONEncoder().encode(t)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("6025"))
        XCTAssertEqual(try JSONDecoder().decode(PitchTrack.self, from: data), t)
        let messy = try JSONDecoder().decode(PitchTrack.self, from: Data(#"{"rate":-5,"cents":[6000,"x",null,7000]}"#.utf8))
        XCTAssertEqual(messy.frameRate, 100)
        XCTAssertEqual(messy.midi, [60, 0, 0, 70])
    }
}

final class WordNotesTests: XCTestCase {
    func testEveryWordGetsABarAtTheSungPitch() {
        // "hello" sung on G4, "world" on A4.
        let t = track(seconds: 3) { $0 < 1 ? 67.2 : 69 }
        let words = [Word(text: "hello", time: 0.2, duration: 0.6), Word(text: "world", time: 1.1, duration: 0.7)]
        let result = WordNotes.build(words: words, track: t)
        XCTAssertEqual(result.notes.map(\.pitch), [67, 69])
        XCTAssertEqual(result.notes.map(\.lyric), ["hello ", "world "])
        XCTAssertEqual(result.notes[0].start, 0.2, accuracy: 1e-9)
        XCTAssertEqual(result.notes[0].end, 0.8, accuracy: 1e-9)
        XCTAssertEqual(result.borrowedPitch, 0)
        XCTAssertEqual(result.lineBreaks, []) // a pause of 0.3 s does not start a new line
    }

    func testAMelismaSplitsIntoHeldNotesThatGlide() {
        // One word over three pitches: C4, D4, E4 (0.4 s each).
        let t = track(seconds: 2) { $0 < 0.4 ? 60 : ($0 < 0.8 ? 62 : 64) }
        let result = WordNotes.build(words: [Word(text: "ooh", time: 0, duration: 1.2)], track: t)
        XCTAssertEqual(result.notes.map(\.pitch), [60, 62, 64])
        XCTAssertEqual(result.notes.map(\.lyric), ["ooh ", "~", "~"])
        XCTAssertFalse(result.notes[0].slidesFromPrevious)
        XCTAssertTrue(result.notes[1].slidesFromPrevious)
        XCTAssertEqual(result.notes[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(result.notes[2].end, 1.2, accuracy: 1e-9)
        // The parts are back to back.
        XCTAssertEqual(result.notes[0].end, result.notes[1].start, accuracy: 1e-9)
    }

    func testAWobbleDoesNotSplitAWord() {
        let t = track(seconds: 1) { 62 + 0.3 * sin($0 * 40) }
        let result = WordNotes.build(words: [Word(text: "long", time: 0.1, duration: 0.8)], track: t)
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertEqual(result.notes[0].pitch, 62)
    }

    func testWordsWithoutAPitchBorrowOne() {
        // Voice only from 1.0 s to 1.5 s (E4).
        let t = track(seconds: 4) { $0 >= 1 && $0 < 1.5 ? 64 : nil }
        let words = [
            Word(text: "near", time: 0.6, duration: 0.3), // nearest sung pitch is 0.25 s away
            Word(text: "sung", time: 1.0, duration: 0.4),
            Word(text: "after", time: 3.0, duration: 0.3), // nothing near: takes the word before's
        ]
        let result = WordNotes.build(words: words, track: t)
        XCTAssertEqual(result.notes.map(\.pitch), [64, 64, 64])
        XCTAssertEqual(result.borrowedPitch, 2)
        XCTAssertEqual(result.lineBreaks, [3.0])
        // A song with no pitch at all still gets bars (middle C).
        let silent = WordNotes.build(words: [Word(text: "a", time: 0, duration: 0.3)], track: PitchTrack(times: [], midi: []))
        XCTAssertEqual(silent.notes.map(\.pitch), [60])
    }

    func testOverlappingAndTinyWordsStayInOrderAndPlayable() {
        let t = track(seconds: 2) { _ in 65 }
        let words = [
            Word(text: "b", time: 0.5, duration: 0.02),
            Word(text: "a", time: 0.0, duration: 2.0), // runs over the next word
            Word(text: "c", time: 0.55, duration: 0.3),
            Word(text: " ", time: 1, duration: 0.3),
            Word(text: "bad", time: .nan, duration: 0.3),
        ]
        let notes = WordNotes.build(words: words, track: t).notes
        XCTAssertEqual(notes.map(\.lyric), ["a ", "b ", "c "])
        for (a, b) in zip(notes, notes.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 1e-9) }
        XCTAssertTrue(notes.allSatisfy { $0.duration >= 0.04 })
        XCTAssertTrue(WordNotes.build(words: [], track: t).notes.isEmpty)
    }

    func testTheVoicePitchIsStoredAndDroppedWhenTheVoiceChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PitchLaneTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SongLibraryStore(root: root)
        var song = Song(id: "s", title: "T", source: .video, notes: [SongNote(start: 0, duration: 1, pitch: 60)])
        try store.save(song)
        let saved = PitchTrack(frameRate: 100, start: 0, midi: [60, 61, 0])
        try store.saveVoicePitch(saved, for: song)
        XCTAssertEqual(store.loadVoicePitch(for: song), saved)

        let vocals = root.appendingPathComponent("v.m4a"), music = root.appendingPathComponent("m.m4a")
        try Data("v".utf8).write(to: vocals)
        try Data("m".utf8).write(to: music)
        song = try store.attachStems(vocals: vocals, music: music, to: song)
        XCTAssertNil(store.loadVoicePitch(for: song), "a new voice track needs a new pitch")

        try store.saveVoicePitch(saved, for: song)
        song = try store.removeStems(from: song)
        XCTAssertNil(store.loadVoicePitch(for: song))

        try store.saveVoicePitch(saved, for: song)
        let backing = root.appendingPathComponent("new.mp3")
        try Data("b".utf8).write(to: backing)
        song = try store.attachBackingAudio(from: backing, to: song)
        XCTAssertNil(store.loadVoicePitch(for: song))
    }
}
