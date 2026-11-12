#if canImport(SwiftUI)
import Foundation
import QuartzCore
import SwiftUI
import PitchLaneCore

struct GameOptions: Hashable {
    var difficulty: Difficulty
    var octaveAgnostic: Bool
    var clickTrack: Bool
    var showNoteNames: Bool
}

/// Runs one play-through: master clock, scoring, pitch-frame mapping, click scheduling and the state the
/// lane renderer reads every frame. Published properties change only when a note ends or the phase
/// changes; per-frame render state is plain stored properties.
@MainActor
final class GameSession: ObservableObject {
    enum Phase: Equatable {
        case waitingForAudio
        case running
        case paused
        case finished
    }

    struct Popup {
        var noteIndex: Int
        var rating: NoteRating
        var points: Int
        var songTime: Double
    }

    struct TrailPoint {
        var time: Double
        var midi: Double
    }

    let song: Song
    let options: GameOptions
    let viewport: LaneViewport
    let noteIndex: NoteIndex

    @Published private(set) var phase: Phase = .waitingForAudio
    @Published private(set) var score = 0
    @Published private(set) var combo = 0
    @Published private(set) var multiplier = 1
    @Published private(set) var accuracy = 0.0
    @Published private(set) var result: GameResult?
    @Published private(set) var isNewBest = false
    @Published private(set) var previousBest: PersonalBest?
    @Published private(set) var results: [NoteResult] = []

    // Render state (read by the Canvas every frame).
    private(set) var clock: GameClock
    private(set) var trail: [TrailPoint] = []
    private(set) var latestVoiced: TrailPoint?
    private(set) var latestFrameSongTime = -Double.infinity
    private(set) var popups: [Popup] = []
    private(set) var ratings: [Int: NoteRating] = [:]
    private(set) var onPitchNote: (index: Int, time: Double)?
    private(set) var pitchRange: ClosedRange<Double>
    private(set) var replay = ReplayTrace()

    private var keeper: ScoreKeeper
    private var mapper = StreamClockMapper()
    private var smoother = ViewportSmoother()
    private var lastRenderHost: Double?
    private var clickHorizon = -Double.infinity
    private var frameMeter = FrameRateMeter()
    private var nextStatsReport = 0.0
    private var worstFrameSeen = 0.0
    private var finishScheduled = false
    private weak var audio: AudioInput?
    private weak var scores: ScoreStore?

    /// The stabiliser's 5-frame median lags ~20 ms; step 4 replaces this with measured latency.
    static let pitchLatency = 0.02
    private static let listenerName = "game"

    init(song: Song, options: GameOptions) {
        self.song = song
        self.options = options
        viewport = LaneViewport(song: song)
        noteIndex = NoteIndex(song: song)
        clock = GameClock(songDuration: song.duration)
        keeper = ScoreKeeper(song: song, rules: ScoringRules(difficulty: options.difficulty, octaveAgnostic: options.octaveAgnostic))
        pitchRange = viewport.range(center: viewport.targetCenter(at: 0))
    }

    // MARK: Lifecycle

    func begin(audio: AudioInput, scores: ScoreStore) {
        self.audio = audio
        self.scores = scores
        previousBest = scores.best(songID: song.id, difficulty: options.difficulty)
        audio.addFrameListener(Self.listenerName) { [weak self] batch, arrival in
            self?.receive(batch, arrival: arrival)
        }
        startClock()
        AppLog.info(
            "Game start: \"\(song.title)\" [\(song.id)] \(options.difficulty.displayName), octave-agnostic \(options.octaveAgnostic), "
                + "click \(options.clickTrack), \(keeper.scoredNoteCount) scored notes, \(song.summary.durationText), "
                + "lane \(Int(viewport.fullRange.lowerBound))-\(Int(viewport.fullRange.upperBound))\(viewport.pans ? " (pans)" : "")",
            category: "game"
        )
    }

    func end() {
        audio?.diagnostics.clearGameFrameStats()
        audio?.removeFrameListener(Self.listenerName)
        audio?.cancelClicks()
        if phase != .finished {
            AppLog.info("Game quit at \(String(format: "%.1f", clock.songTime(at: CACurrentMediaTime()))) s, score \(score)", category: "game")
        }
        logRenderStats()
    }

