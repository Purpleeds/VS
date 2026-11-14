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
        if let base = library.song(withID: route.songID) {
            let plan = route.plan
            let song = base.transposed(by: plan.transpose)
            GameView(song: song, backingURL: library.backingAudioURL(for: base),
                     videoURL: settings.settings.showVideo ? library.videoURL(for: base) : nil,
                     stems: library.stems(for: base),
                     lyrics: JapaneseText.display(for: song, mode: settings.settings.japaneseLyrics), options: GameOptions(
                difficulty: plan.difficulty,
                octaveAgnostic: settings.settings.octaveAgnostic,
                clickTrack: settings.settings.clickTrack,
                showNoteNames: settings.settings.showNoteNames,
                guideTone: settings.settings.guideEnabled(for: plan.difficulty),
                guideVolume: settings.settings.guideVolume,
                backingVolume: settings.settings.backingVolume,
                voiceStemVolume: settings.settings.voiceStemVolume,
                musicStemVolume: settings.settings.musicStemVolume,
                practice: plan.practice,
                failEnabled: settings.settings.failEnabled,
                transpose: plan.transpose
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
