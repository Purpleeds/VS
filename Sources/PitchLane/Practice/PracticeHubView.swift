#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

struct PracticeHubView: View {
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        ZStack {
            GameBackdrop(intensity: 0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("TRAIN YOUR VOICE")
                        .font(.system(.caption, design: .rounded).weight(.heavy))
                        .tracking(3)
                        .foregroundStyle(Theme.textSecondary)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        NavigationLink(value: Route.rangeTest) {
                            GameTile(
                                title: "Range test",
                                detail: settings.settings.vocalRange.map { "Saved: \($0.text(accidentals: settings.settings.accidentals))" }
                                    ?? "Find your lowest and highest notes",
                                symbol: "waveform.path.ecg", color: Theme.accent
                            )
                        }
                        .buttonStyle(PressableStyle())
                        NavigationLink(value: Route.holdDrill) {
                            GameTile(title: "Hold drill", detail: "One long note, scored on steadiness", symbol: "timer", color: Theme.gold)
                        }
                        .buttonStyle(PressableStyle())
                        NavigationLink(value: Route.tuner) {
                            GameTile(title: "Tuner", detail: "See every note you sing", symbol: "tuningfork", color: Theme.violet)
                        }
                        .buttonStyle(PressableStyle())
                        NavigationLink(value: Route.latency) {
                            GameTile(title: "Calibrate", detail: "Line your voice up with the music", symbol: "metronome", color: Theme.accentSecondary)
                        }
                        .buttonStyle(PressableStyle())
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Practise a song", systemImage: "music.note.list")
                            .font(.system(.headline, design: .rounded).weight(.heavy))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Open a song in the Library to slow it down, loop a phrase, sing it in another key, or turn off failing.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                        if settings.settings.instrumentMode {
                            Label("Instrument mode is on (about 40 Hz to 2 kHz).", systemImage: "music.quarternote.3")
                                .font(.footnote)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
        }
        .navigationTitle("Practice")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
