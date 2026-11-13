#if canImport(SwiftUI)
import AVFoundation
import PitchLaneCore

/// The song's backing audio: player -> time-pitch (rate 1 for now; practice speed later) -> main mixer,
/// on the same engine as the mic, so it runs on the same output clock as the guide tone.
@MainActor
final class BackingTrack {
    private(set) var player = AVAudioPlayerNode()
    private(set) var timePitch = AVAudioUnitTimePitch()
    private(set) var file: AVAudioFile?
    private weak var engine: AVAudioEngine?
    private var connectedFormat: AVAudioFormat?

    var duration: Double {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Processing latency of the time-pitch unit; playback is scheduled this much earlier.
    var latency: Double { timePitch.auAudioUnit.latency }

    func attach(to engine: AVAudioEngine, outputRate: Double) {
        if self.engine !== engine {
            player = AVAudioPlayerNode()
            timePitch = AVAudioUnitTimePitch()
            engine.attach(player)
            engine.attach(timePitch)
            self.engine = engine
            connectedFormat = nil
        }
        if connectedFormat == nil, let format = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2) {
            connect(format: format)
        }
    }

    private func connect(format: AVAudioFormat) {
        guard let engine else { return }
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        timePitch.rate = 1
        connectedFormat = format
    }

    /// Opens the file and matches the connection to its format. Throws if it can't be read.
    func load(url: URL) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        if connectedFormat?.sampleRate != format.sampleRate || connectedFormat?.channelCount != format.channelCount {
            connect(format: format)
        }
        self.file = file
    }

    func unload() {
        stop()
        file = nil
    }

    /// Starts playing at `fileTime` seconds into the file, at host time `hostSeconds`.
    func play(fromFileTime fileTime: Double, atHost hostSeconds: Double) {
        guard let file, let engine, engine.isRunning else { return }
        let rate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, fileTime) * rate)
        guard startFrame < file.length else { return }
        let frames = AVAudioFrameCount(min(Int64(UInt32.max), file.length - startFrame))
        player.stop()
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: max(0, hostSeconds)))
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: when, completionHandler: nil)
        player.play()
    }

    func stop() {
        if player.engine != nil { player.stop() }
    }

    /// Practice speed (0.5...1); pitch is preserved by the time-pitch unit.
    func setRate(_ rate: Double) {
        timePitch.rate = Float(max(0.5, min(2, rate)))
    }

    func setVolume(_ volume: Float) {
        player.volume = max(0, min(1, volume))
    }
}
#endif
