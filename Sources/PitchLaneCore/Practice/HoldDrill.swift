import Foundation

public enum SteadinessRating: String, Sendable, Codable {
    case rockSteady
    case steady
    case wobbly
    case unsteady

    public init(score: Double) {
        switch score {
        case 90...: self = .rockSteady
        case 75...: self = .steady
        case 50...: self = .wobbly
        default: self = .unsteady
        }
    }

    public var displayName: String {
        switch self {
        case .rockSteady: return "Rock steady"
        case .steady: return "Steady"
        case .wobbly: return "Wobbly"
        case .unsteady: return "Unsteady"
        }
    }
}

public struct HoldDrillResult: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var time: Double
        /// Cents from the reference (target note, or the median of the hold); nil = unvoiced.
        public var cents: Double?

        public init(time: Double, cents: Double?) {
            self.time = time
            self.cents = cents
        }
    }

    /// 0...100.
    public var score: Double
    public var rating: SteadinessRating
    /// RMS deviation from the median pitch over the measured part of the hold (cents).
    public var wobbleCents: Double
    public var maxDeviationCents: Double
    /// Linear drift of the pitch over the measured part (cents per second).
    public var driftCentsPerSecond: Double
    /// Median pitch minus the target note, in cents (nil when singing free).
    public var offsetFromTargetCents: Double?
    public var voicedFraction: Double
    public var points: [Point]
}

/// One long note scored on steadiness: how much the pitch wobbles around its own centre over time.
///
/// Times are seconds from the start of the hold. The first `settle` seconds (finding the note) aren't scored.
public struct HoldDrill: Sendable {
    public let target: Int?
    public let duration: Double
    public let settle: Double
    public let octaveAgnostic: Bool

    private var samples: [(time: Double, midi: Double?)] = []
    private var lastTime = -Double.infinity

    public init(target: Int?, duration: Double = 8, settle: Double = 0.8, octaveAgnostic: Bool = true) {
        self.target = target
        self.duration = max(2, duration)
        self.settle = min(settle, self.duration / 2)
        self.octaveAgnostic = octaveAgnostic
    }

    public var isComplete: Bool { lastTime >= duration }
    public var elapsed: Double { max(0, lastTime) }

    public mutating func add(time: Double, midi: Double?) {
        guard time >= 0, time > lastTime, lastTime < duration else { return }
        lastTime = time
        samples.append((time, midi))
    }

    public func result() -> HoldDrillResult {
        let measured = samples.filter { $0.time >= settle && $0.time <= duration }
        let voiced = measured.compactMap { sample in sample.midi.map { (time: sample.time, midi: $0) } }
        let fraction = measured.isEmpty ? 0 : Double(voiced.count) / Double(measured.count)
        guard voiced.count >= 5 else {
            return HoldDrillResult(
                score: 0, rating: .unsteady, wobbleCents: 0, maxDeviationCents: 0, driftCentsPerSecond: 0,
                offsetFromTargetCents: nil, voicedFraction: fraction,
                points: samples.map { .init(time: $0.time, cents: nil) }
            )
        }
        // Fold into one octave of the first voiced note so an octave slip doesn't count as wobble.
        let anchor = voiced[0].midi
        func folded(_ m: Double) -> Double { octaveAgnostic ? PitchFolding.fold(m, toward: anchor) : m }
        let values = voiced.map { folded($0.midi) }
        let median = NoteHoldDetector.median(values)
        let deviations = values.map { ($0 - median) * 100 }
        let wobble = (deviations.reduce(0) { $0 + $1 * $1 } / Double(deviations.count)).squareRoot()
        let maxDeviation = deviations.map { abs($0) }.max() ?? 0

        let meanTime = voiced.map(\.time).reduce(0, +) / Double(voiced.count)
        var covariance = 0.0
        var variance = 0.0
        for (sample, deviation) in zip(voiced, deviations) {
            covariance += (sample.time - meanTime) * deviation
            variance += (sample.time - meanTime) * (sample.time - meanTime)
        }
        let drift = variance > 0 ? covariance / variance : 0

        // 100 at <= 3 cents of wobble, falling linearly to 0 at 35 cents; silence counts against it.
        let steadiness = max(0, min(100, 100 * (35 - max(3, wobble)) / 32))
        let score = steadiness * fraction
        var offset: Double?
        if let target {
            offset = PitchFolding.errorCents(sung: median, target: Double(target), octaveAgnostic: octaveAgnostic)
        }
        let reference = target.map(Double.init) ?? median
        let points = samples.map { sample -> HoldDrillResult.Point in
            guard let midi = sample.midi else { return .init(time: sample.time, cents: nil) }
            let cents = target != nil
                ? PitchFolding.errorCents(sung: midi, target: reference, octaveAgnostic: octaveAgnostic)
                : (folded(midi) - reference) * 100
            return .init(time: sample.time, cents: cents)
        }
        return HoldDrillResult(
            score: score,
            rating: SteadinessRating(score: score),
            wobbleCents: wobble,
            maxDeviationCents: maxDeviation,
            driftCentsPerSecond: drift,
            offsetFromTargetCents: offset,
            voicedFraction: fraction,
            points: points
        )
    }
}
