import Foundation

public struct PitchDetectorConfiguration: Sendable, Equatable {
    /// Rate of the samples given to the detector (after resampling).
    public var sampleRate: Double
    public var minFrequency: Double
    public var maxFrequency: Double
    /// YIN absolute threshold on the cumulative mean normalised difference.
    public var threshold: Double

    public init(
        sampleRate: Double = 16_000,
        minFrequency: Double = 65.406_391,   // C2
        maxFrequency: Double = 1_046.502_3,  // C6
        threshold: Double = 0.15
    ) {
        self.sampleRate = sampleRate
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.threshold = threshold
    }

    /// Voice default: C2-C6 at 16 kHz.
    public static let voice = PitchDetectorConfiguration()

    /// Shortest period (in samples) inside the range.
    public var minLag: Int { max(2, Int((sampleRate / maxFrequency).rounded(.down))) }
    /// Longest period searched, +1 so the parabola at the top of the range has a right neighbour.
    public var maxLag: Int { Int((sampleRate / minFrequency).rounded(.up)) + 1 }
    /// Samples summed per lag in the difference function.
    public var integrationWindow: Int { maxLag }
    /// Samples needed per analysis frame.
    public var frameLength: Int { integrationWindow + maxLag }
}

/// Raw, unsmoothed result for one frame.
public struct PitchEstimate: Sendable, Equatable {
    /// Detected fundamental, nil if nothing periodic was found in range.
    public var frequency: Double?
    /// 1 - CMNDF at the chosen lag, clamped to 0...1.
    public var confidence: Double
    /// Linear RMS of the frame.
    public var rms: Double
    /// A clear period was found, but shorter than the minimum lag (pitch above `maxFrequency`).
    public var isAboveRange: Bool

    public init(frequency: Double?, confidence: Double, rms: Double, isAboveRange: Bool = false) {
        self.frequency = frequency
        self.confidence = confidence
        self.rms = rms
        self.isAboveRange = isAboveRange
    }
}

/// YIN pitch detector (de Cheveigné & Kawahara, 2002). Not thread-safe: own one per analysis queue.
/// Scratch buffers are allocated once; `analyze` does not allocate.
public final class PitchDetector {
    public let configuration: PitchDetectorConfiguration
    private var difference: [Float]
    private var cmndf: [Float]

    public init(configuration: PitchDetectorConfiguration = .voice) {
        precondition(configuration.minFrequency > 0, "minFrequency must be positive")
        precondition(configuration.maxFrequency > configuration.minFrequency, "maxFrequency must exceed minFrequency")
        precondition(configuration.maxLag > configuration.minLag + 2, "frequency range too narrow for this sample rate")
        self.configuration = configuration
        self.difference = [Float](repeating: 0, count: configuration.maxLag + 1)
        self.cmndf = [Float](repeating: 1, count: configuration.maxLag + 1)
    }

    public func analyze(_ samples: [Float]) -> PitchEstimate {
        samples.withUnsafeBufferPointer { analyze($0) }
    }

    /// Analyses the most recent `configuration.frameLength` samples of `samples`.
    public func analyze(_ samples: UnsafeBufferPointer<Float>) -> PitchEstimate {
        let config = configuration
        let frameLength = config.frameLength
        precondition(samples.count >= frameLength, "need at least frameLength samples")
        guard let base = samples.baseAddress else {
            return PitchEstimate(frequency: nil, confidence: 0, rms: 0)
        }
        let x = base + (samples.count - frameLength)
        let window = config.integrationWindow
        let maxLag = config.maxLag
        let minLag = config.minLag
        let threshold = Float(config.threshold)

        // RMS over the whole frame.
        var energy: Float = 0
        for i in 0..<frameLength {
            energy += x[i] * x[i]
        }
        let rms = Double((energy / Float(frameLength)).squareRoot())

        return difference.withUnsafeMutableBufferPointer { d -> PitchEstimate in
            cmndf.withUnsafeMutableBufferPointer { c -> PitchEstimate in
                // 1. Difference function d(tau) = sum_j (x_j - x_{j+tau})^2.
                d[0] = 0
                for tau in 1...maxLag {
                    let y = x + tau
                    var s0: Float = 0, s1: Float = 0, s2: Float = 0, s3: Float = 0
                    var j = 0
                    while j + 4 <= window {
                        let e0 = x[j] - y[j]
                        let e1 = x[j + 1] - y[j + 1]
                        let e2 = x[j + 2] - y[j + 2]
                        let e3 = x[j + 3] - y[j + 3]
                        s0 += e0 * e0
                        s1 += e1 * e1
                        s2 += e2 * e2
                        s3 += e3 * e3
                        j += 4
                    }
                    while j < window {
                        let e = x[j] - y[j]
                        s0 += e * e
                        j += 1
                    }
                    d[tau] = (s0 + s1) + (s2 + s3)
                }

                // 2. Cumulative mean normalised difference.
                c[0] = 1
                var running: Float = 0
                for tau in 1...maxLag {
                    running += d[tau]
                    c[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
                }

                // 3. First dip below the threshold, searched from lag 2 so pitches above range are noticed.
                var best = -1
                var tau = 2
                while tau < maxLag {
                    if c[tau] < threshold {
                        while tau + 1 < maxLag && c[tau + 1] < c[tau] {
                            tau += 1
                        }
                        best = tau
                        break
                    }
                    tau += 1
                }
                if best < 0 {
                    // No dip: fall back to the global minimum in range (confidence will be low).
                    best = minLag
                    var t = minLag + 1
                    while t < maxLag {
                        if c[t] < c[best] { best = t }
                        t += 1
                    }
                }

                let value = Double(c[best])
                let confidence = min(1, max(0, 1 - value))
                if best < minLag {
                    return PitchEstimate(frequency: nil, confidence: confidence, rms: rms, isAboveRange: true)
                }
                if value >= 1 {
                    return PitchEstimate(frequency: nil, confidence: 0, rms: rms)
                }

                // 4. Parabolic interpolation on the raw difference function.
                let y0 = Double(d[best - 1])
                let y1 = Double(d[best])
                let y2 = Double(d[best + 1])
                let denominator = y0 - 2 * y1 + y2
                var offset = 0.0
                if denominator > 0 {
                    offset = min(1, max(-1, 0.5 * (y0 - y2) / denominator))
                }
                let frequency = config.sampleRate / (Double(best) + offset)
                if frequency > config.maxFrequency * 1.059_463 {
                    return PitchEstimate(frequency: nil, confidence: confidence, rms: rms, isAboveRange: true)
                }
                return PitchEstimate(frequency: frequency, confidence: confidence, rms: rms)
            }
        }
    }
}
