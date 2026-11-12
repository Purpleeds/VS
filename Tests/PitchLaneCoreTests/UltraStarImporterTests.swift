import XCTest
import PitchLaneCore

final class UltraStarImporterTests: XCTestCase {
    private let basic = """
    #TITLE:Test Song
    #ARTIST:Tester
    #MP3:test.mp3
    #BPM:300,5
    #GAP:1000
    : 0 4 0 Hel
    : 4 4 2 lo
    * 8 8 4  world
    - 18
    F 20 4 -2 spo
    : 24 4 7 ~
    E
    : 99 1 0 ignored after end
    """

    private func parse(_ text: String) throws -> UltraStarImporter.Result {
        try UltraStarImporter.parse(text: text, id: "test")
    }

    private func error(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> SongImportError? {
        do {
            _ = try parse(text)
            XCTFail("expected an import error", file: file, line: line)
            return nil
        } catch let error as SongImportError {
            return error
        } catch {
            XCTFail("unexpected error type \(error)", file: file, line: line)
            return nil
        }
    }

    func testHeadersAndTiming() throws {
        let result = try parse(basic)
        let song = result.song
        XCTAssertEqual(song.title, "Test Song")
        XCTAssertEqual(song.artist, "Tester")
        XCTAssertEqual(song.source, .ultraStar)
        XCTAssertEqual(result.audioReference, "test.mp3")
        XCTAssertEqual(song.notes.count, 5, "notes after E must be ignored")

        let beat = 60 / (300.5 * 4)
        XCTAssertEqual(song.notes[0].start, 1.0, accuracy: 1e-9)
        XCTAssertEqual(song.notes[0].duration, 4 * beat, accuracy: 1e-9)
        XCTAssertEqual(song.notes[0].pitch, 60, "pitch 0 is C4")
        XCTAssertEqual(song.notes[0].lyric, "Hel")
        XCTAssertEqual(song.notes[1].start, 1.0 + 4 * beat, accuracy: 1e-9)
        XCTAssertEqual(song.notes[1].pitch, 62)
        XCTAssertEqual(song.tempo, [TempoSegment(start: 1.0, beatDuration: 60 / 300.5)])
    }

    func testNoteTypesSlidesAndLineBreaks() throws {
        let song = try parse(basic).song
        let beat = 60 / (300.5 * 4)
        let golden = song.notes[2]
        XCTAssertTrue(golden.isGolden)
        XCTAssertTrue(golden.isScored)
        XCTAssertEqual(golden.lyric, " world", "leading space marks a word boundary")
        XCTAssertEqual(golden.displayLyric, "world")
        XCTAssertEqual(golden.duration, 8 * beat, accuracy: 1e-9)

        let freestyle = song.notes[3]
        XCTAssertTrue(freestyle.isFreestyle)
        XCTAssertFalse(freestyle.isScored)
        XCTAssertEqual(freestyle.pitch, 58)

        let slide = song.notes[4]
        XCTAssertTrue(slide.slidesFromPrevious)
        XCTAssertEqual(slide.lyric, "")
        XCTAssertEqual(slide.pitch, 67)
        XCTAssertEqual(slide.slideDuration ?? 0, min(UltraStarImporter.continuationSlide, 2 * beat), accuracy: 1e-9)

        XCTAssertEqual(song.lineBreaks.count, 1)
        XCTAssertEqual(song.lineBreaks[0], 1.0 + 18 * beat, accuracy: 1e-9)
    }

    func testWindowsLineEndingsGiveTheSameSong() throws {
        let crlf = basic.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try parse(crlf).song, try parse(basic).song)
        let cr = basic.replacingOccurrences(of: "\n", with: "\r")
        XCTAssertEqual(try parse(cr).song, try parse(basic).song)
    }

    func testDotDecimalAndCommaGap() throws {
        let song = try parse("#BPM:120.5\n#GAP:1000,5\n: 0 1 0 la\nE").song
        XCTAssertEqual(song.notes[0].start, 1.0005, accuracy: 1e-9)
        XCTAssertEqual(song.notes[0].duration, 60 / (120.5 * 4), accuracy: 1e-9)
    }

