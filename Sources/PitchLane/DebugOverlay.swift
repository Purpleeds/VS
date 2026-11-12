#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

/// Small always-on-top readout, toggled in Settings. Later steps add pitch/latency/fps lines here.
struct DebugOverlay: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if enabled {
                Text("DEBUG \(BuildInfo.current.display)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.accentSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }
}
#endif
