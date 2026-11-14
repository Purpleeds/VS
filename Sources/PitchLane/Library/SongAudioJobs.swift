#if canImport(SwiftUI)
import AVFoundation
import CoreMedia
import Foundation
import Speech
import PitchLaneCore

/// Splits a song's backing audio into a voice stem and a music stem (Core `StemSeparator`), on the phone, in two
/// passes: the first (plain centre extraction, nothing written) finds where and at what pitch the singer sings
/// (Core `VocalGuide`); the second separates again following the singer and writes the stems.
enum StemMaker {
    enum Failure: LocalizedError {
        case noAudio
        case mono
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: return "The song has no backing audio."
            case .mono: return "This recording is mono (both speakers carry the same sound), so the voice can't be told apart from the music."
            case .unreadable(let detail): return "The audio couldn't be processed (\(detail))."
            }
        }
    }

    static let sampleRate = 44_100.0
    /// The first pass's voice is kept at this rate for the guide (about 4 MB per minute).
    static let guideRate = 16_000.0

    /// Writes AAC stereo stems to `vocalsOut` and `musicOut` (.m4a). `progress` gets 0...1.
    static func separate(_ source: URL, vocalsOut: URL, musicOut: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        let duration = max(1, try await asset.load(.duration).seconds)
        let descriptions = try await track.load(.formatDescriptions)
        let channels = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2
        guard channels >= 2 else { throw Failure.mono }
        let started = Date()
        let guide = try findSinger(asset: asset, track: track, duration: duration) { progress(0.35 * $0) }
        AppLog.info(
            "Separation guide: \(guide.singing.count) sung phrases, \(Int(guide.singingDuration)) s of singing, "
                + "pitch known \(Int((guide.pitchedFraction * 100).rounded())) % of it (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)",
            category: "stems"
        )
        try write(
            asset: asset, track: track, duration: duration, guide: guide.singing.isEmpty ? nil : guide,
            vocalsOut: vocalsOut, musicOut: musicOut
        ) { progress(0.35 + 0.65 * $0) }
    }

    /// Pass 1: plain separation, keeping only a 16 kHz mono copy of the voice to analyse.
    private static func findSinger(asset: AVURLAsset, track: AVAssetTrack, duration: Double, progress: (Double) -> Void) throws -> VocalGuide {
        let separator = StemSeparator(sampleRate: sampleRate)
        var resampler = StreamingResampler(inputRate: sampleRate, outputRate: guideRate)
        var voice: [Float] = []
        voice.reserveCapacity(Int(duration * guideRate) + 1)
        var mono: [Float] = []
        func keep(_ out: StemSeparator.Output) {
            guard out.count > 0 else { return }
            if mono.count != out.count { mono = [Float](repeating: 0, count: out.count) }
            for i in 0..<out.count { mono[i] = (out.vocalsLeft[i] + out.vocalsRight[i]) * 0.5 }
            mono.withUnsafeBufferPointer { resampler.process($0, appendingTo: &voice) }
        }
        try readStereo(asset: asset, track: track, duration: duration, progress: progress) { left, right in
            keep(separator.process(left: left, right: right))
        }
        keep(separator.finish())
        if separator.isEffectivelyMono { throw Failure.mono }
        try Task.checkCancellation()
        return VocalGuide.analyze(voice, sampleRate: guideRate)
    }

    /// Pass 2: separation following the singer; writes the stems.
    private static func write(
        asset: AVURLAsset, track: AVAssetTrack, duration: Double, guide: VocalGuide?, vocalsOut: URL, musicOut: URL,
        progress: (Double) -> Void
    ) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { throw Failure.unreadable("format") }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        try? FileManager.default.removeItem(at: vocalsOut)
        try? FileManager.default.removeItem(at: musicOut)
        let vocalsFile = try AVAudioFile(forWriting: vocalsOut, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let musicFile = try AVAudioFile(forWriting: musicOut, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let separator = StemSeparator(sampleRate: sampleRate, guide: guide)

        func emit(_ out: StemSeparator.Output) throws {
            guard out.count > 0 else { return }
            try append(out.vocalsLeft, out.vocalsRight, to: vocalsFile, format: format)
            try append(out.musicLeft, out.musicRight, to: musicFile, format: format)
        }
        try readStereo(asset: asset, track: track, duration: duration, progress: progress) { left, right in
            try emit(separator.process(left: left, right: right))
        }
        try emit(separator.finish())
        if separator.isEffectivelyMono { throw Failure.mono }
        progress(1)
    }

    /// Decodes the track as 44.1 kHz stereo and hands it over in pieces (left, right).
    private static func readStereo(
        asset: AVURLAsset, track: AVAssetTrack, duration: Double, progress: (Double) -> Void, body: ([Float], [Float]) throws -> Void
    ) throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw Failure.unreadable(error.localizedDescription) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.unreadable("unsupported audio track") }
        reader.add(output)
        guard reader.startReading() else { throw Failure.unreadable(reader.error?.localizedDescription ?? "reader didn't start") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        var interleaved: [Float] = []
        var left: [Float] = []
        var right: [Float] = []
        var seconds = 0.0
        var reported = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            let frames = count / 2
            guard frames > 0 else { continue }
            if interleaved.count != count { interleaved = [Float](repeating: 0, count: count) }
            let status = interleaved.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            if left.count != frames {
                left = [Float](repeating: 0, count: frames)
                right = [Float](repeating: 0, count: frames)
            }
            for i in 0..<frames {
                left[i] = interleaved[2 * i]
                right[i] = interleaved[2 * i + 1]
            }
            try body(left, right)
            seconds += Double(frames) / sampleRate
            if seconds - reported >= 2 {
                reported = seconds
                progress(min(0.99, seconds / duration))
            }
        }
        if reader.status == .failed {
            throw Failure.unreadable(reader.error?.localizedDescription ?? "decoding failed")
        }
    }

    private static func append(_ left: [Float], _ right: [Float], to file: AVAudioFile, format: AVAudioFormat) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)),
              let channels = buffer.floatChannelData else { throw Failure.unreadable("buffer") }
        buffer.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: right.count) }
        try file.write(from: buffer)
    }
}

