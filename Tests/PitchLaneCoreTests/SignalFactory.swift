import Foundation
import PitchLaneCore

/// Deterministic SplitMix64 so noise tests are reproducible.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in (0, 1].
    mutating func uniform() -> Double {
        (Double(next() >> 11) + 1) / Double(1 << 53)
    }

    /// Standard normal (Box-Muller).
    mutating func gaussian() -> Double {
        let u1 = uniform()
        let u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

enum Waveform {
    case sine, sawtooth, square

    func value(atPhase phase: Double) -> Double {
        let p = phase - phase.rounded(.down)
        switch self {
        case .sine: return sin(2 * Double.pi * p)
        case .sawtooth: return 2 * p - 1
        case .square: return p < 0.5 ? 1 : -1
        }
    }
}

enum SignalFactory {
    /// Phase-accumulating oscillator whose pitch follows `midiAt(time)`.
    static func tone(
        _ waveform: Waveform = .sine,
        duration: Double,
        sampleRate: Double,
        amplitude: Double = 0.3,
        midiAt: (Double) -> Double
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / sampleRate
            samples[i] = Float(amplitude * waveform.value(atPhase: phase))
            phase += PitchMath.frequency(fromMIDI: midiAt(t)) / sampleRate
        }
        return samples
    }

    static func tone(
        _ waveform: Waveform = .sine,
        midi: Double,
        duration: Double,
        sampleRate: Double,
        amplitude: Double = 0.3
    ) -> [Float] {
        tone(waveform, duration: duration, sampleRate: sampleRate, amplitude: amplitude) { _ in midi }
    }

    static func sine(frequency: Double, duration: Double, sampleRate: Double, amplitude: Double = 0.3) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    static func whiteNoise(duration: Double, sampleRate: Double, sigma: Double, seed: UInt64 = 42) -> [Float] {
        var random = SeededRandom(seed: seed)
        return (0..<Int(duration * sampleRate)).map { _ in Float(sigma * random.gaussian()) }
    }

    /// Rumbly broadband noise, roughly like a fan or air conditioner.
    static func fanNoise(duration: Double, sampleRate: Double, amplitude: Double, seed: UInt64 = 7) -> [Float] {
        let white = whiteNoise(duration: duration, sampleRate: sampleRate, sigma: 1, seed: seed)
        var filter = Biquad.lowPass(sampleRate: sampleRate, cutoff: 300, q: 0.707)
        return white.map { x in Float(amplitude) * (3 * filter.process(x) + 0.1 * x) }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (energy / Double(samples.count)).squareRoot()
    }
}

/// Runs a signal through a fresh pipeline.
func analyze(
    _ signal: [Float],
    sampleRate: Double,
    configuration: PitchPipelineConfiguration = .init()
) -> [PitchFrame] {
    PitchPipeline(inputSampleRate: sampleRate, configuration: configuration).process(signal)
}

func cents(_ hz: Double, from midi: Double) -> Double {
    (PitchMath.midi(fromFrequency: hz) - midi) * 100
}
