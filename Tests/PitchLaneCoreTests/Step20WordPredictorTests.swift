import XCTest
import PitchLaneCore

private typealias Word = LyricListenMatcher.HeardWord

/// Words of one line, 0.4 s apart from `start`, with an optional per-word confidence and alternatives.
private func line(_ texts: [String], at start: Double, confidence: [Double]? = nil, alternatives: [Int: [String]] = [:]) -> [Word] {
    texts.enumerated().map { index, text in
        Word(text: text, time: start + Double(index) * 0.4, duration: 0.3, confidence: confidence?[index] ?? 0.9,
             alternatives: alternatives[index])
    }
}

private func texts(_ words: [Word]) -> [String] { words.map(\.text) }

final class PhoneticsTests: XCTestCase {
    func testSyllables() {
        XCTAssertEqual(Phonetics.syllables("tomorrow"), 3)
        XCTAssertEqual(Phonetics.syllables("fire"), 1)
        XCTAssertEqual(Phonetics.syllables("little"), 2)
        XCTAssertEqual(Phonetics.syllables("beautiful"), 3)
        XCTAssertEqual(Phonetics.syllables("the"), 1)
        XCTAssertEqual(Phonetics.syllables("cake"), 1)
        XCTAssertEqual(Phonetics.syllables("abracadabra"), 5)
        XCTAssertEqual(Phonetics.syllables("さくら"), 3)
        XCTAssertEqual(Phonetics.syllables("!!"), 0)
    }

    func testSoundKeysAndEditDistance() {
        XCTAssertEqual(Phonetics.soundKey("knight"), Phonetics.soundKey("night"))
        XCTAssertEqual(Phonetics.soundKey("write"), Phonetics.soundKey("right"))
        XCTAssertNil(Phonetics.soundKey("さくら"))
        XCTAssertEqual(Phonetics.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(Phonetics.editDistance("kitten", "sitting", limit: 1), 2)
        XCTAssertEqual(Phonetics.editDistance("", "abc"), 3)
        XCTAssertEqual(Phonetics.editDistance("same", "same"), 0)
    }
}

final class WordAlignmentTests: XCTestCase {
    func testAnchorsSubstitutionsAndBlocks() {
        let merged = WordAlignment.align(["dance", "like", "beyond", "say"], ["dance", "like", "Beyoncé"])
        XCTAssertEqual(merged.pairs.filter { $0.kind == .same }.map(\.a), [0, 1])
        XCTAssertTrue(merged.blocks.contains(WordAlignment.Block(aRange: 2..<4, bRange: 2..<3)))

        let swapped = WordAlignment.align(["we", "will", "rok", "ewe"], ["we", "will", "rock", "you"])
        let substituted = swapped.pairs.filter { $0.kind == .substituted }.map { [$0.a, $0.b] }
        XCTAssertEqual(substituted, [[2, 2], [3, 3]])
        XCTAssertEqual(WordAlignment.align([], ["a"]).blocks, [WordAlignment.Block(aRange: 0..<0, bRange: 0..<1)])
        XCTAssertTrue(WordAlignment.align(["a"], ["a"]).blocks.isEmpty)
    }
}

final class WordModelTests: XCTestCase {
    func testLearnsWordsPairsAndSpellings() {
        var model = WordModel()
        XCTAssertTrue(model.isEmpty)
        model.learn(lines: [["Hello", "world"], ["hello", "London", "again"], ["Don't", "stop"]])
        XCTAssertEqual(model.count("hello"), 2)
        XCTAssertEqual(model.count("hello", "world"), 1)
        XCTAssertEqual(model.count("world", "hello"), 0) // no pair across lines
        XCTAssertEqual(model.unigramTotal, 7)
        XCTAssertEqual(model.lyricsLearned, 1)
        XCTAssertEqual(model.spelling(of: "london"), "London")
        XCTAssertEqual(model.spelling(of: "hello"), "hello") // a line-start capital isn't kept
        XCTAssertEqual(model.spelling(of: "dont"), "don't")
    }

