#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

struct GameRoute: Hashable {
    var songID: String
    var plan: GamePlan
}

enum Route: Hashable {
    case play, library, tuner, settings, logs, latency
    case practice, rangeTest, holdDrill, stats
    case songStats(String)
    case game(GameRoute)

    var name: String {
        switch self {
        case .play: return "play"
        case .library: return "library"
        case .tuner: return "tuner"
        case .settings: return "settings"
        case .logs: return "logs"
        case .latency: return "latency"
        case .practice: return "practice"
        case .rangeTest: return "rangeTest"
        case .holdDrill: return "holdDrill"
        case .stats: return "stats"
        case .songStats(let id): return "songStats(\(id))"
        case .game(let route): return "game(\(route.songID), \(route.plan.difficulty.rawValue), shift \(route.plan.transpose), practice \(route.plan.practice.isPractice))"
        }
    }
}

struct HomeView: View {
    @State private var path: [Route] = []
    @EnvironmentObject private var audio: AudioInput
    @EnvironmentObject private var scores: ScoreStore
    @State private var pulse = false

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GameBackdrop()
                ScrollView {
                    VStack(spacing: 22) {
                        header
                        PlayerCard(progress: PlayerProgress(history: scores.history))
                        NavigationLink(value: Route.play) {
                            HStack(spacing: 12) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 22, weight: .black))
                                Text("PLAY")
                                    .tracking(3)
                            }
                        }
                        .buttonStyle(ChunkyButtonStyle(color: Theme.accent, height: 66))
                        .accessibilityLabel("Play")
                        LazyVGrid(columns: columns, spacing: 14) {
                            tile("Library", "Your songs and imports", "books.vertical.fill", Theme.violet, .library)
                            tile("Tuner", "See the note you sing", "tuningfork", Theme.accent, .tuner)
                            tile("Practice", "Range test and hold drill", "target", Theme.accentSecondary, .practice)
                            tile("Stats", "Scores and progress", "chart.line.uptrend.xyaxis", Theme.gold, .stats)
                        }
                        RangeCard { path.append(.rangeTest) }
                        NavigationLink(value: Route.settings) {
                            Label("Settings", systemImage: "gearshape.fill")
                                .font(.system(.subheadline, design: .rounded).weight(.bold))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 18)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(PressableStyle())
                    }
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(BuildInfo.current.buildLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(10)
                    .allowsHitTesting(false)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .play: LibraryView(title: "Choose a Song", onPlay: play)
                case .library: LibraryView(title: "Library", onPlay: play)
                case .game(let route): GameScreen(route: route)
                case .latency: CalibrationView()
                case .practice: PracticeHubView()
                case .rangeTest: RangeTestView()
                case .holdDrill: HoldDrillView()
                case .stats: StatsView()
                case .songStats(let id): SongStatsView(songID: id)
                case .tuner: TunerView()
                case .settings: SettingsView()
                case .logs: LogsView()
                }
            }
        }
        .tint(Theme.accent)
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty { audio.releaseAll(reason: "back on the home screen") }
            AppLog.info("Navigation: \(newPath.map(\.name).joined(separator: " > "))", category: "ui")
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            if let icon = UIImage(named: "AppIcon") {
                // The app icon (Resources/AppIcon.png, copied into the app), gently breathing.
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: Theme.violet.opacity(0.7), radius: pulse ? 22 : 12)
                    .scaleEffect(pulse ? 1.03 : 1)
                    .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: pulse)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(Theme.titleGradient)
                    .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: pulse)
                    .shadow(color: Theme.accent.opacity(0.6), radius: 10)
            }
            NeonTitle(text: "PitchLane")
            Text("SING THE LINE")
                .font(.system(.caption, design: .rounded).weight(.heavy))
                .tracking(4)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 8)
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("PitchLane")
    }

    private func tile(_ title: String, _ detail: String, _ symbol: String, _ color: Color, _ route: Route) -> some View {
        NavigationLink(value: route) {
            GameTile(title: title, detail: detail, symbol: symbol, color: color)
        }
        .buttonStyle(PressableStyle())
    }

    /// Starts a game once the song sheet has finished dismissing.
    private func play(_ song: Song, _ plan: GamePlan) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            path.append(.game(GameRoute(songID: song.id, plan: plan)))
        }
    }
}
#endif
