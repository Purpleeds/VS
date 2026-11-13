#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

/// What to play: the difficulty, a semitone shift, and practice options.
struct GamePlan: Hashable {
    var difficulty: Difficulty
    var transpose: Int = 0
    var practice: PracticeOptions = .normal
}

/// Plays the first notes of a (shifted) song with the guide tone, to hear the new key.
@MainActor
final class TransposePreview: ObservableObject {
    @Published private(set) var isPlaying = false
    private weak var audio: AudioInput?
    private var timebase: SongTimebase?
    private var stopTask: Task<Void, Never>?

    func play(song: Song, audio: AudioInput, volume: Double) async {
        stop()
        guard let first = song.notes.first else { return }
        self.audio = audio
        await audio.acquire("preview")
        guard audio.state == .running else {
            audio.release("preview")
            return
        }
        let excerpt = song.excerpt(from: max(0, first.start - 0.1), duration: 7)
        audio.installGuide(GuideToneRenderer(song: excerpt, envelope: .soft))
        audio.setGuideVolume(Float(max(0.5, volume)))
        let timebase = SongTimebase(audio: audio, songDuration: excerpt.duration, leadIn: 0.3)
        self.timebase = timebase
        for _ in 0..<60 {
            if timebase.start() { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard timebase.isStarted else {
            stop()
            return
        }
        isPlaying = true
        AppLog.info("Transpose preview started (\(excerpt.notes.count) notes)", category: "library")
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(excerpt.duration + 0.8))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        guard timebase != nil || isPlaying else { return }
        timebase?.stop()
        timebase = nil
        audio?.installGuide(nil)
        audio?.release("preview")
        isPlaying = false
    }
}

/// Shift a song into the singer's range: octave and semitone steps, a one-tap fit, and an audio preview.
struct TransposeSection: View {
    let song: Song
    @Binding var shift: Int

    @EnvironmentObject private var settings: SettingsModel
    @EnvironmentObject private var audio: AudioInput
    @StateObject private var preview = TransposePreview()

