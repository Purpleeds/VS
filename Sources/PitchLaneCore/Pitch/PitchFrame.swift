import Foundation

/// One analysis frame (every ~10 ms) after stabilisation.
public struct PitchFrame: Sendable, Equatable {
    /// Seconds since the stream started, at the centre of the analysis window.
    public var time: Double
    /// Stabilised fundamental in Hz; nil when unvoiced.
    public var frequency: Double?
    /// Stabilised fractional MIDI note (A4 = 69); nil when unvoiced.
    public var midi: Double?
    /// Nearest equal-tempered MIDI note.
    public var nearestNote: Int?
    /// Name of `nearestNote`, e.g. "F♯4".
    public var noteName: String?
    /// Offset from `nearestNote` in cents (-50...+50).
    public var cents: Double?
    /// Raw detector confidence 0...1 (reported even when unvoiced).
    public var confidence: Double
    /// Linear RMS level of the frame.
    public var rms: Double
    /// Unsmoothed detector frequency, for diagnostics.
    public var rawFrequency: Double?
    public var unvoicedReason: UnvoicedReason?

    public init(
        time: Double,
        midi: Double?,
        accidentals: Accidentals,
        confidence: Double,
        rms: Double,
        rawFrequency: Double?,
        unvoicedReason: UnvoicedReason?
    ) {
        self.time = time
        self.midi = midi
        self.confidence = confidence
        self.rms = rms
        self.rawFrequency = rawFrequency
        self.unvoicedReason = midi == nil ? (unvoicedReason ?? .lowConfidence) : nil
        if let midi {
            let nearest = NoteNaming.nearestNote(toMIDI: midi)
            self.frequency = PitchMath.frequency(fromMIDI: midi)
            self.nearestNote = nearest.note
            self.cents = nearest.cents
            self.noteName = NoteNaming.name(forMIDINote: nearest.note, accidentals: accidentals)
        } else {
            self.frequency = nil
            self.nearestNote = nil
            self.cents = nil
            self.noteName = nil
        }
    }

    public var isVoiced: Bool { midi != nil }
    public var levelDBFS: Double { PitchMath.decibels(fromLinear: rms) }
}

/// Per-frame analysis cost, for the debug overlay and logs.
public struct AnalysisTiming: Sendable, Equatable {
    public private(set) var count = 0
    public private(set) var totalSeconds = 0.0
    public private(set) var maxSeconds = 0.0

    public init() {}

    public mutating func record(_ seconds: Double) {
        count += 1
        totalSeconds += seconds
        maxSeconds = max(maxSeconds, seconds)
    }

    public mutating func merge(_ other: AnalysisTiming) {
        count += other.count
        totalSeconds += other.totalSeconds
        maxSeconds = max(maxSeconds, other.maxSeconds)
    }

    public var averageSeconds: Double { count > 0 ? totalSeconds / Double(count) : 0 }
}

extension Duration {
    var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}
