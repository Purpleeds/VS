import Foundation

/// Gets a separated voice track ready for speech recognition and note writing:
///
/// 1. **Voice band:** high-pass at 100 Hz and low-pass at 4.5 kHz (what speech recognition listens to), which removes
///    bass and cymbal leakage from the separation.
/// 2. **Sung phrases:** 20 ms loudness frames; a frame is singing when it is clearly above the track's own quiet floor
///    (10 dB over the 15th percentile, and within 30 dB of its loud parts). Gaps under half a second are joined,
///    blips are dropped, phrases are padded and long ones split at their quietest moment (≤ 20 s each).
/// 3. **Clean-up:** each phrase is levelled to the same loudness and everything between phrases is silenced, so the
///    recogniser hears singing and silence, not leftover instruments.
public enum VocalPrep {
    public struct Segment: Sendable, Equatable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }

        public var duration: Double { end - start }
    }

    public struct Prepared: Sendable {
        public var samples: [Float]
        public var segments: [Segment]
    }

    public struct Configuration: Sendable, Equatable {
        public var frame = 0.02
        public var minGap = 0.5
        public var pad = 0.2
        public var minLength = 0.25
        public var maxLength = 20.0
        public var targetRMS: Float = 0.1
        public var maxGain: Float = 30

        public init() {}
    }

    /// Band-limits to the voice range (two-pole high-pass 100 Hz, twice; low-pass 4.5 kHz).
    public static func voiceBand(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard sampleRate > 0 else { return samples }
        var hp1 = Biquad.highPass(sampleRate: sampleRate, cutoff: 100, q: 0.707)
        var hp2 = Biquad.highPass(sampleRate: sampleRate, cutoff: 100, q: 0.707)
        var lp = Biquad.lowPass(sampleRate: sampleRate, cutoff: min(4_500, sampleRate * 0.45), q: 0.707)
        return samples.map { x in
            let y = lp.process(hp2.process(hp1.process(x.isFinite ? x : 0)))
            return y.isFinite ? y : 0
        }
    }

    /// Where someone is singing.
    public static func segments(_ samples: [Float], sampleRate: Double, configuration: Configuration = Configuration()) -> [Segment] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        let hop = max(1, Int(configuration.frame * sampleRate))
        var levels: [Double] = []
        levels.reserveCapacity(samples.count / hop + 1)
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + hop)
            var energy: Double = 0
            for k in i..<end { energy += Double(samples[k]) * Double(samples[k]) }
            levels.append(10 * log10(max(energy / Double(end - i), 1e-12)))
            i = end
        }
        let sorted = levels.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.15)]
        let loud = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let threshold = max(floor + 10, loud - 30, -60)
        guard loud >= threshold else { return [] }

        // Runs of voiced frames, joining short gaps.
        var runs: [(Int, Int)] = []
        let maxGapFrames = Int(configuration.minGap / configuration.frame)
        for (index, level) in levels.enumerated() where level >= threshold {
            if let last = runs.last, index - last.1 <= maxGapFrames {
                runs[runs.count - 1].1 = index
            } else {
                runs.append((index, index))
            }
        }
        let frame = configuration.frame
        let total = Double(samples.count) / sampleRate
        var segments: [Segment] = []
        for run in runs {
            let start = Double(run.0) * frame, end = Double(run.1 + 1) * frame
            guard end - start >= configuration.minLength else { continue }
            segments += split(Segment(start: max(0, start - configuration.pad), end: min(total, end + configuration.pad)),
                              levels: levels, frame: frame, maxLength: configuration.maxLength)
        }
        // Padding can make neighbours overlap: merge them (unless that would make one too long).
        var merged: [Segment] = []
        for segment in segments {
            if var last = merged.last, segment.start <= last.end, segment.end - last.start <= configuration.maxLength {
                last.end = max(last.end, segment.end)
                merged[merged.count - 1] = last
            } else if let last = merged.last, segment.start < last.end {
                merged.append(Segment(start: last.end, end: segment.end))
            } else {
                merged.append(segment)
            }
        }
        return merged.filter { $0.duration > 0.05 }
    }

    /// Splits a long phrase at its quietest frame in the middle half, until every piece fits.
    static func split(_ segment: Segment, levels: [Double], frame: Double, maxLength: Double) -> [Segment] {
        guard segment.duration > maxLength else { return [segment] }
        let a = Int((segment.start + segment.duration * 0.25) / frame)
        let b = max(a + 1, Int((segment.end - segment.duration * 0.25) / frame))
        let range = max(0, a)..<min(levels.count, b)
        let cut: Double
        if let quietest = range.min(by: { levels[$0] < levels[$1] }) {
            cut = Double(quietest) * frame
        } else {
            cut = segment.start + segment.duration / 2
        }
        return split(Segment(start: segment.start, end: cut), levels: levels, frame: frame, maxLength: maxLength)
            + split(Segment(start: cut, end: segment.end), levels: levels, frame: frame, maxLength: maxLength)
    }

    /// Voice band, sung phrases levelled to one loudness, silence in between (10 ms fades at the edges).
    public static func prepare(_ samples: [Float], sampleRate: Double, configuration: Configuration = Configuration()) -> Prepared {
        let band = voiceBand(samples, sampleRate: sampleRate)
        let segments = segments(band, sampleRate: sampleRate, configuration: configuration)
        var out = [Float](repeating: 0, count: band.count)
        let fade = max(1, Int(0.01 * sampleRate))
        for segment in segments {
            let lo = max(0, Int(segment.start * sampleRate)), hi = min(band.count, Int(segment.end * sampleRate))
            guard hi > lo else { continue }
            var energy: Float = 0
            var peak: Float = 0
            for k in lo..<hi {
                energy += band[k] * band[k]
                peak = max(peak, abs(band[k]))
            }
            let rms = (energy / Float(hi - lo)).squareRoot()
            var gain = rms > 0 ? min(configuration.maxGain, configuration.targetRMS / rms) : 0
            if peak * gain > 0.95 { gain = 0.95 / max(peak, 1e-9) }
            for k in lo..<hi {
                let edge = min(k - lo, hi - 1 - k)
                let ramp = edge < fade ? Float(edge) / Float(fade) : 1
                out[k] = band[k] * gain * ramp
            }
        }
        return Prepared(samples: out, segments: segments)
    }

    /// Whether `time` falls inside any of the (sorted) segments.
    public static func contains(_ segments: [Segment], _ time: Double) -> Bool {
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].end <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo < segments.count && segments[lo].start <= time
    }
}