    var body: some View {
        let accidentals = settings.settings.accidentals
        let range = settings.settings.vocalRange
        let base = song.pitchRange
        Section {
            if let range {
                LabeledContent("Your range", value: range.text(accidentals: accidentals))
            } else {
                Text("Run the range test (home screen > Practice) to get a suggested shift.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let base {
                let shifted = VocalRange(low: base.lowerBound + shift, high: base.upperBound + shift)
                LabeledContent("Song range", value: VocalRange(low: base.lowerBound, high: base.upperBound).text(accidentals: accidentals))
                LabeledContent("With shift", value: shifted.text(accidentals: accidentals))
            }
            if let range {
                fitRow(range: range)
                if let best = SongTransposer.bestShift(for: song, in: range), best != shift {
                    Button {
                        shift = best
                    } label: {
                        Label("Fit to my range (\(SongTransposer.shiftText(best)))", systemImage: "wand.and.stars")
                    }
                }
            }
            HStack {
                stepButton("-1 oct", -12)
                stepButton("-1", -1)
                Text(SongTransposer.shiftText(shift))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                stepButton("+1", 1)
                stepButton("+1 oct", 12)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            HStack {
                Button {
                    if preview.isPlaying {
                        preview.stop()
                    } else {
                        Task { await preview.play(song: song.transposed(by: shift), audio: audio, volume: settings.settings.guideVolume) }
                    }
                } label: {
                    Label(preview.isPlaying ? "Stop preview" : "Preview in this key", systemImage: preview.isPlaying ? "stop.fill" : "speaker.wave.2")
                }
                Spacer()
                if shift != 0 {
                    Button("Reset", role: .destructive) { shift = 0 }
                }
            }
        } header: {
            Text("Key")
        } footer: {
            Text(settings.settings.octaveAgnostic
                 ? "Scoring already accepts any octave. Shifting changes where the notes sit on the lane and in the guide tone."
                 : "Any octave counts is off, so sing the notes where they sit on the lane.")
        }
        .onChange(of: shift) { _, _ in
            preview.stop()
        }
        .onDisappear { preview.stop() }
    }

    private func stepButton(_ title: String, _ delta: Int) -> some View {
        Button(title) { shift = max(-36, min(36, shift + delta)) }
    }

    @ViewBuilder
    private func fitRow(range: VocalRange) -> some View {
        switch SongTransposer.fit(of: song, shift: shift, in: range) {
        case .fits:
            Label("Fits your range", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.good)
        case .outside(let below, let above):
            let parts = [below > 0 ? "\(below) too low" : nil, above > 0 ? "\(above) too high" : nil].compactMap { $0 }
            Label("Notes outside your range: " + parts.joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warn)
                .font(.subheadline)
        }
    }
}

/// Practice speed, a looped section and no-fail.
struct PracticeSection: View {
    let song: Song
    @Binding var practice: PracticeOptions

    @State private var loopOn = false
    @State private var startPhrase = 0
    @State private var endPhrase = 0

    private var phrases: [ClosedRange<Double>] { song.phraseRanges() }

    var body: some View {
        let phrases = self.phrases
        Section {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Label("Speed", systemImage: "gauge.with.dots.needle.33percent")
                    Spacer()
                    Text(practice.speedText).monospacedDigit()
                }
                .font(.subheadline)
                Slider(value: Binding(
                    get: { practice.speed },
                    set: { apply(speed: ($0 * 20).rounded() / 20) }
                ), in: PracticeOptions.speedRange)
            }
            if phrases.count >= 2 {
                Toggle("Loop a section", isOn: Binding(
                    get: { loopOn },
                    set: { on in
                        loopOn = on
                        if on { endPhrase = max(endPhrase, startPhrase) }
                        applyLoop()
                    }
                ))
                if loopOn {
                    Picker("From", selection: Binding(get: { startPhrase }, set: { value in
                        startPhrase = value
                        endPhrase = max(endPhrase, value)
                        applyLoop()
                    })) {
                        ForEach(phrases.indices, id: \.self) { Text(label($0, phrases)).tag($0) }
                    }
                    Picker("To", selection: Binding(get: { endPhrase }, set: { value in
                        endPhrase = max(value, startPhrase)
                        applyLoop()
                    })) {
                        ForEach(phrases.indices, id: \.self) { Text(label($0, phrases)).tag($0) }
                    }
                    if practice.loop == nil {
                        Text("Pick at least \(Int(PracticeOptions.minimumLoopLength)) seconds of song.")
                            .font(.caption)
                            .foregroundStyle(Theme.warn)
                    }
                }
            }
            Toggle("No-fail", isOn: Binding(get: { practice.noFail }, set: { apply(noFail: $0) }))
        } header: {
            Text("Practice")
        } footer: {
            Text("Practice runs are saved to your history but never count toward personal bests. Looping repeats the section and shows each pass's accuracy.")
        }
        .onAppear {
            loopOn = practice.loop != nil
        }
    }

    private func label(_ index: Int, _ phrases: [ClosedRange<Double>]) -> String {
        let t = Int(phrases[index].lowerBound.rounded())
        return "Phrase \(index + 1) · \(t / 60):\(String(format: "%02d", t % 60))"
    }

    private func apply(speed: Double? = nil, noFail: Bool? = nil) {
        practice = PracticeOptions(
            speed: speed ?? practice.speed,
            loopStart: practice.loopStart,
            loopEnd: practice.loopEnd,
            noFail: noFail ?? practice.noFail
        )
    }

    private func applyLoop() {
        let phrases = self.phrases
        guard loopOn, phrases.indices.contains(startPhrase), phrases.indices.contains(endPhrase) else {
            practice = PracticeOptions(speed: practice.speed, noFail: practice.noFail)
            return
        }
        practice = PracticeOptions(
            speed: practice.speed,
            loopStart: phrases[startPhrase].lowerBound,
            loopEnd: phrases[endPhrase].upperBound,
            noFail: practice.noFail
        )
    }
}
#endif
