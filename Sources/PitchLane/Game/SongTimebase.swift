#if canImport(SwiftUI)
import Foundation
import QuartzCore
import PitchLaneCore

/// Song clock on the audio output timeline.
///
/// - The `GameClock` runs in *output render seconds* (output sample time / rate), published by the guide voice's
///   render callback, so the lane, guide tone, backing track and clicks all share one clock and never drift.
/// - What the player hears now was rendered `latency.output` ago: the lane shows `songTime(render(now) - output)`.
/// - A mic frame captured at host time h was sung at h - `latency.input`; it lands on the song at
///   `songTime(render(h - input) - output) - correction` (correction = per-route calibration + nudge).
@MainActor
final class SongTimebase {
    private(set) var clock: GameClock
    private(set) var latency: LatencyEstimate = .zero
    private weak var audio: AudioInput?
    private let songDuration: Double
    private let leadIn: Double
    let rate: Double
    /// Output-render time at which the last `seek` takes effect (loops).
    private var lastSeekRender: Double?
    private var captureOffset: Double?
    private var fallbackMapper = StreamClockMapper()
    /// Last output-render time seen, used when the engine has just stopped (route change, interruption).
    private var lastRender: Double?

    init(audio: AudioInput, songDuration: Double, leadIn: Double = 3, rate: Double = 1) {
        self.audio = audio
        self.songDuration = songDuration
        self.leadIn = leadIn
        self.rate = rate
        clock = GameClock(songDuration: songDuration, leadIn: leadIn, rate: rate)
    }

    var isStarted: Bool { clock.isStarted }

    /// Output render seconds now, if the output clock is running.
    func renderNow() -> Double? {
        let render = audio?.renderSeconds(atHost: CACurrentMediaTime())
        if let render { lastRender = render }
        return render
    }

    /// Starts the countdown. Returns false until the output clock is available.
    @discardableResult
    func start(from songStart: Double = 0) -> Bool {
        guard let audio, let render = renderNow() else { return false }
        latency = audio.latency
        clock = GameClock(songDuration: songDuration, leadIn: leadIn, rate: rate)
        clock.start(at: render + 0.05, from: songStart)
        lastSeekRender = nil
        publish()
        return true
    }

    /// True between asking for a seek and it reaching the output (a few ms to a few hundred ms).
    func isSeekPending() -> Bool {
        guard let lastSeekRender, let render = renderNow() else { return false }
        return render < lastSeekRender
    }

    /// Output-render time at which song time `songTime` is rendered (while running).
    func renderSeconds(forSongTime songTime: Double) -> Double? {
        guard let anchor = clock.anchor, anchor.time.isFinite else { return nil }
        return anchor.time + (songTime - anchor.songTime) / rate
    }

    /// Jumps to `target` exactly when the audio reaches song time `switchSong` (a loop wrap). Returns the host
    /// time of the switch so other audio can be scheduled at the same instant.
    @discardableResult
    func seek(toSongTime target: Double, whenRenderingSongTime switchSong: Double) -> Double? {
        guard let switchRender = renderSeconds(forSongTime: switchSong) else { return nil }
        clock.seek(toSongTime: target, at: switchRender)
        lastSeekRender = switchRender
        publish()
        return audio?.hostSeconds(forRender: switchRender)
    }

    /// Freezes at what the player is hearing now.
    func pause() {
        guard let render = renderNow() ?? lastRender else { return }
        clock.pause(at: render - latency.output)
        publish()
    }

    /// Continues after the resume countdown, on the current output timeline (also after an engine restart).
    func resume() {
        guard let audio, let render = renderNow() else { return }
        latency = audio.latency
        clock.resume(at: render)
        publish()
    }

    func stop() {
        audio?.stopGuideTimeline()
    }

    /// Hands the clock's anchor to the guide voice on the render thread.
    func publish() {
        guard let anchor = clock.anchor else { return }
        audio?.setGuideTimeline(anchorRender: anchor.time, anchorSong: anchor.songTime, rate: rate)
    }

    // MARK: What the player hears

    /// Render seconds of what is audible at `host` (falls back to host time before the clock exists).
    func heardRender(atHost host: Double) -> Double {
        if let render = audio?.renderSeconds(atHost: host) {
            lastRender = render
            return render - latency.output
        }
        return (lastRender ?? host) - latency.output
    }

    func heardSongTime(atHost host: Double) -> Double {
        clock.songTime(at: heardRender(atHost: host))
    }

    func countdown(atHost host: Double) -> Int? {
        clock.countdown(at: heardRender(atHost: host))
    }

    func phase(atHost host: Double) -> GameClock.Phase {
        clock.phase(at: heardRender(atHost: host))
    }

    func isAdvancing(atHost host: Double) -> Bool {
        clock.isAdvancing(at: heardRender(atHost: host))
    }

    // MARK: Mic frames

    func observe(_ batch: PitchAnalyzer.Batch, arrival: Double) {
        if let capture = batch.capture {
            captureOffset = capture.hostSeconds - capture.streamTime
        } else if let last = batch.frames.last {
            fallbackMapper.observe(streamTime: last.time, hostTime: arrival)
            if captureOffset == nil { captureOffset = fallbackMapper.offset }
        }
    }

    /// Song time at which the sound in a frame (stream time) was sung, or nil while time isn't advancing.
    /// `applyCorrection: false` gives the raw mapping (used by calibration itself).
    func songTime(forFrameAt streamTime: Double, applyCorrection: Bool = true) -> Double? {
        guard let captureOffset, let audio else { return nil }
        let sungHost = streamTime + captureOffset - latency.input
        guard let render = audio.renderSeconds(atHost: sungHost) else { return nil }
        let heard = render - latency.output
        guard clock.isAdvancing(at: heard) else { return nil }
        if let lastSeekRender, heard < lastSeekRender { return nil }
        return clock.songTime(at: heard) - (applyCorrection ? latency.correction : 0)
    }

    // MARK: Scheduling audio on the clock

    /// Host time at which song time `songTime` is *rendered* (for scheduling players/clicks), while running.
    func hostSeconds(forSongTime songTime: Double) -> Double? {
        guard let anchor = clock.anchor, anchor.time.isFinite else { return nil }
        return audio?.hostSeconds(forRender: anchor.time + (songTime - anchor.songTime) / rate)
    }

    /// Song time at which rendering (not hearing) currently is.
    func renderedSongTime() -> Double? {
        renderNow().map { clock.songTime(at: $0) }
    }
}
#endif
