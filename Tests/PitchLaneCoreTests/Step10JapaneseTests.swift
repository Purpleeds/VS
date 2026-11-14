import XCTest
import PitchLaneCore

final class RomajiTests: XCTestCase {
    func testHepburnFromKana() {
        let cases: [(String, String)] = [
            ("こんにちは", "konnichiha"), ("きょう", "kyou"), ("がっこう", "gakkou"), ("ちょっと", "chotto"),
            ("コーヒー", "koohii"), ("しゃしん", "shashin"), ("ふぁん", "fan"), ("てぃー", "tii"), ("まっちゃ", "matcha"),
            ("じゃあね", "jaane"), ("ヴァイオリン", "vaiorin"), ("つなみ", "tsunami"), ("ぢ", "ji"), ("うぃ", "wi"),
            ("さくら、さくら。", "sakura,sakura."), ("あっ", "a"), ("ABC", "ABC"),
        ]
        for (kana, romaji) in cases {
            XCTAssertEqual(Romaji.fromKana(kana), romaji, kana)
        }
    }

    func testMoraeAndScriptChecks() {
        XCTAssertEqual(Kana.morae("きょうは"), ["きょ", "う", "は"])
        XCTAssertEqual(Kana.morae("がっこう"), ["が", "っ", "こ", "う"])
        XCTAssertEqual(Kana.morae("コーヒー"), ["コ", "ー", "ヒ", "ー"])
        XCTAssertEqual(Kana.morae("空 を、見て"), ["空", "を", "見", "て"])
        XCTAssertEqual(Kana.toHiragana("サクラ"), "さくら")
        XCTAssertTrue(Kana.containsJapanese("Hello 世界"))
        XCTAssertTrue(Kana.containsKanji("世界"))
        XCTAssertFalse(Kana.containsJapanese("Café résumé"))
        XCTAssertEqual(Romaji.normalizeLatin("Tōkyō"), "toukyou")
    }
}

final class JapaneseRomanizerTests: XCTestCase {
    func testParticlesFromWordBoundaries() {
        let syllables = ["わ", "た", "し", "は"]
        let romaji = JapaneseRomanizer.romanize(syllables: syllables, tokens: [.init(text: "わたし"), .init(text: "は")])
        XCTAssertEqual(romaji, ["wa", "ta", "shi", "wa"])
        // The same は inside a word stays "ha".
        XCTAssertEqual(JapaneseRomanizer.romanize(syllables: ["は", "な"], tokens: [.init(text: "はな")]), ["ha", "na"])
    }

    func testKanjiReadingsOkuriganaAndSharedWords() {
        XCTAssertEqual(
            JapaneseRomanizer.romanize(syllables: ["空", "を", "見", "て"],
                                       tokens: [.init(text: "空", reading: "そら"), .init(text: "を"), .init(text: "見て", reading: "みて")]),
            ["sora", "o", "mi", "te"]
        )
        XCTAssertEqual(JapaneseRomanizer.romanize(syllables: ["好", "き"], tokens: [.init(text: "好き", reading: "すき")]), ["su", "ki"])
        XCTAssertEqual(JapaneseRomanizer.romanize(syllables: ["東", "京"], tokens: [.init(text: "東京", reading: "とうきょう")]), ["tou", "kyou"])
        XCTAssertEqual(JapaneseRomanizer.romanize(syllables: ["世界"], tokens: [.init(text: "世界", reading: "セカイ")]), ["sekai"])
    }

    func testSokuonAcrossNotesAndFallbacks() {
        XCTAssertEqual(JapaneseRomanizer.romanize(syllables: ["が", "っ", "こう"], tokens: []), ["ga", "k", "kou"])
        XCTAssertEqual(JapaneseRomanizer.romanize(syllables: ["さ", "く", "ら"], tokens: []), ["sa", "ku", "ra"])
        XCTAssertEqual(JapaneseRomanizer.romanize(syllables: ["Hello ", "世界"], tokens: [.init(text: "Hello"), .init(text: "世界", reading: "せかい")]),
                       ["Hello ", "sekai"])
        // A kanji with no reading passes through rather than vanishing.
        XCTAssertEqual(JapaneseRomanizer.romanize(syllables: ["愛"], tokens: []), ["愛"])
        XCTAssertEqual(JapaneseRomanizer.romanize(syllables: [], tokens: []), [])
    }

