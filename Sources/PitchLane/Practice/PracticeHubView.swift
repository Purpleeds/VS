#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

struct PracticeHubView: View {
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        List {
            Section {
                NavigationLink(value: Route.rangeTest) {
                    row(
                        "Range test", symbol: "waveform.path.ecg",
                        detail: settings.settings.vocalRange.map { "Saved: \($0.text(accidentals: settings.settings.accidentals))" } ?? "Find your lowest and highest notes"
                    )
                }
                NavigationLink(value: Route.holdDrill) {
                    row("Hold drill", symbol: "timer", detail: "One long note, scored on steadiness")
                }
            } header: {
                Text("Train")
            }
            Section {
                Text("To loop a phrase, slow a song down, or sing in a different key, open a song in the Library and use Practice and Key.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                if settings.settings.instrumentMode {
                    Label("Instrument mode is on (about 40 Hz to 2 kHz).", systemImage: "music.quarternote.3")
                        .font(.footnote)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GameBackdrop(intensity: 0.5))
        .navigationTitle("Practice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, symbol: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 28)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
#endif
