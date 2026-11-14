import Foundation

/// Focuses a (separated) voice track on the singer before speech recognition: wherever the singer's pitch is known,
/// only the singer's harmonics (multiples of the sung pitch) are kept and everything between them (chords, bass,
/// drums that leaked through the separation) is turned down. Where no pitch is known (consonants, breaths, unclear
/// frames) the sound passes through unchanged, so the recogniser still hears every consonant.
///
/// Short-time Fourier transform (about 64 ms frames, 75 % overlap, √Hann windows). In a voiced frame a bin within
/// `c` of the nearest harmonic of f0 passes (`c` = one bin, or 3 % of the harmonic's frequency for vibrato, whichever
/// is wider); further away the gain falls off as `exp(-((d - c) / 1.5 bins)²)` down to `floor`, and below the
/// fundamental it is `floor`. A pitch that is an octave too low still keeps every real harmonic, so the usual tracking mistake is harmless.
public enum VoiceFocus {
    public struct Configuration: Sendable, Equatable {
        /// Frame length in seconds (rounded to a power of two in samples).
        public var frameDuration = 0.064
        /// Gain between harmonics (0.2 ≈ -14 dB): turned down, never removed.
        public var floor: Float = 0.2
        /// Harmonic width as a fraction of the harmonic's frequency (vibrato and pitch drift within a frame).
        public var widthFraction = 0.03
        /// Harmonics above this pass unchanged (VocalPrep already low-passes at 4.5 kHz).
        public var maxHarmonicHz = 4_000.0

        public init() {}
    }

    /// Sung pitch at one time (Hz; nil = unknown or unvoiced).
    public struct PitchPoint: Sendable, Equatable {
        public var time: Double
        public var frequency: Double?

        public init(time: Double, frequency: Double?) {
            self.time = time
            self.frequency = frequency
        }
    }

    public struct Result: Sendable {
        public var samples: [Float]
        /// Share of frames that were filtered around a known pitch (0...1 of the frames that had sound).
        public var focusedFraction: Double
    }

    /// The singer's pitch every 10 ms, from Core's `PitchPipeline` (YIN with the usual stabiliser).
    public static func pitchTrack(_ samples: [Float], sampleRate: Double) -> [PitchPoint] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        let pipeline = PitchPipeline(inputSampleRate: sampleRate)
        var points: [PitchPoint] = []
        points.reserveCapacity(Int(Double(samples.count) / sampleRate * 100) + 1)
        let clean = samples.map { $0.isFinite ? $0 : 0 }
        clean.withUnsafeBufferPointer { buffer in
            pipeline.process(buffer) { frame in
                let hz = frame.midi.map { 440 * pow(2, ($0 - 69) / 12) }
                points.append(PitchPoint(time: frame.time, frequency: hz))
            }
        }
        return points
    }

    /// Tracks the pitch, then filters around it.
    public static func apply(_ samples: [Float], sampleRate: Double, configuration: Configuration = Configuration()) -> Result {
        apply(samples, sampleRate: sampleRate, track: pitchTrack(samples, sampleRate: sampleRate), configuration: configuration)
    }

    /// Filters around a given pitch track (sorted by time). Output length = input length.
    public static func apply(
        _ input: [Float], sampleRate: Double, track: [PitchPoint], configuration: Configuration = Configuration()
    ) -> Result {
        guard sampleRate > 0, !input.isEmpty else { return Result(samples: input.map { $0.isFinite ? $0 : 0 }, focusedFraction: 0) }
        let samples = input.map { $0.isFinite ? $0 : 0 }
        let transform = FFT(size: max(256, Int(configuration.frameDuration * sampleRate)))
        let n = transform.size
        let hop = n / 4
        let half = n / 2
        let binHz = sampleRate / Double(n)
        let window = (0..<n).map { Float(sin(Double.pi * Double($0) / Double(n))) } // √(periodic Hann)
        // Pad so every sample is covered by four frames; trimmed at the end.
        let lead = n - hop
        var padded = [Float](repeating: 0, count: lead)
        padded.reserveCapacity(lead + samples.count + n)
        padded += samples
        padded += [Float](repeating: 0, count: n)
        var output = [Float](repeating: 0, count: padded.count)
        var re = [Float](repeating: 0, count: n)
        var im = [Float](repeating: 0, count: n)
        var gains = [Float](repeating: 1, count: half + 1)
        var cursor = 0
        var focusedFrames = 0
        var soundFrames = 0
        var start = 0
        while start + n <= padded.count {
            var energy: Float = 0
            for i in 0..<n {
                let x = padded[start + i]
                energy += x * x
                re[i] = x * window[i]
                im[i] = 0
            }
            guard energy > 1e-10 else {
                start += hop
                continue // silence stays silence
            }
            soundFrames += 1
            let centre = (Double(start + n / 2) - Double(lead)) / sampleRate
            let f0 = pitch(at: centre, in: track, cursor: &cursor)
            if let f0, f0 > binHz * 2 {
                focusedFrames += 1
                fillGains(&gains, f0: f0, binHz: binHz, configuration: configuration)
                re.withUnsafeMutableBufferPointer { rb in
                    im.withUnsafeMutableBufferPointer { ib in
                        guard let rp = rb.baseAddress, let ip = ib.baseAddress else { return }
                        transform.forward(real: rp, imag: ip)
                        for k in 0...half {
                            let g = gains[k]
                            rp[k] *= g
                            ip[k] *= g
                            let m = (n - k) % n
                            if m != k {
                                rp[m] *= g
                                ip[m] *= g
                            }
                        }
                        transform.inverse(real: rp, imag: ip)
                    }
                }
            }
            // Overlap-add (√Hann² = Hann sums to 2 at 75 % overlap).
            for i in 0..<n {
                output[start + i] += re[i] * window[i] * 0.5
            }
            start += hop
        }
        let trimmed = Array(output[lead..<(lead + samples.count)]).map { $0.isFinite ? $0 : 0 }
        return Result(samples: trimmed, focusedFraction: soundFrames > 0 ? Double(focusedFrames) / Double(soundFrames) : 0)
    }

    static func fillGains(_ gains: inout [Float], f0: Double, binHz: Double, configuration: Configuration) {
        let floor = configuration.floor
        for k in gains.indices {
            let f = Double(k) * binHz
            if f > configuration.maxHarmonicHz {
                gains[k] = 1
                continue
            }
            if f < f0 * 0.75 {
                gains[k] = floor
                continue
            }
            let harmonic = max(1, (f / f0).rounded())
            let distance = abs(f - harmonic * f0)
            let core = max(binHz, configuration.widthFraction * harmonic * f0)
            if distance <= core {
                gains[k] = 1
                continue
            }
            let ratio = (distance - core) / (1.5 * binHz)
            gains[k] = max(floor, Float(exp(-ratio * ratio)))
        }
    }

    /// The tracked pitch nearest to `time` (within 15 ms), walking forward from `cursor`.
    static func pitch(at time: Double, in track: [PitchPoint], cursor: inout Int) -> Double? {
        guard !track.isEmpty else { return nil }
        while cursor + 1 < track.count, track[cursor + 1].time <= time { cursor += 1 }
        var best: PitchPoint?
        for index in [cursor, cursor + 1] where index < track.count {
            let point = track[index]
            if abs(point.time - time) <= 0.015, best.map({ abs(point.time - time) < abs($0.time - time) }) ?? true {
                best = point
            }
        }
        guard let hz = best?.frequency, hz.isFinite, hz > 0 else { return nil }
        return hz
    }
}
