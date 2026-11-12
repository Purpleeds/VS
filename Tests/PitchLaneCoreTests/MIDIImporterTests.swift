import XCTest
import PitchLaneCore

/// Builds Standard MIDI Files byte by byte for tests.
enum MIDIBytes {
    static func vlq(_ value: Int) -> [UInt8] {
        var v = value >> 7
        var out = [UInt8(value & 0x7F)]
        while v > 0 {
            out.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return out
    }

    static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    static func header(format: Int, tracks: Int, division: Int = 480) -> [UInt8] {
        Array("MThd".utf8) + be32(6) + be16(format) + be16(tracks) + be16(division)
    }

    static func track(_ events: [UInt8]) -> [UInt8] {
        Array("MTrk".utf8) + be32(events.count) + events
    }

    static func on(_ delta: Int, _ key: Int, channel: Int = 0, velocity: Int = 100) -> [UInt8] {
        vlq(delta) + [UInt8(0x90 | channel), UInt8(key), UInt8(velocity)]
    }

    static func off(_ delta: Int, _ key: Int, channel: Int = 0) -> [UInt8] {
        vlq(delta) + [UInt8(0x80 | channel), UInt8(key), 0]
    }

    static func tempo(_ delta: Int, bpm: Double) -> [UInt8] {
        let micros = Int((60_000_000 / bpm).rounded())
        return vlq(delta) + [0xFF, 0x51, 0x03, UInt8((micros >> 16) & 0xFF), UInt8((micros >> 8) & 0xFF), UInt8(micros & 0xFF)]
    }

    static func meta(_ delta: Int, type: UInt8, _ text: String) -> [UInt8] {
        let bytes = Array(text.utf8)
        return vlq(delta) + [0xFF, type] + vlq(bytes.count) + bytes
    }

    static func end(_ delta: Int = 0) -> [UInt8] {
        vlq(delta) + [0xFF, 0x2F, 0x00]
    }
}

final class MIDIImporterTests: XCTestCase {
    typealias M = MIDIBytes

    private func parse(_ bytes: [UInt8]) throws -> MIDIFile {
        try MIDIFile.parse(Data(bytes))
    }

