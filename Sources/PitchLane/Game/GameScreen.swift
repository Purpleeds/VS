#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

/// Resolves a game route to its song and the current game options, then shows the game.
struct GameScreen: View {
    let route: GameRoute
    /// Starts another run of this song with a practice plan (from the results screen).
    var onPractice: ((GamePlan) -> Void)?

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
                     lyrics: LyricRomanizer.display(for: song, mode: settings.settings.romanizedLyrics), options: GameOptions(
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
                transpose: plan.transpose,
                haptics: settings.settings.haptics
            ), onPractice: practiceHandler(plan))
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

    /// The same difficulty and key, with `practice` instead of the current plan's options.
    private func practiceHandler(_ plan: GamePlan) -> ((PracticeOptions) -> Void)? {
        guard let onPractice else { return nil }
        return { practice in
            onPractice(GamePlan(difficulty: plan.difficulty, transpose: plan.transpose, practice: practice))
        }
    }
}
#endif
