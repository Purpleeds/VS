#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

struct SettingsView: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        let build = BuildInfo.current
        List {
            Section("About") {
                LabeledContent("Version", value: build.version)
                LabeledContent("Build", value: build.build)
            }
            Section("Notes") {
                Picker("Note names", selection: $model.settings.accidentals) {
                    Text("Sharps (C♯, F♯)").tag(Accidentals.sharps)
                    Text("Flats (D♭, G♭)").tag(Accidentals.flats)
                }
            }
            Section {
                Toggle("Any octave counts", isOn: $model.settings.octaveAgnostic)
                Toggle("Click track", isOn: $model.settings.clickTrack)
                Toggle("Note names on notes", isOn: $model.settings.showNoteNames)
            } header: {
                Text("Game")
            } footer: {
                Text("Any octave counts lets low and high voices sing every song. The click track is easiest to follow with headphones.")
            }
            Section("Developer") {
                Toggle("Debug overlay", isOn: $model.settings.debugOverlay)
                NavigationLink(value: Route.logs) {
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