/// Runs a closure at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

private final class UncheckedBox<Value>: @unchecked Sendable {
    var value: Value?
}

/// Listens to a song file with on-device speech recognition and returns the words it heard, with times.
/// Audio is decoded and recognised on the phone; nothing is sent anywhere.
enum SongListener {
    enum Failure: LocalizedError {
        case permission
        case unavailable
        case noAudio

        var errorDescription: String? {
            switch self {
            case .permission: return "speech recognition is off for PitchLane in Settings"
            case .unavailable: return "on-device speech recognition isn't available for this language"
            case .noAudio: return "the song has no audio"
            }
        }
    }

    static let rate = 16_000.0

    /// Heard words with their song times. Steps:
    /// 1. decode the (voice) track to 16 kHz mono;
    /// 2. clean it up with Core `VocalPrep` (voice band, sung phrases levelled, silence between them);
    /// 3. focus it on the singer with Core `VoiceFocus` (keeps the sung pitch's harmonics, turns leftover music down);
    /// 4. recognise both the focused and the plain voice with the long-form on-device engine (`SpeechTranscriber`,
    ///    biased towards `hints`), keeping each phrase from the pass that heard it best (`HeardWordPicker`);
    /// 5. phrases nobody heard (or everything, if the long-form engine isn't available) go through the classic
    ///    on-device recogniser one at a time and are stitched back onto the timeline by phrase start;
    /// 6. tidy: words over silence, duplicates and stuck repeats are dropped.
    /// `locale` nil = work out the language from the singing first (`detectLocale`). Returns the words and the
    /// language actually used ("en-US", "ja-JP", ...).
    static func heardWords(
        in url: URL, locale requested: Locale?, hints: [String], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (words: [LyricListenMatcher.HeardWord], language: String) {
        guard await VoiceSearch.authorization() == .authorized else { throw Failure.permission }
        let samples = try await decodeMono(url)
        guard !samples.isEmpty else { throw Failure.noAudio }
        try Task.checkCancellation()
        let prepared = VocalPrep.prepare(samples, sampleRate: rate)
        let sung = prepared.segments.reduce(0) { $0 + $1.duration }
        AppLog.info("Voice prepared: \(prepared.segments.count) sung phrases, \(Int(sung)) s of \(Int(Double(samples.count) / rate)) s", category: "lyrics")
        let fallbackLocale = requested ?? Locale.current
        guard !prepared.segments.isEmpty else { return ([], identifier(fallbackLocale)) }
        progress(0.02)
        let focus = VoiceFocus.apply(prepared.samples, sampleRate: rate)
        try Task.checkCancellation()
        AppLog.info("Voice focus: pitch followed in \(Int((focus.focusedFraction * 100).rounded())) % of the sound", category: "lyrics")
        let voice = Voice(plain: prepared.samples, focused: focus.samples, segments: prepared.segments)
        var locale = fallbackLocale
        if requested == nil {
            if let detected = await detectLocale(voice, progress: { progress(0.05 + 0.15 * $0) }) {
                locale = detected
            }
            AppLog.info("Language detected from the singing: \(identifier(locale))", category: "lyrics")
        }
        let words = try await heardWords(voice: voice, locale: locale, hints: hints) { progress(0.2 + 0.8 * $0) }
        return (words, identifier(locale))
    }

    /// The prepared voice two ways: plain (`VocalPrep`) and focused on the sung pitch (`VoiceFocus`).
    struct Voice: Sendable {
        var plain: [Float]
        var focused: [Float]
        var segments: [VocalPrep.Segment]

        func slice(_ samples: [Float], _ segment: VocalPrep.Segment, maxLength: Double = .infinity) -> [Float] {
            let lo = max(0, Int(segment.start * SongListener.rate))
            let hi = min(samples.count, Int(min(segment.end, segment.start + maxLength) * SongListener.rate))
            return hi > lo ? Array(samples[lo..<hi]) : []
        }
    }

    static func identifier(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// Languages tried when detecting: the phone's own, then the most common song languages.
    static let detectionCandidates = ["en-US", "ja-JP", "zh-CN", "ko-KR", "es-ES"]

    /// Tries each candidate recogniser on the longest sung phrases (about 15 s) and keeps the language it is most
    /// confident in, as long as it actually heard words. Nil if nothing was convincing.
    static func detectLocale(_ voice: Voice, progress: @escaping @Sendable (Double) -> Void) async -> Locale? {
        var seen = Set<String>()
        let candidates = ([identifier(Locale.current)] + detectionCandidates).filter { id in
            seen.insert(String(id.prefix(2)).lowercased()).inserted
        }
        var sample: [VocalPrep.Segment] = []
        var total = 0.0
        for segment in voice.segments.sorted(by: { $0.duration > $1.duration }) where total < 15 && sample.count < 4 {
            sample.append(segment)
            total += min(segment.duration, 15)
        }
        var best: (locale: Locale, score: Double)?
        for (index, id) in candidates.enumerated() {
            if Task.isCancelled { return nil }
            let locale = Locale(identifier: id)
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { continue }
            var count = 0
            var confidence = 0.0
            for segment in sample {
                let piece = voice.slice(voice.focused, segment, maxLength: 15)
                guard !piece.isEmpty else { continue }
                let heard = await recognize(piece, recognizer: recognizer, hints: [])
                count += heard.words.count
                confidence += heard.confidence * Double(heard.words.count)
            }
            let mean = count > 0 ? confidence / Double(count) : 0
            // Confident and actually hearing words (a recogniser in the wrong language hears little, with low confidence).
            let score = mean * min(1, Double(count) / max(1, total * 0.6))
            AppLog.debug("Language \(id): \(count) words, confidence \(String(format: "%.2f", mean)), score \(String(format: "%.2f", score))", category: "lyrics")
            if score > (best?.score ?? 0.15) { best = (locale, score) }
            progress(Double(index + 1) / Double(candidates.count))
        }
        return best?.locale
    }

    private static func heardWords(
        voice: Voice, locale: Locale, hints: [String], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [LyricListenMatcher.HeardWord] {
        // Long-form passes: focused voice first (wins ties), then the plain voice.
        var passes: [[HeardWord]] = []
        for (index, input) in [voice.focused, voice.plain].enumerated() {
            do {
                let raw = try await longForm(input, locale: locale, hints: hints) { progress(0.3 * Double(index) + 0.3 * $0) }
                passes.append(splitMultiWord(raw))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLog.info("Long-form recogniser unavailable (\(error.localizedDescription)); using phrase-by-phrase", category: "lyrics")
                break
            }
        }
        var words = HeardWordPicker.bestPerSegment(passes, segments: voice.segments)
        if !passes.isEmpty {
            AppLog.info(
                "Long-form recogniser heard \(passes.map { String($0.count) }.joined(separator: " / ")) words (focused / plain); kept \(words.count)",
                category: "lyrics"
            )
        }
        progress(0.6)

        // Phrases nothing was heard in: try each on its own with the classic recogniser (focused, then plain).
        let missing = HeardWordPicker.unheard(words, segments: voice.segments, minDuration: passes.isEmpty ? 0 : 0.8)
        if !missing.isEmpty {
            if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition {
                var filled = 0
                for (step, index) in missing.enumerated() {
                    try Task.checkCancellation()
                    let segment = voice.segments[index]
                    var heard = await recognize(voice.slice(voice.focused, segment), recognizer: recognizer, hints: hints).words
                    if heard.isEmpty {
                        heard = await recognize(voice.slice(voice.plain, segment), recognizer: recognizer, hints: hints).words
                    }
                    if !heard.isEmpty { filled += 1 }
                    words += heard.map { HeardWord(text: $0.text, time: $0.time + segment.start, duration: $0.duration, confidence: $0.confidence) }
                    progress(0.6 + 0.38 * Double(step + 1) / Double(missing.count))
                }
                AppLog.info("Phrase-by-phrase recogniser: words in \(filled) of \(missing.count) phrases that were still empty", category: "lyrics")
            } else if passes.isEmpty {
                throw Failure.unavailable
            }
        }
        let split = splitMultiWord(words)
        let cleaned = HeardWordPicker.clean(split, segments: voice.segments)
        if cleaned.count != split.count {
            AppLog.debug("Tidied heard words: \(split.count) -> \(cleaned.count)", category: "lyrics")
        }
        progress(1)
        return cleaned
    }

    /// iOS 26 long-form speech-to-text over the cleaned voice (written to a temporary file), with word times on the
    /// song's own timeline. The language model is managed by iOS; audio stays on the phone.
    private static func longForm(
        _ samples: [Float], locale: Locale, hints: [String], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [HeardWord] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw Failure.unavailable }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pitchlane-voice-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        try writeMono(samples, to: file)
        let duration = max(1, Double(samples.count) / rate)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !hints.isEmpty {
            // Bias towards words we expect (the lyrics, or the title); harmless where the engine ignores it.
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(hints.prefix(100))
            do {
                try await analyzer.setContext(context)
            } catch {
                AppLog.debug("Listening hints not used: \(error.localizedDescription)", category: "lyrics")
            }
        }
        let collector = Task { () -> [HeardWord] in
            var words: [HeardWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = range.start.seconds, length = range.duration.seconds
                    guard start.isFinite, length.isFinite else { continue }
                    let confidence = run.transcriptionConfidence.map { Double($0) }
                    words.append(HeardWord(text: text, time: start, duration: max(0.05, length), confidence: confidence))
                    progress(min(1, (start + length) / duration))
                }
            }
            return words
        }
        let audioFile = try AVAudioFile(forReading: file)
        if let last = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    /// A recognised run with several words ("happy birthday") becomes one timed word each, sharing its time.
    private static func splitMultiWord(_ words: [HeardWord]) -> [HeardWord] {
        words.flatMap { word -> [HeardWord] in
            let parts = word.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count > 1 else { return [word] }
            let step = word.duration / Double(parts.count)
            return parts.enumerated().map {
                HeardWord(text: $1, time: word.time + Double($0) * step, duration: step, confidence: word.confidence)
            }
        }
    }

    private static func writeMono(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            throw Failure.noAudio
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var index = 0
        let piece = Int(rate) * 4
        while index < samples.count {
            let n = min(piece, samples.count - index)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let channel = buffer.floatChannelData?[0] else { throw Failure.noAudio }
            buffer.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + index, count: n) }
            try file.write(from: buffer)
            index += n
        }
    }

