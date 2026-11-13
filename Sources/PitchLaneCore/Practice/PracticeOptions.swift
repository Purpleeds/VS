import Foundation

/// How a play-through is practised: speed, a looped section, and no-fail.
public struct PracticeOptions: Codable, Hashable, Sendable {
    public static let speedRange: ClosedRange<Double> = 0.5...1
    /// Shortest loop (seconds of song) so a section can't flip faster than the audio latency.
    public static let minimumLoopLength = 3.0

    public var speed: Double
    public var loopStart: Double?
    public var loopEnd: Double?
    public var noFail: Bool

    public init(speed: Double = 1, loopStart: Double? = nil, loopEnd: Double? = nil, noFail: Bool = false) {
        self.speed = min(Self.speedRange.upperBound, max(Self.speedRange.lowerBound, speed))
        if let start = loopStart, let end = loopEnd, end - start >= Self.minimumLoopLength {
            self.loopStart = max(0, start)
            self.loopEnd = end
        } else {
            self.loopStart = nil
            self.loopEnd = nil
        }
        self.noFail = noFail
    }

    public static let normal = PracticeOptions()

    public var loop: ClosedRange<Double>? {
        guard let loopStart, let loopEnd else { return nil }
        return loopStart...loopEnd
    }

    /// Anything other than a plain full-speed run: such runs don't count toward personal bests.
    public var isPractice: Bool { speed < 0.999 || loop != nil || noFail }

    public var speedText: String { "\(Int((speed * 100).rounded()))%" }
}

/// Energy bar: good notes top it up, misses drain it; at zero the song is failed (unless no-fail).
public struct HealthMeter: Sendable, Equatable {
    public private(set) var value = 1.0
    public let enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    public static func delta(for rating: NoteRating) -> Double {
        switch rating {
        case .perfect: return 0.04
        case .great: return 0.03
        case .good: return 0.01
        case .meh: return -0.05
        case .miss: return -0.12
        }
    }

    public mutating func apply(_ rating: NoteRating) {
        guard enabled else { return }
        value = min(1, max(0, value + Self.delta(for: rating)))
    }

    public var isFailed: Bool { enabled && value <= 0 }

    public mutating func reset() {
        value = 1
    }
}
