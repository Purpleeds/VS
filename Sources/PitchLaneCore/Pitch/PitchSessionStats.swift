import Foundation

/// One continuous sung/played stretch (short dropouts bridged).
public struct VoicedSegmentSummary: Sendable, Equatable {
    public var startTime: Double
    public var duration: Double
    public var frameCount: Int
    public var medianMIDI: Double
    public var minMIDI: Double
    public var maxMIDI: Double
    public var meanConfidence: Double

    public func description(accidentals: Accidentals) -> String {
        let median = NoteNaming.nearestNote(toMIDI: medianMIDI)
        let low = NoteNaming.name(forMIDINote: Int(minMIDI.rounded()), accidentals: accidentals)
        let high = NoteNaming.name(forMIDINote: Int(maxMIDI.rounded()), accidentals: accidentals)
        let name = NoteNaming.name(forMIDINote: median.note, accidentals: accidentals)
        return "Voiced \(fixed(duration, 2)) s at \(fixed(startTime, 2)) s: median \(name) \(signed(median.cents))c "
            + "(\(fixed(PitchMath.frequency(fromMIDI: medianMIDI), 1)) Hz), range \(low)..\(high) "
            + "(\(fixed((maxMIDI - minMIDI) * 100, 0))c), conf \(fixed(meanConfidence, 2))"
    }
}

/// Everything heard during one reporting interval.
public struct IntervalSummary: Sendable, Equatable {
    public var startTime: Double
    public var duration: Double
    public var frameCount: Int
    public var voicedCount: Int
    public var meanLevelDBFS: Double
    public var minLevelDBFS: Double
    public var maxLevelDBFS: Double
    public var meanConfidence: Double
    public var unvoicedCounts: [UnvoicedReason: Int]
    /// Voiced stretches shorter than the minimum segment duration (not logged individually).
    public var blipCount: Int

    public var voicedFraction: Double { frameCount > 0 ? Double(voicedCount) / Double(frameCount) : 0 }

    public var description: String {
        let reasons = UnvoicedReason.allCases
            .map { "\($0.rawValue) \(unvoicedCounts[$0, default: 0])" }
            .joined(separator: ", ")
        return "Interval \(fixed(duration, 1)) s: \(frameCount) frames, voiced \(fixed(voicedFraction * 100, 0))%, "
            + "level avg \(fixed(meanLevelDBFS, 0)) dBFS (min \(fixed(minLevelDBFS, 0)), max \(fixed(maxLevelDBFS, 0))), "
            + "conf avg \(fixed(meanConfidence, 2)), blips \(blipCount), unvoiced: \(reasons)"
    }
}

/// "%.Nf" formatting (numbers only; never pass strings through String(format:) on Linux).
func fixed(_ value: Double, _ digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}

/// Whole number with an explicit sign, e.g. "+3" / "-12".
func signed(_ value: Double) -> String {
    let rounded = Int(value.rounded())
    return rounded >= 0 ? "+\(rounded)" : "\(rounded)"
}

public enum PitchLogEvent: Sendable, Equatable {
    case segment(VoicedSegmentSummary)
    case interval(IntervalSummary)
}

/// Condenses the 100 frames/s stream into a few log lines: one per voiced segment and one per interval.
/// Only derived numbers, never audio.
public struct PitchSessionStats: Sendable {
    public let reportInterval: Double
    public let minimumSegmentDuration: Double
    public let maxGapFrames: Int
    public let frameInterval: Double

    // Interval accumulators.
    private var intervalStart: Double?
    private var frames = 0
    private var voiced = 0
    private var powerSum = 0.0
    private var minDB = Double.infinity
    private var maxDB = -Double.infinity
    private var confidenceSum = 0.0
    private var reasons: [UnvoicedReason: Int] = [:]
    private var blips = 0
    private var lastFrameTime = 0.0

    // Segment accumulators.
    private var segmentMIDI: [Double] = []
    private var segmentConfidence = 0.0
    private var segmentStart = 0.0
    private var segmentLast = 0.0
    private var gap = 0

    public init(
        reportInterval: Double = 5,
        minimumSegmentDuration: Double = 0.15,
        maxGapFrames: Int = 2,
        frameInterval: Double = 0.01
    ) {
        self.reportInterval = reportInterval
        self.minimumSegmentDuration = minimumSegmentDuration
        self.maxGapFrames = maxGapFrames
        self.frameInterval = frameInterval
    }

    public mutating func add(_ frame: PitchFrame) -> [PitchLogEvent] {
        var events: [PitchLogEvent] = []
        if let start = intervalStart, frame.time - start >= reportInterval {
            if let summary = closeInterval(endingAt: frame.time) {
                events.append(.interval(summary))
            }
        }
        if intervalStart == nil { intervalStart = frame.time }

        frames += 1
        lastFrameTime = frame.time
        powerSum += frame.rms * frame.rms
        minDB = min(minDB, frame.levelDBFS)
        maxDB = max(maxDB, frame.levelDBFS)
        confidenceSum += frame.confidence

        if let midi = frame.midi {
            voiced += 1
            if segmentMIDI.isEmpty { segmentStart = frame.time }
            segmentMIDI.append(midi)
            segmentConfidence += frame.confidence
            segmentLast = frame.time
            gap = 0
        } else {
            reasons[frame.unvoicedReason ?? .lowConfidence, default: 0] += 1
            if !segmentMIDI.isEmpty {
                gap += 1
                if gap > maxGapFrames, let segment = closeSegment() {
                    events.append(.segment(segment))
                }
            }
        }
        return events
    }

    /// Flush everything (call when capture stops).
    public mutating func finish() -> [PitchLogEvent] {
        var events: [PitchLogEvent] = []
        if let segment = closeSegment() { events.append(.segment(segment)) }
        if let summary = closeInterval(endingAt: lastFrameTime + frameInterval) {
            events.append(.interval(summary))
        }
        return events
    }

    private mutating func closeSegment() -> VoicedSegmentSummary? {
        defer {
            segmentMIDI.removeAll(keepingCapacity: true)
            segmentConfidence = 0
            gap = 0
        }
        guard !segmentMIDI.isEmpty else { return nil }
        let duration = segmentLast - segmentStart + frameInterval
        guard duration >= minimumSegmentDuration else {
            blips += 1
            return nil
        }
        let sorted = segmentMIDI.sorted()
        let n = sorted.count
        let median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        return VoicedSegmentSummary(
            startTime: segmentStart,
            duration: duration,
            frameCount: n,
            medianMIDI: median,
            minMIDI: sorted[0],
            maxMIDI: sorted[n - 1],
            meanConfidence: segmentConfidence / Double(n)
        )
    }

    private mutating func closeInterval(endingAt end: Double) -> IntervalSummary? {
        defer {
            intervalStart = nil
            frames = 0
            voiced = 0
            powerSum = 0
            minDB = .infinity
            maxDB = -.infinity
            confidenceSum = 0
            reasons = [:]
            blips = 0
        }
        guard let start = intervalStart, frames > 0 else { return nil }
        return IntervalSummary(
            startTime: start,
            duration: end - start,
            frameCount: frames,
            voicedCount: voiced,
            meanLevelDBFS: PitchMath.decibels(fromLinear: (powerSum / Double(frames)).squareRoot()),
            minLevelDBFS: minDB,
            maxLevelDBFS: maxDB,
            meanConfidence: confidenceSum / Double(frames),
            unvoicedCounts: reasons,
            blipCount: blips
        )
    }
}
