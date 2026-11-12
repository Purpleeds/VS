import Foundation

/// Transposed direct-form II biquad (Float state, RBJ cookbook coefficients).
public struct Biquad: Sendable {
    public let b0: Float
    public let b1: Float
    public let b2: Float
    public let a1: Float
    public let a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public static func lowPass(sampleRate: Double, cutoff: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: Float((1 - cosW) / 2 / a0),
            b1: Float((1 - cosW) / a0),
            b2: Float((1 - cosW) / 2 / a0),
            a1: Float(-2 * cosW / a0),
            a2: Float((1 - alpha) / a0)
        )
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }
}
