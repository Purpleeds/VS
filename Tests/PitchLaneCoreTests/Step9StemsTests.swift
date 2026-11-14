import XCTest
import PitchLaneCore

final class FFTTests: XCTestCase {
    func testSineLandsInItsBinAndInverseRoundTrips() {
        let fft = FFT(size: 64)
        XCTAssertEqual(fft.size, 64)
        var re = (0..<64).map { Float(sin(2 * Double.pi * 5 * Double($0) / 64)) }
        var im = [Float](repeating: 0, count: 64)
        let original = re
        re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { i in fft.forward(real: r.baseAddress!, imag: i.baseAddress!) } }
        let magnitudes = zip(re, im).map { ($0 * $0 + $1 * $1).squareRoot() }
        XCTAssertEqual(magnitudes[5], 32, accuracy: 1e-3)
        XCTAssertEqual(magnitudes[59], 32, accuracy: 1e-3)
        XCTAssertLessThan(magnitudes.enumerated().filter { $0.offset != 5 && $0.offset != 59 }.map(\.element).max() ?? 0, 1e-3)
        re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { i in fft.inverse(real: r.baseAddress!, imag: i.baseAddress!) } }
        for (a, b) in zip(re, original) { XCTAssertEqual(a, b, accuracy: 1e-5) }
        XCTAssertEqual(FFT(size: 100).size, 128)
    }
}

final class StemSeparatorTests: XCTestCase {
    let rate = 44_100.0

