#if canImport(SwiftUI)
import QuartzCore
import SwiftUI
import UIKit
import PitchLaneCore

/// Runs one calibration pass: count-in + measured beeps from the guide voice on the output clock, mic levels
/// mapped onto the song clock exactly like gameplay frames (but without the current correction).
@MainActor
final class CalibrationSession: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case finished(CalibrationResult?)
    }

    static let countIn = 4
    static let measured = 8
    static let interval = 0.6

    @Published private(set) var state: State = .idle
    let beeps: [Double]
    let measuredBeeps: [Double]
    private let song: Song
    private var timebase: SongTimebase?
    private var levels: [LatencyCalibrator.Level] = []
    private var finishTask: Task<Void, Never>?
    private weak var audio: AudioInput?
    /// The route the last run measured; a result is saved for this route, even if the output changed since.
    private(set) var route: AudioRouteKind = .other

    init() {
        beeps = LatencyCalibrator.beepTimes(count: Self.countIn + Self.measured, interval: Self.interval)
        measuredBeeps = Array(beeps.dropFirst(Self.countIn))
        let notes = beeps.enumerated().map { index, time in
            SongNote(start: time, duration: 0.06, pitch: index < Self.countIn ? 84 : 91)
        }
        song = Song(id: "calibration", title: "Calibration", source: .builtIn, notes: notes)
    }

    func start(audio: AudioInput) {
        self.audio = audio
        route = audio.routeKind
        levels = []
        let timebase = SongTimebase(audio: audio, songDuration: song.duration, leadIn: 1)
        self.timebase = timebase
        audio.installGuide(GuideToneRenderer(song: song, envelope: .percussive))
        audio.setGuideVolume(0.9)
        audio.addFrameListener("calibration") { [weak self] batch, arrival in
            self?.receive(batch, arrival: arrival)
        }
        // A restart mid-run changes the clock and route: the measurement would be meaningless.
        audio.addEngineStopListener("calibration") { [weak self] in
            guard self?.state == .running else { return }
            AppLog.warning("Calibration cancelled: audio engine stopped", category: "latency")
            self?.cancel()
        }
        state = .running
        AppLog.info("Calibration started on \(route.rawValue): \(Self.countIn) count-in + \(Self.measured) beeps every \(Self.interval) s", category: "latency")
        finishTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            // Wait for the output clock, then for the last beep to pass.
            for _ in 0..<100 {
                if timebase.start() { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .seconds(1 + (self?.song.duration ?? 7) + 0.8))
            self?.finish()
        }
    }

    func cancel() {
        finishTask?.cancel()
        tearDown()
        if state == .running { state = .idle }
    }

    /// Back to the start button (after saving a result).
    func reset() {
        cancel()
        state = .idle
    }

    /// Song time the player hears now (for the beat indicator).
    func heardTime(atHost host: Double) -> Double? {
        guard state == .running, let timebase, timebase.isStarted else { return nil }
        return timebase.heardSongTime(atHost: host)
    }

    private func receive(_ batch: PitchAnalyzer.Batch, arrival: Double) {
        guard let timebase else { return }
        timebase.observe(batch, arrival: arrival)
        for frame in batch.frames {
            if let t = timebase.songTime(forFrameAt: frame.time, applyCorrection: false) {
                levels.append(.init(time: t, dBFS: frame.levelDBFS))
            }
        }
    }

    private func finish() {
        guard state == .running else { return }
        let bias = LatencyCalibrator.onsetBias(
            windowDuration: Double(PitchDetectorConfiguration.voice.frameLength) / PitchDetectorConfiguration.voice.sampleRate,
            hop: 0.01
        )
        let result = LatencyCalibrator.estimate(beeps: measuredBeeps, levels: levels.sorted { $0.time < $1.time }, onsetBias: bias)
        tearDown()
        state = .finished(result)
        if let result {
            AppLog.info(
                "Calibration \(route.rawValue): offset \(String(format: "%.1f", result.offsetMs)) ms, matched \(result.matchedBeats)/\(result.totalBeats), "
                    + "spread \(String(format: "%.1f", result.spreadMs)) ms, reliable \(result.isReliable), per beat "
                    + result.perBeatMs.map { String(format: "%.0f", $0) }.joined(separator: ","),
                category: "latency"
            )
        } else {
            AppLog.warning("Calibration \(route.rawValue): no onsets detected (\(levels.count) frames)", category: "latency")
        }
    }

    private func tearDown() {
        audio?.removeFrameListener("calibration")
        audio?.removeEngineStopListener("calibration")
        timebase?.stop()
        audio?.installGuide(nil)
    }
}

struct CalibrationView: View {
    @EnvironmentObject private var audio: AudioInput
    @EnvironmentObject private var latency: LatencyStore
    @Environment(\.openURL) private var openURL
    @StateObject private var session = CalibrationSession()
    @State private var savedRoute: AudioRouteKind?
    @State private var starting = false

