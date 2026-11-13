import XCTest
import PitchLaneCore

final class LRCParserTests: XCTestCase {
    func testLinesTagsOffsetAndRepeats() {
        let lrc = """
        [ti:Test]
        [ar:Someone]
        [offset:+500]
        [00:12.50]Hello bright world
        [00:15.00]
        [00:20.00][01:05.25]Chorus line here
        not a lyric line
        [99:xx]broken
        """
        let lines = LRCParser.parse(lrc)
        XCTAssertEqual(lines.map(\.text), ["Hello bright world", "", "Chorus line here", "Chorus line here"])
        XCTAssertEqual(lines[0].time, 12.0, accuracy: 1e-9)   // 12.5 - 0.5 offset
        XCTAssertEqual(lines[3].time, 64.75, accuracy: 1e-9)
        XCTAssertEqual(lines[0].words.map(\.text), ["Hello", "bright", "world"])
        XCTAssertTrue(lines[1].words.isEmpty)
    }

    func testTimestampVariantsAndEnhancedWords() {
        let lines = LRCParser.parse("[1:02]a\n[00:03.4]b\n[00:04:50]c\n[00:05.123]<00:05.20>one <00:05.90>two")
        assertTimes(lines.map(\.time), [3.4, 4.5, 5.123, 62])
        XCTAssertEqual(lines[2].words, [LyricLine.Word(time: 5.2, text: "one"), LyricLine.Word(time: 5.9, text: "two")])
    }

    func testGarbageNeverTraps() {
        var random = SeededRandom(seed: 11)
        for _ in 0..<300 {
            let bytes = (0..<Int(random.next() % 200)).map { _ in UInt8(random.next() % 128) }
            _ = LRCParser.parse(String(decoding: bytes, as: UTF8.self))
        }
        _ = LRCParser.parse("[99999999999:00.00]x\n[00:-5]y\n[::]z\n[")
    }
}

private func assertTimes(_ a: [Double], _ b: [Double], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 1e-9, file: file, line: line) }
}

