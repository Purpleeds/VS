import Foundation

/// In-place radix-2 complex FFT on split real/imaginary arrays (Float). Tables are built once per size.
public final class FFT {
    public let size: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let reversed: [Int]

    /// `size` is rounded up to a power of two (minimum 2).
    public init(size requested: Int) {
        var n = 2
        while n < requested { n <<= 1 }
        size = n
        cosTable = (0..<(n / 2)).map { Float(cos(2 * Double.pi * Double($0) / Double(n))) }
        sinTable = (0..<(n / 2)).map { Float(sin(2 * Double.pi * Double($0) / Double(n))) }
        var bits = 0
        while (1 << bits) < n { bits += 1 }
        reversed = (0..<n).map { index in
            var r = 0
            var x = index
            for _ in 0..<bits {
                r = (r << 1) | (x & 1)
                x >>= 1
            }
            return r
        }
    }

    /// X[k] = Σ x[n] e^{-2πikn/N}. Both buffers must hold `size` values.
    public func forward(real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
        transform(real: real, imag: imag, sign: -1)
    }

    /// x[n] = (1/N) Σ X[k] e^{2πikn/N}.
    public func inverse(real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>) {
        transform(real: real, imag: imag, sign: 1)
        let scale = 1 / Float(size)
        for i in 0..<size {
            real[i] *= scale
            imag[i] *= scale
        }
    }

    private func transform(real: UnsafeMutablePointer<Float>, imag: UnsafeMutablePointer<Float>, sign: Float) {
        let n = size
        reversed.withUnsafeBufferPointer { rev in
            for i in 0..<n {
                let j = rev[i]
                if j > i {
                    swap(&real[i], &real[j])
                    swap(&imag[i], &imag[j])
                }
            }
        }
        cosTable.withUnsafeBufferPointer { cosT in
            sinTable.withUnsafeBufferPointer { sinT in
                var length = 2
                while length <= n {
                    let half = length / 2
                    let step = n / length
                    var start = 0
                    while start < n {
                        for j in 0..<half {
                            let wr = cosT[j * step]
                            let wi = sign * sinT[j * step]
                            let a = start + j
                            let b = a + half
                            let vr = real[b] * wr - imag[b] * wi
                            let vi = real[b] * wi + imag[b] * wr
                            real[b] = real[a] - vr
                            imag[b] = imag[a] - vi
                            real[a] += vr
                            imag[a] += vi
                        }
                        start += length
                    }
                    length <<= 1
                }
            }
        }
    }
}