    func testLineGroups() {
        let notes = [0.0, 0.5, 3.0, 3.5].map { SongNote(start: $0, duration: 0.4, pitch: 60) }
        XCTAssertEqual(JapaneseRomanizer.lineGroups(for: Song(id: "a", title: "a", source: .ultraStar, notes: notes)), [[0, 1], [2, 3]])
        let withBreaks = Song(id: "b", title: "b", source: .ultraStar, notes: notes, lineBreaks: [0.5])
        XCTAssertEqual(JapaneseRomanizer.lineGroups(for: withBreaks), [[0], [1, 2, 3]])
    }

    func testMoraeForFittingAndHeardWords() {
        let tokens: [JapaneseToken] = [.init(text: "空", reading: "そら"), .init(text: "を"), .init(text: "見て", reading: "みて")]
        XCTAssertEqual(JapaneseLyrics.morae(of: tokens), ["そ", "ら", "を", "み", "て"])
        let heard = JapaneseLyrics.heardMorae([.init(text: "見て", reading: "みて")], time: 3, duration: 0.4)
        XCTAssertEqual(heard.map(\.text), ["み", "て"])
        XCTAssertEqual(heard[1].time, 3.2, accuracy: 1e-9)
        // Morae match one to one through the listen matcher.
        let match = LyricListenMatcher.match(lyrics: [["そ", "ら", "を", "み", "て"]], heard: heard)
        XCTAssertEqual(match.matchedWords, 2)
        XCTAssertEqual(match.lines[0].words.map(\.text), ["そ", "ら", "を", "み", "て"])
    }
}

final class ShiftJISTests: XCTestCase {
    func testShiftJISLyricsAreDecoded() throws {
        // こんにちは in Shift-JIS.
        let bytes: [UInt8] = [0x82, 0xB1, 0x82, 0xF1, 0x82, 0xC9, 0x82, 0xBF, 0x82, 0xCD]
        try XCTSkipIf(String(data: Data(bytes), encoding: .shiftJIS) == nil, "Shift-JIS isn't available on this platform")
        XCTAssertEqual(TextDecoding.decode(Data(bytes)), "こんにちは")
        let ultraStar = Array("#TITLE:".utf8) + [0x82, 0xB3, 0x82, 0xAD, 0x82, 0xE7] + Array("\n#BPM:120\n: 0 4 0 ".utf8) + [0x82, 0xB3] + Array("\nE\n".utf8)
        let song = try UltraStarImporter.parse(data: Data(ultraStar), fallbackTitle: "x").song
        XCTAssertEqual(song.title, "さくら")
        XCTAssertEqual(song.notes[0].displayLyric, "さ")
    }

    func testLatinWithAccentsStaysWindows1252() {
        // "résumé" and "Café" in Windows-1252: é + letter can look like a Shift-JIS pair, but there is no kana.
        XCTAssertEqual(TextDecoding.decode(Data([0x72, 0xE9, 0x73, 0x75, 0x6D, 0xE9])), "résumé")
        XCTAssertEqual(TextDecoding.decode(Data([0x43, 0x61, 0x66, 0xE9])), "Café")
    }

    func testJapaneseLyricsSettingDefaultsToRomaji() throws {
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).japaneseLyrics, .romaji)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"japaneseLyrics":"both"}"#.utf8)).japaneseLyrics, .both)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(#"{"japaneseLyrics":"klingon"}"#.utf8)).japaneseLyrics, .romaji)
    }
}
