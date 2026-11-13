import Foundation

/// Envelope of the guide synth.
public struct GuideEnvelope: Sendable, Equatable {
    /// Raised-cosine fade-in at a note start (seconds).
    public var attack: Double
    /// Raised-cosine fade-out before a note end (seconds).
    public var release: Double
    /// Notes closer than this are played legato: no fade between them, pitch held across the gap.
    public var legatoGap: Double

    public init(attack: Double, release: Double, legatoGap: Double) {
        self.attack = max(0.0005, attack)
        self.release = max(0.0005, release)
        self.legatoGap = max(0, legatoGap)
    }

    /// Gentle singing guide.
    public static let soft = GuideEnvelope(attack: 0.03, release: 0.06, legatoGap: 0.04)
    /// Short, crisp beeps (latency calibration).
    public static let percussive = GuideEnvelope(attack: 0.002, release: 0.02, legatoGap: 0)
}

/// Real-time synth that plays a song's notes as a soft tone (fundamental plus a little 2nd and 3rd harmonic),
/// with gentle attack/release, legato between touching notes and glides on slides.
///
/// Real-time safe: notes are copied into a fixed buffer at init; `render` never allocates, locks or logs.
/// Not thread-safe: after handing it to the audio thread, only that thread may call `render`/`reset`.
public final class GuideToneRenderer: @unchecked Sendable {
    private struct Voice {
        var start: Double
        var end: Double
        var pitch: Double
        var fromPitch: Double
        /// Seconds of glide from `fromPitch` at the start; 0 = none.
        var glide: Double
        var legatoIn: Bool
        var legatoOut: Bool
    }

    public let envelope: GuideEnvelope
    public let noteCount: Int
    private let voices: UnsafeMutableBufferPointer<Voice>
    private var phase = 0.0
    private var gain: Float = 0
    private var cursor = 0
    private var lastTime = -Double.infinity
    private var cachedPitch = Double.nan
    private var cachedIncrementPerSecond = 0.0

    /// Plays every non-freestyle note of `song`.
    public init(song: Song, envelope: GuideEnvelope = .soft) {
        self.envelope = envelope
        let notes = song.notes.filter { !$0.isFreestyle }
        noteCount = notes.count
        voices = .allocate(capacity: max(1, notes.count))
        for (i, note) in notes.enumerated() {
            let previous = i > 0 ? notes[i - 1] : nil
            let next = i + 1 < notes.count ? notes[i + 1] : nil
            let slides = note.slidesFromPrevious && previous != nil
            let voice = Voice(
                start: note.start,
                end: note.end,
                pitch: Double(note.pitch),
                fromPitch: slides ? Double(previous!.pitch) : Double(note.pitch),
                glide: slides ? max(0.001, min(note.duration, note.slideDuration ?? note.duration)) : 0,
                legatoIn: previous.map { note.start - $0.end <= envelope.legatoGap } ?? false,
                legatoOut: next.map { $0.start - note.end <= envelope.legatoGap } ?? false
            )
            (voices.baseAddress! + i).initialize(to: voice)
        }
    }

    deinit {
        voices.baseAddress?.deinitialize(count: noteCount)
        voices.deallocate()
    }

    /// Forget phase/gain/position (e.g. on restart). Audio thread only once rendering has started.
    public func reset() {
        phase = 0
        gain = 0
        cursor = 0
        lastTime = -.infinity
        cachedPitch = .nan
    }

    /// Renders `frameCount` mono samples. `songTime` is the song time of the first sample and song time advances
    /// `rate` song-seconds per output second (practice speed; pitch is unaffected). When `advancing` is false
    /// (paused, countdown hold) time stands still and the output fades to silence.
    public func render(
        into out: UnsafeMutablePointer<Float>,
        frameCount: Int,
        sampleRate: Double,
        songTime: Double,
        rate: Double = 1,
        advancing: Bool,
        volume: Float
    ) {
        guard frameCount > 0, sampleRate > 0 else { return }
        // ~3 ms one-pole smoothing on the gain: declicks pauses and volume changes.
        let smoothing = Float(1 - exp(-1 / (0.003 * sampleRate)))
        let step = 1 / sampleRate
        let songStep = step * (rate.isFinite && rate > 0 ? rate : 1)
        let level = max(0, min(1, volume))
        for i in 0..<frameCount {
            let t = advancing ? songTime + Double(i) * songStep : songTime
            var targetGain: Float = 0
            var pitch = cachedPitch.isNaN ? 69 : cachedPitch
            if advancing, level > 0, let sound = evaluate(at: t) {
                targetGain = Float(sound.amplitude) * level
                pitch = sound.pitch
            }
            gain += (targetGain - gain) * smoothing
            if gain < 1e-5 && targetGain == 0 {
                gain = 0
                out[i] = 0
                continue
            }
            if pitch != cachedPitch {
                cachedPitch = pitch
                cachedIncrementPerSecond = 440 * pow(2, (pitch - 69) / 12)
            }
            phase += cachedIncrementPerSecond * step
            phase -= phase.rounded(.down)
            let x = 2 * Double.pi * phase
            let tone = sin(x) + 0.22 * sin(2 * x) + 0.07 * sin(3 * x)
            out[i] = Float(tone / 1.29 * 0.5) * gain
        }
    }

    /// Amplitude (0...1) and pitch at song time `t`, or nil for silence.
    private func evaluate(at t: Double) -> (amplitude: Double, pitch: Double)? {
        let n = noteCount
        guard n > 0 else { return nil }
        if t < lastTime - 0.05 {
            // Time jumped back (restart / seek): binary search for the first voice ending after t.
            var low = 0
            var high = n
            while low < high {
                let mid = (low + high) / 2
                if voices[mid].end <= t { low = mid + 1 } else { high = mid }
            }
            cursor = low
        }
        lastTime = t
        while cursor < n, voices[cursor].end <= t {
            if voices[cursor].legatoOut, cursor + 1 < n, t < voices[cursor + 1].start {
                break // in a legato gap: hold this voice
            }
            cursor += 1
        }
        guard cursor < n else { return nil }
        let v = voices[cursor]
        if t < v.start { return nil }
        if t >= v.end { return (1, v.pitch) } // legato gap
        let attack = v.legatoIn ? 1 : Self.raisedCosine((t - v.start) / envelope.attack)
        let release = v.legatoOut ? 1 : Self.raisedCosine((v.end - t) / envelope.release)
        var pitch = v.pitch
        if v.glide > 0 {
            let x = min(1, max(0, (t - v.start) / v.glide))
            pitch = v.fromPitch + (v.pitch - v.fromPitch) * x * x * (3 - 2 * x)
        }
        return (min(attack, release), pitch)
    }

    @inline(__always)
    private static func raisedCosine(_ x: Double) -> Double {
        if x >= 1 { return 1 }
        if x <= 0 { return 0 }
        return 0.5 - 0.5 * cos(Double.pi * x)
    }
}
