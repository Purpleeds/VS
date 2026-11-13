import Foundation

/// The single master clock for a play-through: maps host time (seconds, e.g. `CACurrentMediaTime()`) to song time.
///
/// `start` makes song time run from `-leadIn * rate`, so notes scroll in during a countdown of `leadIn` real
/// seconds. `pause` freezes it. `resume` keeps it frozen for `resumeDelay` seconds (a 3-2-1 countdown), then lets it
/// run again. `rate` is the practice speed (0.5 = half speed): song time advances `rate` song-seconds per second.
/// `seek` jumps the song position (loops); times before the jump still map to the old position.
public struct GameClock: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case notStarted
        case countdown
        case playing
        case paused
        case finished
    }

    public let leadIn: Double
    public let resumeDelay: Double
    public let rate: Double
    /// Song time at which the play-through is over (last note end + tail).
    public let endTime: Double

    private var anchorHost: Double?
    private var anchorSong = 0.0
    /// Mapping in force before the last `seek`, valid for host times before `switchHost`.
    private var previousHost: Double?
    private var previousSong = 0.0
    private var switchHost = -Double.infinity
    public private(set) var isPaused = false

    public init(songDuration: Double, leadIn: Double = 3, resumeDelay: Double = 3, tail: Double = 1.5, rate: Double = 1) {
        self.leadIn = leadIn
        self.resumeDelay = resumeDelay
        self.rate = max(0.1, min(2, rate))
        self.endTime = songDuration + tail
    }

    public var isStarted: Bool { anchorHost != nil }

    /// Time base value from which song time runs (`+infinity` while paused), and the song time it starts from.
    /// Used to hand the timeline to the audio render thread (which also needs `rate`).
    public var anchor: (time: Double, songTime: Double)? {
        guard let anchorHost else { return nil }
        return (isPaused ? .infinity : anchorHost, anchorSong)
    }

    public mutating func start(at host: Double) {
        anchorHost = host
        anchorSong = -leadIn * rate
        previousHost = nil
        switchHost = -.infinity
        isPaused = false
    }

    public func songTime(at host: Double) -> Double {
        guard let anchorHost else { return -leadIn * rate }
        if let previousHost, host < switchHost {
            return previousSong + max(0, host - previousHost) * rate
        }
        if isPaused || host < anchorHost { return anchorSong }
        return anchorSong + (host - anchorHost) * rate
    }

    public mutating func pause(at host: Double) {
        guard isStarted, !isPaused else { return }
        anchorSong = songTime(at: host)
        previousHost = nil
        isPaused = true
    }

    public mutating func resume(at host: Double) {
        guard isStarted, isPaused else { return }
        anchorHost = host + resumeDelay
        isPaused = false
    }

    /// Jumps to song time `target` starting at host time `host` (while running). Earlier host times keep their
    /// old song time, so a display that lags the audio doesn't skip ahead.
    public mutating func seek(toSongTime target: Double, at host: Double) {
        guard let current = anchorHost else { return }
        if isPaused {
            anchorSong = target
            return
        }
        previousHost = current
        previousSong = anchorSong
        switchHost = host
        anchorHost = host
        anchorSong = target
    }

    /// True while song time is actually moving (started, not paused, not in a resume countdown).
    /// Pitch frames are only scored while this holds.
    public func isAdvancing(at host: Double) -> Bool {
        guard let anchorHost, !isPaused else { return false }
        if previousHost != nil, host < switchHost { return true }
        return host >= anchorHost
    }

    public func phase(at host: Double) -> Phase {
        guard let anchorHost else { return .notStarted }
        if isPaused { return .paused }
        let t = songTime(at: host)
        if t >= endTime { return .finished }
        if t < 0 || (host < anchorHost && previousHost == nil) { return .countdown }
        return .playing
    }

    /// 3, 2, 1 during the start or resume countdown (real seconds), otherwise nil.
    public func countdown(at host: Double) -> Int? {
        guard let anchorHost, !isPaused else { return nil }
        if host < anchorHost, previousHost == nil {
            return max(1, Int((anchorHost - host).rounded(.up)))
        }
        let t = songTime(at: host)
        return t < 0 ? max(1, Int((-t / rate).rounded(.up))) : nil
    }
}

/// Maps pitch-frame stream time (seconds of audio since capture started) to host time.
///
/// Each delivered batch gives `arrival host time - stream time`; the smallest value seen is the least-delayed
/// delivery, so it is the best estimate of the true offset. It creeps up slowly (default 2 ms per second) so a
/// lasting change in delay is followed, and it resets when the stream restarts (stream time goes backwards).
public struct StreamClockMapper: Sendable, Equatable {
    public private(set) var offset: Double?
    private var lastStreamTime = -Double.infinity
    public let creepPerSecond: Double

    public init(creepPerSecond: Double = 0.002) {
        self.creepPerSecond = creepPerSecond
    }

    public mutating func observe(streamTime: Double, hostTime: Double) {
        if streamTime < lastStreamTime - 0.25 {
            offset = nil
        }
        let candidate = hostTime - streamTime
        if let current = offset {
            let elapsed = max(0, streamTime - lastStreamTime)
            offset = min(current + creepPerSecond * elapsed, candidate)
        } else {
            offset = candidate
        }
        lastStreamTime = streamTime
    }

    public func hostTime(forStream streamTime: Double) -> Double? {
        offset.map { streamTime + $0 }
    }

    public mutating func reset() {
        offset = nil
        lastStreamTime = -.infinity
    }
}

/// Rendering frame-rate meter over the last second.
public struct FrameRateMeter: Sendable {
    private var times: [Double] = []
    private let window: Double

    public init(window: Double = 1) {
        self.window = window
        times.reserveCapacity(256)
    }

    public mutating func tick(at time: Double) {
        if let last = times.last, time < last { times.removeAll(keepingCapacity: true) }
        times.append(time)
        let cutoff = time - window
        if let first = times.first, first < cutoff, let keep = times.firstIndex(where: { $0 >= cutoff }) {
            times.removeFirst(keep)
        }
    }

    public var framesPerSecond: Double {
        guard times.count >= 2, let first = times.first, let last = times.last, last > first else { return 0 }
        return Double(times.count - 1) / (last - first)
    }

    /// Longest gap between frames in the window, in seconds.
    public var worstFrameInterval: Double {
        zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0
    }
}
