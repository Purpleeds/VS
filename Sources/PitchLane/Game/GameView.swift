#if canImport(SwiftUI)
import QuartzCore
import SwiftUI
import PitchLaneCore

/// The landscape game screen.
struct GameView: View {
    let song: Song
    let backingURL: URL?
    let videoURL: URL?
    let stems: BackingStems?
    let options: GameOptions
    let onPractice: ((PracticeOptions) -> Void)?

    @StateObject private var session: GameSession
    @EnvironmentObject private var audio: AudioInput
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var scores: ScoreStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = false
    @State private var showRouteWarning = true

    init(
        song: Song, backingURL: URL?, videoURL: URL? = nil, stems: BackingStems? = nil, lyrics: LyricDisplay? = nil,
        options: GameOptions, onPractice: ((PracticeOptions) -> Void)? = nil
    ) {
        self.onPractice = onPractice
        self.song = song
        self.backingURL = backingURL
        self.videoURL = videoURL
        self.stems = stems
        self.options = options
        _session = StateObject(wrappedValue: GameSession(song: song, options: options, lyrics: lyrics))
    }

    var body: some View {
        ZStack {
            Theme.lane.ignoresSafeArea()
            if let result = session.result {
                ResultsView(
                    session: session,
                    result: result,
                    accidentals: settings.settings.accidentals,
                    onAgain: {
                        Task {
                            await audio.acquire("game")
                            session.restart()
                        }
                    },
                    onDone: { dismiss() },
                    onPractice: onPractice
                )
            } else if audio.state == .permissionDenied {
                // Same explanation + Settings link as the other mic screens.
                MicrophonePermissionView(onBack: { dismiss() })
            } else if case .failed(let message) = audio.state {
                AudioFailedView(message: message, retry: { Task { await audio.retry() } }, onBack: { dismiss() })
            } else {
                if let videoURL {
                    VideoBackdrop(url: videoURL, session: session)
                }
                lane
                GameHUD(session: session) { session.pause(reason: "pause button") }
                if settings.settings.showFPS {
                    FPSBadge()
                }
                if let problem = session.backingProblem {
                    RouteWarningBanner(text: problem, symbol: "music.note") { session.backingProblem = nil }
                } else if showRouteWarning, let warning = routeWarning {
                    RouteWarningBanner(text: warning) { showRouteWarning = false }
                }
                if session.phase == .paused {
                    PauseMenu(
                        session: session,
                        audioReady: audio.state == .running,
                        onResume: { _ = session.resume() },
                        onRestart: { session.restart() },
                        onQuit: { dismiss() }
                    )
                }
            }
        }
        .lockOrientation(.landscape)
        .toolbar(.hidden, for: .navigationBar)
        // No swipe-back mid-song: leaving goes through Pause > Quit or the results screen.
        .navigationBarBackButtonHidden(true)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            await audio.acquire("game")
            if Task.isCancelled {
                audio.release("game")
                return
            }
            if audio.state == .running, !started {
                started = true
                session.begin(audio: audio, scores: scores, backingURL: backingURL, stems: stems)
            }
        }
        .onChange(of: audio.state) { _, state in
            switch state {
            case .running where !started:
                started = true
                session.begin(audio: audio, scores: scores, backingURL: backingURL, stems: stems)
            case .running:
                break
            default:
                session.pause(reason: "audio \(state)")
            }
        }
        .onChange(of: session.result != nil) { _, showingResults in
            // The microphone isn't needed on the results screen: let the recording indicator go away.
            if showingResults { audio.release("game") }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.pause(reason: "app \(phase == .background ? "backgrounded" : "inactive")") }
        }
        .onChange(of: audio.routeKind) { _, _ in
            showRouteWarning = true
        }
        .task(id: session.backingProblem) {
            guard session.backingProblem != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            session.backingProblem = nil
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
                        showNoteNames: options.showNoteNames,
                        videoBehind: videoURL != nil,
                        reduceMotion: reduceMotion
                    )
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("Note lane")
        .accessibilityValue("Score \(session.score), accuracy \(Int((session.accuracy * 100).rounded())) percent")
    }
}

