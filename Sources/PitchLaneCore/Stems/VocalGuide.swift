import Foundation

/// Where the singer sings and at what pitch, worked out from a first, plain separation. The second separation pass
/// uses it (`StemSeparator(guide:)`): outside singing the voice is turned right down, and while the singer holds a
/// pitch only that pitch's harmonics stay in the voice, so centred instruments go back to the music.
public struct VocalGuide: Sendable, Equatable {
    /// Sung phrases (sorted).
    public var singing: [VocalPrep.Segment]
    /// The singer's pitch every 10 ms (nil = unknown or not singing).
    public var pitch: [VoiceFocus.PitchPoint]

    public init(singing: [VocalPrep.Segment], pitch: [VoiceFocus.PitchPoint]) {
        self.singing = singing
        self.pitch = pitch
    }

    /// From the first-pass voice (mono, any sample rate; 16 kHz is plenty).
    public static func analyze(_ voice: [Float], sampleRate: Double) -> VocalGuide {
        guard sampleRate > 0, !voice.isEmpty else { return VocalGuide(singing: [], pitch: []) }
        let band = VocalPrep.voiceBand(voice, sampleRate: sampleRate)
        let singing = VocalPrep.segments(band, sampleRate: sampleRate)
        let pitch = VoiceFocus.pitchTrack(band, sampleRate: sampleRate).map { point in
            VoiceFocus.PitchPoint(time: point.time, frequency: VocalPrep.contains(singing, point.time) ? point.frequency : nil)
        }
        return VocalGuide(singing: singing, pitch: pitch)
    }

    /// Seconds of singing.
    public var singingDuration: Double { singing.reduce(0) { $0 + $1.duration } }

    /// Share of the sung time with a known pitch (0...1).
    public var pitchedFraction: Double {
        let sung = pitch.filter { VocalPrep.contains(singing, $0.time) }
        guard !sung.isEmpty else { return 0 }
        return Double(sung.filter { $0.frequency != nil }.count) / Double(sung.count)
    }

    /// Whether `time` is inside a sung phrase, walking forward from `cursor` (times must not go backwards).
    func isSinging(at time: Double, cursor: inout Int) -> Bool {
        while cursor < singing.count, singing[cursor].end <= time { cursor += 1 }
        return cursor < singing.count && singing[cursor].start <= time
    }
}
