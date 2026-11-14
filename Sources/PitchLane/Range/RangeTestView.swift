#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

@MainActor
final class RangeTestModel: ObservableObject {
    @Published private(set) var stage: RangeTestStage = .low
    @Published private(set) var progress = 0.0
    @Published private(set) var currentMIDI: Double?
    @Published private(set) var low: Int?
    @Published private(set) var message: String?

    private var flow = RangeTestFlow()
    /// Keeps the flow's clock monotonic across an engine restart (the analyser's stream time starts over).
    private var timeOffset = 0.0
    private var lastTime = -Double.infinity

    func receive(_ batch: PitchAnalyzer.Batch) {
        for frame in batch.frames {
            if frame.time + timeOffset < lastTime - 0.5 {
                timeOffset = lastTime - frame.time
                AppLog.info("Range test: audio stream restarted, keeping the clock continuous", category: "range")
            }
            let time = frame.time + timeOffset
            lastTime = time
            guard let event = flow.add(time: time, midi: frame.midi) else { continue }
            switch event {
            case .lockedLow(let note):
                message = nil
                AppLog.info("Range test: lowest note locked at MIDI \(note)", category: "range")
            case .lockedHigh:
                break
            case .highTooLow(let sung, let low):
                message = "That's only \(sung - low) semitones above your lowest note. Sing higher, and hold it."
                AppLog.info("Range test: high note MIDI \(sung) too close to low \(low)", category: "range")
            case .finished(let range):
                message = nil
                AppLog.info("Range test finished: MIDI \(range.low)-\(range.high)", category: "range")
            }
        }
        stage = flow.stage
        progress = flow.progress
        currentMIDI = flow.currentMIDI
        low = flow.low
    }

    func restart() {
        flow.restart()
        message = nil
        stage = .low
        progress = 0
        low = nil
        currentMIDI = nil
    }

    func redoHigh() {
        flow.redoHigh()
        message = nil
        stage = flow.stage
        progress = 0
    }
}

/// "Sing your lowest comfortable note, then your highest. Hold each for a second."
struct RangeTestView: View {
    @EnvironmentObject private var audio: AudioInput
    @EnvironmentObject private var settings: SettingsModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = RangeTestModel()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch audio.state {
            case .permissionDenied:
                MicrophonePermissionView()
            case .failed(let message):
                AudioFailedView(message: message) { Task { await audio.retry() } }
            default:
                content
            }
        }
        .navigationTitle("Range test")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            audio.addFrameListener("range") { batch, _ in model.receive(batch) }
            await audio.acquire("range")
            if Task.isCancelled { audio.release("range") }
        }
        .onDisappear {
            audio.removeFrameListener("range")
            audio.release("range")
        }
    }

    private var content: some View {
        let accidentals = settings.settings.accidentals
        return ScrollView {
            VStack(spacing: 18) {
                Text(prompt)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textPrimary)
                ZStack {
                    Circle().stroke(Theme.surface, lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: isDone ? 1 : model.progress)
                        .stroke(isDone ? Theme.good : Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.05), value: model.progress)
                    VStack(spacing: 2) {
                        Text(liveName(accidentals))
                            .font(.system(size: 56, weight: .heavy, design: .rounded))
                            .foregroundStyle(model.currentMIDI == nil ? Theme.textSecondary.opacity(0.4) : Theme.textPrimary)
                            .minimumScaleFactor(0.5)
                        Text(statusLine)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 200, height: 200)
                if let message = model.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 6) {
                    noteRow("Lowest", note: model.low ?? (isDone ? doneRange?.low : nil))
                    noteRow("Highest", note: doneRange?.high)
                }
                if let range = doneRange {
                    Text("\(range.text(accidentals: accidentals)) · \(range.spanText)")
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    HStack {
                        Button {
                            settings.settings.vocalRange = range
                            AppLog.info("Vocal range saved: MIDI \(range.low)-\(range.high)", category: "range")
                            dismiss()
                        } label: {
                            Label("Save range", systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Redo high note") { model.redoHigh() }
                            .buttonStyle(.bordered)
                        Button("Start over") { model.restart() }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.regular)
                } else if model.low != nil {
                    Button("Start over") { model.restart() }
                        .buttonStyle(.bordered)
                }
                Text("Pick notes you can sing comfortably, not the very edge of your voice.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
    }

    private var doneRange: VocalRange? {
        if case .done(let range) = model.stage { return range }
        return nil
    }

    private var isDone: Bool { doneRange != nil }

    private var prompt: String {
        switch model.stage {
        case .low: return "Sing your lowest comfortable note"
        case .release: return "Got it. Take a breath…"
        case .high: return "Now sing your highest comfortable note"
        case .done: return "All set"
        }
    }

    private var statusLine: String {
        switch model.stage {
        case .low, .high: return model.currentMIDI == nil ? "Waiting for your voice" : "Hold it steady for a second"
        case .release: return "Stop singing for a moment"
        case .done: return "Locked in"
        }
    }

    private func liveName(_ accidentals: Accidentals) -> String {
        guard let midi = model.currentMIDI else { return "–" }
        return NoteNaming.name(forMIDINote: NoteNaming.nearestNote(toMIDI: midi).note, accidentals: accidentals)
    }

    private func noteRow(_ title: String, note: Int?) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(note.map { NoteNaming.name(forMIDINote: $0, accidentals: settings.settings.accidentals) } ?? "–")
                .font(.headline.monospacedDigit())
                .foregroundStyle(note == nil ? Theme.textSecondary : Theme.good)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Home-screen card: the saved range, or an invitation to find it.
struct RangeCard: View {
    let onTap: () -> Void
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        let accidentals = settings.settings.accidentals
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    if let range = settings.settings.vocalRange {
                        Text("Your range")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text(range.text(accidentals: accidentals))
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(range.spanText)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("Find your vocal range")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Takes 20 seconds. Songs can then fit your voice.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Text(settings.settings.vocalRange == nil ? "Start" : "Retest")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(14)
            .background(.ultraThinMaterial.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(settings.settings.vocalRange.map { "Your range \($0.text(accidentals: accidentals)). Retest." } ?? "Find your vocal range")
    }
}
#endif