    private func startClock() {
        clock = GameClock(songDuration: song.duration)
        clock.start(at: CACurrentMediaTime())
        clickHorizon = -Double.infinity
        phase = .running
    }

    func pause(reason: String) {
        guard phase == .running else { return }
        let now = CACurrentMediaTime()
        clock.pause(at: now)
        audio?.cancelClicks()
        clickHorizon = -Double.infinity
        phase = .paused
        AppLog.info("Game paused (\(reason)) at \(String(format: "%.2f", clock.songTime(at: now))) s", category: "game")
    }

    func resume() {
        guard phase == .paused else { return }
        clock.resume(at: CACurrentMediaTime())
        lastRenderHost = nil
        phase = .running
        AppLog.info("Game resumed", category: "game")
    }

    func restart() {
        audio?.cancelClicks()
        keeper = ScoreKeeper(song: song, rules: ScoringRules(difficulty: options.difficulty, octaveAgnostic: options.octaveAgnostic))
        score = 0
        combo = 0
        multiplier = 1
        accuracy = 0
        results = []
        result = nil
        isNewBest = false
        trail = []
        latestVoiced = nil
        latestFrameSongTime = -.infinity
        popups = []
        ratings = [:]
        onPitchNote = nil
        replay = ReplayTrace()
        smoother.reset()
        lastRenderHost = nil
        finishScheduled = false
        previousBest = scores?.best(songID: song.id, difficulty: options.difficulty)
        startClock()
        AppLog.info("Game restarted", category: "game")
    }

    // MARK: Pitch frames

    private func receive(_ batch: PitchAnalyzer.Batch, arrival: Double) {
        guard let last = batch.frames.last else { return }
        mapper.observe(streamTime: last.time, hostTime: arrival)
        guard phase == .running, let offset = mapper.offset else { return }
        var changed = false
        for frame in batch.frames {
            let host = frame.time + offset - Self.pitchLatency
            guard clock.isAdvancing(at: host) else { continue }
            let t = clock.songTime(at: host)
            guard t > latestFrameSongTime else { continue }
            latestFrameSongTime = t

            var display: Double?
            if let midi = frame.midi {
                let shown = options.octaveAgnostic ? PitchFolding.fold(midi, toward: referencePitch(at: t)) : midi
                display = shown
                let point = TrailPoint(time: t, midi: shown)
                trail.append(point)
                latestVoiced = point
            }
            replay.append(time: t, midi: display)

            guard t >= 0 else { continue }
            let finished = keeper.add(time: t, midi: frame.midi)
            if let evaluation = keeper.lastEvaluation, evaluation.time == t {
                onPitchNote = evaluation.onPitch ? (evaluation.noteIndex, t) : nil
            }
            if !finished.isEmpty {
                record(finished)
                changed = true
            }
        }
        if let cutoff = trail.last?.time, let first = trail.first, first.time < cutoff - 0.6,
           let keep = trail.firstIndex(where: { $0.time >= cutoff - 0.6 }) {
            trail.removeFirst(keep)
        }
        if changed { publishScore() }
    }

    private func record(_ finished: [NoteResult]) {
        for note in finished {
            ratings[note.noteIndex] = note.rating
            popups.append(Popup(noteIndex: note.noteIndex, rating: note.rating, points: note.points, songTime: note.endTime))
        }
        results = keeper.results
        if popups.count > 24 { popups.removeFirst(popups.count - 24) }
    }

    private func publishScore() {
        score = keeper.score
        combo = keeper.combo
        multiplier = keeper.multiplier
        accuracy = keeper.accuracy
    }

