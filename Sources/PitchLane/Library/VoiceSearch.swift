#if canImport(SwiftUI)
import AVFoundation
import Speech
import SwiftUI
import PitchLaneCore

/// Mic samples from the pitch analyser's queue into a speech request (never on the audio thread).
private final class SpeechFeed: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    /// Analysis-queue only.
    private var format: AVAudioFormat?

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        guard let base = samples.baseAddress, !samples.isEmpty, sampleRate > 0 else { return }
        if format?.sampleRate != sampleRate {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        }
        guard let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: base, count: samples.count)
        request.append(buffer)
    }
}

/// Listens for a song name with Apple's speech recogniser, **on the device only**: if on-device recognition isn't
/// available for the language, it refuses rather than sending audio to a server. The mic comes from the shared
/// `AudioInput` engine. Stops by itself after a short pause in speech.
@MainActor
final class VoiceSearch: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case done
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""

    static let client = "voice-search"
    private var feed: SpeechFeed?
    private var task: SFSpeechRecognitionTask?
    private weak var audio: AudioInput?
    private var lastChange = Date()
    private var startedAt = Date()
    private var watchdog: Task<Void, Never>?
    private var holdsAudio = false

    func start(audio: AudioInput, hints: [String]) async {
        guard state != .starting, state != .listening else { return }
        transcript = ""
        state = .starting
        self.audio = audio
        let status = await Self.authorization()
        guard state == .starting else { return }
        guard status == .authorized else {
            AppLog.info("Voice search: speech permission \(status.rawValue)", category: "voice")
            fail(status == .denied || status == .restricted
                 ? "Speech recognition is off for PitchLane. Turn it on in Settings > PitchLane, or type the name."
                 : "Speech recognition isn't available.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            fail("Speech recognition isn't available right now. Type the name instead.")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            AppLog.info("Voice search: no on-device recognition for \(recognizer.locale.identifier)", category: "voice")
            fail("On-device speech recognition isn't available for this language, and PitchLane never sends your voice off the phone. Type the name instead.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .search
        request.contextualStrings = Array(hints.prefix(100))

        await audio.acquire(Self.client)
        holdsAudio = true
        guard state == .starting, !Task.isCancelled else {
            stopAudio()
            return
        }
        guard audio.state == .running else {
            let denied = audio.state == .permissionDenied
            stopAudio()
            fail(denied ? "Microphone access is off. Turn it on in Settings > PitchLane." : "The microphone couldn't start.")
            return
        }
        let feed = SpeechFeed(request: request)
        self.feed = feed
        audio.setSampleSink { samples, rate in feed.append(samples, sampleRate: rate) }
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil && result == nil
            Task { @MainActor in self?.update(text: text, isFinal: isFinal, failed: failed) }
        }
        startedAt = Date()
        lastChange = Date()
        state = .listening
        AppLog.info("Voice search listening (on-device, \(recognizer.locale.identifier))", category: "voice")
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.checkTimeouts()
            }
        }
    }

    /// Stop listening and keep what was heard.
    func finish() {
        guard state == .listening || state == .starting else { return }
        stopAudio()
        if transcript.trimmingCharacters(in: .whitespaces).isEmpty {
            fail("Didn't catch a song name. Try again, or type it.")
        } else {
            state = .done
            AppLog.info("Voice search heard \(transcript.count) characters", category: "voice")
        }
    }

    func cancel() {
        stopAudio()
        if state != .done { state = .idle }
    }

    private func update(text: String?, isFinal: Bool, failed: Bool) {
        guard state == .listening else { return }
        if let text, text != transcript {
            transcript = text
            lastChange = Date()
        }
        if isFinal || failed { finish() }
    }

    private func checkTimeouts() {
        guard state == .listening else {
            watchdog?.cancel()
            return
        }
        let now = Date()
        let heardSomething = !transcript.isEmpty
        if (heardSomething && now.timeIntervalSince(lastChange) > 1.4) || now.timeIntervalSince(startedAt) > 10
            || (!heardSomething && now.timeIntervalSince(startedAt) > 6) {
            finish()
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
    }

    private func stopAudio() {
        watchdog?.cancel()
        watchdog = nil
        audio?.setSampleSink(nil)
        feed?.request.endAudio()
        feed = nil
        task?.finish()
        task = nil
        if holdsAudio {
            holdsAudio = false
            audio?.release(Self.client)
        }
    }

    static func authorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }
}

/// "Say a song name": live transcript, stops by itself; returns the cleaned-up words.
struct VoiceSearchSheet: View {
    let prompt: String
    let hints: [String]
    let onResult: (String) -> Void

    @EnvironmentObject private var audio: AudioInput
    @StateObject private var voice = VoiceSearch()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(voice.state == .listening ? 0.18 : 0.06))
                    .frame(width: 110, height: 110)
                    .scaleEffect(voice.state == .listening ? 1.08 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: voice.state == .listening)
                Image(systemName: voice.state == .listening ? "waveform" : "mic.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: voice.state == .listening)
            }
            .accessibilityHidden(true)
            Text(headline)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(voice.transcript.isEmpty ? " " : "“\(voice.transcript)”")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .accessibilityLabel(voice.transcript.isEmpty ? "Nothing heard yet" : "Heard \(voice.transcript)")
            if case .failed(let message) = voice.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.warn)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Button("Cancel", role: .cancel) {
                    voice.cancel()
                    dismiss()
                }
                .buttonStyle(.bordered)
                if case .failed = voice.state {
                    Button("Try Again", systemImage: "mic") { Task { await voice.start(audio: audio, hints: hints) } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Done", systemImage: "checkmark") { voice.finish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(voice.transcript.isEmpty)
                }
            }
            Text("Recognised on your phone. Your voice never leaves it.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GameBackdrop(intensity: 0.5))
        .presentationDetents([.medium])
        .task { await voice.start(audio: audio, hints: hints) }
        .onChange(of: voice.state) { _, state in
            if state == .done {
                onResult(VoiceQuery.clean(voice.transcript))
                dismiss()
            }
        }
        .onDisappear { voice.cancel() }
    }

    private var headline: String {
        switch voice.state {
        case .idle, .starting: return "Getting ready…"
        case .listening: return prompt
        case .done: return "Got it"
        case .failed: return "Voice search"
        }
    }
}
#endif
