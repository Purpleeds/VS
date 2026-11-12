import Foundation

/// Fast lookup of the notes overlapping a time span (notes are sorted by start).
public struct NoteIndex: Sendable {
    private let starts: [Double]
    private let ends: [Double]
    private let maxDuration: Double

    public init(song: Song) {
        starts = song.notes.map(\.start)
        ends = song.notes.map(\.end)
        maxDuration = song.notes.map(\.duration).max() ?? 0
    }

    /// Indices of notes that overlap [from, to].
    public func indices(overlapping from: Double, _ to: Double) -> [Int] {
        guard !starts.isEmpty, from <= to else { return [] }
        let lower = firstIndex { $0 >= from - maxDuration }
        let upper = firstIndex { $0 > to }
        guard lower < upper else { return [] }
        return (lower..<upper).filter { ends[$0] >= from }
    }

    /// Binary search: first index whose start satisfies `predicate` (which must be monotonic).
    private func firstIndex(where predicate: (Double) -> Bool) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(starts[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

/// Vertical pitch window of the lane.
///
/// Fits the song's range plus `margin` semitones (at least `minimumSpan`). Songs wider than `maximumSpan`
/// get a fixed `maximumSpan` window that pans to the notes near the playhead.
public struct LaneViewport: Sendable {
    public let fullRange: ClosedRange<Double>
    public let windowSpan: Double
    public let pans: Bool
    public let lookBehind: Double
    public let lookAhead: Double
    private let index: NoteIndex
    private let pitches: [Double]

    public init(
        song: Song,
        margin: Double = 3,
        minimumSpan: Double = 12,
        maximumSpan: Double = 26,
        lookBehind: Double = 1,
        lookAhead: Double = 4
    ) {
        let all = song.notes.map { Double($0.pitch) }
        let low = (all.min() ?? 60) - margin
        let high = (all.max() ?? 60) + margin
        var span = high - low
        var lower = low
        if span < minimumSpan {
            lower -= (minimumSpan - span) / 2
            span = minimumSpan
        }
        fullRange = lower...(lower + span)
        pans = span > maximumSpan
        windowSpan = pans ? maximumSpan : span
        self.lookBehind = lookBehind
        self.lookAhead = lookAhead
        index = NoteIndex(song: song)
        pitches = all
    }

    /// Where the window wants to be centred at `songTime` (before smoothing).
    public func targetCenter(at songTime: Double) -> Double {
        let fullCenter = (fullRange.lowerBound + fullRange.upperBound) / 2
        guard pans else { return fullCenter }
        let nearby = index.indices(overlapping: songTime - lookBehind, songTime + lookAhead)
        let center: Double
        if nearby.isEmpty {
            // Between phrases: aim at the next note (or the last one).
            let upcoming = index.indices(overlapping: songTime, songTime + 3_600).first
            let anchor = upcoming ?? pitches.indices.last
            center = anchor.map { pitches[$0] } ?? fullCenter
        } else {
            let values = nearby.map { pitches[$0] }
            center = ((values.min() ?? fullCenter) + (values.max() ?? fullCenter)) / 2
        }
        return clamp(center)
    }

    public func range(center: Double) -> ClosedRange<Double> {
        let c = clamp(center)
        return (c - windowSpan / 2)...(c + windowSpan / 2)
    }

    private func clamp(_ center: Double) -> Double {
        let half = windowSpan / 2
        let low = fullRange.lowerBound + half
        let high = fullRange.upperBound - half
        guard low <= high else { return (fullRange.lowerBound + fullRange.upperBound) / 2 }
        return min(high, max(low, center))
    }
}

/// Exponential smoothing of the window centre, by elapsed time (frame-rate independent).
public struct ViewportSmoother: Sendable, Equatable {
    public private(set) var value: Double?
    public let timeConstant: Double

    public init(timeConstant: Double = 0.6) {
        self.timeConstant = timeConstant
    }

    @discardableResult
    public mutating func update(target: Double, dt: Double) -> Double {
        guard let current = value, dt.isFinite else {
            value = target
            return target
        }
        let alpha = 1 - exp(-max(0, dt) / timeConstant)
        let next = current + (target - current) * alpha
        value = next
        return next
    }

    public mutating func reset() {
        value = nil
    }
}
