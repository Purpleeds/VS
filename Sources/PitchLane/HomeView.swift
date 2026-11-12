#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

enum Route: Hashable {
    case play, library, tuner, settings, logs

    var name: String {
        switch self {
        case .play: return "play"
        case .library: return "library"
        case .tuner: return "tuner"
        case .settings: return "settings"
        case .logs: return "logs"
        }
    }
}

struct HomeView: View {
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 28) {
                        VStack(spacing: 6) {
                            Image(systemName: "waveform")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            Text("PitchLane")
                                .font(.system(size: 40, weight: .heavy, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Sing the line.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        VStack(spacing: 12) {
                            menuButton("Play", symbol: "play.fill", route: .play, prominent: true)
                            menuButton("Library", symbol: "books.vertical", route: .library)
                            menuButton("Tuner", symbol: "tuningfork", route: .tuner)
                            menuButton("Settings", symbol: "gearshape", route: .settings)
                        }
                        .frame(maxWidth: 360)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
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
                case .play: PlayView()
                case .library: LibraryView()
                case .tuner: TunerView()
                case .settings: SettingsView()
                case .logs: LogsView()
                }
            }
        }
        .tint(Theme.accent)
        .onChange(of: path) { _, newPath in
            AppLog.info("Navigation: \(newPath.map(\.name).joined(separator: " > "))", category: "ui")
        }
    }

    private func menuButton(_ title: String, symbol: String, route: Route, prominent: Bool = false) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(prominent ? Theme.background : Theme.textPrimary)
            .background(
                prominent ? Theme.accent : Theme.surface,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
    }
}
#endif
