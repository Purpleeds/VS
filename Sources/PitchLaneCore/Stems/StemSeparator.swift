import Foundation

/// Splits a stereo mix into "voice" and "music" by centre extraction: lead vocals are almost always mixed in the
/// middle (same level and phase in both channels), most instruments are spread left/right.
///
/// Short-time Fourier transform (2048-point, 75 % overlap, √Hann windows). Both channels go through one complex FFT
/// (left + i·right). For each bin the mask is `max(0, 2·Re(L·R̄) / (|L|²+|R|²))^sharpness` — 1 for a centred,
/// in-phase sound, 0 for one-sided or out-of-phase sound — limited to the vocal band and smoothed over time.
/// Voice = masked spectrum; music = input − voice, so the two always add back up to the original exactly.
///
/// With a `VocalGuide` (from a first, plain pass) the mask also follows the singer: outside sung phrases it is turned
/// right down (`offVoiceGain`), and while the singer's pitch is known only that pitch's harmonics keep their mask
/// (between them `harmonicFloor`), so centred keys, bass, guitar and drums go back to the music instead of sitting in
/// the voice. Consonants and unclear frames inside a phrase keep the plain centre mask.
/// Still an approximation (reverb goes to the music, a centred instrument playing the singer's own note stays with
/// the voice), not studio stems.
public final class StemSeparator {
    public struct Configuration: Sendable, Equatable {
        public var frameSize = 2048
        public var lowCut = 150.0
        public var highCut = 7_000.0
        public var sharpness: Float = 3
        /// 0 = no smoothing; closer to 1 = steadier mask (less "watery" artefacts, softer onsets).
        public var smoothing: Float = 0.5
        /// Guided only: voice mask outside sung phrases (0.1 = -20 dB).
        public var offVoiceGain: Float = 0.1
        /// Guided only: voice mask between the singer's harmonics (0.25 = -12 dB).
        public var harmonicFloor: Float = 0.25
        /// Guided only: harmonics are followed up to here; above it the centre mask alone decides.
        public var harmonicMaxHz = 5_000.0

        public init() {}
    }

    public struct Output: Sendable, Equatable {
        public var vocalsLeft: [Float] = []
        public var vocalsRight: [Float] = []
        public var musicLeft: [Float] = []
        public var musicRight: [Float] = []

        public init() {}

        public var count: Int { vocalsLeft.count }

        mutating func reserve(_ n: Int) {
            vocalsLeft.reserveCapacity(n)
            vocalsRight.reserveCapacity(n)
            musicLeft.reserveCapacity(n)
            musicRight.reserveCapacity(n)
        }
    }

    public let configuration: Configuration
    public let sampleRate: Double
    public let guide: VocalGuide?
    private let n: Int
    private let hop: Int
    private let fft: FFT
    private let window: [Float]
    private let band: [Float]
    private var smoothedMask: [Float]
    private var re: [Float]
    private var im: [Float]
    private var pendingLeft: [Float]
    private var pendingRight: [Float]
    private var olaLeft: [Float]
    private var olaRight: [Float]
    private var toDrop: Int
    private var inputCount = 0
    private var emitted = 0
    private var finished = false
    private var midEnergy = 0.0
    private var sideEnergy = 0.0
    private var frameIndex = 0
    private var singCursor = 0
    private var pitchCursor = 0
    private var harmonicGains: [Float]
    private let binHz: Double

    public init(sampleRate: Double, configuration: Configuration = Configuration(), guide: VocalGuide? = nil) {
        self.configuration = configuration
        self.sampleRate = max(1, sampleRate)
        self.guide = guide
        let transform = FFT(size: max(256, configuration.frameSize))
        let size = transform.size
        fft = transform
        n = size
        hop = size / 4
        window = (0..<size).map { Float(sin(Double.pi * Double($0) / Double(size))) } // √(periodic Hann)
        let low = configuration.lowCut, high = configuration.highCut
        let binHz = max(1, sampleRate) / Double(size)
        self.binHz = binHz
        harmonicGains = [Float](repeating: 1, count: size / 2 + 1)
        band = (0...(size / 2)).map { k in
            let f = Double(k) * binHz
            if f < low * 0.7 || f > high * 1.5 { return 0 }
            if f < low { return Float((f - low * 0.7) / (low * 0.3)) }
            if f > high { return Float(1 - (f - high) / (high * 0.5)) }
            return 1
        }
        smoothedMask = [Float](repeating: 0, count: size / 2 + 1)
        re = [Float](repeating: 0, count: size)
        im = [Float](repeating: 0, count: size)
        // Pad the front so the first real sample is covered by a full set of frames; drop that much output later.
        pendingLeft = [Float](repeating: 0, count: size - size / 4)
        pendingRight = [Float](repeating: 0, count: size - size / 4)
        olaLeft = [Float](repeating: 0, count: size)
        olaRight = [Float](repeating: 0, count: size)
        toDrop = size - size / 4
    }

    /// Samples of delay inside the separator (output catches up in `finish()`).
    public var latency: Int { n - hop }

    /// Both channels carry (nearly) the same signal, so there is nothing to separate.
    public var isEffectivelyMono: Bool { sideEnergy <= 0.002 * max(midEnergy, 1e-12) }

