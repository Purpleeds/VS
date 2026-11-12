#if canImport(SwiftUI)
import SwiftUI

@main
struct PitchLaneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsModel

    init() {
        AppLog.bootstrap()
        _settings = StateObject(wrappedValue: SettingsModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        HomeView()
            .modifier(DebugOverlay(enabled: settings.settings.debugOverlay))
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    AppLog.markRunning()
                    AppLog.info("Scene active", category: "lifecycle")
                case .inactive:
                    AppLog.info("Scene inactive", category: "lifecycle")
                case .background:
                    AppLog.info("Scene background (marking clean exit)", category: "lifecycle")
                    AppLog.markCleanExit()
                @unknown default:
                    break
                }
            }
    }
}
#endif
