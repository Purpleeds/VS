import XCTest
import PitchLaneCore

final class KaraokeLinesTests: XCTestCase {
    private func song(_ lyrics: [String], step: Double = 1, duration: Double = 0.8, breaks: [Double] = []) -> Song {
        let notes = lyrics.enumerated().map { SongNote(start: Double($0) * step, duration: duration, pitch: 60, lyric: $1) }
        return Song(id: "k", title: "K", source: .ultraStar, notes: notes, lineBreaks: breaks)
    }

    func testSyllablesJoinIntoWordsAndLinesSplitAtBreaks() {
        let s = song(["Twin", "kle ", "twin", "kle ", "lit", "tle ", "star"], breaks: [4])
        let lines = KaraokeLines.build(song: s, display: s.notes.map(\.displayLyric))
        XCTAssertEqual(lines.map(\.text), ["Twinkle twinkle", "little star"])
        XCTAssertEqual(lines[0].pieces.map(\.text), ["Twin", "kle", " twin", "kle"])
        XCTAssertEqual(lines[1].pieces.map(\.noteIndex), [4, 5, 6])
        XCTAssertEqual(lines[1].start, 4)
        XCTAssertEqual(lines[1].end, 6.8, accuracy: 1e-9)
    }

    func testHeldAndWordlessNotesExtendTheWordBeforeThem() {
        let s = song(["Hel", "~", "lo", ""], step: 0.5, duration: 0.5)
        let lines = KaraokeLines.build(song: s, display: s.notes.map(\.displayLyric))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hel lo")
        XCTAssertEqual(lines[0].pieces[0].end, 1.0, accuracy: 1e-9)
        XCTAssertEqual(lines[0].pieces[1].end, 2.0, accuracy: 1e-9)
    }

    func testJapaneseRomajiHasNoSpacesAndFittedWordsKeepTheirs() {
        let japanese = song(["か", "ぜ", "が"])
        XCTAssertEqual(KaraokeLines.build(song: japanese, display: ["ka", "ze", "ga"]).map(\.text), ["kazega"])
        let words = song(["hello ", "big ", "world "])
        XCTAssertEqual(KaraokeLines.build(song: words, display: words.notes.map(\.displayLyric)).map(\.text), ["hello big world"])
        // A display list of the wrong length falls back to the notes' own words.
        XCTAssertEqual(KaraokeLines.build(song: words, display: ["x"]).map(\.text), ["hello big world"])
    }

    func testPausesSplitLinesWhenThereAreNoBreaksAndEmptySongsHaveNone() {
        let s = Song(id: "p", title: "P", source: .video, notes: [0, 0.5, 4, 4.5].map {
            SongNote(start: $0, duration: 0.4, pitch: 60, lyric: "la ")
        })
        XCTAssertEqual(KaraokeLines.build(song: s, display: s.notes.map(\.displayLyric)).map(\.text), ["la la", "la la"])
        let silent = song(["", "", ""])
        XCTAssertTrue(KaraokeLines.build(song: silent, display: ["", "", ""]).isEmpty)
        XCTAssertTrue(KaraokeLines.build(song: Song(id: "e", title: "E", source: .video, notes: []), display: []).isEmpty)
    }

    func testWhichLineIsShown() {
        // Two lines with a gap: 0...2.8 and 6...8.8.
        let notes = [0.0, 1, 2, 6, 7, 8].map { SongNote(start: $0, duration: 0.8, pitch: 60, lyric: "la ") }
        let lines = KaraokeLines.build(song: Song(id: "g", title: "G", source: .ultraStar, notes: notes, lineBreaks: [6]), display: notes.map(\.displayLyric))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(KaraokeLines.current(lines, at: -1), 0)
        XCTAssertNil(KaraokeLines.current(lines, at: -4))
        XCTAssertEqual(KaraokeLines.current(lines, at: 3.1), 0) // held a moment after its last word
        XCTAssertEqual(KaraokeLines.current(lines, at: 3.3), 1) // then the next one, three seconds ahead
        XCTAssertEqual(KaraokeLines.current(lines, at: 7.5), 1)
        XCTAssertNil(KaraokeLines.current(lines, at: 9.5))
        XCTAssertNil(KaraokeLines.current([], at: 0))
        // Back to back (0...2.8 and 3...5.8): the next line takes over just before it starts.
        let s = song(["a ", "b ", "c ", "d ", "e ", "f "], breaks: [3])
        let close = KaraokeLines.build(song: s, display: s.notes.map(\.displayLyric))
        XCTAssertEqual(KaraokeLines.current(close, at: 2.7), 0)
        XCTAssertEqual(KaraokeLines.current(close, at: 2.9), 1)
        let piece = lines[0].pieces[0]
        XCTAssertEqual(KaraokeLines.progress(of: piece, at: -1), 0)
        XCTAssertEqual(KaraokeLines.progress(of: piece, at: 0.4), 0.5, accuracy: 1e-9)
        XCTAssertEqual(KaraokeLines.progress(of: piece, at: 5), 1)
    }
}