    func testLearnsCorrectionsAndEdits() {
        var model = WordModel()
        model.learnCorrections([("rite", "right"), ("rite", "right"), ("same", "same"), ("", "x")])
        XCTAssertEqual(model.corrections(of: "rite"), ["right": 2])
        XCTAssertEqual(model.correctionsLearned, 2)
        model.learnEdit(heard: ["dance", "like", "beyond", "say"], corrected: ["dance", "like", "Beyoncé"])
        XCTAssertEqual(model.corrections(of: "beyond say"), ["beyonce": 1])
        XCTAssertEqual(model.spelling(of: "beyonce"), "Beyoncé")
        XCTAssertEqual(model.count("like", "beyonce"), 2) // corrected lines count twice
    }

    func testWordsToKnow() {
        var model = WordModel()
        XCTAssertTrue(model.addCustomWord("Beyoncé"))
        XCTAssertFalse(model.addCustomWord("beyonce")) // same word
        XCTAssertTrue(model.addCustomWord("New York"))
        XCTAssertFalse(model.addCustomWord("   "))
        XCTAssertEqual(model.customWords, ["New York", "Beyoncé"])
        XCTAssertEqual(model.spelling(of: "new york"), "New York")
        model.removeCustomWord("new york")
        XCTAssertEqual(model.customWords, ["Beyoncé"])
        model.learn(lines: [["a", "b"]])
        model.forgetLearned()
        XCTAssertEqual(model.customWords, ["Beyoncé"])
        XCTAssertEqual(model.count("a"), 0)
        XCTAssertEqual(WordModel.phraseKey("  New   York! "), "new york")
    }

    func testSavesAndLoadsLeniently() throws {
        var model = WordModel()
        model.addCustomWord("Zayn")
        model.learn(lines: [["i", "love", "you"]])
        model.learnCorrections([("ewe", "you")])
        let back = try JSONDecoder().decode(WordModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(back, model)
        let messy = #"{"customWords":["ok",3,null,"OK"],"unigrams":{"a":2,"b":-1,"":4},"bigrams":"nope","confusions":{"x":{"y":1,"z":0}}}"#
        let decoded = try JSONDecoder().decode(WordModel.self, from: Data(messy.utf8))
        XCTAssertEqual(decoded.customWords, ["ok"])
        XCTAssertEqual(decoded.unigrams, ["a": 2])
        XCTAssertEqual(decoded.unigramTotal, 2)
        XCTAssertTrue(decoded.bigrams.isEmpty)
        XCTAssertEqual(decoded.corrections(of: "x"), ["y": 1])
        XCTAssertEqual(try JSONDecoder().decode(WordModel.self, from: Data("{}".utf8)), WordModel())
    }

    func testStaysInsideItsSizeLimits() {
        var model = WordModel()
        model.learn(lines: [(0..<(WordModel.maxUnigrams + 50)).map { "w\($0)" }])
        XCTAssertEqual(model.unigrams.count, WordModel.maxUnigrams)
        XCTAssertEqual(model.unigramTotal, WordModel.maxUnigrams)
    }
}

final class PassAlternativesTests: XCTestCase {
    func testOtherPassesAndSecondBestReadingsBecomeAlternatives() {
        let best = [Word(text: "night", time: 1, duration: 0.4), Word(text: "falls", time: 1.5, duration: 0.4)]
        let other = [Word(text: "knight", time: 1.05, duration: 0.4), Word(text: "falls", time: 1.5, duration: 0.4)]
        let combined = HeardWordPicker.withAlternatives(best, from: other)
        XCTAssertEqual(combined[0].alternatives, ["knight"])
        XCTAssertNil(combined[1].alternatives)

        let attached = HeardWordPicker.attachAlternatives(
            [Word(text: "goodnight", time: 0), Word(text: "my", time: 0.5), Word(text: "dear", time: 1)],
            alternative: ["good", "night", "my", "deer"]
        )
        XCTAssertEqual(attached[0].alternatives, ["good night"])
        XCTAssertEqual(attached[2].alternatives, ["deer"])
        XCTAssertNil(attached[1].alternatives)
        XCTAssertNil(Word(text: "x", time: 0, alternatives: ["x", " ", "X"]).alternatives)
    }

