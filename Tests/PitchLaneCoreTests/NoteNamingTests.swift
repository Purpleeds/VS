import XCTest
import PitchLaneCore

final class NoteNamingTests: XCTestCase {
    func testNaturalNotes() {
        XCTAssertEqual(NoteNaming.name(forMIDINote: 60, accidentals: .sharps), "C4")
        XCTAssertEqual(NoteNaming.name(forMIDINote: 69, accidentals: .flats), "A4")
        XCTAssertEqual(NoteNaming.name(forMIDINote: 36, accidentals: .sharps), "C2")
        XCTAssertEqual(NoteNaming.name(forMIDINote: 84, accidentals: .sharps), "C6")
        XCTAssertEqual(NoteNaming.name(forMIDINote: 59, accidentals: .sharps), "B3")
        XCTAssertEqual(NoteNaming.name(forMIDINote: 0, accidentals: .sharps), "C-1")
    }

    func testAccidentalIsAlwaysOnTheNote() {
        let sharps = (60...71).map { NoteNaming.name(forMIDINote: $0, accidentals: .sharps) }
        let flats = (60...71).map { NoteNaming.name(forMIDINote: $0, accidentals: .flats) }
        XCTAssertEqual(sharps, ["C4", "C♯4", "D4", "D♯4", "E4", "F4", "F♯4", "G4", "G♯4", "A4", "A♯4", "B4"])
        XCTAssertEqual(flats, ["C4", "D♭4", "D4", "E♭4", "E4", "F4", "G♭4", "G4", "A♭4", "A4", "B♭4", "B4"])
        XCTAssertEqual(NoteNaming.name(forMIDINote: 58, accidentals: .flats), "B♭3")
        for name in sharps + flats {
            XCTAssertFalse(name.contains("#"), name)
            XCTAssertFalse(name.dropFirst().contains("b"), name)
        }
    }

    func testOctaveBoundaryBelowZero() {
        XCTAssertEqual(NoteNaming.name(forMIDINote: -1, accidentals: .sharps), "B-2")
    }

    func testFrequencyConversions() {
        XCTAssertEqual(PitchMath.midi(fromFrequency: 440), 69, accuracy: 1e-12)
        XCTAssertEqual(PitchMath.midi(fromFrequency: 220), 57, accuracy: 1e-12)
        XCTAssertEqual(PitchMath.frequency(fromMIDI: 60), 261.625_565, accuracy: 1e-5)
        XCTAssertEqual(PitchMath.frequency(fromMIDI: PitchMath.midi(fromFrequency: 123.4)), 123.4, accuracy: 1e-9)
        XCTAssertEqual(PitchMath.midi(fromFrequency: 466.16, a4: 466.16), 69, accuracy: 1e-12)
    }

    func testNearestNoteAndCents() {
        let a = NoteNaming.nearestNote(toMIDI: 69.3)
        XCTAssertEqual(a.note, 69)
        XCTAssertEqual(a.cents, 30, accuracy: 1e-9)
        let b = NoteNaming.nearestNote(toMIDI: 69.6)
        XCTAssertEqual(b.note, 70)
        XCTAssertEqual(b.cents, -40, accuracy: 1e-9)
    }

    func testDecibels() {
        XCTAssertEqual(PitchMath.decibels(fromLinear: 1), 0, accuracy: 1e-12)
        XCTAssertEqual(PitchMath.decibels(fromLinear: 0.1), -20, accuracy: 1e-12)
        XCTAssertEqual(PitchMath.decibels(fromLinear: 0), -160)
    }
}
