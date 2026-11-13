import Foundation

public enum UnvoicedReason: String, Sendable, CaseIterable, Codable {
    /// Frame RMS below the noise gate.
    case belowNoiseGate
    /// No clear period (YIN confidence below threshold).
    case lowConfidence
    /// Clear period, but above the configured range (e.g. whistling).
    case outOfRange
    /// Sudden octave-sized jump not yet confirmed by later frames.
    case pendingJump
}

public struct PitchStabilizerConfiguration: Sendable, Equatable {
    public var noiseGateDBFS: Double
    public var minimumConfidence: Double
    public var medianLength: Int
    /// Jumps at least this large (semitones) from the current median need confirmation.
    public var jumpSemitones: Double
    /// Consecutive agreeing frames needed to accept such a jump.
    public var jumpConfirmationFrames: Int
    /// How close (semitones) the confirming frames must be to each other.
    public var jumpAgreementSemitones: Double
    /// Unvoiced frames in a row after which the history is cleared.
    public var resetAfterUnvoicedFrames: Int
    /// Hysteresis: while a note is already sounding, a frame this confident is still accepted if it stays within
    /// `holdSemitones` of the current median (keeps breathy singing from flickering). Starting a note still
    /// needs `minimumConfidence`.
    public var holdConfidence: Double
    public var holdSemitones: Double

    public init(
        noiseGateDBFS: Double = -50,
        minimumConfidence: Double = 0.85,
        medianLength: Int = 5,
        jumpSemitones: Double = 9,
        jumpConfirmationFrames: Int = 3,
        jumpAgreementSemitones: Double = 1.5,
        resetAfterUnvoicedFrames: Int = 3,
        holdConfidence: Double = 0.80,
        holdSemitones: Double = 1.0
    ) {
        self.noiseGateDBFS = noiseGateDBFS
        self.minimumConfidence = minimumConfidence
        self.medianLength = max(1, medianLength)
        self.jumpSemitones = jumpSemitones
        self.jumpConfirmationFrames = max(1, jumpConfirmationFrames)
        self.jumpAgreementSemitones = jumpAgreementSemitones
        self.resetAfterUnvoicedFrames = max(1, resetAfterUnvoicedFrames)
        self.holdConfidence = min(holdConfidence, minimumConfidence)
        self.holdSemitones = max(0, holdSemitones)
    }
}

public struct StabilizedPitch: Sendable, Equatable {
    /// Smoothed fractional MIDI note; nil = unvoiced (hide the cursor).
    public var midi: Double?
    public var unvoicedReason: UnvoicedReason?

    public init(midi: Double?, unvoicedReason: UnvoicedReason?) {
        self.midi = midi
        self.unvoicedReason = unvoicedReason
    }
}

/// Turns raw per-frame estimates into a steady pitch line. When unsure, it reports unvoiced.
public struct PitchStabilizer: Sendable {
    public let configuration: PitchStabilizerConfiguration
    private var history: [Double] = []
    private var pending: [Double] = []
    private var scratch: [Double] = []
    private var unvoicedRun = 0

    public init(configuration: PitchStabilizerConfiguration = .init()) {
        self.configuration = configuration
        history.reserveCapacity(configuration.medianLength)
        pending.reserveCapacity(configuration.jumpConfirmationFrames)
        scratch.reserveCapacity(configuration.medianLength)
    }

    public mutating func reset() {
        history.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        unvoicedRun = 0
    }

    public mutating func process(_ estimate: PitchEstimate) -> StabilizedPitch {
        if PitchMath.decibels(fromLinear: estimate.rms) < configuration.noiseGateDBFS {
            return unvoiced(.belowNoiseGate)
        }
        if estimate.isAboveRange {
            return unvoiced(.outOfRange)
        }
        guard let frequency = estimate.frequency, frequency > 0, frequency.isFinite else {
            return unvoiced(.lowConfidence)
        }
        let midi = PitchMath.midi(fromFrequency: frequency)
        if estimate.confidence < configuration.minimumConfidence {
            // Hysteresis: a slightly less confident frame continues the current note, never starts or moves one.
            guard estimate.confidence >= configuration.holdConfidence, !history.isEmpty,
                  abs(midi - median(of: history)) <= configuration.holdSemitones else {
                return unvoiced(.lowConfidence)
            }
        }
        unvoicedRun = 0

        if !history.isEmpty {
            let reference = median(of: history)
            if abs(midi - reference) >= configuration.jumpSemitones {
                if let last = pending.last, abs(midi - last) > configuration.jumpAgreementSemitones {
                    pending.removeAll(keepingCapacity: true)
                }
                pending.append(midi)
                guard pending.count >= configuration.jumpConfirmationFrames else {
                    return StabilizedPitch(midi: nil, unvoicedReason: .pendingJump)
                }
                history.removeAll(keepingCapacity: true)
                history.append(contentsOf: pending.suffix(configuration.medianLength))
                pending.removeAll(keepingCapacity: true)
                return StabilizedPitch(midi: median(of: history), unvoicedReason: nil)
            }
        }

        pending.removeAll(keepingCapacity: true)
        if history.count == configuration.medianLength {
            history.removeFirst()
        }
        history.append(midi)
        return StabilizedPitch(midi: median(of: history), unvoicedReason: nil)
    }

    private mutating func unvoiced(_ reason: UnvoicedReason) -> StabilizedPitch {
        unvoicedRun += 1
        pending.removeAll(keepingCapacity: true)
        if unvoicedRun >= configuration.resetAfterUnvoicedFrames {
            history.removeAll(keepingCapacity: true)
        }
        return StabilizedPitch(midi: nil, unvoicedReason: reason)
    }

    private mutating func median(of values: [Double]) -> Double {
        scratch.removeAll(keepingCapacity: true)
        scratch.append(contentsOf: values)
        scratch.sort()
        let n = scratch.count
        return n % 2 == 1 ? scratch[n / 2] : (scratch[n / 2 - 1] + scratch[n / 2]) / 2
    }
}
