import XCTest
import PitchLaneCore

final class SongModelTests: XCTestCase {
    private func sample() -> Song {
        Song(
            id: "s",
            title: "Sample",
            artist: "Me",
            source: .ultraStar,
            notes: [
                SongNote(start: 2, duration: 1, pitch: 67, lyric: "two", isGolden: true),
                SongNote(start: 0, duration: 1, pitch: 60, lyric: "one"),
                SongNote(start: 3, duration: 1, pitch: 72, lyric: "", slidesFromPrevious: true, slideDuration: 0.5),
                SongNote(start: 5, duration: 0.5, pitch: 40, lyric: "talk", isFreestyle: true),
            ],
            lineBreaks: [3, 1],
            tempo: [TempoSegment(start: 0, beatDuration: 0.5)]
        )
    }

    func testInitSortsNotesAndBreaks() {
        let song = sample()
        XCTAssertEqual(song.notes.map(\.start), [0, 2, 3, 5])
        XCTAssertEqual(song.lineBreaks, [1, 3])
        XCTAssertEqual(song.schemaVersion, Song.currentSchemaVersion)
    }

    func testJSONRoundTrip() throws {
        let song = sample()
        let data = try JSONEncoder().encode(song)
        XCTAssertEqual(try JSONDecoder().decode(Song.self, from: data), song)
    }

    func testForgivingDecodeOfMinimalJSON() throws {
        let json = #"{"id":"x","title":"Min","notes":[{"start":1,"duration":0.5,"pitch":62}]}"#
        let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        XCTAssertEqual(song.artist, "")
        XCTAssertEqual(song.offsetMs, 0)
        XCTAssertEqual(song.notes[0].lyric, "")
        XCTAssertFalse(song.notes[0].isGolden)
        XCTAssertNil(song.backingAudioFile)
        XCTAssertTrue(song.tempo.isEmpty)
    }

    func testSummary() {
        let summary = sample().summary
        XCTAssertEqual(summary.noteCount, 4)
        XCTAssertEqual(summary.scoredNoteCount, 3)
        XCTAssertEqual(summary.goldenCount, 1)
        XCTAssertEqual(summary.pitchRange, 60...72, "freestyle notes don't count toward the range")
        XCTAssertEqual(summary.duration, 5.5)
        XCTAssertEqual(summary.durationText, "0:06")
        XCTAssertEqual(summary.rangeText(accidentals: .sharps), "C4–C5")
        XCTAssertFalse(summary.hasBackingAudio)
        XCTAssertEqual(SongSummary(noteCount: 0, scoredNoteCount: 0, goldenCount: 0, pitchRange: nil, duration: 125, hasBackingAudio: true).durationText, "2:05")
    }

    func testTargetPitchFollowsSlides() {
        let song = sample()
        XCTAssertEqual(song.targetPitch(noteAt: 0, time: 0.5), 60)
        // Note 2 glides from G4 (67) to C5 (72) over its first 0.5 s.
        XCTAssertEqual(song.targetPitch(noteAt: 2, time: 3.0), 67, accuracy: 1e-9)
        XCTAssertEqual(song.targetPitch(noteAt: 2, time: 3.25), 69.5, accuracy: 1e-9)
        XCTAssertEqual(song.targetPitch(noteAt: 2, time: 3.5), 72, accuracy: 1e-9)
        XCTAssertEqual(song.targetPitch(noteAt: 2, time: 3.9), 72, accuracy: 1e-9)
    }

    func testWholeNoteGlide() {
        let song = Song(id: "g", title: "G", source: .builtIn, notes: [
            SongNote(start: 0, duration: 1, pitch: 60),
            SongNote(start: 1, duration: 2, pitch: 72, slidesFromPrevious: true),
        ])
        XCTAssertEqual(song.targetPitch(noteAt: 1, time: 2.0), 66, accuracy: 1e-9)
        XCTAssertEqual(song.targetPitch(noteAt: 1, time: 3.0), 72, accuracy: 1e-9)
    }

    func testClickTimes() {
        let song = Song(id: "c", title: "C", source: .midi, notes: [SongNote(start: 0, duration: 1, pitch: 60)],
                        tempo: [TempoSegment(start: 0.25, beatDuration: 0.5), TempoSegment(start: 2.25, beatDuration: 1)])
        XCTAssertEqual(song.clickTimes(from: 0, to: 4.3), [0.25, 0.75, 1.25, 1.75, 2.25, 3.25, 4.25])
        XCTAssertEqual(song.clickTimes(from: 1.0, to: 2.0), [1.25, 1.75])
        let noTempo = Song(id: "n", title: "N", source: .midi, notes: [])
        XCTAssertEqual(noTempo.clickTimes(from: 0, to: 1.1), [0, 0.5, 1.0])
    }