    /// One piece of audio through the classic on-device recogniser: the words and their mean confidence (0...1).
    private static func recognize(_ samples: [Float], recognizer: SFSpeechRecognizer, hints: [String]) async -> (words: [HeardWord], confidence: Double) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return ([], 0) }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = Array(hints.prefix(100))
        let once = Once()
        let taskBox = UncheckedBox<SFSpeechRecognitionTask>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<(words: [HeardWord], confidence: Double), Never>) in
            taskBox.value = recognizer.recognitionTask(with: request) { @Sendable result, error in
                guard (result?.isFinal ?? false) || error != nil else { return }
                let segments = result?.bestTranscription.segments ?? []
                let words = segments.map {
                    HeardWord(text: $0.substring, time: $0.timestamp, duration: $0.duration, confidence: $0.confidence > 0 ? Double($0.confidence) : nil)
                }
                let confidence = segments.isEmpty ? 0 : segments.reduce(0.0) { $0 + Double($1.confidence) } / Double(segments.count)
                once.run { continuation.resume(returning: (words, confidence)) }
            }
            var index = 0
            let piece = Int(rate)
            while index < samples.count {
                let n = min(piece, samples.count - index)
                if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)), let channel = buffer.floatChannelData?[0] {
                    buffer.frameLength = AVAudioFrameCount(n)
                    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + index, count: n) }
                    request.append(buffer)
                }
                index += n
            }
            request.endAudio()
            // Never wait forever on one piece.
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
                once.run { continuation.resume(returning: ([], 0)) }
                taskBox.value?.cancel()
            }
        }
    }

    /// The whole file as mono floats at 16 kHz (about 4 MB per minute).
    static func decodeMono(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        return try readMono(asset: asset, track: track)
    }

    private static func readMono(asset: AVURLAsset, track: AVAssetTrack) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { throw Failure.noAudio }
        reader.add(output)
        guard reader.startReading() else { throw Failure.noAudio }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            _ = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
        }
        return samples
    }
}

typealias HeardWord = LyricListenMatcher.HeardWord
/// Notes written from the singer's voice only: pitch frames outside sung phrases (instrument leakage, breaths,
/// silence) are dropped, so the lane holds the vocal melody, not the backing.
enum VocalAnalysis {
    static func notes(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [SongNote] {
        let rate = SongListener.rate
        let samples = try await SongListener.decodeMono(url)
        try Task.checkCancellation()
        let segments = VocalPrep.segments(VocalPrep.voiceBand(samples, sampleRate: rate), sampleRate: rate)
        let pipeline = PitchPipeline(inputSampleRate: rate)
        var transcriber = MelodyTranscriber()
        let piece = Int(rate)
        var index = 0
        while index < samples.count {
            try Task.checkCancellation()
            let end = min(samples.count, index + piece)
            for frame in pipeline.process(Array(samples[index..<end])) {
                transcriber.add(time: frame.time, midi: VocalPrep.contains(segments, frame.time) ? frame.midi : nil)
            }
            index = end
            if index % (piece * 5) == 0 { progress(Double(index) / Double(samples.count)) }
        }
        progress(1)
        return transcriber.finish()
    }
}
#endif
