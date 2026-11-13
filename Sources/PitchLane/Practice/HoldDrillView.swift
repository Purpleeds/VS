#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

@MainActor
final class HoldDrillModel: ObservableObject {
    enum Phase: Equatable {
        case setup
        case countdown(Int)
        case holding
        case done
    }

    static let countdownSeconds = 3.0

    @Published private(set) var phase: Phase = .setup
    @Published private(set) var liveMIDI: Double?
    @Published private(set) var elapsed = 0.0
    @Published private(set) var result: HoldDrillResult?
    /// Live graph points: seconds into the hold, MIDI (nil = unvoiced).
    @Published private(set) var live: [(time: Double, midi: Double?)] = []

    private(set) var target: Int?
    private(set) var duration = 8.0
    private var octaveAgnostic = true
    private var drill = HoldDrill(target: nil)
    private var streamNow = 0.0
    private var startStream = 0.0

    func start(target: Int?, duration: Double, octaveAgnostic: Bool) {
        self.target = target
        self.duration = duration
        self.octaveAgnostic = octaveAgnostic
        drill = HoldDrill(target: target, duration: duration, octaveAgnostic: octaveAgnostic)
        live = []
        result = nil
        elapsed = 0
        startStream = streamNow + Self.countdownSeconds
        phase = .countdown(Int(Self.countdownSeconds))
        AppLog.info("Hold drill started: target \(target.map(String.init) ?? "free"), \(Int(duration)) s", category: "drill")
    }

    func reset() {
        phase = .setup
        result = nil
        live = []
    }

    func receive(_ batch: PitchAnalyzer.Batch) {
        guard let first = batch.frames.first, let last = batch.frames.last else { return }
        // An engine restart (route change, headphones) restarts the analyser's stream clock near 0: shift the
        // drill's start by the jump so the countdown and hold carry on instead of waiting forever.
        if first.time < streamNow - 0.5 {
            let jump = first.time - streamNow
            startStream += jump
            AppLog.info("Hold drill: audio stream restarted (\(String(format: "%.1f", jump)) s), shifting the drill clock", category: "drill")
        }
        streamNow = last.time
        liveMIDI = last.midi
        switch phase {
        case .setup, .done:
            return
        case .countdown:
            let remaining = startStream - streamNow
            if remaining > 0 {
                phase = .countdown(max(1, Int(remaining.rounded(.up))))
                return
            }
            phase = .holding
        case .holding:
            break
        }
        for frame in batch.frames {
            let t = frame.time - startStream
            guard t >= 0 else { continue }
            drill.add(time: t, midi: frame.midi)
            live.append((t, frame.midi))
        }
        elapsed = drill.elapsed
        if drill.isComplete {
            let finished = drill.result()
            result = finished
            phase = .done
            AppLog.info(
                "Hold drill result: score \(Int(finished.score.rounded())) (\(finished.rating.displayName)), wobble \(String(format: "%.1f", finished.wobbleCents)) c, "
                    + "max \(String(format: "%.0f", finished.maxDeviationCents)) c, drift \(String(format: "%+.1f", finished.driftCentsPerSecond)) c/s, "
                    + "voiced \(String(format: "%.0f", finished.voicedFraction * 100))%",
                category: "drill"
            )
        }
    }
}

