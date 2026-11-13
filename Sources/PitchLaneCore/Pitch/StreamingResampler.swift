import Foundation

/// Streaming sample-rate converter for the analysis path (default 16 kHz output).
///
/// Downsampling: 6th-order Butterworth low-pass (three biquads) at min(5.5 kHz, 0.45 x input rate), then
/// linear interpolation. That is plenty for pitch analysis of a voice (fundamentals <= ~1 kHz); it is not a
/// hi-fi resampler. Upsampling (e.g. an 8 kHz Bluetooth mic) skips the filter.
/// Processing is chunk-size independent: splitting the input differently gives identical output.
public struct StreamingResampler: Sendable {
    public let inputRate: Double
    public let outputRate: Double
    private let step: Double
    private let filtering: Bool
    private var f0: Biquad
    private var f1: Biquad
    private var f2: Biquad
    private var previous: Float = 0
    private var position: Double = 0

    public init(inputRate: Double, outputRate: Double = 16_000) {
        precondition(inputRate > 0 && outputRate > 0, "sample rates must be positive")
        self.inputRate = inputRate
        self.outputRate = outputRate
        self.step = inputRate / outputRate
        self.filtering = inputRate > outputRate * 1.0001
        let cutoff = min(5_500, 0.45 * inputRate, 0.45 * outputRate * 2)
        // Butterworth Q values for a 6th-order cascade.
        self.f0 = .lowPass(sampleRate: inputRate, cutoff: cutoff, q: 0.517_638_09)
        self.f1 = .lowPass(sampleRate: inputRate, cutoff: cutoff, q: 0.707_106_78)
        self.f2 = .lowPass(sampleRate: inputRate, cutoff: cutoff, q: 1.931_851_65)
    }

    /// Converts `input` and appends the result to `output`.
    public mutating func process(_ input: UnsafeBufferPointer<Float>, appendingTo output: inout [Float]) {
        var t = position
        var prev = previous
        for x in input {
            // A single NaN/Inf would poison the filter state for good: treat it as silence and reset.
            var y = x.isFinite ? x : 0
            if filtering {
                y = f2.process(f1.process(f0.process(y)))
                if !y.isFinite {
                    f0.reset()
                    f1.reset()
                    f2.reset()
                    y = 0
                }
            }
            while t < 1 {
                output.append(prev + (y - prev) * Float(t))
                t += step
            }
            t -= 1
            prev = y
        }
        position = t
        previous = prev
    }

    public mutating func process(_ input: [Float]) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(Int(Double(input.count) / step) + 2)
        input.withUnsafeBufferPointer { process($0, appendingTo: &output) }
        return output
    }

    public mutating func reset() {
        f0.reset()
        f1.reset()
        f2.reset()
        previous = 0
        position = 0
    }
}
