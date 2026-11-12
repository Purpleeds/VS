import Foundation

/// Which spelling to use for the five black-key notes. The accidental is always written on the note
/// itself (F♯4, B♭3); no key signature is ever assumed.
public enum Accidentals: String, Codable, Sendable, CaseIterable {
    case sharps
    case flats
}

public enum PitchMath {
    public static let a4Frequency: Double = 440

    /// Fractional MIDI note number (A4 = 69).
    public static func midi(fromFrequency hz: Double, a4: Double = a4Frequency) -> Double {
        69 + 12 * log2(hz / a4)
    }

    public static func frequency(fromMIDI midi: Double, a4: Double = a4Frequency) -> Double {
        a4 * pow(2, (midi - 69) / 12)
    }

    /// Linear amplitude -> dBFS, floored at -160 so silence stays finite.
    public static func decibels(fromLinear value: Double) -> Double {
        value > 1e-8 ? 20 * log10(value) : -160
    }
}

public enum NoteNaming {
    private static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    private static let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

    /// Scientific pitch notation, MIDI 60 = "C4", 61 = "C♯4" / "D♭4".
    public static func name(forMIDINote note: Int, accidentals: Accidentals) -> String {
        let pitchClass = ((note % 12) + 12) % 12
        let octave = Int((Double(note) / 12).rounded(.down)) - 1
        let names = accidentals == .sharps ? sharpNames : flatNames
        return names[pitchClass] + String(octave)
    }

    /// Parses "C4", "F#4", "F♯4", "Bb3", "B♭3", "C-1". Returns nil if it isn't a note name.
    public static func midiNote(named name: String) -> Int? {
        var chars = Substring(name.trimmingCharacters(in: .whitespaces))
        guard let letter = chars.first?.uppercased(), let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][letter] else {
            return nil
        }
        chars = chars.dropFirst()
        var offset = 0
        while let c = chars.first, "#♯b♭".contains(c) {
            offset += (c == "#" || c == "♯") ? 1 : -1
            chars = chars.dropFirst()
        }
        guard let octave = Int(chars) else { return nil }
        return (octave + 1) * 12 + base + offset
    }

    /// Nearest equal-tempered note and the offset from it in cents (-50...+50).
    public static func nearestNote(toMIDI midi: Double) -> (note: Int, cents: Double) {
        let note = Int(midi.rounded())
        return (note, (midi - Double(note)) * 100)
    }
}
