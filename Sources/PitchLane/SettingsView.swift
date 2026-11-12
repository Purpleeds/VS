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