final class LyricsSearchTests: XCTestCase {
    func testSearchURLEncodesTheQuery() {
        let url = LyricsSearch.searchURL(query: "  Björk & Friends / Song?  ")
        XCTAssertEqual(url?.host, "lrclib.net")
        XCTAssertEqual(url?.path, "/api/search")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.first { $0.name == "q" }?.value, "Björk & Friends / Song?")
        XCTAssertNil(LyricsSearch.searchURL(query: "   "))
    }

    func testDecodeRanksSyncedAndCloseDurationsAndSkipsJunk() throws {
        let json = #"""
        [
          {"id":1,"trackName":"Plain","artistName":"A","duration":200,"instrumental":false,"plainLyrics":"la la","syncedLyrics":null},
          {"id":2,"trackName":"Far","artistName":"A","duration":400,"instrumental":false,"plainLyrics":"x","syncedLyrics":"[00:01.00]x"},
          {"id":3,"trackName":"Close","artistName":"A","duration":181,"instrumental":false,"plainLyrics":"x","syncedLyrics":"[00:01.00]x"},
          {"id":4,"trackName":"Inst","artistName":"A","duration":180,"instrumental":true},
          {"id":"bad"},
          {"id":5,"trackName":"Empty","artistName":"A","duration":180,"instrumental":false,"plainLyrics":"","syncedLyrics":""}
        ]
        """#
        let results = try LyricsSearch.decode(Data(json.utf8), songDuration: 180)
        XCTAssertEqual(results.map(\.id), [3, 2, 1])
        XCTAssertEqual(results[0].credit, "Close · A")
        XCTAssertThrowsError(try LyricsSearch.decode(Data("not json".utf8)))
    }
}

final class LyricAlignerTests: XCTestCase {
    private func song(_ starts: [Double], duration: Double = 0.4) -> Song {
        Song(id: "s", title: "S", source: .video, notes: starts.map { SongNote(start: $0, duration: duration, pitch: 60, lyric: "old") })
    }

    func testWordsGoOntoTheNotesOfTheirLine() {
        // Line 1 at 1.0 s over notes 1.0, 1.5, 2.0; line 2 at 4.0 s over 4.0, 4.5.
        let target = song([1.0, 1.5, 2.0, 4.0, 4.5])
        let lines = LRCParser.parse("[00:01.00]one two three\n[00:04.00]four five six")
        let result = LyricAligner.apply(lines: lines, to: target, autoOffset: false)
        XCTAssertEqual(result.song.notes.map(\.displayLyric), ["one", "two", "three", "four", "five six"])
        XCTAssertEqual(result.wordsPlaced, 6)
        XCTAssertEqual(result.wordsTotal, 6)
        XCTAssertEqual(result.song.lineBreaks, [4.0])
        XCTAssertEqual(result.song.notes[0].lyric, "one ", "word boundary kept")
    }

    func testMoreNotesThanWordsSpreadsAndBlankLinesEndALine() {
        let target = song([1.0, 1.4, 1.8, 2.2, 6.0])
        let lines = LRCParser.parse("[00:01.00]hold on\n[00:03.00]\n[00:06.00]end")
        let result = LyricAligner.apply(lines: lines, to: target, autoOffset: false)
        XCTAssertEqual(result.song.notes.map(\.displayLyric), ["hold", "", "on", "", "end"])
    }

    func testAutoOffsetFindsAShiftedIntro() {
        // Notes start 2.5 s after the lyric times (a video with a longer intro).
        let lineTimes = [5.0, 9.0, 13.0, 17.0, 21.0, 25.0]
        var starts: [Double] = []
        for t in lineTimes { starts += [t + 2.5, t + 3.0, t + 3.5] }
        let lrc = lineTimes.map { String(format: "[00:%05.2f]a b c", $0) }.joined(separator: "\n")
        let result = LyricAligner.apply(lines: LRCParser.parse(lrc), to: song(starts))
        XCTAssertEqual(result.offset, 2.5, accuracy: 0.051)
        XCTAssertEqual(result.notesWithWords, starts.count)
        // Already aligned: offset stays 0.
        let aligned = LyricAligner.apply(lines: LRCParser.parse(lrc), to: song(lineTimes.flatMap { [$0, $0 + 0.5, $0 + 1] }))
        XCTAssertEqual(aligned.offset, 0)
    }

    func testEnhancedWordTimesPickTheNearestNote() {
        let target = song([1.0, 1.3, 1.6, 1.9])
        let lines = LRCParser.parse("[00:01.00]<00:01.00>one <00:01.85>two")
        let result = LyricAligner.apply(lines: lines, to: target, autoOffset: false)
        XCTAssertEqual(result.song.notes.map(\.displayLyric), ["one", "", "", "two"])
    }

    func testPlainLyricsFollowPhrases() {
        // Two phrases separated by a 1 s gap.
        let target = song([0, 0.5, 1.0, 2.5, 3.0])
        let result = LyricAligner.applyPlain("[Verse]\nfirst line words\n\nsecond go", to: target)
        XCTAssertEqual(result.song.notes.map(\.displayLyric), ["first", "line", "words", "second", "go"])
        XCTAssertEqual(result.song.lineBreaks, [2.5])
        XCTAssertEqual(LyricAligner.applyPlain("", to: target).wordsPlaced, 0)
    }

    func testLyricsCreditRoundTrips() throws {
        var target = song([0])
        target.lyricsCredit = "LRCLIB: X · Y"
        XCTAssertEqual(try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(target)).lyricsCredit, "LRCLIB: X · Y")
    }
}

final class VoiceQueryTests: XCTestCase {
    private let songs = [
        VoiceQuery.Candidate(id: "1", title: "Morning Glory Waltz", artist: "Tester"),
        VoiceQuery.Candidate(id: "2", title: "Major Scale"),
        VoiceQuery.Candidate(id: "3", title: "Minor Scale"),
        VoiceQuery.Candidate(id: "4", title: "Café Nocturne", artist: "Duo"),
    ]

    func testCleanRemovesRequestWords() {
        XCTAssertEqual(VoiceQuery.clean("Play Morning Glory Waltz please."), "Morning Glory Waltz")
        XCTAssertEqual(VoiceQuery.clean("can you play the song Café Nocturne"), "Café Nocturne")
        XCTAssertEqual(VoiceQuery.clean("Minor scale"), "Minor scale")
    }

    func testBestMatchToleratesAccentsAndSmallMishearings() {
        XCTAssertEqual(VoiceQuery.bestMatch(for: "morning glory", in: songs)?.id, "1")
        XCTAssertEqual(VoiceQuery.bestMatch(for: "cafe nocturn", in: songs)?.id, "4")
        XCTAssertEqual(VoiceQuery.bestMatch(for: "minor scale", in: songs)?.id, "3")
    }

    func testAmbiguousOrUnknownGivesNoMatch() {
        XCTAssertNil(VoiceQuery.bestMatch(for: "scale", in: songs))
        XCTAssertNil(VoiceQuery.bestMatch(for: "something else entirely", in: songs))
        XCTAssertNil(VoiceQuery.bestMatch(for: "", in: songs))
    }
}
