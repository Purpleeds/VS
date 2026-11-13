import Foundation

/// What to do to keep a muted video player in step with the song clock.
public enum VideoSyncAction: Sendable, Equatable {
    case none
    case seek(to: Double)
    case setRate(Double)
    case pause(at: Double)
}

/// Keeps a video locked to the audio: big drifts seek, small drifts nudge the playback rate a few percent
/// (invisible), and anything that isn't playing (countdown, pause, before the video starts) holds the frame.
public struct VideoSyncPolicy: Sendable, Equatable {
    public var seekThreshold: Double = 0.25
    public var nudgeThreshold: Double = 0.035
    public var nudge: Double = 0.06

    public init() {}

    /// Video time that matches song time `songTime` (same mapping as the backing audio).
    public static func videoTime(forSongTime songTime: Double, offsetMs: Double) -> Double {
        songTime - offsetMs / 1_000
    }

    /// - Parameters:
    ///   - videoTime: the player's current time.
    ///   - targetTime: where the video should be now.
    ///   - advancing: the song clock is moving (not counting down or paused).
    ///   - songRate: practice speed.
    ///   - currentRate: the player's rate right now (0 = paused).
    ///   - duration: video length, if known.
    public func action(
        videoTime: Double,
        targetTime: Double,
        advancing: Bool,
        songRate: Double,
        currentRate: Double,
        duration: Double? = nil
    ) -> VideoSyncAction {
        guard videoTime.isFinite, targetTime.isFinite else { return .none }
        let clamped = max(0, min(targetTime, duration ?? .infinity))
        let beforeStart = targetTime < 0
        let afterEnd = duration.map { targetTime >= $0 } ?? false
        if !advancing || beforeStart || afterEnd {
            if currentRate != 0 || abs(videoTime - clamped) > seekThreshold { return .pause(at: clamped) }
            return .none
        }
        let drift = videoTime - targetTime
        if abs(drift) > seekThreshold { return .seek(to: targetTime) }
        let base = max(0.25, songRate)
        let wanted: Double
        if abs(drift) > nudgeThreshold {
            wanted = base * (drift > 0 ? 1 - nudge : 1 + nudge)
        } else {
            wanted = base
        }
        return abs(currentRate - wanted) > 0.001 ? .setRate(wanted) : .none
    }
}