/// One long note scored on steadiness.
struct HoldDrillView: View {
    @EnvironmentObject private var audio: AudioInput
    @EnvironmentObject private var settings: SettingsModel
    @StateObject private var model = HoldDrillModel()
    @StateObject private var tone = TransposePreview()
    @State private var free = false
    @State private var note = 60
    @State private var duration = 8.0
    @State private var seeded = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch audio.state {
            case .permissionDenied:
                MicrophonePermissionView()
            case .failed(let message):
                AudioFailedView(message: message) { Task { await audio.retry() } }
            default:
                ScrollView {
                    VStack(spacing: 16) {
                        switch model.phase {
                        case .setup: setup
                        case .countdown(let count): countdown(count)
                        case .holding: holding
                        case .done: done
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Hold drill")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !seeded {
                seeded = true
                if let range = settings.settings.vocalRange {
                    note = (range.low + range.high) / 2
                }
            }
            audio.addFrameListener("drill") { batch, _ in model.receive(batch) }
            await audio.acquire("drill")
            if Task.isCancelled { audio.release("drill") }
        }
        .onDisappear {
            tone.stop()
            audio.removeFrameListener("drill")
            audio.release("drill")
        }
    }

    // MARK: Phases

    private var setup: some View {
        let accidentals = settings.settings.accidentals
        return VStack(spacing: 16) {
            Text("Hold one note as steadily as you can")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("You're scored on how little your pitch wobbles, not on which note it is.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Picker("Note", selection: $free) {
                Text("A note I choose").tag(true)
                Text("A set note").tag(false)
            }
            .pickerStyle(.segmented)
            if !free {
                HStack {
                    Stepper(value: $note, in: noteRange) {
                        Text(NoteNaming.name(forMIDINote: note, accidentals: accidentals))
                            .font(.title.weight(.bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Button {
                        if tone.isPlaying {
                            tone.stop()
                        } else {
                            Task { await tone.play(song: referenceSong, audio: audio, volume: settings.settings.guideVolume) }
                        }
                    } label: {
                        Label(tone.isPlaying ? "Stop" : "Hear it", systemImage: tone.isPlaying ? "stop.fill" : "speaker.wave.2")
                    }
                    .buttonStyle(.bordered)
                }
            }
            Picker("Length", selection: $duration) {
                ForEach([5.0, 8.0, 10.0, 15.0], id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            .pickerStyle(.segmented)
            Button {
                tone.stop()
                model.start(target: free ? nil : note, duration: duration, octaveAgnostic: settings.settings.octaveAgnostic)
            } label: {
                Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(audio.state != .running)
        }
    }

    private func countdown(_ count: Int) -> some View {
        VStack(spacing: 12) {
            Text(model.target.map { "Get ready to sing \(NoteNaming.name(forMIDINote: $0, accidentals: settings.settings.accidentals))" } ?? "Get ready")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
            Text("\(count)")
                .font(.system(size: 120, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.accent)
        }
        .padding(.top, 40)
    }

    private var holding: some View {
        let accidentals = settings.settings.accidentals
        let reference = model.target.map(Double.init) ?? firstVoiced
        return VStack(spacing: 14) {
            Text(model.target.map { "Hold \(NoteNaming.name(forMIDINote: $0, accidentals: accidentals))" } ?? "Hold your note")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(liveName(accidentals))
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(model.liveMIDI == nil ? Theme.textSecondary.opacity(0.4) : Theme.textPrimary)
            CentsNeedle(cents: liveDeviation(reference))
            ProgressView(value: min(1, model.elapsed / model.duration))
                .tint(Theme.accent)
            HoldGraph(points: model.live.map { .init(time: $0.time, cents: deviation($0.midi, reference)) }, duration: model.duration)
                .frame(height: 150)
        }
    }

    private var done: some View {
        let result = model.result
        let accidentals = settings.settings.accidentals
        return VStack(spacing: 14) {
            if let result {
                Text(result.rating.displayName)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(color(for: result.rating))
                Text("\(Int(result.score.rounded()))")
                    .font(.system(size: 72, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                Text("steadiness score out of 100")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                HoldGraph(points: result.points, duration: model.duration)
                    .frame(height: 150)
                VStack(spacing: 6) {
                    stat("Wobble (RMS)", "±\(String(format: "%.1f", result.wobbleCents)) cents")
                    stat("Biggest swing", "\(String(format: "%.0f", result.maxDeviationCents)) cents")
                    stat("Drift", "\(String(format: "%+.1f", result.driftCentsPerSecond)) cents/s")
                    stat("Voiced", "\(Int((result.voicedFraction * 100).rounded()))%")
                    if let offset = result.offsetFromTargetCents, let target = model.target {
                        stat("Centre vs \(NoteNaming.name(forMIDINote: target, accidentals: accidentals))", "\(String(format: "%+.0f", offset)) cents")
                    }
                }
                Text(advice(result))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Button {
                    model.start(target: model.target, duration: model.duration, octaveAgnostic: settings.settings.octaveAgnostic)
                } label: {
                    Label("Again", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent)
                Button("Change note") { model.reset() }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Helpers

    private var noteRange: ClosedRange<Int> {
        if settings.settings.instrumentMode { return 28...95 }
        return 36...84
    }

    private var referenceSong: Song {
        Song(id: "reference", title: "Reference", source: .builtIn, notes: [SongNote(start: 0, duration: 2.5, pitch: note)])
    }

    private var firstVoiced: Double? {
        model.live.first { $0.midi != nil && $0.time >= 0.4 }?.midi
    }

    private func liveName(_ accidentals: Accidentals) -> String {
        guard let midi = model.liveMIDI else { return "–" }
        return NoteNaming.name(forMIDINote: NoteNaming.nearestNote(toMIDI: midi).note, accidentals: accidentals)
    }

    private func deviation(_ midi: Double?, _ reference: Double?) -> Double? {
        guard let midi, let reference else { return nil }
        return PitchFolding.errorCents(sung: midi, target: reference, octaveAgnostic: settings.settings.octaveAgnostic)
    }

    private func liveDeviation(_ reference: Double?) -> Double? {
        deviation(model.liveMIDI, reference)
    }

    private func color(for rating: SteadinessRating) -> Color {
        switch rating {
        case .rockSteady: return Theme.good
        case .steady: return Theme.accent
        case .wobbly: return Theme.warn
        case .unsteady: return Theme.bad
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(Theme.textPrimary)
        }
        .font(.subheadline)
    }

    private func advice(_ result: HoldDrillResult) -> String {
        if result.voicedFraction < 0.7 { return "Your voice dropped out a lot. Breathe from lower down and keep a steady airflow." }
        if abs(result.driftCentsPerSecond) > 6 { return result.driftCentsPerSecond < 0 ? "You're drifting flat as the note goes on: keep your support up." : "You're creeping sharp: ease off the pressure." }
        if result.wobbleCents > 20 { return "Lots of movement. Try a quieter, more even breath, or a vowel like \"oo\"." }
        return result.score >= 90 ? "Excellent. Try a longer hold or a higher note." : "Nice and even. A little less movement and you're rock steady."
    }
}

/// Deviation from the reference over time, with ±25 / ±50 cent guides.
struct HoldGraph: View {
    let points: [HoldDrillResult.Point]
    let duration: Double

    var body: some View {
        Canvas { context, size in
            MainActor.assumeIsolated {
                draw(&context, size: size)
            }
        }
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Pitch deviation over the hold")
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let span = 100.0 // ±50 cents
        func x(_ t: Double) -> CGFloat { size.width * CGFloat(min(1, max(0, t / duration))) }
        func y(_ cents: Double) -> CGFloat { size.height * CGFloat(0.5 - max(-span / 2, min(span / 2, cents)) / span) }
        for (cents, alpha) in [(0.0, 0.5), (25.0, 0.18), (-25.0, 0.18), (50.0, 0.1), (-50.0, 0.1)] {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y(cents)))
            line.addLine(to: CGPoint(x: size.width, y: y(cents)))
            context.stroke(line, with: .color(Theme.grid.opacity(alpha)), lineWidth: cents == 0 ? 1.5 : 0.5)
        }
        var path = Path()
        var penDown = false
        var lastTime = -Double.infinity
        for point in points {
            guard let cents = point.cents else {
                penDown = false
                continue
            }
            let p = CGPoint(x: x(point.time), y: y(cents))
            if penDown && point.time - lastTime < 0.05 { path.addLine(to: p) } else { path.move(to: p) }
            penDown = true
            lastTime = point.time
        }
        context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
}
#endif