    private func importError(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) -> SongImportError? {
        do {
            _ = try parse(bytes)
            XCTFail("expected an error", file: file, line: line)
        } catch let error as SongImportError {
            return error
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
        return nil
    }

    func testType0WithRunningStatus() throws {
        // Note on with running status; note off sent as note-on velocity 0.
        var events = M.tempo(0, bpm: 120) + M.on(0, 60)
        events += M.vlq(480) + [60, 0]          // running status: C4 velocity 0 -> off
        events += M.vlq(0) + [64, 90]           // running status: E4 on
        events += M.off(480, 64)
        events += M.end()
        let midi = try parse(M.header(format: 0, tracks: 1) + M.track(events))
        XCTAssertEqual(midi.format, 0)
        XCTAssertEqual(midi.tracks.count, 1)
        XCTAssertEqual(midi.tracks[0].noteCount, 2)
        let song = try midi.song(track: 0, id: "m", title: "T")
        XCTAssertEqual(song.source, .midi)
        XCTAssertEqual(song.notes.map(\.pitch), [60, 64])
        XCTAssertEqual(song.notes[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(song.notes[0].duration, 0.5, accuracy: 1e-9)
        XCTAssertEqual(song.notes[1].start, 0.5, accuracy: 1e-9)
        XCTAssertEqual(song.notes[1].duration, 0.5, accuracy: 1e-9)
    }

    private func type1File() -> [UInt8] {
        let conductor = M.meta(0, type: 0x03, "Test Tune") + M.tempo(0, bpm: 120) + M.tempo(960, bpm: 60) + M.end()
        let melody = M.meta(0, type: 0x03, "Melody")
            + M.on(0, 67) + M.off(480, 67)
            + M.on(480, 69) + M.off(480, 69)
            + M.end()
        let chords = M.meta(0, type: 0x03, "Chords")
            + M.on(0, 60, channel: 1) + M.on(0, 64, channel: 1) + M.on(0, 67, channel: 1)
            + M.off(960, 60, channel: 1) + M.off(0, 64, channel: 1) + M.off(0, 67, channel: 1)
            + M.end()
        let drums = M.meta(0, type: 0x03, "Kit") + M.on(0, 36, channel: 9) + M.off(120, 36, channel: 9) + M.end()
        return M.header(format: 1, tracks: 4) + M.track(conductor) + M.track(melody) + M.track(chords) + M.track(drums)
    }

    func testType1TrackListAndTempoMap() throws {
        let midi = try parse(type1File())
        XCTAssertEqual(midi.format, 1)
        XCTAssertEqual(midi.title, "Test Tune")
        XCTAssertEqual(midi.tracks.map(\.noteCount), [0, 2, 3, 1])
        XCTAssertEqual(midi.tracks.map(\.displayName), ["Test Tune", "Melody", "Chords", "Kit"])
        XCTAssertEqual(midi.tracks[2].channels, [2])
        XCTAssertEqual(midi.tracks[2].lowestPitch, 60)
        XCTAssertEqual(midi.tracks[2].highestPitch, 67)
        XCTAssertTrue(midi.tracks[3].isDrums)
        XCTAssertFalse(midi.tracks[1].isDrums)
        XCTAssertEqual(midi.suggestedMelodyTrack, 1)
        XCTAssertTrue(midi.warnings.isEmpty)

        let song = try midi.song(track: 1, id: "m")
        XCTAssertEqual(song.title, "Test Tune")
        XCTAssertEqual(song.notes.map(\.pitch), [67, 69])
        // 120 BPM until tick 960 (1.0 s), then 60 BPM: a quarter note lasts 1 s.
        XCTAssertEqual(song.notes[1].start, 1.0, accuracy: 1e-9)
        XCTAssertEqual(song.notes[1].duration, 1.0, accuracy: 1e-9)
        XCTAssertEqual(song.tempo, [TempoSegment(start: 0, beatDuration: 0.5), TempoSegment(start: 1.0, beatDuration: 1.0)])
    }

    func testChordsCollapseToHighestNote() throws {
        let song = try parse(type1File()).song(track: 2, id: "c")
        XCTAssertEqual(song.notes.count, 1)
        XCTAssertEqual(song.notes[0].pitch, 67)
        XCTAssertEqual(song.notes[0].duration, 1.0, accuracy: 1e-9)
    }

    func testOverlapsKeepTheHighestSoundingNote() throws {
        // C4 held 0-960; G4 240-480 on top. Expect C4, G4, then C4 resuming.
        let events = M.tempo(0, bpm: 120) + M.on(0, 60) + M.on(240, 67) + M.off(240, 67) + M.off(480, 60) + M.end()
        let song = try parse(M.header(format: 0, tracks: 1) + M.track(events)).song(track: 0, id: "o")
        XCTAssertEqual(song.notes.map(\.pitch), [60, 67, 60])
        XCTAssertEqual(song.notes.map(\.start), [0, 0.25, 0.5])
        XCTAssertEqual(song.notes.map(\.duration), [0.25, 0.25, 0.5])
    }

    func testLyricsAttachAndMarkLines() throws {
        let events = M.tempo(0, bpm: 120)
            + M.meta(0, type: 0x05, "Hel") + M.on(0, 60) + M.off(480, 60)
            + M.meta(0, type: 0x05, "lo ") + M.on(0, 62) + M.off(480, 62)
            + M.meta(0, type: 0x05, "/next") + M.on(0, 64) + M.off(480, 64)
            + M.end()
        let midi = try parse(M.header(format: 0, tracks: 1) + M.track(events))
        XCTAssertEqual(midi.tracks[0].lyricCount, 3)
        let song = try midi.song(track: 0, id: "l")
        XCTAssertEqual(song.notes.map(\.lyric), ["Hel", "lo ", "next"])
        XCTAssertEqual(song.lineBreaks, [1.0])
    }

    func testSMPTEDivision() throws {
        // -25 fps x 40 ticks per frame = 1000 ticks per second.
        let division = (0xE7 << 8) | 40
        let events = M.on(0, 60) + M.off(1_000, 60) + M.end()
        let song = try parse(M.header(format: 0, tracks: 1, division: division) + M.track(events)).song(track: 0, id: "s")
        XCTAssertEqual(song.notes[0].duration, 1.0, accuracy: 1e-9)
    }

    func testUnclosedNoteEndsWithTrackAndUnknownChunksAreSkipped() throws {
        let alien = Array("XFIH".utf8) + M.be32(3) + [1, 2, 3]
        let events = M.on(0, 60) + M.end(960)
        let midi = try parse(M.header(format: 0, tracks: 1) + alien + M.track(events))
        let song = try midi.song(track: 0, id: "u")
        XCTAssertEqual(song.notes[0].duration, 1.0, accuracy: 1e-9)
    }

    func testSysexIsSkipped() throws {
        let sysex = M.vlq(0) + [0xF0] + M.vlq(3) + [0x7E, 0x7F, 0xF7]
        let events = sysex + M.on(0, 62) + M.off(480, 62) + M.end()
        XCTAssertEqual(try parse(M.header(format: 0, tracks: 1) + M.track(events)).tracks[0].noteCount, 1)
    }

    // MARK: Malformed files

    func testNotAMIDIFile() {
        let e = importError(Array("hello, this is text".utf8))
        XCTAssertEqual(e?.byteOffset, 0)
        XCTAssertTrue(e?.message.contains("not a MIDI file") ?? false)
        XCTAssertNotNil(importError([]))
    }

    func testType2Unsupported() {
        XCTAssertTrue(importError(M.header(format: 2, tracks: 1) + M.track(M.end()))?.message.contains("type 2") ?? false)
    }

    func testTruncatedTrackChunk() {
        let bytes = M.header(format: 0, tracks: 1) + Array("MTrk".utf8) + M.be32(100) + [0, 0x90, 60]
        let e = importError(bytes)
        XCTAssertEqual(e?.byteOffset, 14)
        XCTAssertTrue(e?.message.contains("truncated") ?? false)
    }

    func testTruncatedEvent() {
        let bytes = M.header(format: 0, tracks: 1) + M.track(M.vlq(0) + [0x90, 60])
        XCTAssertTrue(importError(bytes)?.message.contains("ends unexpectedly") ?? false)
    }

    func testDataByteWithoutStatus() {
        let bytes = M.header(format: 0, tracks: 1) + M.track(M.vlq(0) + [0x3C, 0x40] + M.end())
        let e = importError(bytes)
        XCTAssertTrue(e?.message.contains("no status") ?? false)
        XCTAssertEqual(e?.byteOffset, 23)
    }

    func testEmptyOrMissingTrackSelection() throws {
        let midi = try parse(type1File())
        XCTAssertThrowsError(try midi.song(track: 0)) { error in
            XCTAssertTrue("\(error)".contains("no notes"))
        }
        XCTAssertThrowsError(try midi.song(track: 9))
    }

    func testRandomBytesAfterValidHeaderThrow() {
        var random = SeededRandom(seed: 5)
        for _ in 0..<100 {
            let junk = (0..<200).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            let bytes = M.header(format: 1, tracks: 1) + M.track(junk)
            do {
                _ = try parse(bytes)
            } catch {
                XCTAssertTrue(error is SongImportError)
            }
        }
    }
}
