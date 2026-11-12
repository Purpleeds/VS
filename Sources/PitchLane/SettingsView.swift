#if canImport(SwiftUI)
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        let build = BuildInfo.current
        List {
            Section("About") {
                LabeledContent("Version", value: build.version)
                LabeledContent("Build", value: build.build)
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