    /// Feeds stereo samples (extra samples in the longer channel are ignored) and returns what is ready.
    public func process(left: [Float], right: [Float]) -> Output {
        guard !finished else { return Output() }
        let count = min(left.count, right.count)
        for i in 0..<count {
            let l = left[i].isFinite ? left[i] : 0
            let r = right[i].isFinite ? right[i] : 0
            pendingLeft.append(l)
            pendingRight.append(r)
            let mid = Double(l + r) * 0.5, side = Double(l - r) * 0.5
            midEnergy += mid * mid
            sideEnergy += side * side
        }
        inputCount += count
        return drain()
    }

    /// Flushes the tail. The total output length equals the total input length.
    public func finish() -> Output {
        guard !finished else { return Output() }
        pendingLeft.append(contentsOf: [Float](repeating: 0, count: n))
        pendingRight.append(contentsOf: [Float](repeating: 0, count: n))
        let output = drain()
        finished = true
        return output
    }

    private func drain() -> Output {
        var output = Output()
        output.reserve(max(0, pendingLeft.count - n + hop))
        var consumed = 0
        while pendingLeft.count - consumed >= n, emitted < inputCount {
            processFrame(at: consumed, into: &output)
            consumed += hop
        }
        if consumed > 0 {
            pendingLeft.removeFirst(consumed)
            pendingRight.removeFirst(consumed)
        }
        return output
    }

    /// What the guide says about the frame starting `frameIndex` hops in: 0 = no guide, 1 = nobody singing,
    /// 2 = singing at a known pitch (`harmonicGains` filled), 3 = singing, pitch unknown.
    private func guideMode() -> Int {
        defer { frameIndex += 1 }
        guard let guide else { return 0 }
        // Centre of this frame on the input's timeline (the first frame starts `latency` samples before it).
        let time = (Double(frameIndex * hop + n / 2) - Double(n - hop)) / sampleRate
        guard guide.isSinging(at: time, cursor: &singCursor) else { return 1 }
        guard let f0 = VoiceFocus.pitch(at: time, in: guide.pitch, cursor: &pitchCursor), f0 > binHz * 2 else { return 3 }
        var focus = VoiceFocus.Configuration()
        focus.floor = configuration.harmonicFloor
        focus.maxHarmonicHz = configuration.harmonicMaxHz
        VoiceFocus.fillGains(&harmonicGains, f0: f0, binHz: binHz, configuration: focus)
        return 2
    }

    private func processFrame(at offset: Int, into output: inout Output) {
        let half = n / 2
        let sharpness = configuration.sharpness
        let smoothing = configuration.smoothing
        let mode = guideMode()
        let offVoice = configuration.offVoiceGain
        re.withUnsafeMutableBufferPointer { reBuf in
            im.withUnsafeMutableBufferPointer { imBuf in
                guard let rp = reBuf.baseAddress, let ip = imBuf.baseAddress else { return }
                for i in 0..<n {
                    rp[i] = pendingLeft[offset + i] * window[i]
                    ip[i] = pendingRight[offset + i] * window[i]
                }
                fft.forward(real: rp, imag: ip)
                for k in 0...half {
                    let m = (n - k) % n
                    let ar = rp[k], ai = ip[k], br = rp[m], bi = ip[m]
                    // Left and right spectra from the packed transform.
                    let lr = (ar + br) * 0.5, li = (ai - bi) * 0.5
                    let rr = (ai + bi) * 0.5, ri = (br - ar) * 0.5
                    let power = lr * lr + li * li + rr * rr + ri * ri
                    var mask: Float = 0
                    if power > 1e-12, band[k] > 0 {
                        let similarity = max(0, 2 * (lr * rr + li * ri) / power)
                        mask = pow(similarity, sharpness) * band[k]
                    }
                    if mode == 1 {
                        mask *= offVoice
                    } else if mode == 2 {
                        mask *= harmonicGains[k]
                    }
                    let smoothed = smoothing * smoothedMask[k] + (1 - smoothing) * mask
                    smoothedMask[k] = smoothed
                    rp[k] = ar * smoothed
                    ip[k] = ai * smoothed
                    if m != k {
                        rp[m] = br * smoothed
                        ip[m] = bi * smoothed
                    }
                }
                fft.inverse(real: rp, imag: ip)
                // Overlap-add (√Hann² = Hann sums to 2 at 75 % overlap).
                for i in 0..<n {
                    olaLeft[i] += rp[i] * window[i] * 0.5
                    olaRight[i] += ip[i] * window[i] * 0.5
                }
            }
        }
        // The first hop of the accumulator is complete: emit it (after the start-up padding is dropped).
        for i in 0..<hop {
            if toDrop > 0 {
                toDrop -= 1
                continue
            }
            guard emitted < inputCount else { break }
            let vl = olaLeft[i], vr = olaRight[i]
            output.vocalsLeft.append(vl)
            output.vocalsRight.append(vr)
            output.musicLeft.append(pendingLeft[offset + i] - vl)
            output.musicRight.append(pendingRight[offset + i] - vr)
            emitted += 1
        }
        olaLeft.removeFirst(hop)
        olaLeft.append(contentsOf: repeatElement(0, count: hop))
        olaRight.removeFirst(hop)
        olaRight.append(contentsOf: repeatElement(0, count: hop))
    }
}
