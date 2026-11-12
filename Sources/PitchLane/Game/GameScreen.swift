#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

/// Resolves a game route to its song and the current game options, then shows the game.
struct GameScreen: View {
    let route: GameRoute

    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let song = library.song(withID: route.songID) {
            GameView(song: song, options: GameOptions(
                difficulty: route.difficulty,
                octaveAgnostic: settings.settings.octaveAgnostic,
                clickTrack: settings.settings.clickTrack,
                showNoteNames: settings.settings.showNoteNames
            ))
        } else {
            VStack(spacing: 12) {
                Text("This song is no longer in the library.")
                    .foregroundStyle(Theme.textSecondary)
                Button("Back") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .onAppear {
                AppLog.warning("Game route for missing song \(route.songID)", category: "game")
            }
        }
    }
}
#endif
