#if canImport(SwiftUI)
import SwiftUI
import UIKit
import PitchLaneCore

struct TunerView: View {
    @EnvironmentObject private var audio: AudioInput
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Tuner")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await audio.acquire("tuner")
        }
        .onDisappear {
            audio.release("tuner")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch audio.state {
        case .permissionDenied:
            MicrophonePermissionView()
        case .failed(let message):
            AudioFailedView(message: message) {
                Task { await audio.retry() }
            }
        default:
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                Group {
                    if landscape {
                        HStack(spacing: 20) {
                            readout(compact: true)
                                .frame(width: min(340, geo.size.width * 0.42))
                            graph
                        }
                    } else {
                        VStack(spacing: 20) {
                            readout(compact: false)
                            graph.frame(minHeight: 160)
                        }
                    }
                }
                .padding(16)
            }
            .overlay(alignment: .top) { statusBanner }
        }
    }

    private func readout(compact: Bool) -> some View {
        TunerReadout(
            frame: audio.latest,
            lastVoiced: audio.lastVoiced,
            accidentals: settings.settings.accidentals,
            noiseGateDBFS: settings.settings.noiseGateDBFS,
            compact: compact
        )
    }

    private var graph: some View {
        PitchGraph(history: audio.history, range: audio.graphRange, accidentals: settings.settings.accidentals)
    }

    @ViewBuilder
    private var statusBanner: some View {
        let text: String? = switch audio.state {
        case .requestingPermission: "Waiting for microphone permission…"
        case .starting: "Starting microphone…"
        case .interrupted: "Paused: audio interrupted (call, Siri or another app)"
        case .idle: "Microphone off"
        default: nil
        }
        if let text {
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.surfaceHighlight, in: Capsule())
                .padding(.top, 6)
        }
    }
}

/// Note name, Hz, cents needle, confidence and input level.
struct TunerReadout: View {
    let frame: PitchFrame?
    let lastVoiced: PitchFrame?
    let accidentals: Accidentals
    let noiseGateDBFS: Double
    let compact: Bool

    private static let stabilizerDefaults = PitchStabilizerConfiguration()
    private static let meterFloorDB = -80.0

    var body: some View {
        let voiced = frame?.isVoiced == true
        let shown = voiced ? frame : lastVoiced
        VStack(spacing: compact ? 10 : 16) {
            Text(noteName(shown))
                .font(.system(size: compact ? 72 : 104, weight: .heavy, design: .rounded))
                .foregroundStyle(voiced ? Theme.textPrimary : Theme.textSecondary.opacity(0.35))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(voiced ? "Note \(noteName(shown))" : "No pitch")
            Text(frequencyText(voiced ? frame : nil))
                .font(.system(.title3, design: .monospaced))
                .foregroundStyle(voiced ? Theme.textPrimary : Theme.textSecondary)
            CentsNeedle(cents: voiced ? frame?.cents : nil)
            MeterBar(
                title: "Confidence",
                value: frame?.confidence ?? 0,
                marker: Self.stabilizerDefaults.minimumConfidence,
                valueText: String(format: "%.2f", frame?.confidence ?? 0),
                tint: (frame?.confidence ?? 0) >= Self.stabilizerDefaults.minimumConfidence ? Theme.good : Theme.warn
            )
            MeterBar(
                title: "Input level",
                value: levelFraction(frame?.levelDBFS),
                marker: levelFraction(noiseGateDBFS),
                valueText: frame.map { String(format: "%.0f dBFS", max(Self.meterFloorDB, $0.levelDBFS)) } ?? "–",
                tint: (frame?.levelDBFS ?? -160) >= noiseGateDBFS ? Theme.accent : Theme.textSecondary
            )
            if !voiced, let reason = frame?.unvoicedReason {
                Text(Self.explain(reason))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func noteName(_ frame: PitchFrame?) -> String {
        guard let note = frame?.nearestNote else { return "–" }
        return NoteNaming.name(forMIDINote: note, accidentals: accidentals)
    }

    private func frequencyText(_ frame: PitchFrame?) -> String {
        guard let hz = frame?.frequency else { return "— Hz" }
        return String(format: "%.1f Hz", hz)
    }

    private func levelFraction(_ db: Double?) -> Double {
        guard let db else { return 0 }
        return (max(Self.meterFloorDB, min(0, db)) - Self.meterFloorDB) / -Self.meterFloorDB
    }

    private static func explain(_ reason: UnvoicedReason) -> String {
        switch reason {
        case .belowNoiseGate: return "Too quiet"
        case .lowConfidence: return "No clear pitch"
        case .outOfRange: return "Above the detector range"
        case .pendingJump: return "Checking a big jump…"
        }
    }
}

struct MicrophonePermissionView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accentSecondary)
            Text("Microphone access is off")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("PitchLane listens to your voice to show your pitch. Audio is analysed on your phone and never leaves it.\n\nTurn on Microphone for PitchLane in Settings.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    AppLog.info("Opening Settings for microphone permission", category: "audio")
                    openURL(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gearshape")
                    .font(.headline)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: 420)
    }
}

struct AudioFailedView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.warn)
            Text("The microphone couldn't start")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
            Button("Try again", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: 420)
    }
}
#endif