    var body: some View {
        let route = audio.routeKind
        let profile = latency.profiles[route]
        let estimate = audio.latency
        List {
            Section {
                LabeledContent("Output", value: route.displayName)
                LabeledContent("System input latency", value: "\(Int((estimate.input * 1_000).rounded())) ms")
                LabeledContent("System output latency", value: "\(Int((estimate.output * 1_000).rounded())) ms")
                LabeledContent("Calibration", value: profile.calibrationMs.map { "\(Int($0.rounded())) ms" } ?? "Not calibrated")
                Stepper(value: Binding(
                    get: { profile.nudgeMs },
                    set: { latency.setNudge($0, for: route) }
                ), in: -300...300, step: 5) {
                    LabeledContent("Fine-tune", value: "\(profile.nudgeMs >= 0 ? "+" : "")\(Int(profile.nudgeMs)) ms")
                }
            } header: {
                Text("Current route")
            } footer: {
                Text(routeAdvice(route))
            }

            Section {
                Text("After four count-in beeps, clap or sing a short \"ta\" exactly on each of the next eight beeps. On the speaker you can also stay silent: the mic hears the beeps themselves.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                CalibrationBeatView(session: session)
                    .frame(height: 44)
                switch session.state {
                case .idle:
                    if let savedRoute {
                        Label("Saved for \(savedRoute.displayName)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.good)
                    }
                    micStatus
                    Button("Start calibration", systemImage: "metronome") { begin() }
                        .disabled(starting || audio.state == .permissionDenied)
                case .running:
                    Button("Cancel", role: .cancel) { session.cancel() }
                case .finished(let result):
                    resultView(result, route: session.route)
                }
            } header: {
                Text("Calibrate")
            }

            if profile.isCalibrated || profile.nudgeMs != 0 {
                Section {
                    Button("Reset \(route.displayName)", role: .destructive) { latency.reset(route) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GameBackdrop(intensity: 0.5))
        .navigationTitle("Latency")
        .navigationBarTitleDisplayMode(.inline)
        // The microphone is on only while a calibration runs, not while this screen is just open.
        .onChange(of: session.state) { _, state in
            if state != .running { audio.release("calibration") }
        }
        .onDisappear {
            session.cancel()
            audio.release("calibration")
        }
    }

    @ViewBuilder
    private func resultView(_ result: CalibrationResult?, route: AudioRouteKind) -> some View {
        if let result {
            VStack(alignment: .leading, spacing: 4) {
                Text("Measured \(result.offsetMs >= 0 ? "+" : "")\(Int(result.offsetMs.rounded())) ms")
                    .font(.headline)
                Text("\(result.matchedBeats) of \(result.totalBeats) beats heard · spread \(Int(result.spreadMs.rounded())) ms")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if !result.isReliable {
                    Text("The beats didn't agree well. Try again, a little louder and right on the beep.")
                        .font(.caption)
                        .foregroundStyle(Theme.warn)
                }
            }
            Button("Save for \(route.displayName)", systemImage: "checkmark") {
                latency.setCalibration(result.offsetMs, for: route)
                savedRoute = route
                session.reset()
            }
            .disabled(!result.isReliable)
        } else {
            Text("No claps or beeps were detected. Check the microphone and try again a little louder.")
                .font(.footnote)
                .foregroundStyle(Theme.warn)
        }
        Button("Try again", systemImage: "arrow.counterclockwise") { begin() }
    }

    @ViewBuilder
    private var micStatus: some View {
        switch audio.state {
        case .permissionDenied:
            VStack(alignment: .leading, spacing: 6) {
                Text("Microphone access is off, so PitchLane can't hear the beeps. Turn on Microphone for PitchLane in Settings.")
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
                Button("Open Settings", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .failed(let message):
            Text("The microphone couldn't start: \(message). Tap Start to try again.")
                .font(.footnote)
                .foregroundStyle(Theme.warn)
        default:
            EmptyView()
        }
    }

    private func begin() {
        savedRoute = nil
        starting = true
        Task {
            defer { starting = false }
            if case .failed = audio.state {
                await audio.acquire("calibration")
                await audio.retry()
            } else {
                await audio.acquire("calibration")
            }
            // Wait briefly for the engine (first start, or right after a route change).
            for _ in 0..<50 where audio.state != .running {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard audio.state == .running else {
                AppLog.warning("Calibration couldn't start: audio \(audio.state)", category: "latency")
                audio.release("calibration")
                return
            }
            session.start(audio: audio)
        }
    }

    private func routeAdvice(_ route: AudioRouteKind) -> String {
        switch route {
        case .speaker: return "Headphones work best: on the speaker the guide and backing leak into the mic."
        case .bluetooth: return "Bluetooth adds a lot of delay that varies by device. Calibrate each time you switch earbuds."
        case .wired: return "Wired headphones have the lowest, steadiest delay."
        case .other: return "Calibrate to line up your voice with the notes on this output."
        }
    }
}

/// Twelve dots lighting up with the beeps the player hears.
struct CalibrationBeatView: View {
    @ObservedObject var session: CalibrationSession

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: session.state != .running)) { _ in
            let heard = session.heardTime(atHost: CACurrentMediaTime())
            HStack(spacing: 8) {
                ForEach(Array(session.beeps.enumerated()), id: \.offset) { index, beep in
                    let isCountIn = index < CalibrationSession.countIn
                    let lit = heard.map { $0 >= beep && $0 < beep + 0.25 } ?? false
                    let past = heard.map { $0 >= beep } ?? false
                    Circle()
                        .fill(lit ? (isCountIn ? Theme.textPrimary : Theme.accent) : (past ? Theme.surfaceHighlight : Theme.surface))
                        .frame(width: lit ? 18 : 12, height: lit ? 18 : 12)
                        .overlay(Circle().stroke(isCountIn ? Theme.textSecondary : Theme.accent, lineWidth: 1))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
#endif
