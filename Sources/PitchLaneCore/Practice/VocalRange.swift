import Foundation

/// The singer's comfortable range as MIDI notes.
public struct VocalRange: Codable, Sendable, Equatable, Hashable {
    public var low: Int
    public var high: Int

    public init(low: Int, high: Int) {
        self.low = min(low, high)
        self.high = max(low, high)
    }

    public var span: Int { high - low }
    public var closedRange: ClosedRange<Int> { low...high }

    public func contains(_ pitch: Int) -> Bool { pitch >= low && pitch <= high }

    /// e.g. "C3–G4".
    public func text(accidentals: Accidentals) -> String {
        "\(NoteNaming.name(forMIDINote: low, accidentals: accidentals))–\(NoteNaming.name(forMIDINote: high, accidentals: accidentals))"
    }

    /// e.g. "1 octave + 7 semitones" / "2 octaves".
    public var spanText: String {
        let octaves = span / 12
        let rest = span % 12
        var parts: [String] = []
        if octaves > 0 { parts.append("\(octaves) octave\(octaves == 1 ? "" : "s")") }
        if rest > 0 || parts.isEmpty { parts.append("\(rest) semitone\(rest == 1 ? "" : "s")") }
        return parts.joined(separator: " + ")
    }
}

/// Locks in a note once it has been held steadily for `holdDuration` seconds.
///
/// Feed it stabilised frames in time order. A run continues while voiced frames stay within `tolerance`
/// semitones of the run's median; a gap longer than `maxGap` or a bigger change starts a new run.
public struct NoteHoldDetector: Sendable {
    public let holdDuration: Double
    public let tolerance: Double
    public let maxGap: Double

    private var values: [Double] = []
    private var runStart: Double?
    private var lastVoiced = -Double.infinity

    public init(holdDuration: Double = 1, tolerance: Double = 0.7, maxGap: Double = 0.08) {
        self.holdDuration = holdDuration
        self.tolerance = tolerance
        self.maxGap = maxGap
    }

    /// 0...1 progress of the current run.
    public private(set) var progress = 0.0
    /// Median of the current run (the note being held), nil when no run.
    public var current: Double? { values.isEmpty ? nil : Self.median(values) }

    public mutating func reset() {
        values.removeAll(keepingCapacity: true)
        runStart = nil
        progress = 0
        lastVoiced = -.infinity
    }

    /// Returns the held note (median MIDI) the moment the hold completes; the detector then resets.
    public mutating func add(time: Double, midi: Double?) -> Double? {
        guard let midi else {
            if time - lastVoiced > maxGap { reset() }
            return nil
        }
        lastVoiced = time
        if let reference = current, abs(midi - reference) > tolerance {
            values.removeAll(keepingCapacity: true)
            runStart = nil
        }
        if runStart == nil { runStart = time }
        values.append(midi)
        progress = min(1, (time - (runStart ?? time)) / holdDuration)
        if progress >= 1, let held = current {
            reset()
            return held
        }
        return nil
    }

    static func median(_ input: [Double]) -> Double {
        let sorted = input.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}

public enum RangeTestStage: Sendable, Equatable {
    case low
    /// Waiting for the singer to stop before asking for the highest note.
    case release
    case high
    case done(VocalRange)
}

public enum RangeTestEvent: Sendable, Equatable {
    case lockedLow(Int)
    case lockedHigh(Int)
    /// The "highest" note wasn't at least `minimumSpan` semitones above the lowest.
    case highTooLow(sung: Int, low: Int)
    case finished(VocalRange)
}

/// "Sing your lowest comfortable note, then your highest; hold each for a second."
public struct RangeTestFlow: Sendable {
    public static let minimumSpan = 5
    /// Silence needed between the two notes.
    public static let releaseDuration = 0.6

    public private(set) var stage: RangeTestStage = .low
    public private(set) var low: Int?
    public private(set) var high: Int?
    public private(set) var currentMIDI: Double?
    public var progress: Double { detector.progress }

    private var detector = NoteHoldDetector()
    private var silentSince: Double?

    public init() {}

    public mutating func restart() {
        self = RangeTestFlow()
    }

    /// Redo only the high note (keeps the low).
    public mutating func redoHigh() {
        guard let low else { return restart() }
        let keep = low
        self = RangeTestFlow()
        self.low = keep
        stage = .high
    }

    @discardableResult
    public mutating func add(time: Double, midi: Double?) -> RangeTestEvent? {
        currentMIDI = midi
        switch stage {
        case .low:
            guard let held = detector.add(time: time, midi: midi) else { return nil }
            let note = Int(held.rounded())
            low = note
            stage = .release
            silentSince = nil
            return .lockedLow(note)

        case .release:
            if midi == nil {
                if silentSince == nil { silentSince = time }
                if time - (silentSince ?? time) >= Self.releaseDuration {
                    stage = .high
                    detector.reset()
                }
            } else {
                silentSince = nil
            }
            return nil

        case .high:
            guard let held = detector.add(time: time, midi: midi) else { return nil }
            let note = Int(held.rounded())
            guard let low, note >= low + Self.minimumSpan else {
                return .highTooLow(sung: note, low: low ?? note)
            }
            high = note
            let range = VocalRange(low: low, high: note)
            stage = .done(range)
            return .finished(range)

        case .done:
            return nil
        }
    }
}
