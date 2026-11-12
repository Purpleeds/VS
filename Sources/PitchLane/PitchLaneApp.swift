#if canImport(SwiftUI)
import SwiftUI

@main
struct PitchLaneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsModel
    @StateObject private var audio: AudioInput
    @StateObject private var library: LibraryModel
    @StateObject private var scores: ScoreStore

    init() {
        AppLog.bootstrap()
        _settings = StateObject(wrappedValue: SettingsModel())
        _audio = StateObject(wrappedValue: AudioInput())
        _library = StateObject(wrappedValue: LibraryModel())
        _scores = StateObject(wrappedValue: ScoreStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(audio)
                .environmentObject(audio.diagnostics)
                .environmentObject(library)
                .environmentObject(scores)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var audio: AudioInput

    var body: some View {
        HomeView()
            .modifier(DebugOverlay(enabled: settings.settings.debugOverlay))
            .onChange(of: settings.settings.accidentals, initial: true) { _, accidentals in
                audio.setAccidentals(accidentals)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    AppLog.markRunning()
                    AppLog.info("Scene active", category: "lifecycle")
                    Task { await audio.enterForeground() }
                case .inactive:
                    AppLog.info("Scene inactive", category: "lifecycle")
                case .background:
                    AppLog.info("Scene background (marking clean exit)", category: "lifecycle")
                    audio.enterBackground()
                    AppLog.markCleanExit()
                @unknown default:
                    break
                }
            }
    }
}
#endif
