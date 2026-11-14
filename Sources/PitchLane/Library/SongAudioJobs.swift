#if canImport(SwiftUI)
import AVFoundation
import CoreMedia
import Foundation
import Speech
import PitchLaneCore

/// Splits a song's backing audio into a voice stem and a music stem (Core `StemSeparator`), on the phone.
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

    /// Writes AAC stereo stems to `vocalsOut` and `musicOut` (.m4a). `progress` gets 0...1.
    static func separate(_ source: URL, vocalsOut: URL, musicOut: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        let duration = max(1, try await asset.load(.duration).seconds)
        let descriptions = try await track.load(.formatDescriptions)
        let channels = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2
        guard channels >= 2 else { throw Failure.mono }
        try run(asset: asset, track: track, duration: duration, vocalsOut: vocalsOut, musicOut: musicOut, progress: progress)
    }

    private static func run(
        asset: AVURLAsset, track: AVAssetTrack, duration: Double, vocalsOut: URL, musicOut: URL, progress: @Sendable (Double) -> Void
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
        let separator = StemSeparator(sampleRate: sampleRate)

        func write(_ out: StemSeparator.Output) throws {
            guard out.count > 0 else { return }
            try append(out.vocalsLeft, out.vocalsRight, to: vocalsFile, format: format)
            try append(out.musicLeft, out.musicRight, to: musicFile, format: format)
        }

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
            try write(separator.process(left: left, right: right))
            seconds += Double(frames) / sampleRate
            if seconds - reported >= 2 {
                reported = seconds
                progress(min(0.99, seconds / duration))
            }
        }
        if reader.status == .failed {
            throw Failure.unreadable(reader.error?.localizedDescription ?? "decoding failed")
        }
        try write(separator.finish())
        if separator.isEffectivelyMono { throw Failure.mono }
        progress(1)
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
/// Audio is decoded and recognised on the phone, in 30-second pieces; nothing is sent anywhere.
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
    /// 3. recognise it with the long-form on-device engine (`SpeechTranscriber`), which keeps the song's own timeline;
    /// 4. if that isn't available or hears almost nothing, recognise each sung phrase on its own with the classic
    ///    on-device recogniser and stitch the words back onto the timeline by phrase start.
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
        var locale = fallbackLocale
        if requested == nil {
            if let detected = await detectLocale(prepared, progress: { progress(0.2 * $0) }) {
                locale = detected
            }
            AppLog.info("Language detected from the singing: \(identifier(locale))", category: "lyrics")
        }
        let words = try await heardWords(prepared: prepared, locale: locale, hints: hints) { progress(0.2 + 0.8 * $0) }
        return (words, identifier(locale))
    }

    static func identifier(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// Languages tried when detecting: the phone's own, then the most common song languages.
    static let detectionCandidates = ["en-US", "ja-JP", "zh-CN", "ko-KR", "es-ES"]

    /// Tries each candidate recogniser on the longest sung phrases (about 15 s) and keeps the language it is most
    /// confident in, as long as it actually heard words. Nil if nothing was convincing.
    static func detectLocale(_ prepared: VocalPrep.Prepared, progress: @escaping @Sendable (Double) -> Void) async -> Locale? {
        var seen = Set<String>()
        let candidates = ([identifier(Locale.current)] + detectionCandidates).filter { id in
            seen.insert(String(id.prefix(2)).lowercased()).inserted
        }
        var sample: [VocalPrep.Segment] = []
        var total = 0.0
        for segment in prepared.segments.sorted(by: { $0.duration > $1.duration }) where total < 15 && sample.count < 4 {
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
                let lo = max(0, Int(segment.start * rate)), hi = min(prepared.samples.count, Int(min(segment.end, segment.start + 15) * rate))
                guard hi > lo else { continue }
                let heard = await recognize(Array(prepared.samples[lo..<hi]), recognizer: recognizer, hints: [])
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
        prepared: VocalPrep.Prepared, locale: Locale, hints: [String], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [LyricListenMatcher.HeardWord] {
        var words: [HeardWord] = []
        do {
            words = try await longForm(prepared.samples, locale: locale) { progress(0.6 * $0) }
            AppLog.info("Long-form recogniser heard \(words.count) words", category: "lyrics")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLog.info("Long-form recogniser unavailable (\(error.localizedDescription)); using phrase-by-phrase", category: "lyrics")
        }
        if words.count < 3 {
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                if words.isEmpty { throw Failure.unavailable }
                return words
            }
            var stitched: [HeardWord] = []
            for (index, segment) in prepared.segments.enumerated() {
                try Task.checkCancellation()
                let lo = max(0, Int(segment.start * rate)), hi = min(prepared.samples.count, Int(segment.end * rate))
                guard hi > lo else { continue }
                let heard = await recognize(Array(prepared.samples[lo..<hi]), recognizer: recognizer, hints: hints).words
                stitched += heard.map { HeardWord(text: $0.text, time: $0.time + segment.start, duration: $0.duration) }
                progress(0.6 + 0.4 * Double(index + 1) / Double(prepared.segments.count))
            }
            AppLog.info("Phrase-by-phrase recogniser heard \(stitched.count) words", category: "lyrics")
            if stitched.count > words.count { words = stitched }
        }
        progress(1)
        return splitMultiWord(words).sorted { $0.time < $1.time }
    }

    /// iOS 26 long-form speech-to-text over the cleaned voice (written to a temporary file), with word times on the
    /// song's own timeline. The language model is managed by iOS; audio stays on the phone.
    private static func longForm(_ samples: [Float], locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> [HeardWord] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw Failure.unavailable }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pitchlane-voice-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        try writeMono(samples, to: file)
        let duration = max(1, Double(samples.count) / rate)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [HeardWord] in
            var words: [HeardWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = range.start.seconds, length = range.duration.seconds
                    guard start.isFinite, length.isFinite else { continue }
                    words.append(HeardWord(text: text, time: start, duration: max(0.05, length)))
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
            return parts.enumerated().map { HeardWord(text: $1, time: word.time + Double($0) * step, duration: step) }
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
                let words = segments.map { HeardWord(text: $0.substring, time: $0.timestamp, duration: $0.duration) }
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
