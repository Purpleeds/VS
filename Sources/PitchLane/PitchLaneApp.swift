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
                .environmentObject(audio.latencyStore)
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
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        HomeView()
            .modifier(DebugOverlay(enabled: settings.settings.debugOverlay))
            .onChange(of: settings.settings.pipelineConfiguration(), initial: true) { _, configuration in
                audio.setDetection(configuration)
            }
            .onChange(of: settings.settings.autoLyrics, initial: true) { _, on in
                library.autoLyrics = on
            }
            .onChange(of: settings.settings.uploadLanguage, initial: true) { _, language in
                library.uploadLanguage = language
            }
            .onChange(of: settings.settings.onlySungNotes, initial: true) { _, on in
                library.onlySungNotes = on
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    AppLog.markRunning()
                    AppLog.info("Scene active", category: "lifecycle")
                    Task { await audio.enterForeground() }
                case .inactive:
                    AppLog.info("Scene inactive", category: "lifecycle")
                    settings.flush()
                case .background:
                    AppLog.info("Scene background (marking clean exit)", category: "lifecycle")
                    settings.flush()
                    audio.enterBackground()
                    AppLog.markCleanExit()
                @unknown default:
                    break
                }
            }
    }
}
#endif
