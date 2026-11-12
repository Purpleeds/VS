#if canImport(SwiftUI)
import QuartzCore
import SwiftUI
import PitchLaneCore

/// The landscape game screen.
struct GameView: View {
    let song: Song
    let backingURL: URL?
    let options: GameOptions

    @StateObject private var session: GameSession
    @EnvironmentObject private var audio: AudioInput
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var scores: ScoreStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = false
    @State private var showRouteWarning = true

    init(song: Song, backingURL: URL?, options: GameOptions) {
        self.song = song
        self.backingURL = backingURL
        self.options = options
        _session = StateObject(wrappedValue: GameSession(song: song, options: options))
    }

    var body: some View {
        ZStack {
            Theme.lane.ignoresSafeArea()
            if let result = session.result {
                ResultsView(session: session, result: result, accidentals: settings.settings.accidentals) {
                    session.restart()
                } onDone: {
                    dismiss()
                }
            } else if let problem = audioProblem {
                AudioProblemView(message: problem, onRetry: { Task { await audio.retry() } }, onQuit: { dismiss() })
            } else {
                lane
                GameHUD(session: session) { session.pause(reason: "pause button") }
                if showRouteWarning, let warning = routeWarning {
                    RouteWarningBanner(text: warning) { showRouteWarning = false }
                }
                if session.phase == .paused {
                    PauseMenu(
                        session: session,
                        onResume: { session.resume() },
                        onRestart: { session.restart() },
                        onQuit: { dismiss() }
                    )
                }
            }
        }
        .lockOrientation(.landscape)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            await audio.acquire("game")
            if audio.state == .running, !started {
                started = true
                session.begin(audio: audio, scores: scores, backingURL: backingURL)
            }
        }
        .onChange(of: audio.state) { _, state in
            switch state {
            case .running where !started:
                started = true
                session.begin(audio: audio, scores: scores, backingURL: backingURL)
            case .running:
                break
            default:
                session.pause(reason: "audio \(state)")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.pause(reason: "app \(phase == .background ? "backgrounded" : "inactive")") }
        }
        .onChange(of: audio.routeKind) { _, _ in
            showRouteWarning = true
        }
        .task(id: showRouteWarning) {
            guard showRouteWarning else { return }
            if let warning = routeWarning {
                AppLog.info("Route warning shown: \(warning)", category: "game")
            }
            try? await Task.sleep(for: .seconds(8))
            showRouteWarning = false
        }
        .onDisappear {
            session.end()
            audio.release("game")
        }
    }

    private var routeWarning: String? {
        switch audio.routeKind {
        case .speaker:
            return "Headphones work best: on the speaker, the guide tone and backing leak into the mic and can be scored as your voice."
        case .bluetooth:
            let calibrated = audio.latencyStore.profiles[.bluetooth].isCalibrated
            return "Bluetooth adds delay\(calibrated ? "" : ". Calibrate in Settings > Latency for this route") (wired headphones are tighter)."
        case .wired, .other:
            return nil
        }
    }

    private var audioProblem: String? {
        switch audio.state {
        case .permissionDenied: return "Microphone access is off. Turn it on in Settings > PitchLane to play."
        case .failed(let message): return "The microphone couldn't start: \(message)"
        default: return nil
        }
    }

    private var lane: some View {
        TimelineView(.animation(minimumInterval: nil, paused: session.phase == .paused || session.phase == .finished)) { _ in
            Canvas { context, size in
                MainActor.assumeIsolated {
                    let host = CACurrentMediaTime()
                    let t = session.renderTick(host: host)
                    LaneRenderer.draw(
                        &context,
                        size: size,
                        session: session,
                        songTime: t,
                        host: host,
                        accidentals: settings.settings.accidentals,
                        showNoteNames: options.showNoteNames
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct GameHUD: View {
    @ObservedObject var session: GameSession
    let onPause: () -> Void

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(session.score)")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: session.score)
                    Text(String(format: "%.0f%%", session.accuracy * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                VStack(spacing: 2) {
                    Text(session.song.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if session.combo > 1 {
                        HStack(spacing: 6) {
                            Text("\(session.combo) combo")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                            if session.multiplier > 1 {
                                Text("×\(session.multiplier)")
                                    .font(.headline.weight(.heavy))
                                    .foregroundStyle(Theme.lane)
                                    .padding(.horizontal, 6)
                                    .background(Theme.gold, in: Capsule())
                            }
                        }
                        .transition(.opacity)
                    }
                }
                Spacer()
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(Theme.surface.opacity(0.8), in: Circle())
                }
                .accessibilityLabel("Pause")
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            Spacer()
        }
    }
}

struct PauseMenu: View {
    @ObservedObject var session: GameSession
    let onResume: () -> Void
    let onRestart: () -> Void
    let onQuit: () -> Void

    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            HStack(alignment: .top, spacing: 28) {
                VStack(spacing: 14) {
                    Text("Paused")
                        .font(.largeTitle.weight(.heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Button(action: onResume) {
                        Label("Resume", systemImage: "play.fill").frame(width: 190)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(action: onRestart) {
                        Label("Restart", systemImage: "arrow.counterclockwise").frame(width: 190)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive, action: onQuit) {
                        Label("Quit", systemImage: "xmark").frame(width: 190)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Guide tone", isOn: Binding(
                        get: { session.guideOn },
                        set: { on in
                            session.setGuide(on)
                            settings.settings.setGuide(on, for: session.options.difficulty)
                        }
                    ))
                    VolumeSlider(title: "Guide volume", symbol: "tuningfork", value: Binding(
                        get: { settings.settings.guideVolume },
                        set: { value in
                            settings.settings.guideVolume = value
                            session.setGuideVolume(value)
                        }
                    ))
                    .disabled(!session.guideOn)
                    if session.hasBacking {
                        VolumeSlider(title: "Backing volume", symbol: "music.note", value: Binding(
                            get: { settings.settings.backingVolume },
                            set: { value in
                                settings.settings.backingVolume = value
                                session.setBackingVolume(value)
                            }
                        ))
                    }
                }
                .frame(width: 240)
                .foregroundStyle(Theme.textPrimary)
            }
            .padding(26)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

struct VolumeSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text("\(Int((value * 100).rounded()))%").monospacedDigit()
            }
            .font(.subheadline)
            Slider(value: $value, in: 0...1)
        }
    }
}

struct RouteWarningBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "headphones")
                Text(text)
                    .font(.footnote.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Button("OK", action: onDismiss)
                    .font(.footnote.weight(.bold))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.surfaceHighlight.opacity(0.95), in: Capsule())
            .frame(maxWidth: 640)
            .padding(.bottom, 10)
        }
    }
}