    func testSearch() {
        let song = Song(id: "x", title: "Café Morning", artist: "Ünder Group", source: .ultraStar, notes: [])
        XCTAssertTrue(SongSearch.matches(song, query: ""))
        XCTAssertTrue(SongSearch.matches(song, query: "cafe"))
        XCTAssertTrue(SongSearch.matches(song, query: "MORNING under"))
        XCTAssertFalse(SongSearch.matches(song, query: "evening"))
    }

    func testNoteNameParsing() {
        XCTAssertEqual(NoteNaming.midiNote(named: "C4"), 60)
        XCTAssertEqual(NoteNaming.midiNote(named: "F#4"), 66)
        XCTAssertEqual(NoteNaming.midiNote(named: "F♯4"), 66)
        XCTAssertEqual(NoteNaming.midiNote(named: "Bb3"), 58)
        XCTAssertEqual(NoteNaming.midiNote(named: "B♭3"), 58)
        XCTAssertEqual(NoteNaming.midiNote(named: "C-1"), 0)
        XCTAssertNil(NoteNaming.midiNote(named: "H2"))
        XCTAssertNil(NoteNaming.midiNote(named: "C"))
    }

    func testDifficultyTolerances() {
        XCTAssertEqual(Difficulty.easy.toleranceCents, 100)
        XCTAssertEqual(Difficulty.normal.toleranceCents, 50)
        XCTAssertEqual(Difficulty.hard.toleranceCents, 25)
    }
}

final class BuiltInSongsTests: XCTestCase {
    func testEveryKindHasThreeDifficulties() {
        XCTAssertEqual(BuiltInSongs.all.count, BuiltInKind.allCases.count * 3)
        XCTAssertEqual(Set(BuiltInSongs.all.map(\.id)).count, BuiltInSongs.all.count)
        for kind in BuiltInKind.allCases {
            for difficulty in Difficulty.allCases {
                let song = BuiltInSongs.song(kind, difficulty)
                XCTAssertEqual(song.id, BuiltInSongs.id(kind, difficulty))
                XCTAssertEqual(song.difficulty, difficulty)
                XCTAssertEqual(song.source, .builtIn)
                XCTAssertEqual(BuiltInSongs.song(withID: song.id), song)
            }
        }
    }

    func testSongsAreWellFormed() {
        for song in BuiltInSongs.all {
            XCTAssertGreaterThanOrEqual(song.notes.count, 4, song.id)
            XCTAssertFalse(song.tempo.isEmpty, song.id)
            XCTAssertGreaterThan(song.duration, 8, song.id)
            XCTAssertLessThan(song.duration, 90, song.id)
            for (a, b) in zip(song.notes, song.notes.dropFirst()) {
                XCTAssertLessThanOrEqual(a.end, b.start + 1e-9, "\(song.id): overlapping notes at \(b.start)")
            }
            for note in song.notes {
                XCTAssertGreaterThan(note.duration, 0.1, song.id)
                XCTAssertTrue((43...84).contains(note.pitch), "\(song.id): pitch \(note.pitch) out of a singable range")
            }
            XCTAssertFalse(song.notes.filter(\.isGolden).isEmpty, "\(song.id) has no golden note")
            XCTAssertNotEqual(song.notes.first?.slidesFromPrevious, true, song.id)
        }
    }

    func testDifficultyProgression() {
        for kind in BuiltInKind.allCases {
            let easy = BuiltInSongs.song(kind, .easy)
            let hard = BuiltInSongs.song(kind, .hard)
            let span: (Song) -> Int = { ($0.pitchRange?.upperBound ?? 0) - ($0.pitchRange?.lowerBound ?? 0) }
            XCTAssertGreaterThanOrEqual(span(hard), span(easy), kind.rawValue)
            let easyBeat = easy.tempo[0].beatDuration
            let hardBeat = hard.tempo[0].beatDuration
            XCTAssertLessThanOrEqual(hardBeat, easyBeat, "\(kind.rawValue): hard should not be slower")
        }
    }

