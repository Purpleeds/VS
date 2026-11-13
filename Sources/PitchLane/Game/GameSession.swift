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
    var guideTone: Bool
    var guideVolume: Double
    var backingVolume: Double
    var practice: PracticeOptions = .normal
    /// Songs end when the energy bar empties (also needs `practice.noFail` off and no loop).
    var failEnabled: Bool = true
    /// Semitones the song was shifted by (for the history).
    var transpose: Int = 0
}

/// Runs one play-through: song clock on the audio output timeline, scoring, guide tone, backing track,
/// clicks, and the state the lane renderer reads every frame. Published properties change only when a note
/// ends or the phase changes; per-frame render state is plain stored properties.
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
    let viewport: LaneViewport
    let noteIndex: NoteIndex
    private(set) var options: GameOptions

    @Published private(set) var phase: Phase = .waitingForAudio
    @Published private(set) var score = 0
    @Published private(set) var combo = 0
    @Published private(set) var multiplier = 1
    @Published private(set) var accuracy = 0.0
    @Published private(set) var result: GameResult?
    @Published private(set) var isNewBest = false
    @Published private(set) var previousBest: PersonalBest?
    @Published private(set) var results: [NoteResult] = []
    @Published private(set) var guideOn: Bool
    @Published private(set) var hasBacking = false
    @Published private(set) var health = 1.0
    @Published private(set) var loopPasses: [Double] = []
    @Published private(set) var failed = false

    // Render state (read by the Canvas every frame).
    private(set) var trail: [TrailPoint] = []
    private(set) var latestVoiced: TrailPoint?
    private(set) var latestFrameSongTime = -Double.infinity
    private(set) var popups: [Popup] = []
    private(set) var ratings: [Int: NoteRating] = [:]
    private(set) var onPitchNote: (index: Int, time: Double)?
    private(set) var pitchRange: ClosedRange<Double>
    private(set) var replay = ReplayTrace()

    private var keeper: ScoreKeeper
    /// Notes scored this pass (the loop section, or the whole song) and their indices in `song`.
    private var scoringSong: Song
    private var scoringIndices: [Int]
    private var healthMeter: HealthMeter
    /// The energy bar is in play (fail on, no-fail off, not looping).
    var showsHealth: Bool { healthMeter.enabled }
    private var timebase: SongTimebase?
    private var smoother = ViewportSmoother()
    private var lastRenderHost: Double?
    private var clickHorizon = -Double.infinity
    private var frameMeter = FrameRateMeter()
    private var nextStatsReport = 0.0
    private var worstFrameSeen = 0.0
    private var finishScheduled = false
    private var pendingVisualReset = false
    private weak var audio: AudioInput?
    private weak var scores: ScoreStore?
    private var backingURL: URL?

    /// The stabiliser's 5-frame median lags ~20 ms behind the sound.
    static let pitchLatency = 0.02
    private static let listenerName = "game"

    init(song: Song, options: GameOptions) {
        let viewport = LaneViewport(song: song)
        self.song = song
        self.options = options
        self.viewport = viewport
        noteIndex = NoteIndex(song: song)
        let scoring = Self.scoringSong(for: song, practice: options.practice)
        scoringSong = scoring.song
        scoringIndices = scoring.indices
        keeper = ScoreKeeper(song: scoring.song, rules: ScoringRules(difficulty: options.difficulty, octaveAgnostic: options.octaveAgnostic))
        healthMeter = HealthMeter(enabled: options.failEnabled && !options.practice.noFail && options.practice.loop == nil)
        pitchRange = viewport.range(center: viewport.targetCenter(at: options.practice.loop?.lowerBound ?? 0))
        guideOn = options.guideTone
    }

    private static func scoringSong(for song: Song, practice: PracticeOptions) -> (song: Song, indices: [Int]) {
        guard let loop = practice.loop else { return (song, Array(song.notes.indices)) }
        let section = song.section(from: loop.lowerBound, to: loop.upperBound)
        return (section.song, section.originalIndices)
    }

    private var loopStartSong: Double { max(0, (options.practice.loop?.lowerBound ?? 0) - 1) }

    // MARK: Lifecycle

    func begin(audio: AudioInput, scores: ScoreStore, backingURL: URL?) {
        self.audio = audio
        self.scores = scores
        previousBest = scores.best(songID: song.id, difficulty: options.difficulty)
        timebase = SongTimebase(audio: audio, songDuration: song.duration, rate: options.practice.speed)
        audio.backing.setRate(options.practice.speed)
        audio.addFrameListener(Self.listenerName) { [weak self] batch, arrival in
            self?.receive(batch, arrival: arrival)
        }
        audio.installGuide(GuideToneRenderer(song: song, envelope: .soft))
        audio.setGuideVolume(guideOn ? Float(options.guideVolume) : 0)
        loadBacking(backingURL)
        let latency = audio.latency
        AppLog.info(
            "Game start: \"\(song.title)\" [\(song.id)] \(options.difficulty.displayName), octave-agnostic \(options.octaveAgnostic), "
                + "click \(options.clickTrack), guide \(guideOn ? String(format: "%.0f%%", options.guideVolume * 100) : "off"), "
                + "backing \(hasBacking ? String(format: "%.0f%%", options.backingVolume * 100) : "none"), "
                + "\(keeper.scoredNoteCount) scored notes, \(song.summary.durationText), "
                + "lane \(Int(viewport.fullRange.lowerBound))-\(Int(viewport.fullRange.upperBound))\(viewport.pans ? " (pans)" : ""), "
                + "route \(latency.route.rawValue) in \(Self.ms(latency.input)) out \(Self.ms(latency.output)) correction \(Self.ms(latency.correction)) ms, "
                + "practice speed \(options.practice.speedText) loop \(options.practice.loop.map { String(format: "%.1f-%.1f s", $0.lowerBound, $0.upperBound) } ?? "off") "
                + "noFail \(options.practice.noFail) fail \(options.failEnabled) shift \(options.transpose)",
            category: "game"
        )
        startWhenClockIsReady()
    }

    private func loadBacking(_ url: URL?) {
        backingURL = url
        guard let audio, let url else {
            hasBacking = false
            return
        }
        do {
            try audio.backing.load(url: url)
            audio.backing.setVolume(Float(options.backingVolume))
            hasBacking = true
            AppLog.info(
                "Backing loaded: \(url.lastPathComponent), \(String(format: "%.1f", audio.backing.duration)) s, "
                    + "offset \(Int(song.offsetMs)) ms, time-pitch latency \(Self.ms(audio.backingLatency)) ms",
                category: "game"
            )
        } catch {
            hasBacking = false
            AppLog.error("Backing audio couldn't be opened: \(error.localizedDescription)", category: "game")
        }
    }

    func end() {
        audio?.diagnostics.clearGameFrameStats()
        audio?.removeFrameListener(Self.listenerName)
        audio?.cancelClicks()
        audio?.backing.unload()
        audio?.backing.setRate(1)
        timebase?.stop()
        audio?.installGuide(nil)
        if phase != .finished {
            AppLog.info("Game quit at \(String(format: "%.1f", currentSongTime())) s, score \(score)", category: "game")
        }
        logRenderStats()
    }

    /// Starts the countdown as soon as the output clock is ticking.
    private func startWhenClockIsReady() {
        guard let timebase else { return }
        if timebase.start(from: options.practice.loop == nil ? 0 : loopStartSong) {
            clickHorizon = -Double.infinity
            phase = .running
            scheduleBacking(fromSong: options.practice.loop == nil ? 0 : loopStartSong)
        } else {
            phase = .waitingForAudio
        }
    }

    func pause(reason: String) {
        guard phase == .running, let timebase else { return }
        timebase.pause()
        audio?.cancelClicks()
        audio?.backing.stop()
        clickHorizon = -Double.infinity
        phase = .paused
        AppLog.info("Game paused (\(reason)) at \(String(format: "%.2f", currentSongTime())) s", category: "game")
    }

    func resume() {
        guard phase == .paused, let timebase else { return }
        timebase.resume()
        lastRenderHost = nil
        phase = .running
        if let anchor = timebase.clock.anchor {
            scheduleBacking(fromSong: anchor.songTime)
        }
        AppLog.info("Game resumed at \(String(format: "%.2f", currentSongTime())) s", category: "game")
    }

    func restart() {
        audio?.cancelClicks()
        audio?.backing.stop()
        keeper = ScoreKeeper(song: scoringSong, rules: ScoringRules(difficulty: options.difficulty, octaveAgnostic: options.octaveAgnostic))
        healthMeter.reset()
        health = 1
        failed = false
        loopPasses = []
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
        startWhenClockIsReady()
        AppLog.info("Game restarted", category: "game")
    }

    // MARK: Live audio options

    func setGuide(_ on: Bool) {
        guideOn = on
        audio?.setGuideVolume(on ? Float(options.guideVolume) : 0)
        AppLog.info("Guide tone \(on ? "on" : "off")", category: "game")
    }

    func setGuideVolume(_ volume: Double) {
        options.guideVolume = volume
        if guideOn { audio?.setGuideVolume(Float(volume)) }
    }

    func setBackingVolume(_ volume: Double) {
        options.backingVolume = volume
        audio?.backing.setVolume(Float(volume))
    }

    // MARK: Backing and clicks on the song clock

    /// Plays the backing so that song time `songTime` is rendered exactly when the clock renders it.
    private func scheduleBacking(fromSong songTime: Double) {
        guard hasBacking, let audio, let timebase else { return }
        let offset = song.offsetMs / 1_000
        var fileTime = songTime - offset
        var startSong = songTime
        if fileTime < 0 {
            startSong -= fileTime
            fileTime = 0
        }
        guard fileTime < audio.backing.duration, let host = timebase.hostSeconds(forSongTime: startSong) else { return }
        audio.backing.play(fromFileTime: fileTime, atHost: host - audio.backingLatency)
        AppLog.debug("Backing scheduled: file \(String(format: "%.2f", fileTime)) s at song \(String(format: "%.2f", startSong)) s", category: "game")
    }

    private func scheduleClicks(renderedSong t: Double) {
        guard let timebase else { return }
        let horizon = t + 0.5
        let from = max(clickHorizon, t)
        guard horizon > from else { return }
        for click in song.clickTimes(from: from, to: horizon) {
            if let host = timebase.hostSeconds(forSongTime: click) {
                audio?.scheduleClick(atHostTime: host)
            }
        }
        clickHorizon = horizon
    }

    // MARK: Pitch frames

    private func receive(_ batch: PitchAnalyzer.Batch, arrival: Double) {
        guard let timebase else { return }
        timebase.observe(batch, arrival: arrival)
        guard phase == .running else { return }
        var changed = false
        for frame in batch.frames {
            guard let mapped = timebase.songTime(forFrameAt: frame.time) else { continue }
            let t = mapped - Self.pitchLatency
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
        if changed {
            publishScore()
            if healthMeter.isFailed { complete(failed: true) }
        }
    }

    private func record(_ finished: [NoteResult]) {
        for note in finished {
            let full = scoringIndices[note.noteIndex]
            ratings[full] = note.rating
            popups.append(Popup(noteIndex: full, rating: note.rating, points: note.points, songTime: note.endTime))
            healthMeter.apply(note.rating)
        }
        results = keeper.results
        health = healthMeter.value
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

    func countdown(atHost host: Double) -> Int? {
        guard phase == .running else { return nil }
        return timebase?.countdown(atHost: host)
    }

    private func currentSongTime() -> Double {
        timebase?.heardSongTime(atHost: CACurrentMediaTime()) ?? 0
    }

    /// Advances render-side state for the frame at `host` and returns the song time to draw (what the player
    /// hears now). Never publishes synchronously.
    @discardableResult
    func renderTick(host: Double) -> Double {
        frameMeter.tick(at: host)
        let dt = lastRenderHost.map { host - $0 } ?? 0
        lastRenderHost = host
        if phase == .waitingForAudio, timebase != nil {
            Task { @MainActor [weak self] in
                if self?.phase == .waitingForAudio { self?.startWhenClockIsReady() }
            }
        }
        guard let timebase else { return -3 }
        let t = timebase.heardSongTime(atHost: host)

        let target = viewport.targetCenter(at: t)
        let center = smoother.update(target: target, dt: dt)
        pitchRange = viewport.range(center: center)

        if options.clickTrack, phase == .running, !timebase.isSeekPending(),
           let rendered = timebase.renderedSongTime(), timebase.isAdvancing(atHost: host) {
            scheduleClicks(renderedSong: rendered)
        }
        if let loop = options.practice.loop, phase == .running {
            if pendingVisualReset, t < loop.upperBound - 1.5 {
                pendingVisualReset = false
                ratings = [:]
                popups = []
            }
            if !timebase.isSeekPending(), let rendered = timebase.renderedSongTime(), rendered >= loop.upperBound - 0.1 * options.practice.speed {
                wrapLoop(loop)
            }
        }
        popups.removeAll { t - $0.songTime > 1.2 }

        if phase == .running, !finishScheduled, timebase.phase(atHost: host) == .finished {
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

    // MARK: Loops

    /// Ends one pass of the practice loop and jumps back, exactly when the audio reaches the loop end.
    private func wrapLoop(_ loop: ClosedRange<Double>) {
        guard let timebase else { return }
        let target = loopStartSong
        guard timebase.seek(toSongTime: target, whenRenderingSongTime: loop.upperBound) != nil else { return }
        record(keeper.finish())
        let pass = keeper.accuracy
        loopPasses.append(pass)
        AppLog.info(
            "Loop pass \(loopPasses.count): accuracy \(String(format: "%.1f", pass * 100))%, score \(keeper.score), best combo \(keeper.maxCombo)",
            category: "game"
        )
        keeper = ScoreKeeper(song: scoringSong, rules: ScoringRules(difficulty: options.difficulty, octaveAgnostic: options.octaveAgnostic))
        publishScore()
        latestFrameSongTime = -.infinity
        trail = []
        pendingVisualReset = true
        audio?.cancelClicks()
        clickHorizon = target
        audio?.backing.stop()
        scheduleBacking(fromSong: target)
    }

    // MARK: Finish

    private func finish() {
        complete(failed: false)
    }

    /// Ends the play-through: finished normally, or failed when the energy bar emptied.
    private func complete(failed didFail: Bool) {
        guard phase == .running else { return }
        if !didFail { record(keeper.finish()) }
        publishScore()
        var summary = keeper.result(songID: song.id, songTitle: song.title)
        summary.failed = didFail
        failed = didFail
        isNewBest = scores?.record(summary, practice: options.practice, transpose: options.transpose) ?? false
        result = summary
        phase = .finished
        audio?.cancelClicks()
        audio?.backing.stop()
        timebase?.stop()
        let counts = NoteRating.allCases.map { "\($0.rawValue) \(summary.counts[$0, default: 0])" }.joined(separator: ", ")
        AppLog.info(
            "Game \(didFail ? "FAILED (energy ran out)" : "finished"): score \(summary.score), grade \(summary.grade.rawValue), "
                + "accuracy \(String(format: "%.1f", summary.accuracy * 100))%, max combo \(summary.maxCombo), \(counts)"
                + "\(isNewBest ? ", NEW BEST" : "")\(options.practice.isPractice ? ", practice \(options.practice.speedText)" : "")",
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

    private static func ms(_ seconds: Double) -> String {
        String(format: "%.0f", seconds * 1_000)
    }
}

/// Personal bests and the play history, persisted as JSON in Application Support.
@MainActor
final class ScoreStore: ObservableObject {
    @Published private(set) var bests = PersonalBests()
    @Published private(set) var history = GameHistory()
    private let bestsStore = JSONFileStore<PersonalBests>(url: AppPaths.personalBestsFile)
    private let historyStore = JSONFileStore<GameHistory>(url: AppPaths.historyFile)

    init() {
        do {
            bests = try bestsStore.load() ?? PersonalBests()
        } catch {
            AppLog.error("Personal bests unreadable, starting fresh: \(error)", category: "game")
        }
        do {
            history = try historyStore.load() ?? GameHistory()
        } catch {
            AppLog.error("History unreadable, starting fresh: \(error)", category: "game")
        }
    }

    func best(songID: String, difficulty: Difficulty) -> PersonalBest? {
        bests.best(songID: songID, difficulty: difficulty)
    }

    /// Adds the run to the history; completed full-speed runs may also set a personal best.
    /// Returns true when it is a new personal best.
    func record(_ result: GameResult, practice: PracticeOptions, transpose: Int) -> Bool {
        var updatedHistory = history
        updatedHistory.add(GameRecord(result: result, practice: practice, failed: result.failed, transpose: transpose))
        history = updatedHistory
        save(history, to: historyStore, "history")

        guard !practice.isPractice, !result.failed else { return false }
        var updated = bests
        guard updated.record(result) else { return false }
        bests = updated
        save(updated, to: bestsStore, "personal bests")
        return true
    }

    func forget(songID: String) {
        var updated = bests
        updated.remove(songID: songID)
        bests = updated
        save(updated, to: bestsStore, "personal bests")
        var updatedHistory = history
        updatedHistory.removeAll(songID: songID)
        history = updatedHistory
        save(updatedHistory, to: historyStore, "history")
    }

    func resetAll() {
        bests = PersonalBests()
        history = GameHistory()
        save(bests, to: bestsStore, "personal bests")
        save(history, to: historyStore, "history")
        AppLog.info("Scores and history cleared", category: "game")
    }

    private func save<T: Codable & Sendable>(_ value: T, to store: JSONFileStore<T>, _ what: String) {
        do {
            try store.save(value)
        } catch {
            AppLog.error("Saving \(what) failed: \(error)", category: "game")
        }
    }
}
#endif