    func testUTF8WithBOM() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("#TITLE:Björk Test\n#BPM:100\n: 0 1 0 ö\nE\n".utf8)
        let song = try UltraStarImporter.parse(data: data, id: "x").song
        XCTAssertEqual(song.title, "Björk Test")
        XCTAssertEqual(song.notes[0].lyric, "ö")
    }

    func testLatin1AndWindows1252() throws {
        var bytes: [UInt8] = Array("#TITLE:Caf".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: "\n#ARTIST:".utf8)
        bytes.append(0x93)
        bytes.append(contentsOf: "Q".utf8)
        bytes.append(0x94)
        bytes.append(contentsOf: "\n#BPM:120\n: 0 1 0 ".utf8)
        bytes.append(0xFC)
        bytes.append(contentsOf: "ber\nE\n".utf8)
        let song = try UltraStarImporter.parse(data: Data(bytes), id: "x").song
        XCTAssertEqual(song.title, "Café")
        XCTAssertEqual(song.artist, "\u{201C}Q\u{201D}")
        XCTAssertEqual(song.notes[0].lyric, "über")
    }

    func testRelativeMode() throws {
        let song = try parse("""
        #BPM:120
        #RELATIVE:YES
        : 0 2 0 a
        : 2 2 0 b
        - 4 4
        : 0 2 0 c
        - 2 6
        : 1 2 0 d
        E
        """).song
        let beat = 60.0 / 480
        XCTAssertEqual(song.notes.map(\.lyric), ["a", "b", "c", "d"])
        XCTAssertEqual(song.notes.map(\.start), [0, 2, 4, 11].map { Double($0) * beat })
        XCTAssertEqual(song.lineBreaks, [4, 6].map { Double($0) * beat })
    }

    func testDuetImportsPlayerOne() throws {
        let result = try parse("#BPM:120\nP1\n: 0 1 0 one\nP2\n: 0 1 5 two\nP1\n: 2 1 0 three\nE")
        XCTAssertEqual(result.song.notes.map(\.lyric), ["one", "three"])
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testAudioHeaderPreferredOverMP3AndTitleFallback() throws {
        let result = try UltraStarImporter.parse(text: "#MP3:old.mp3\n#AUDIO:new.m4a\n#BPM:100\n: 0 1 0 a\nE", id: "x", fallbackTitle: "my-file")
        XCTAssertEqual(result.audioReference, "new.m4a")
        XCTAssertEqual(result.song.title, "my-file")
    }

    func testMissingEndMarkerIsFine() throws {
        XCTAssertEqual(try parse("#BPM:100\n: 0 1 0 a\n: 2 1 0 b\n").song.notes.count, 2)
    }

    func testUnsortedNotesAreSorted() throws {
        let song = try parse("#BPM:100\n: 8 1 0 b\n: 0 1 0 a\nE").song
        XCTAssertEqual(song.notes.map(\.lyric), ["a", "b"])
    }

    // MARK: Malformed files

    func testMissingBPM() {
        let e = error("#TITLE:x\n: 0 1 0 a\nE")
        XCTAssertNil(e?.line)
        XCTAssertTrue(e?.description.contains("#BPM") ?? false)
    }

    func testBadBPM() {
        XCTAssertEqual(error("#BPM:fast\n: 0 1 0 a")?.line, 1)
        XCTAssertEqual(error("#TITLE:x\n#BPM:0\n: 0 1 0 a")?.line, 2)
        XCTAssertEqual(error("#BPM:-20\n: 0 1 0 a")?.line, 1)
    }

    func testBadGap() {
        XCTAssertEqual(error("#BPM:100\n#GAP:soon\n: 0 1 0 a")?.line, 2)
    }

    func testMalformedNoteLinesReportTheLine() {
        let missingPitch = error("#BPM:100\n: 0 1 0 ok\n: 4 2 la\nE")
        XCTAssertEqual(missingPitch?.line, 3)
        XCTAssertEqual(missingPitch?.description.hasPrefix("Line 3: note needs start, length and pitch"), true)
        XCTAssertEqual(error("#BPM:100\n: a 4 0 x")?.line, 2)
        XCTAssertEqual(error("#BPM:100\n: 0 4 0x la")?.line, 2)
        XCTAssertEqual(error("#BPM:100\n: 0 0 0 la")?.line, 2)
        XCTAssertEqual(error("#BPM:100\n: 0 -3 0 la")?.line, 2)
    }

    func testUnknownLineTypeAndBPMChanges() {
        let unknown = error("#BPM:100\n: 0 1 0 a\nX 0 1 0 la")
        XCTAssertEqual(unknown?.line, 3)
        XCTAssertTrue(unknown?.message.contains("unknown line type") ?? false)
        XCTAssertEqual(error("#BPM:100\n: 0 1 0 a\nB 4 200")?.line, 3)
    }

    func testHeaderWithoutColonAndBadBreak() {
        XCTAssertEqual(error("#TITLE Something\n#BPM:100\n: 0 1 0 a")?.line, 1)
        XCTAssertEqual(error("#BPM:100\n: 0 1 0 a\n- soon")?.line, 3)
        XCTAssertEqual(error("#BPM:100\nP x\n: 0 1 0 a")?.line, 2)
    }

    func testNoNotes() {
        XCTAssertEqual(error("#TITLE:x\n#BPM:100\nE")?.message, "no notes found")
        XCTAssertNotNil(error(""))
    }

    func testRandomBytesThrowInsteadOfCrashing() {
        var random = SeededRandom(seed: 99)
        for _ in 0..<50 {
            let bytes = (0..<300).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            XCTAssertThrowsError(try UltraStarImporter.parse(data: Data(bytes)))
        }
    }

    func testErrorDescriptions() {
        XCTAssertEqual(SongImportError(line: 7, "bad").description, "Line 7: bad")
        XCTAssertEqual(SongImportError(byteOffset: 12, "bad").description, "Byte 12: bad")
        XCTAssertEqual(SongImportError("bad").errorDescription, "bad")
    }
}