struct GameHUD: View {
    @ObservedObject var session: GameSession
    let onPause: () -> Void

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("\(session.score)")
                            .accessibilityLabel("Score \(session.score)")
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                            .shadow(color: Theme.accent.opacity(0.45), radius: 6)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: session.score)
                        if !session.results.isEmpty {
                            GradeBadge(grade: Grade(accuracy: session.accuracy), size: 24)
                                .accessibilityLabel("Grade so far \(Grade(accuracy: session.accuracy).rawValue)")
                        }
                    }
                    Text(String(format: "%.0f%% accuracy", session.accuracy * 100))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    if session.showsHealth {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(session.health > 0.25 ? Theme.gold : Theme.bad)
                            EnergyBar(value: session.health)
                                .frame(width: 104, height: 7)
                        }
                        .padding(.top, 1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                Spacer()
                VStack(spacing: 2) {
                    Text(session.song.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if session.options.practice.isPractice {
                        Text(practiceLine)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.gold)
                    }
                    if let last = session.loopPasses.last {
                        Text("Pass \(session.loopPasses.count + 1) · last \(Int((last * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.accent)
                    }
                    if session.combo > 1 {
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill")
                                .foregroundStyle(session.combo >= 25 ? Theme.gold : Theme.accentSecondary)
                                .symbolEffect(.bounce, value: session.combo / 10)
                            Text("\(session.combo)")
                                .font(.title3.weight(.heavy).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                                .contentTransition(.numericText(value: Double(session.combo)))
                                .animation(.snappy, value: session.combo)
                            Text("combo")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                            if session.multiplier > 1 {
                                Text("×\(session.multiplier)")
                                    .font(.headline.weight(.heavy))
                                    .foregroundStyle(Theme.lane)
                                    .padding(.horizontal, 7)
                                    .background(Theme.gold, in: Capsule())
                                    .id(session.multiplier)
                                    .transition(.scale(scale: 1.8).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.gold.opacity(session.multiplier > 1 ? 0.7 : 0.12), lineWidth: 1.5))
                        .shadow(color: Theme.gold.opacity(session.multiplier > 1 ? 0.45 : 0), radius: 10)
                        .animation(.spring(response: 0.35, dampingFraction: 0.5), value: session.multiplier)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityElement(children: .combine)
                    }
                }
                Spacer()
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                }
                .accessibilityLabel("Pause")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            Spacer()
        }
    }

    private var practiceLine: String {
        let practice = session.options.practice
        var parts = ["PRACTICE"]
        if practice.speed < 0.999 { parts.append(practice.speedText) }
        if practice.loop != nil { parts.append("LOOP") }
        if practice.noFail { parts.append("NO-FAIL") }
        return parts.joined(separator: " · ")
    }
}

struct EnergyBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            let color = value > 0.5 ? Theme.good : (value > 0.25 ? Theme.warn : Theme.bad)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface)
                Capsule()
                    .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.35), color], startPoint: .top, endPoint: .bottom))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, value))))
                    .shadow(color: color.opacity(0.6), radius: 4)
                    .animation(.easeOut(duration: 0.2), value: value)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Energy")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

/// Frame-rate counter for the game screen (Settings > Show FPS).
struct FPSBadge: View {
    @EnvironmentObject private var diagnostics: AudioDiagnostics

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(diagnostics.snapshot.gameFPS.map { String(format: "%.0f fps", $0) } ?? "– fps")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.5), in: Capsule())
                    .padding(8)
            }
        }
        .allowsHitTesting(false)
    }
}

