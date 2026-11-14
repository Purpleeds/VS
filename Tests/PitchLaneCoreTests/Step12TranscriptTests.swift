import XCTest
import PitchLaneCore

final class SongTranscriptTests: XCTestCase {
    private typealias Word = LyricListenMatcher.HeardWord

    private let heard: [Word] = [
        Word(text: "hello", time: 1.0, duration: 0.4),
        Word(text: "my", time: 1.5, duration: 0.2),
        Word(text: "friend", time: 1.8, duration: 0.6),
        Word(text: "see", time: 4.0, duration: 0.3),   // after a pause: new line
        Word(text: "you", time: 4.4, duration: 0.3),
    ]

    func testLinesSplitAtPausesAndKeepTimes() {
        let transcript = SongTranscript(language: "en-US", source: "mix", words: heard)
        let lines = transcript.lines()
        XCTAssertEqual(lines.map(\.text), ["hello my friend", "see you"])
        XCTAssertEqual(lines[0].start, 1.0)
        XCTAssertEqual(lines[0].end, 2.4, accuracy: 1e-9)
        XCTAssertEqual(lines[1].firstWord, 3)
        let lyricLines = transcript.lyricLines()
        XCTAssertEqual(lyricLines[1].words.map(\.time), [4.0, 4.4])
    }

    func testWordsGoOntoTheNotesTheyWereHeardOn() {
        let song = Song(id: "s", title: "S", source: .video, notes: [1.0, 1.5, 1.8, 2.5, 4.0, 4.4].map {
            SongNote(start: $0, duration: 0.3, pitch: 60)
        })
        let fitted = LyricAligner.apply(lines: SongTranscript(language: "en-US", source: "mix", words: heard).lyricLines(), to: song, autoOffset: false)
        XCTAssertEqual(fitted.song.notes.map(\.displayLyric), ["hello", "my", "friend", "", "see", "you"])
        XCTAssertEqual(fitted.song.lineBreaks, [4.0])
    }

    func testEditingALineRespacesItsWords() {
        let transcript = SongTranscript(language: "en-US", source: "mix", words: heard)
        let fixed = transcript.replacingLine(transcript.lines()[0], with: "hello  dear old friend")
        XCTAssertTrue(fixed.edited)
        XCTAssertEqual(fixed.lines().map(\.text), ["hello dear old friend", "see you"])
        let times = fixed.words.prefix(4).map(\.time)
        XCTAssertEqual(times[0], 1.0, accuracy: 1e-9)
        XCTAssertEqual(times[3], 1.0 + 3 * 1.4 / 4, accuracy: 1e-9)
        // Clearing a line removes its words.
        let cleared = transcript.replacingLine(transcript.lines()[1], with: "  ")
        XCTAssertEqual(cleared.lines().map(\.text), ["hello my friend"])
    }

    func testCleaningAndLenientDecoding() throws {
        let messy = SongTranscript(language: "en-US", source: "mix", words: [
            Word(text: " b ", time: 2, duration: 99), Word(text: "", time: 1, duration: 1),
            Word(text: "a", time: .nan, duration: 1), Word(text: "a", time: 1, duration: 0),
        ])
        XCTAssertEqual(messy.words.map(\.text), ["a", "b"])
        XCTAssertEqual(messy.words[0].duration, 0.05)
        XCTAssertEqual(messy.words[1].duration, 10)
        let data = try JSONEncoder().encode(messy)
        XCTAssertEqual(try JSONDecoder().decode(SongTranscript.self, from: data), messy)
        let partial = try JSONDecoder().decode(SongTranscript.self, from: Data(#"{"words":[{"text":"ok","time":1,"duration":0.5},{"bad":1}]}"#.utf8))
        XCTAssertEqual(partial.words.map(\.text), ["ok"])
        XCTAssertEqual(partial.language, "en-US")
    }

    func testStoreSavesTranscriptsAndDropsThemWithNewBackingAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PitchLaneTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SongLibraryStore(root: root)
        let song = Song(id: "s", title: "T", source: .video, notes: [SongNote(start: 0, duration: 1, pitch: 60)])
        try store.save(song)
        XCTAssertNil(store.loadTranscript(for: song))
        let transcript = SongTranscript(language: "ja-JP", source: "voice", words: heard)
        try store.saveTranscript(transcript, for: song)
        XCTAssertEqual(store.loadTranscript(for: song), transcript)
        let audio = root.appendingPathComponent("a.mp3")
        try Data("a".utf8).write(to: audio)
        _ = try store.attachBackingAudio(from: audio, to: song)
        XCTAssertNil(store.loadTranscript(for: song), "new audio, old words are stale")
        try store.saveTranscript(transcript, for: song)
        store.deleteTranscript(for: song)
        XCTAssertNil(store.loadTranscript(for: song))
    }

    func testAutoLyricsSettingDefaultsOn() throws {
        let defaults = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(defaults.autoLyrics)
        XCTAssertNil(defaults.uploadLanguage)
        XCTAssertTrue(defaults.haptics)
        let set = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"uploadLanguage":"ja-JP","haptics":false}"#.utf8))
        XCTAssertEqual(set.uploadLanguage, "ja-JP")
        XCTAssertFalse(set.haptics)
        XCTAssertNil(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"uploadLanguage":""}"#.utf8)).uploadLanguage)
    }
}
