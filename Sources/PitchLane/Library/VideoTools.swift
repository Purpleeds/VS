#if canImport(SwiftUI)
import AVFoundation
import CoreMedia
import CoreTransferable
import Foundation
import PitchLaneCore
import UniformTypeIdentifiers

/// Video helpers: pull the soundtrack out as backing audio, and transcribe the singing into notes.
/// Video frames are never analysed; audio is decoded on the fly and only pitch frames are kept.
enum VideoTools {
    enum Failure: LocalizedError {
        case noAudio
        case cannotExport
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noAudio: return "The video has no sound."
            case .cannotExport: return "The video's sound couldn't be extracted."
            case .unreadable(let detail): return "The video couldn't be read (\(detail))."
            }
        }
    }

    static let extensions: Set<String> = ["mov", "mp4", "m4v"]
    static let contentTypes: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie]

    static func isVideo(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Writes the video's soundtrack to `output` as AAC (.m4a).
    static func extractAudio(from video: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw Failure.noAudio }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure.cannotExport
        }
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: .m4a)
    }

    /// Decodes the soundtrack, runs it through the pitch pipeline, and turns the sung line into notes.
    /// `progress` gets 0...1 about once a second of audio.
    static func transcribe(_ video: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [SongNote] {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.noAudio }
        let duration = max(1, try await asset.load(.duration).seconds)
        return try decodeAndTranscribe(asset: asset, track: track, duration: duration, progress: progress)
    }

    private static func decodeAndTranscribe(
        asset: AVURLAsset,
        track: AVAssetTrack,
        duration: Double,
        progress: @Sendable (Double) -> Void
    ) throws -> [SongNote] {
        let sampleRate = 48_000.0
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.unreadable("unsupported audio track") }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.unreadable(reader.error?.localizedDescription ?? "reader didn't start")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let pipeline = PitchPipeline(inputSampleRate: sampleRate)
        var transcriber = MelodyTranscriber()
        var samples: [Float] = []
        var seconds = 0.0
        var reported = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if samples.count != count { samples = [Float](repeating: 0, count: count) }
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for frame in pipeline.process(samples) {
                transcriber.add(time: frame.time, midi: frame.midi)
            }
            seconds += Double(count) / sampleRate
            if seconds - reported >= 1 {
                reported = seconds
                progress(min(1, seconds / duration))
            }
        }
        if reader.status == .failed {
            throw Failure.unreadable(reader.error?.localizedDescription ?? "decoding failed")
        }
        progress(1)
        return transcriber.finish()
    }
}

/// A video picked in Photos, copied into the app's temporary import folder.
struct PickedMovie: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PitchLaneImport", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension.lowercased()
            let copy = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}
#endif
