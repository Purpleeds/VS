#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

private enum ResetKind: Identifiable {
    case settings, range, scores, latency, songs, everything

    var id: Self { self }

    var title: String {
        switch self {
        case .settings: return "Reset settings?"
        case .range: return "Forget your vocal range?"
        case .scores: return "Clear scores and history?"
        case .latency: return "Reset latency calibration?"
        case .songs: return "Delete all imported songs?"
        case .everything: return "Erase everything?"
        }
    }

    var message: String {
        switch self {
        case .settings: return "All preferences go back to their defaults. Your range, song keys, scores and songs are kept."
        case .range: return "Your saved vocal range and per-song key shifts are removed."
        case .scores: return "Personal bests, play history and stats are deleted."
        case .latency: return "Calibration and fine-tuning for every output (speaker, wired, Bluetooth) are removed."
        case .songs: return "Imported songs, their backing audio and their scores are deleted. Built-in songs stay."
        case .everything: return "Settings, range, scores, history, latency calibration, imported songs and the logs are all deleted. This can't be undone."
        }
    }

    var buttonTitle: String {
        switch self {
        case .settings: return "Reset settings"
        case .range: return "Forget range"
        case .scores: return "Clear scores"
        case .latency: return "Reset calibration"
        case .songs: return "Delete songs"
        case .everything: return "Erase everything"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: SettingsModel
    @EnvironmentObject private var scores: ScoreStore
    @EnvironmentObject private var latency: LatencyStore
    @EnvironmentObject private var library: LibraryModel
    @State private var resetKind: ResetKind?

    var body: some View {
        let build = BuildInfo.current
        List {
            Section("About") {
                LabeledContent("Version", value: build.version)
                LabeledContent("Build", value: build.build)
            }

            Section {
                Picker("Difficulty", selection: $model.settings.lastDifficulty) {
                    ForEach(Difficulty.allCases) { level in
                        Text("\(level.displayName) (±\(Int(level.toleranceCents))¢)").tag(level)
                    }
                }
                Toggle("Any octave counts", isOn: $model.settings.octaveAgnostic)
                Toggle("Songs can be failed", isOn: $model.settings.failEnabled)
                Toggle("Click track", isOn: $model.settings.clickTrack)
                Toggle("Song videos behind the lane", isOn: $model.settings.showVideo)
                Toggle("Write lyrics for new songs by listening", isOn: $model.settings.autoLyrics)
                Picker("Japanese, Korean & Chinese lyrics", selection: $model.settings.romanizedLyrics) {
                    ForEach(RomanizedLyricsMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("Play")
            } footer: {
                Text("Difficulty is the on-pitch window. Any octave counts lets low and high voices sing every song. With failing on, too many misses empty the energy bar and end the song; practice runs can be no-fail.")
            }

            Section {
                Picker("Note names", selection: $model.settings.accidentals) {
                    Text("Sharps (C♯, F♯)").tag(Accidentals.sharps)
                    Text("Flats (D♭, G♭)").tag(Accidentals.flats)
                }
                Toggle("Note names on notes", isOn: $model.settings.showNoteNames)
            } header: {
                Text("Notes")
            }

            Section {
                Toggle("Guide tone on Easy & Normal", isOn: $model.settings.guideOnEasyNormal)
                Toggle("Guide tone on Hard", isOn: $model.settings.guideOnHard)
                VolumeSlider(title: "Guide volume", symbol: "tuningfork", value: $model.settings.guideVolume)
                VolumeSlider(title: "Backing volume", symbol: "music.note", value: $model.settings.backingVolume)
                NavigationLink(value: Route.latency) {
                    Label("Latency & calibration", systemImage: "metronome")
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("Headphones work best. On the speaker the guide tone and backing leak into the mic.")
            }

            Section {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label("Noise gate", systemImage: "waveform.badge.minus")
                        Spacer()
                        Text("\(Int(model.settings.noiseGateDBFS)) dBFS").monospacedDigit()
                    }
                    .font(.subheadline)
                    Slider(value: $model.settings.noiseGateDBFS, in: AppSettings.noiseGateRange, step: 1)
                    HStack {
                        Text("More sensitive").font(.caption2)
                        Spacer()
                        Text("Ignores more noise").font(.caption2)
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                Toggle("Instrument mode", isOn: $model.settings.instrumentMode)
            } header: {
                Text("Detection")
            } footer: {
                Text("A lower gate hears quieter notes but may pick up room noise. Instrument mode widens the pitch range to about 40 Hz–2 kHz for trombone, sax, clarinet and similar.")
            }

            Section("Display") {
                Toggle("Show FPS in games", isOn: $model.settings.showFPS)
                Toggle("Debug overlay", isOn: $model.settings.debugOverlay)
            }

            Section {
                Label("Your voice is analysed live on this phone and is never recorded, saved or uploaded.",
                      systemImage: "mic.slash")
                Label("Scores, settings, songs and logs stay on this phone. Logs leave it only if you copy or share them.",
                      systemImage: "lock")
                Label("Voice search, timing lyrics by listening, and separating voice from music all run on the phone; no audio is ever sent anywhere.",
                      systemImage: "waveform")
                Label("Find Lyrics Online sends only the song name you search for to lrclib.net. Nothing else goes online.",
                      systemImage: "network")
                Label("The microphone is only on during the tuner, games, practice, calibration and voice search; the orange dot shows when.",
                      systemImage: "circle.fill")
            } header: {
                Text("Privacy")
            }
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)

            Section("Developer") {
                NavigationLink(value: Route.logs) {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                }
            }

            Section {
                resetButton("Reset settings", .settings)
                resetButton("Forget my vocal range", .range)
                resetButton("Clear scores & history", .scores)
                resetButton("Reset latency calibration", .latency)
                resetButton("Delete imported songs", .songs)
                resetButton("Erase everything", .everything)
            } header: {
                Text("Reset data")
            } footer: {
                Text("Each reset asks for confirmation first.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(GameBackdrop(intensity: 0.5))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            resetKind?.title ?? "",
            isPresented: Binding(get: { resetKind != nil }, set: { if !$0 { resetKind = nil } }),
            titleVisibility: .visible,
            presenting: resetKind
        ) { kind in
            Button(kind.buttonTitle, role: .destructive) { perform(kind) }
        } message: { kind in
            Text(kind.message)
        }
    }

    private func resetButton(_ title: String, _ kind: ResetKind) -> some View {
        Button(title, role: .destructive) { resetKind = kind }
    }

    private func perform(_ kind: ResetKind) {
        AppLog.info("Reset data: \(kind.buttonTitle)", category: "settings")
        switch kind {
        case .settings:
            resetSettings()
        case .range:
            model.settings.vocalRange = nil
            model.settings.songTranspose = [:]
        case .scores:
            scores.resetAll()
        case .latency:
            latency.resetAll()
        case .songs:
            deleteSongs()
        case .everything:
            model.settings = AppSettings()
            scores.resetAll()
            latency.resetAll()
            deleteSongs()
            library.eraseSongStorage()
            AppLog.clear()
        }
    }

    private func resetSettings() {
        var fresh = AppSettings()
        fresh.vocalRange = model.settings.vocalRange
        fresh.songTranspose = model.settings.songTranspose
        model.settings = fresh
    }

    private func deleteSongs() {
        for id in library.deleteAllImported() {
            scores.forget(songID: id)
            model.settings.setTranspose(0, for: id)
        }
    }
}
#endif