struct AudioProblemView: View {
    let message: String
    let onRetry: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accentSecondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: 420)
            HStack {
                Button("Try again", action: onRetry).buttonStyle(.borderedProminent)
                Button("Back", action: onQuit).buttonStyle(.bordered)
            }
        }
        .padding(24)
    }
}

struct ResultsView: View {
    @ObservedObject var session: GameSession
    let result: GameResult
    let accidentals: Accidentals
    let onAgain: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(result.grade.rawValue)
                        .font(.system(size: 72, weight: .black, design: .rounded))
                        .foregroundStyle(gradeColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(result.score)")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(String(format: "%.1f", result.accuracy * 100))% accuracy · combo \(result.maxCombo)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if session.isNewBest {
                    Label("New personal best!", systemImage: "star.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.gold)
                } else if let best = session.previousBest {
                    Text("Personal best: \(best.score) (\(best.grade.rawValue))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("\(session.song.title) · \(result.difficulty.displayName)\(result.octaveAgnostic ? " · any octave" : "")")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 12) {
                    ForEach(NoteRating.allCases, id: \.self) { rating in
                        VStack(spacing: 2) {
                            Text("\(result.counts[rating, default: 0])")
                                .font(.title3.weight(.bold).monospacedDigit())
                                .foregroundStyle(rating.color)
                            Text(rating.displayName)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Button(action: onAgain) {
                        Label("Sing again", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Done", action: onDone)
                        .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: 360, alignment: .leading)
            ReplayGraph(session: session, accidentals: accidentals)
        }
        .padding(20)
    }

    private var gradeColor: Color {
        switch result.grade {
        case .s: return Theme.gold
        case .a: return Theme.good
        case .b: return Theme.accent
        case .c: return Theme.warn
        case .d, .f: return Theme.bad
        }
    }
}

/// The whole song: target notes tinted by rating, with the sung pitch drawn over them.
struct ReplayGraph: View {
    @ObservedObject var session: GameSession
    let accidentals: Accidentals

    var body: some View {
        Canvas { context, size in
            MainActor.assumeIsolated {
                draw(&context, size: size)
            }
        }
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("Replay of your pitch over the song")
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let song = session.song
        let range = session.viewport.fullRange
        let span = max(1, range.upperBound - range.lowerBound)
        let duration = max(1, song.duration)
        let inset: CGFloat = 30
        func x(_ t: Double) -> CGFloat { inset + (size.width - inset - 8) * CGFloat(t / duration) }
        func y(_ m: Double) -> CGFloat { 8 + (size.height - 16) * CGFloat(1 - (min(range.upperBound, max(range.lowerBound, m)) - range.lowerBound) / span) }

        let lowest = Int(range.lowerBound.rounded(.up))
        let highest = Int(range.upperBound.rounded(.down))
        if lowest <= highest {
            for note in lowest...highest where ((note % 12) + 12) % 12 == 0 {
                var line = Path()
                line.move(to: CGPoint(x: inset, y: y(Double(note))))
                line.addLine(to: CGPoint(x: size.width, y: y(Double(note))))
                context.stroke(line, with: .color(Theme.grid.opacity(0.25)), lineWidth: 1)
                context.draw(
                    Text(NoteNaming.name(forMIDINote: note, accidentals: accidentals)).font(.caption2).foregroundStyle(Theme.textSecondary),
                    at: CGPoint(x: 2, y: y(Double(note))),
                    anchor: .leading
                )
            }
        }
        let barHeight = max(3, min(8, (size.height - 16) / CGFloat(span) * 0.6))
        for (index, note) in song.notes.enumerated() {
            var bar = Path()
            bar.move(to: CGPoint(x: x(note.start), y: y(Double(note.pitch))))
            bar.addLine(to: CGPoint(x: max(x(note.start) + 1, x(note.end)), y: y(Double(note.pitch))))
            let color = note.isFreestyle ? Theme.textSecondary.opacity(0.4) : (session.ratings[index]?.color ?? Theme.textSecondary).opacity(0.55)
            context.stroke(bar, with: .color(color), style: StrokeStyle(lineWidth: barHeight, lineCap: .round))
        }
        var sung = Path()
        var penDown = false
        var lastTime = -Double.infinity
        for point in session.replay.points {
            guard let midi = point.midi, point.time >= 0 else {
                penDown = false
                continue
            }
            let p = CGPoint(x: x(point.time), y: y(midi))
            if penDown && point.time - lastTime < 0.06 { sung.addLine(to: p) } else { sung.move(to: p) }
            penDown = true
            lastTime = point.time
        }
        context.stroke(sung, with: .color(Theme.accentSecondary), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}
#endif