struct PauseMenu: View {
    @ObservedObject var session: GameSession
    /// Resume needs a running engine (after a call or a route change it can take a moment to come back).
    let audioReady: Bool
    let onResume: () -> Void
    let onRestart: () -> Void
    let onQuit: () -> Void

    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            CenteredScroll { card }
        }
        .accessibilityAddTraits(.isModal)
    }

    private var card: some View {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) { buttons; controls }
                VStack(spacing: 20) { buttons; controls }
            }
            .padding(26)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(12)
    }

    private var buttons: some View {
                VStack(spacing: 14) {
                    Text("Paused")
                        .font(.largeTitle.weight(.heavy))
                        .foregroundStyle(Theme.textPrimary)
                    Button(action: onResume) {
                        Label("RESUME", systemImage: "play.fill").frame(minWidth: 190)
                    }
                    .buttonStyle(ChunkyButtonStyle(color: Theme.accent, height: 50))
                    .disabled(!audioReady)
                    if !audioReady {
                        Text("Waiting for audio…")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Button(action: onRestart) {
                        Label("Restart", systemImage: "arrow.counterclockwise").frame(minWidth: 190)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!audioReady)
                    Button(role: .destructive, action: onQuit) {
                        Label("Quit", systemImage: "xmark").frame(minWidth: 190)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
    }

    private var controls: some View {
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
                    if session.hasStems {
                        VolumeSlider(title: "Singer's voice", symbol: "music.mic", value: Binding(
                            get: { settings.settings.voiceStemVolume },
                            set: { value in
                                settings.settings.voiceStemVolume = value
                                session.setStemVolumes(voice: value, music: settings.settings.musicStemVolume)
                            }
                        ))
                        VolumeSlider(title: "Music", symbol: "guitars", value: Binding(
                            get: { settings.settings.musicStemVolume },
                            set: { value in
                                settings.settings.musicStemVolume = value
                                session.setStemVolumes(voice: settings.settings.voiceStemVolume, music: value)
                            }
                        ))
                    } else if session.hasBacking {
                        VolumeSlider(title: "Backing volume", symbol: "music.note", value: Binding(
                            get: { settings.settings.backingVolume },
                            set: { value in
                                settings.settings.backingVolume = value
                                session.setBackingVolume(value)
                            }
                        ))
                    }
                }
                .frame(minWidth: 220, maxWidth: 280)
                .foregroundStyle(Theme.textPrimary)
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
    var symbol = "headphones"
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: symbol)
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

struct ResultsView: View {
    @ObservedObject var session: GameSession
    let result: GameResult
    let accidentals: Accidentals
    let onAgain: () -> Void
    let onDone: () -> Void
    /// Starts a practice run of a line (nil = not offered).
    var onPractice: ((PracticeOptions) -> Void)?
    @ScaledMetric(relativeTo: .largeTitle) private var gradeSize: CGFloat = 72
    @State private var revealed = false
    @State private var shownScore = 0
    @State private var toughest: LineReport.Line?

    /// Confetti for a great run.
    private var celebrates: Bool { !result.failed && (result.grade == .s || result.grade == .a || session.isNewBest) }

    var body: some View {
        HStack(spacing: 20) {
            // Scrolls at large text sizes so "Sing again" / "Done" are always reachable in landscape.
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(result.grade.rawValue)
                        .font(.system(size: gradeSize, weight: .black, design: .rounded))
                        .foregroundStyle(gradeColor)
                        .shadow(color: gradeColor.opacity(0.6), radius: revealed ? 18 : 0)
                        .scaleEffect(revealed ? 1 : 0.2)
                        .rotationEffect(.degrees(revealed ? 0 : -25))
                        .opacity(revealed ? 1 : 0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(shownScore)")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textPrimary)
                            .contentTransition(.numericText(value: Double(shownScore)))
                            .accessibilityLabel("Score \(result.score)")
                        Text("\(String(format: "%.1f", result.accuracy * 100))% accuracy · combo \(result.maxCombo)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if result.failed {
                    Label("Out of energy: the song ended early", systemImage: "bolt.slash.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.bad)
                } else if session.options.practice.isPractice {
                    Label("Practice run (not counted for bests)", systemImage: "figure.mind.and.body")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gold)
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
                if !session.newBadges.isEmpty {
                    newBadges
                }
                if let line = toughest, let onPractice {
                    toughestLine(line, onPractice: onPractice)
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
                        Label("AGAIN", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(ChunkyButtonStyle(color: Theme.accent, height: 50))
                    Button(action: onDone) {
                        Text("DONE")
                    }
                    .buttonStyle(ChunkyButtonStyle(color: Theme.surfaceHighlight, textColor: Theme.textPrimary, height: 50))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: 360)
            ReplayGraph(session: session, accidentals: accidentals)
        }
        .padding(20)
        .overlay {
            if celebrates { ConfettiView().allowsHitTesting(false).ignoresSafeArea() }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.55).delay(0.1)) { revealed = true }
            withAnimation(.easeOut(duration: 1.2).delay(0.25)) { shownScore = result.score }
            // Full runs only: a loop's results cover just that section.
            if session.options.practice.loop == nil {
                toughest = LineReport(song: session.song, results: session.results).toughest
            }
        }
    }

    private var newBadges: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.newBadges.count == 1 ? "NEW BADGE" : "NEW BADGES")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .tracking(2)
                .foregroundStyle(Theme.gold)
            ForEach(session.newBadges) { badge in
                HStack(spacing: 10) {
                    BadgeCoin(badge: badge, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(badge.title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(badge.detail)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private func toughestLine(_ line: LineReport.Line, onPractice: @escaping (PracticeOptions) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TOUGHEST LINE")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .tracking(2)
                .foregroundStyle(Theme.accentSecondary)
            Text(line.text.isEmpty ? "\(Self.clock(line.start)) to \(Self.clock(line.end))" : "\u{201C}\(line.text)\u{201D}")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            Text("\(Int((line.accuracy * 100).rounded()))% on this line. Loop it at 80% speed, no failing.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Button {
                AppLog.info("Practising the toughest line (\(Int((line.accuracy * 100).rounded())) %)", category: "game")
                onPractice(LineReport.practice(for: line))
            } label: {
                Label("PRACTICE THIS LINE", systemImage: "repeat")
            }
            .buttonStyle(ChunkyButtonStyle(color: Theme.violet, height: 42))
        }
        .padding(12)
        .background(Theme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
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
        .accessibilityElement()
        .accessibilityLabel("Replay of your pitch over the song")
        .accessibilityValue("\(Int((session.result?.accuracy ?? session.accuracy) * 100)) percent accuracy")
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
/// A few seconds of confetti falling across the results screen (Core `ParticleField`, drawn in one Canvas).
struct ConfettiView: View {
    @State private var start = CACurrentMediaTime()
    @State private var done = false
    @State private var field: ParticleField = {
        var field = ParticleField(capacity: 160, gravity: 170, seed: 42)
        for column in 0..<16 {
            field.emit(count: 10, time: Double(column) / 15, midi: 0, now: Double(column % 4) * 0.12, kind: .confetti,
                       angle: .pi / 2, spread: 1.6, speed: 90, life: 3.2, size: 4)
        }
        return field
    }()

    private static let colors = [Theme.accent, Theme.accentSecondary, Theme.gold, Theme.good, Theme.violet]

    var body: some View {
        let field = self.field
        let start = self.start
        let colors = Self.colors
        Group {
            if !done {
                TimelineView(.animation(minimumInterval: 1.0 / 60)) { _ in
                    Canvas { context, size in
                        let now = CACurrentMediaTime() - start
                        field.forEachLive(at: now) { particle, age, remaining in
                            let offset = field.offset(of: particle, age: age)
                            let x = CGFloat(particle.originTime) * size.width + CGFloat(offset.dx)
                            let y = -12 + CGFloat(offset.dy)
                            let spin = CGFloat(sin(age * 9 + particle.hue * 6))
                            let w = CGFloat(particle.size) * 1.6
                            let h = CGFloat(particle.size) * max(0.3, abs(spin))
                            let color = colors[min(colors.count - 1, Int(particle.hue * Double(colors.count)))]
                            context.fill(Path(CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)), with: .color(color.opacity(min(1, remaining * 2))))
                        }
                    }
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(4))
            done = true
        }
        .accessibilityHidden(true)
    }
}
#endif