    private func tone(_ hz: Double, seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    /// Power of `signal` at `hz` (Goertzel), on the steady middle part.
    private func power(_ signal: [Float], _ hz: Double) -> Double {
        let part = signal[(signal.count / 4)..<(3 * signal.count / 4)]
        let coefficient = 2 * cos(2 * Double.pi * hz / rate)
        var s1 = 0.0, s2 = 0.0
        for x in part {
            let s0 = Double(x) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        return (s1 * s1 + s2 * s2 - coefficient * s1 * s2) / Double(part.count * part.count)
    }

    private func separate(left: [Float], right: [Float], chunk: Int = 4_096) -> (StemSeparator.Output, StemSeparator) {
        let separator = StemSeparator(sampleRate: rate)
        var out = StemSeparator.Output()
        var i = 0
        while i < left.count {
            let j = min(left.count, i + chunk)
            let part = separator.process(left: Array(left[i..<j]), right: Array(right[i..<j]))
            out.vocalsLeft += part.vocalsLeft; out.vocalsRight += part.vocalsRight
            out.musicLeft += part.musicLeft; out.musicRight += part.musicRight
            i = j
        }
        let tail = separator.finish()
        out.vocalsLeft += tail.vocalsLeft; out.vocalsRight += tail.vocalsRight
        out.musicLeft += tail.musicLeft; out.musicRight += tail.musicRight
        return (out, separator)
    }

    func testCentredVoiceGoesToVocalsAndPannedInstrumentsToMusic() {
        let voice = tone(440, seconds: 2)
        let guitar = tone(660, seconds: 2)   // left only
        let keys = tone(990, seconds: 2)     // right only
        let bass = tone(80, seconds: 2)      // centred but below the vocal band
        let left = (0..<voice.count).map { voice[$0] + guitar[$0] + bass[$0] }
        let right = (0..<voice.count).map { voice[$0] + keys[$0] + bass[$0] }
        let (out, separator) = separate(left: left, right: right)

        XCTAssertEqual(out.count, left.count)
        XCTAssertFalse(separator.isEffectivelyMono)
        let voiceKept = power(out.vocalsLeft, 440) / power(left, 440)
        let guitarLeaked = power(out.vocalsLeft, 660) / power(left, 660)
        let keysLeaked = power(out.vocalsRight, 990) / power(right, 990)
        let bassLeaked = power(out.vocalsLeft, 80) / power(left, 80)
        XCTAssertGreaterThan(voiceKept, 0.8, "voice kept \(voiceKept)")
        XCTAssertLessThan(guitarLeaked, 0.05, "guitar leaked \(guitarLeaked)")
        XCTAssertLessThan(keysLeaked, 0.05, "keys leaked \(keysLeaked)")
        XCTAssertLessThan(bassLeaked, 0.05, "bass leaked \(bassLeaked)")
        XCTAssertGreaterThan(power(out.musicLeft, 660) / power(left, 660), 0.9)
    }

    func testStemsAddBackToTheOriginalAndChunkingDoesNotMatter() {
        var random = SeededRandom(seed: 5)
        let left = (0..<20_000).map { _ in Float(random.uniform() - 0.5) }
        let right = (0..<20_000).map { i in 0.5 * left[i] + Float(random.uniform() - 0.5) * 0.3 }
        let (a, _) = separate(left: left, right: right, chunk: 4_096)
        let (b, _) = separate(left: left, right: right, chunk: 777)
        XCTAssertEqual(a.count, left.count)
        for i in stride(from: 0, to: left.count, by: 97) {
            XCTAssertEqual(a.vocalsLeft[i] + a.musicLeft[i], left[i], accuracy: 1e-5)
            XCTAssertEqual(a.vocalsRight[i] + a.musicRight[i], right[i], accuracy: 1e-5)
            XCTAssertEqual(a.vocalsLeft[i], b.vocalsLeft[i], accuracy: 1e-5)
        }
    }

    func testMonoIsDetectedAndGarbageIsSafe() {
        let signal = tone(300, seconds: 0.5)
        let (_, mono) = separate(left: signal, right: signal)
        XCTAssertTrue(mono.isEffectivelyMono)
        let separator = StemSeparator(sampleRate: rate)
        let out = separator.process(left: [.nan, .infinity, 1, 2], right: [0, 0])
        XCTAssertTrue(out.vocalsLeft.allSatisfy(\.isFinite))
        XCTAssertEqual(separator.finish().count, 2)
        XCTAssertEqual(separator.finish().count, 0)
        XCTAssertEqual(StemSeparator(sampleRate: rate).finish().count, 0)
    }
}

final class LyricListenMatcherTests: XCTestCase {
    func testHeardWordsTimeTheLyricsAndGapsAreInterpolated() {
        let lyrics = LyricListenMatcher.lines(from: "[Verse]\nHello my darling\n\nSee you tomorrow night")
        XCTAssertEqual(lyrics, [["Hello", "my", "darling"], ["See", "you", "tomorrow", "night"]])
        // The recogniser misses "my" and "you", mishears "tomorrow" as "tomorow", and hears an extra "uh".
        let heard = [
            LyricListenMatcher.HeardWord(text: "hello", time: 10.0),
            LyricListenMatcher.HeardWord(text: "uh", time: 10.4),
            LyricListenMatcher.HeardWord(text: "Darling!", time: 11.0),
            LyricListenMatcher.HeardWord(text: "see", time: 14.0),
            LyricListenMatcher.HeardWord(text: "tomorow", time: 15.0),
            LyricListenMatcher.HeardWord(text: "night", time: 16.0),
        ]
        let result = LyricListenMatcher.match(lyrics: lyrics, heard: heard)
        XCTAssertEqual(result.matchedWords, 5)
        XCTAssertEqual(result.totalWords, 7)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(result.lines[0].time, 10)
        XCTAssertEqual(result.lines[0].words.map(\.time), [10, 10.5, 11])
        XCTAssertEqual(result.lines[1].words.map(\.text), ["See", "you", "tomorrow", "night"])
        XCTAssertEqual(result.lines[1].words[1].time ?? 0, 14.5, accuracy: 1e-9)
    }

    func testTheResultFitsOntoNotes() {
        let song = Song(id: "s", title: "S", source: .video, notes: [10, 10.5, 11, 14, 14.5, 15, 16].map {
            SongNote(start: $0, duration: 0.4, pitch: 60)
        })
        let heard = ["hello", "darling", "see", "tomorrow", "night"].enumerated().map {
            LyricListenMatcher.HeardWord(text: $1, time: [10, 11, 14, 15, 16][$0])
        }
        let matched = LyricListenMatcher.match(lyrics: [["Hello", "my", "darling"], ["See", "you", "tomorrow", "night"]], heard: heard)
        let fitted = LyricAligner.apply(lines: matched.lines, to: song, autoOffset: false)
        XCTAssertEqual(fitted.song.notes.map(\.displayLyric), ["Hello", "my", "darling", "See", "you", "tomorrow", "night"])
        XCTAssertEqual(fitted.song.lineBreaks, [14])
    }

    func testNothingHeardOrNothingInCommon() {
        let lyrics = [["la", "la"]]
        XCTAssertEqual(LyricListenMatcher.match(lyrics: lyrics, heard: []).matchedWords, 0)
        XCTAssertTrue(LyricListenMatcher.match(lyrics: lyrics, heard: [.init(text: "zebra", time: 1)]).lines.isEmpty)
        XCTAssertEqual(LyricListenMatcher.match(lyrics: [], heard: [.init(text: "la", time: 1)]).totalWords, 0)
    }
}

final class StemStorageTests: XCTestCase {
    func testAttachRemoveAndNewBackingDropsStaleStems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PitchLaneTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SongLibraryStore(root: root)
        var song = Song(id: "s", title: "T", source: .ultraStar, notes: [SongNote(start: 0, duration: 1, pitch: 60)])
        try store.save(song)
        let vocals = root.appendingPathComponent("v.m4a"), music = root.appendingPathComponent("m.m4a")
        try Data("v".utf8).write(to: vocals)
        try Data("m".utf8).write(to: music)
        song = try store.attachStems(vocals: vocals, music: music, to: song)
        XCTAssertTrue(song.hasStems)
        let urls = try XCTUnwrap(store.stemURLs(for: song))
        XCTAssertEqual(try Data(contentsOf: urls.vocals), Data("v".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vocals.path), "sources are moved")
        XCTAssertTrue(store.loadAll().songs[0].hasStems)

        let backing = root.appendingPathComponent("new.mp3")
        try Data("b".utf8).write(to: backing)
        let replaced = try store.attachBackingAudio(from: backing, to: song)
        XCTAssertFalse(replaced.hasStems)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls.vocals.path))

        try Data("v".utf8).write(to: vocals)
        try Data("m".utf8).write(to: music)
        let again = try store.attachStems(vocals: vocals, music: music, to: replaced)
        let removed = try store.removeStems(from: again)
        XCTAssertFalse(removed.hasStems)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls.music.path))
        XCTAssertFalse(store.loadAll().songs[0].hasStems)
    }

    func testStemVolumesDecodeWithDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"musicStemVolume":7}"#.utf8))
        XCTAssertEqual(settings.voiceStemVolume, 0.3)
        XCTAssertEqual(settings.musicStemVolume, 1)
    }
}