    func testSongsHaveLyricsLinesAndHardSlides() {
        XCTAssertEqual(BuiltInKind.allCases.filter { !$0.isOriginal }.count, 7)
        for kind in BuiltInKind.allCases {
            for difficulty in Difficulty.allCases {
                let song = BuiltInSongs.song(kind, difficulty)
                let sung = song.notes.filter { !$0.slidesFromPrevious }
                XCTAssertTrue(sung.allSatisfy { !$0.displayLyric.isEmpty }, song.id)
                XCTAssertGreaterThanOrEqual(song.lineBreaks.count, 3, song.id)
            }
            XCTAssertTrue(BuiltInSongs.song(kind, .hard).notes.contains(where: \.slidesFromPrevious), "\(kind) hard has no slides")
        }
        // Hard slides start exactly where the note before ends (a held vowel, not a new note).
        for kind in BuiltInKind.allCases {
            let hard = BuiltInSongs.song(kind, .hard)
            for (i, note) in hard.notes.enumerated() where note.slidesFromPrevious {
                XCTAssertEqual(hard.notes[i - 1].end, note.start, accuracy: 1e-9, hard.id)
            }
        }
    }
}

final class SongLibraryStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PitchLaneSongs-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func song(_ id: String, _ title: String) -> Song {
        Song(id: id, title: title, source: .ultraStar, notes: [SongNote(start: 0, duration: 1, pitch: 60)])
    }

    func testSaveLoadDelete() throws {
        let store = SongLibraryStore(root: root)
        XCTAssertTrue(store.loadAll().songs.isEmpty)
        try store.save(song("b", "Beta"), originalFileName: "beta.TXT", originalData: Data("#BPM:1".utf8))
        try store.save(song("a", "alpha"))
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.songs.map(\.title), ["alpha", "Beta"])
        XCTAssertTrue(loaded.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder(for: "b").appendingPathComponent("original.txt").path))

        try store.delete(id: "b")
        XCTAssertEqual(store.loadAll().songs.map(\.id), ["a"])
        XCTAssertNoThrow(try store.delete(id: "missing"))
    }

    func testCorruptSongIsReportedOthersStillLoad() throws {
        let store = SongLibraryStore(root: root)
        try store.save(song("good", "Good"))
        let bad = store.folder(for: "bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: bad.appendingPathComponent(SongLibraryStore.songFileName))
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.songs.map(\.id), ["good"])
        XCTAssertEqual(loaded.failures.map(\.folderName), ["bad"])
    }

    func testAttachBackingAudioCopiesAndReplaces() throws {
        let store = SongLibraryStore(root: root)
        let original = song("s", "S")
        try store.save(original)
        let source = root.appendingPathComponent("incoming.MP3")
        try Data([1, 2, 3]).write(to: source)
        let updated = try store.attachBackingAudio(from: source, to: original)
        XCTAssertEqual(updated.backingAudioFile, "backing.mp3")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.backingAudioURL(for: updated))), Data([1, 2, 3]))
        XCTAssertEqual(store.loadAll().songs.first?.backingAudioFile, "backing.mp3")

        let wav = root.appendingPathComponent("other.wav")
        try Data([9]).write(to: wav)
        let replaced = try store.attachBackingAudio(from: wav, to: updated)
        XCTAssertEqual(replaced.backingAudioFile, "backing.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(for: "s").appendingPathComponent("backing.mp3").path))
    }
}

final class PublicDomainSongTests: XCTestCase {
    func testWellKnownMelodiesStartRight() {
        // First pitches and words, to catch typos in the melody tables.
        let twinkle = BuiltInSongs.song(.twinkle, .normal)
        XCTAssertEqual(twinkle.notes.prefix(7).map(\.pitch), [60, 60, 67, 67, 69, 69, 67])
        XCTAssertEqual(twinkle.notes.prefix(4).map(\.displayLyric), ["Twin", "kle", "twin", "kle"])
        XCTAssertEqual(BuiltInSongs.song(.odeToJoy, .normal).notes.prefix(8).map(\.pitch), [64, 64, 65, 67, 67, 65, 64, 62])
        XCTAssertEqual(BuiltInSongs.song(.happyBirthday, .normal).notes.prefix(6).map(\.pitch), [67, 67, 69, 67, 72, 71])
        XCTAssertEqual(BuiltInSongs.song(.jingleBells, .normal).notes.prefix(11).map(\.pitch), [64, 64, 64, 64, 64, 64, 64, 67, 60, 62, 64])
        XCTAssertEqual(BuiltInSongs.song(.areYouSleeping, .normal).notes.prefix(4).map(\.pitch), [60, 62, 64, 60])
        XCTAssertTrue(BuiltInKind.allCases.allSatisfy { !$0.title.isEmpty && !$0.subtitle.isEmpty })
    }
}
