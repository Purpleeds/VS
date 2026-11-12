import Foundation

/// Kind of audio output route; latency is calibrated per kind.
public enum AudioRouteKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case speaker
    case wired
    case bluetooth
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .speaker: return "Speaker"
        case .wired: return "Wired headphones"
        case .bluetooth: return "Bluetooth"
        case .other: return "Other output"
        }
    }

    /// Classifies `AVAudioSession.Port` raw values of the current outputs (e.g. "Speaker", "Headphones",
    /// "BluetoothA2DPOutput"). Bluetooth wins over everything, then wired, then the built-in speaker.
    public static func classify(outputPortTypes: [String]) -> AudioRouteKind {
        let types = Set(outputPortTypes)
        if types.contains(where: { $0.hasPrefix("Bluetooth") }) { return .bluetooth }
        if !types.isDisjoint(with: ["Headphones", "LineOut", "USBAudio"]) { return .wired }
        if !types.isDisjoint(with: ["Speaker", "Receiver"]) { return .speaker }
        return .other
    }
}

/// Calibration for one route kind. `correctionMs` is subtracted from mapped pitch-frame times.
public struct RouteLatency: Codable, Sendable, Equatable {
    /// Measured residual offset from the calibration screen (nil = never calibrated).
    public var calibrationMs: Double?
    /// Manual fine-tune on top.
    public var nudgeMs: Double
    public var calibratedAt: Date?

    public init(calibrationMs: Double? = nil, nudgeMs: Double = 0, calibratedAt: Date? = nil) {
        self.calibrationMs = calibrationMs
        self.nudgeMs = nudgeMs
        self.calibratedAt = calibratedAt
    }

    public var correctionMs: Double { (calibrationMs ?? 0) + nudgeMs }
    public var isCalibrated: Bool { calibrationMs != nil }
}

/// Per-route calibrations, persisted as JSON.
public struct LatencyProfiles: Codable, Sendable, Equatable {
    public private(set) var routes: [AudioRouteKind: RouteLatency] = [:]

    public init() {}

    public subscript(route: AudioRouteKind) -> RouteLatency {
        routes[route] ?? RouteLatency()
    }

    public mutating func setCalibration(_ milliseconds: Double, for route: AudioRouteKind, at date: Date = Date()) {
        var entry = self[route]
        entry.calibrationMs = milliseconds
        entry.calibratedAt = date
        routes[route] = entry
    }

    public mutating func setNudge(_ milliseconds: Double, for route: AudioRouteKind) {
        var entry = self[route]
        entry.nudgeMs = max(-300, min(300, milliseconds))
        routes[route] = entry
    }

    public mutating func reset(_ route: AudioRouteKind) {
        routes[route] = nil
    }
}

/// Everything needed to put a sung frame on the song clock, in seconds.
public struct LatencyEstimate: Sendable, Equatable {
    public var route: AudioRouteKind
    /// From `AVAudioSession.inputLatency`.
    public var input: Double
    /// From `AVAudioSession.outputLatency`.
    public var output: Double
    /// Per-route calibration + nudge.
    public var correction: Double

    public init(route: AudioRouteKind, input: Double, output: Double, correction: Double) {
        self.route = route
        self.input = input
        self.output = output
        self.correction = correction
    }

    public static let zero = LatencyEstimate(route: .other, input: 0, output: 0, correction: 0)
}

/// One (sample time, host time) pair from the output render callback. The output sample timeline is the
/// master clock; host time is only used to interpolate between callbacks and to talk to other APIs.
public struct OutputClockAnchor: Sendable, Equatable {
    public var sampleTime: Double
    public var hostSeconds: Double
    public var sampleRate: Double

    public init(sampleTime: Double, hostSeconds: Double, sampleRate: Double) {
        self.sampleTime = sampleTime
        self.hostSeconds = hostSeconds
        self.sampleRate = sampleRate
    }

    /// Output-render seconds at a host time.
    public func renderSeconds(atHost host: Double) -> Double {
        sampleTime / sampleRate + (host - hostSeconds)
    }

    /// Host time at which output-render seconds `render` is rendered.
    public func hostSeconds(forRender render: Double) -> Double {
        hostSeconds + (render - sampleTime / sampleRate)
    }
}

public struct CalibrationResult: Sendable, Equatable {
    /// Median of (detected onset - beep), positive = sung/clapped sound lands late on the song clock.
    public var offsetMs: Double
    public var matchedBeats: Int
    public var totalBeats: Int
    /// Median absolute deviation of the per-beat offsets.
    public var spreadMs: Double
    public var perBeatMs: [Double]

    /// Enough beats matched and they agree.
    public var isReliable: Bool {
        matchedBeats * 4 >= totalBeats * 3 && spreadMs <= 35
    }
}

/// Finds when the player's clap / "ta" landed for each beep and returns the typical offset.
public enum LatencyCalibrator {
    public struct Level: Sendable, Equatable {
        public var time: Double
        public var dBFS: Double

        public init(time: Double, dBFS: Double) {
            self.time = time
            self.dBFS = dBFS
        }
    }

    /// `count` beeps every `interval` seconds starting at `start`.
    public static func beepTimes(count: Int, interval: Double, start: Double = 0) -> [Double] {
        (0..<max(0, count)).map { start + Double($0) * interval }
    }

    /// Onset bias for centred analysis windows: a sudden sound first shows up in the frame whose window's
    /// leading edge reaches it, i.e. on average half a window minus half a hop before the frame centre.
    public static func onsetBias(windowDuration: Double, hop: Double) -> Double {
        windowDuration / 2 - hop / 2
    }

    /// `levels` must be in time order (song time, centred frames). Each beep gets the first rising crossing of
    /// max(local floor + 12 dB, -45 dBFS) within [-0.15, +0.45] s; returns nil when nothing matched.
    public static func estimate(beeps: [Double], levels: [Level], onsetBias: Double) -> CalibrationResult? {
        guard !beeps.isEmpty, levels.count > 2 else { return nil }
        var offsets: [Double] = []
        for beep in beeps {
            let before = levels.filter { $0.time >= beep - 0.35 && $0.time < beep - 0.12 }.map(\.dBFS).sorted()
            let floor = before.isEmpty ? -90 : before[before.count / 2]
            let threshold = max(floor + 12, -45)
            guard let start = levels.firstIndex(where: { $0.time >= beep - 0.15 }) else { continue }
            var index = max(1, start)
            while index < levels.count, levels[index].time <= beep + 0.45 {
                if levels[index].dBFS >= threshold, levels[index - 1].dBFS < threshold {
                    offsets.append(levels[index].time + onsetBias - beep)
                    break
                }
                index += 1
            }
        }
        guard !offsets.isEmpty else { return nil }
        let median = Self.median(offsets)
        let spread = Self.median(offsets.map { abs($0 - median) })
        return CalibrationResult(
            offsetMs: median * 1_000,
            matchedBeats: offsets.count,
            totalBeats: beeps.count,
            spreadMs: spread * 1_000,
            perBeatMs: offsets.map { $0 * 1_000 }
        )
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
