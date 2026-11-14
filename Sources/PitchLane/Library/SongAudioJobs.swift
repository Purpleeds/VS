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
    static let chunkSeconds = 30.0

    static func heardWords(
        in url: URL, locale: Locale = .current, hints: [String], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [LyricListenMatcher.HeardWord] {
        guard await VoiceSearch.authorization() == .authorized else { throw Failure.permission }
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw Failure.unavailable }
        let samples = try await decodeMono(url)
        guard !samples.isEmpty else { throw Failure.noAudio }
        let chunk = Int(chunkSeconds * rate)
        let pieces = max(1, (samples.count + chunk - 1) / chunk)
        var words: [HeardWord] = []
        var start = 0
        var done = 0
        while start < samples.count {
            try Task.checkCancellation()
            let end = min(samples.count, start + chunk)
            let offset = Double(start) / rate
            let heard = await recognize(Array(samples[start..<end]), recognizer: recognizer, hints: hints)
            words += heard.map { HeardWord(text: $0.text, time: $0.time + offset, duration: $0.duration) }
            done += 1
            progress(Double(done) / Double(pieces))
            start = end
        }
        return words
    }

    private static func recognize(_ samples: [Float], recognizer: SFSpeechRecognizer, hints: [String]) async -> [HeardWord] {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else { return [] }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = Array(hints.prefix(100))
        let once = Once()
        let taskBox = UncheckedBox<SFSpeechRecognitionTask>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<[HeardWord], Never>) in
            taskBox.value = recognizer.recognitionTask(with: request) { @Sendable result, error in
                guard (result?.isFinal ?? false) || error != nil else { return }
                let words = result?.bestTranscription.segments.map {
                    HeardWord(text: $0.substring, time: $0.timestamp, duration: $0.duration)
                } ?? []
                once.run { continuation.resume(returning: words) }
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
                once.run { continuation.resume(returning: []) }
                taskBox.value?.cancel()
            }
        }
    }

    /// The whole file as mono floats at 16 kHz (about 4 MB per minute).
    private static func decodeMono(_ url: URL) async throws -> [Float] {
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
#endif
