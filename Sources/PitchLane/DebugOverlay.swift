#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

/// Small always-on-top readout, toggled in Settings.
struct DebugOverlay: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomLeading) {
            if enabled {
                DebugOverlayPanel()
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct DebugOverlayPanel: View {
    @EnvironmentObject private var diagnostics: AudioDiagnostics

    var body: some View {
        let s = diagnostics.snapshot
        VStack(alignment: .leading, spacing: 1) {
            Text("DEBUG \(BuildInfo.current.display)")
            if let fps = s.gameFPS {
                Text("game \(f(fps, 0)) fps · worst \(f(s.gameWorstFrameMs, 1)) ms")
            }
            if s.isRunning {
                Text("analysis \(f(s.analysisAverageMs, 3)) ms avg · \(f(s.analysisMaxMs, 3)) max")
                Text("frames \(f(s.framesPerSecond, 1))/s · dropped \(s.droppedBuffers)")
                Text("input \(Int(s.inputSampleRate)) Hz · io \(f(s.ioBufferMs, 1)) ms")
            } else {
                Text("audio off · dropped \(s.droppedBuffers)")
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Theme.accentSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
        .padding(4)
    }

    private func f(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}
#endif
