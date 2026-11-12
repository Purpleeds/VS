import Foundation

/// The last few seconds of pitch, for the scrolling graph.
public struct PitchHistory: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var time: Double
        /// nil = unvoiced (a gap in the line).
        public var midi: Double?

        public init(time: Double, midi: Double?) {
            self.time = time
            self.midi = midi
        }
    }

    public let duration: Double
    public private(set) var points: [Point] = []

    public init(duration: Double = 5) {
        self.duration = duration
        points.reserveCapacity(Int(duration * 110))
    }

    public var latestTime: Double? { points.last?.time }

    public mutating func append(time: Double, midi: Double?) {
        if let last = points.last, time < last.time {
            // Stream restarted: start over rather than draw backwards.
            points.removeAll(keepingCapacity: true)
        }
        points.append(Point(time: time, midi: midi))
        let cutoff = time - duration
        if let first = points.first, first.time < cutoff,
           let keepFrom = points.firstIndex(where: { $0.time >= cutoff }) {
            points.removeFirst(keepFrom)
        }
    }

    public mutating func append(_ frame: PitchFrame) {
        append(time: frame.time, midi: frame.midi)
    }

    public mutating func removeAll() {
        points.removeAll(keepingCapacity: true)
    }

    /// Lowest...highest voiced MIDI value currently held.
    public var voicedRange: ClosedRange<Double>? {
        var low = Double.infinity
        var high = -Double.infinity
        for point in points {
            guard let midi = point.midi else { continue }
            low = min(low, midi)
            high = max(high, midi)
        }
        return low <= high ? low...high : nil
    }
}

/// Vertical range (in MIDI notes) for the pitch graph. Sticky, so the axis doesn't twitch every frame:
/// it only changes when the line nears an edge or the range is far bigger than needed.
public enum PitchGraphScale {
    public static func range(
        for history: PitchHistory,
        current: ClosedRange<Double>?,
        bounds: ClosedRange<Double>,
        minimumSpan: Double = 12,
        edgeMargin: Double = 1,
        padding: Double = 3
    ) -> ClosedRange<Double> {
        guard let voiced = history.voicedRange else {
            return current ?? centered(on: (bounds.lowerBound + bounds.upperBound) / 2, span: minimumSpan, bounds: bounds)
        }
        let wanted = max(minimumSpan, (voiced.upperBound - voiced.lowerBound) + 2 * padding)
        if let current {
            let span = current.upperBound - current.lowerBound
            let neededLow = max(bounds.lowerBound, voiced.lowerBound - edgeMargin)
            let neededHigh = min(bounds.upperBound, voiced.upperBound + edgeMargin)
            let fits = current.lowerBound <= neededLow && current.upperBound >= neededHigh
            if fits && span <= wanted * 1.5 {
                return current
            }
        }
        return centered(on: (voiced.lowerBound + voiced.upperBound) / 2, span: wanted, bounds: bounds)
    }

    private static func centered(on center: Double, span: Double, bounds: ClosedRange<Double>) -> ClosedRange<Double> {
        let boundsSpan = bounds.upperBound - bounds.lowerBound
        if span >= boundsSpan { return bounds }
        var low = center - span / 2
        var high = center + span / 2
        if low < bounds.lowerBound {
            low = bounds.lowerBound
            high = low + span
        }
        if high > bounds.upperBound {
            high = bounds.upperBound
            low = high - span
        }
        return low...high
    }
}