    /// Pitch the sung dot is folded toward: the note under or nearest the playhead.
    func referencePitch(at time: Double) -> Double {
        let nearby = noteIndex.indices(overlapping: time - 1.5, time + 1.5)
        guard !nearby.isEmpty else { return (viewport.fullRange.lowerBound + viewport.fullRange.upperBound) / 2 }
        var best = nearby[0]
        var bestDistance = Double.infinity
        for index in nearby {
            let note = song.notes[index]
            let distance = time < note.start ? note.start - time : (time > note.end ? time - note.end : 0)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        let note = song.notes[best]
        return time >= note.start && time <= note.end ? song.targetPitch(noteAt: best, time: time) : Double(note.pitch)
    }

    // MARK: Per frame (called from the Canvas)

    /// Advances render-side state for the frame at `host`. Never publishes synchronously.
    @discardableResult
    func renderTick(host: Double) -> Double {
        frameMeter.tick(at: host)
        let dt = lastRenderHost.map { host - $0 } ?? 0
        lastRenderHost = host
        let t = clock.songTime(at: host)

        let target = viewport.targetCenter(at: t)
        let center = smoother.update(target: target, dt: dt)
        pitchRange = viewport.range(center: center)

        if options.clickTrack, phase == .running, clock.isAdvancing(at: host) {
            scheduleClicks(songTime: t, host: host)
        }
        popups.removeAll { t - $0.songTime > 1.2 }

        if phase == .running, !finishScheduled, clock.phase(at: host) == .finished {
            finishScheduled = true
            Task { @MainActor [weak self] in self?.finish() }
        }
        if host >= nextStatsReport {
            nextStatsReport = host + 0.5
            let fps = frameMeter.framesPerSecond
            let worst = frameMeter.worstFrameInterval * 1_000
            worstFrameSeen = max(worstFrameSeen, worst)
            Task { @MainActor [weak self] in
                self?.audio?.diagnostics.setGameFrameStats(fps: fps, worstFrameMs: worst)
            }
        }
        return t
    }

    private func scheduleClicks(songTime t: Double, host: Double) {
        let horizon = t + 0.5
        let from = max(clickHorizon, t)
        guard horizon > from else { return }
        for click in song.clickTimes(from: from, to: horizon) {
            audio?.scheduleClick(atHostTime: host + (click - t))
        }
        clickHorizon = horizon
    }

    // MARK: Finish

    private func finish() {
        guard phase == .running else { return }
        let finished = keeper.finish()
        record(finished)
        publishScore()
        let summary = keeper.result(songID: song.id, songTitle: song.title)
        isNewBest = scores?.record(summary) ?? false
        result = summary
        phase = .finished
        audio?.cancelClicks()
        let counts = NoteRating.allCases.map { "\($0.rawValue) \(summary.counts[$0, default: 0])" }.joined(separator: ", ")
        AppLog.info(
            "Game finished: score \(summary.score), grade \(summary.grade.rawValue), accuracy \(String(format: "%.1f", summary.accuracy * 100))%, "
                + "max combo \(summary.maxCombo), \(counts)\(isNewBest ? ", NEW BEST" : "")",
            category: "game"
        )
        logRenderStats()
    }

    private func logRenderStats() {
        AppLog.info(
            "Render: \(String(format: "%.0f", frameMeter.framesPerSecond)) fps (last second), worst frame seen \(String(format: "%.1f", worstFrameSeen)) ms",
            category: "game"
        )
    }
}

/// Personal bests, persisted as JSON in Application Support.
@MainActor
final class ScoreStore: ObservableObject {
    @Published private(set) var bests = PersonalBests()
    private let store = JSONFileStore<PersonalBests>(url: AppPaths.personalBestsFile)

    init() {
        do {
            bests = try store.load() ?? PersonalBests()
        } catch {
            AppLog.error("Personal bests unreadable, starting fresh: \(error)", category: "game")
        }
    }

    func best(songID: String, difficulty: Difficulty) -> PersonalBest? {
        bests.best(songID: songID, difficulty: difficulty)
    }

    /// Returns true when the result is a new personal best.
    func record(_ result: GameResult) -> Bool {
        var updated = bests
        guard updated.record(result) else { return false }
        bests = updated
        do {
            try store.save(updated)
        } catch {
            AppLog.error("Saving personal bests failed: \(error)", category: "game")
        }
        return true
    }

    func forget(songID: String) {
        var updated = bests
        updated.remove(songID: songID)
        bests = updated
        try? store.save(updated)
    }
}
#endif