    func testMisheardLyricWordsAreReported() {
        let result = LyricListenMatcher.match(lyrics: [["see", "you", "tomorrow", "night"]], heard: line(["see", "you", "tomorow", "night"], at: 0))
        XCTAssertEqual(result.misheard, [LyricListenMatcher.Misheard(heard: "tomorow", lyric: "tomorrow")])
    }

    func testRawWordsAreSavedWithTheTranscript() throws {
        let raw = line(["i", "love", "ewe"], at: 0)
        let transcript = SongTranscript(language: "en-US", source: "voice", words: line(["i", "love", "you"], at: 0), rawWords: raw, predictedChanges: 1)
        let back = try JSONDecoder().decode(SongTranscript.self, from: JSONEncoder().encode(transcript))
        XCTAssertEqual(back.rawWords.map(texts), ["i", "love", "ewe"])
        XCTAssertEqual(back.predictedChanges, 1)
        let old = try JSONDecoder().decode(SongTranscript.self, from: Data(#"{"words":[{"text":"hi","time":1,"duration":0.5}]}"#.utf8))
        XCTAssertNil(old.rawWords)
        XCTAssertEqual(old.predictedChanges, 0)
    }
}

final class WordPredictorTests: XCTestCase {
    func testAChorusHeardRightTwiceFixesTheThirdTime() {
        var heard = line(["i", "see", "the", "night"], at: 0) + line(["i", "see", "the", "night"], at: 10)
        heard += line(["i", "see", "the", "knight"], at: 20, confidence: [0.9, 0.9, 0.9, 0.3])
        // The same tune under every line.
        let notes = [0.0, 10, 20].flatMap { start in [60, 62, 64, 65].enumerated().map { SongNote(start: start + Double($0) * 0.4, duration: 0.3, pitch: $1) } }
        let result = WordPredictor.predict(heard, notes: notes, model: WordModel())
        XCTAssertEqual(texts(result.words), Array(repeating: ["i", "see", "the", "night"], count: 3).flatMap { $0 })
        XCTAssertEqual(result.changed, 1)
        XCTAssertEqual(result.words.last?.alternatives, ["knight"])
        XCTAssertEqual(result.words.last?.time ?? 0, 21.2, accuracy: 1e-9)
    }

    func testCorrectionsTeachItTheRecognisersHabits() {
        var model = WordModel()
        model.learnCorrections([("rite", "right"), ("rite", "right"), ("rite", "right")])
        let result = WordPredictor.predict(line(["do", "it", "rite", "now"], at: 0, confidence: [0.5, 0.5, 0.5, 0.5]), notes: [], model: model)
        XCTAssertEqual(texts(result.words), ["do", "it", "right", "now"])
    }

    func testWordsToKnowCatchANameHeardInPieces() {
        var model = WordModel()
        model.addCustomWord("Beyoncé")
        let heard = line(["dance", "like", "beyond", "say", "tonight"], at: 0, confidence: [0.8, 0.8, 0.4, 0.4, 0.8])
        let result = WordPredictor.predict(heard, notes: [], model: model)
        XCTAssertEqual(texts(result.words), ["dance", "like", "Beyoncé", "tonight"])
        XCTAssertEqual(result.changed, 2)
        XCTAssertEqual(result.words[2].alternatives, ["beyond say"])
    }

    func testAnEditedLineIsRememberedForNextTime() {
        var model = WordModel()
        model.learnEdit(heard: ["dance", "like", "beyond", "say"], corrected: ["dance", "like", "Beyoncé"])
        let result = WordPredictor.predict(line(["move", "like", "beyond", "say"], at: 0, confidence: [0.5, 0.5, 0.5, 0.5]), notes: [], model: model)
        XCTAssertEqual(texts(result.words), ["move", "like", "Beyoncé"])
    }

    func testPreviousWordsPickTheWordThatFits() {
        var model = WordModel()
        for _ in 0..<3 { model.learn(lines: [["do", "it", "right", "now"]]) }
        let unsure = WordPredictor.predict(line(["do", "it", "rite", "now"], at: 0, confidence: [0.6, 0.6, 0.6, 0.6]), notes: [], model: model)
        XCTAssertEqual(texts(unsure.words), ["do", "it", "right", "now"])
        // A word the recogniser was sure of stays.
        let sure = WordPredictor.predict(line(["do", "it", "write", "now"], at: 0, confidence: [0.95, 0.95, 0.95, 0.95]), notes: [], model: model)
        XCTAssertEqual(texts(sure.words), ["do", "it", "write", "now"])
        XCTAssertEqual(sure.changed, 0)
    }

    func testTheRecognisersAlternativesAreWeighedAgainstThePreviousWords() {
        var model = WordModel()
        for _ in 0..<2 { model.learn(lines: [["i", "love", "you"]]) }
        let heard = line(["i", "love", "ewe"], at: 0, confidence: [0.9, 0.9, 0.3], alternatives: [2: ["you"]])
        XCTAssertEqual(texts(WordPredictor.predict(heard, notes: [], model: model).words), ["i", "love", "you"])
    }

    func testAWordCantHaveMoreSyllablesThanNotesSung() {
        var model = WordModel()
        for _ in 0..<3 { model.learn(lines: [["say", "abracadabra", "now"]]) }
        let heard = [
            Word(text: "say", time: 0, duration: 0.3, confidence: 0.9),
            Word(text: "a", time: 0.4, duration: 0.4, confidence: 0.4, alternatives: ["abracadabra"]),
            Word(text: "now", time: 0.9, duration: 0.3, confidence: 0.9),
        ]
        // Without notes the word fits the words around it...
        XCTAssertEqual(texts(WordPredictor.predict(heard, notes: [], model: model).words), ["say", "abracadabra", "now"])
        // ...but only one note was sung there, so five syllables can't be right.
        let oneNote = [SongNote(start: 0.45, duration: 0.3, pitch: 60)]
        XCTAssertEqual(texts(WordPredictor.predict(heard, notes: oneNote, model: model).words), ["say", "a", "now"])
    }

    func testNothingChangesWithoutEvidence() {
        let heard = line(["i", "love", "ewe"], at: 0) + line(["something", "else"], at: 5, confidence: [0.5, 0.5])
        let result = WordPredictor.predict(heard, notes: [], model: WordModel())
        XCTAssertEqual(result.words, heard)
        XCTAssertEqual(result.changed, 0)
        XCTAssertTrue(WordPredictor.predict([], notes: [], model: WordModel()).words.isEmpty)
        let junk = [Word(text: "!!", time: 0), Word(text: "ok", time: .nan)]
        XCTAssertEqual(WordPredictor.predict(junk, notes: [], model: WordModel()).changed, 0)
    }

    func testJapaneseRepeatsStillVote() {
        // No sound keys for kana, but repeated lines still fix each other.
        var heard = line(["さくら", "さくら"], at: 0) + line(["さくら", "さくら"], at: 5)
        heard += line(["さくら", "さかな"], at: 10, confidence: [0.9, 0.2])
        let result = WordPredictor.predict(heard, notes: [], model: WordModel())
        XCTAssertEqual(texts(result.words).suffix(2), ["さくら", "さくら"])
    }
}
