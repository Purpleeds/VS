#if canImport(SwiftUI)
import AVFoundation
import PitchLaneCore

/// A song's separated stems (voice and music), played together in place of the full backing.
struct BackingStems: Hashable {
    var vocals: URL
    var music: URL
}

/// The song's backing audio on the shared engine, so it runs on the same output clock as the guide tone:
///
///     player (full mix, or the voice stem) ──┐
///                                            ├─ stem mixer ─ time-pitch (practice speed) ─ main mixer
///     music player (music stem, if any) ─────┘
///
/// With stems both players are scheduled at the same host time, so they stay sample-locked; each has its own
/// volume (the voice/music sliders) and the stem mixer carries the overall backing volume.
@MainActor
final class BackingTrack {
    private(set) var player = AVAudioPlayerNode()
    private(set) var musicPlayer = AVAudioPlayerNode()
    private(set) var stemMixer = AVAudioMixerNode()
    private(set) var timePitch = AVAudioUnitTimePitch()
    private(set) var file: AVAudioFile?
    private(set) var musicFile: AVAudioFile?
    private weak var engine: AVAudioEngine?
    private var connected: (main: AVAudioFormat, music: AVAudioFormat)?
    private var outputRate = 48_000.0
    private var rate: Float = 1
    private var voiceVolume: Float = 1
    private var musicVolume: Float = 1

    var hasStems: Bool { musicFile != nil }

    var duration: Double {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Processing latency of the time-pitch unit; playback is scheduled this much earlier.
    var latency: Double { timePitch.auAudioUnit.latency }

    func attach(to engine: AVAudioEngine, outputRate: Double) {
        self.outputRate = outputRate
        if self.engine !== engine {
            player = AVAudioPlayerNode()
            musicPlayer = AVAudioPlayerNode()
            stemMixer = AVAudioMixerNode()
            timePitch = AVAudioUnitTimePitch()
            engine.attach(player)
            engine.attach(musicPlayer)
            engine.attach(stemMixer)
            engine.attach(timePitch)
            self.engine = engine
            connected = nil
        }
        // After a media-services reset the nodes are new but the files are still loaded: connect with the files' own
        // formats, or scheduling them later would hit a channel/rate mismatch.
        if connected == nil { connectForFiles() }
    }

    /// Wires the graph for the loaded files (or a plain stereo format when nothing is loaded).
    private func connectForFiles() {
        guard let engine, let fallback = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2) else { return }
        let main = file?.processingFormat ?? fallback
        let music = musicFile?.processingFormat ?? main
        if let connected, connected.main == main, connected.music == music { return }
        guard let mixed = AVAudioFormat(standardFormatWithSampleRate: main.sampleRate, channels: 2) else { return }
        engine.connect(player, to: stemMixer, fromBus: 0, toBus: 0, format: main)
        engine.connect(musicPlayer, to: stemMixer, fromBus: 0, toBus: 1, format: music)
        engine.connect(stemMixer, to: timePitch, format: mixed)
        engine.connect(timePitch, to: engine.mainMixerNode, format: mixed)
        timePitch.rate = rate
        connected = (main, music)
        applyStemVolumes()
    }

    private static func open(_ url: URL) throws -> AVAudioFile {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard (1...2).contains(format.channelCount), format.sampleRate > 0 else {
            throw NSError(domain: "PitchLane.BackingTrack", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Backing audio must be mono or stereo (this file has \(format.channelCount) channels).",
            ])
        }
        return file
    }

    /// Opens the full backing mix. Throws if it can't be read.
    func load(url: URL) throws {
        stop()
        let opened = try Self.open(url)
        file = opened
        musicFile = nil
        connectForFiles()
    }

    /// Opens the voice and music stems (same length and rate). Throws if either can't be read.
    func load(stems: BackingStems) throws {
        stop()
        let vocals = try Self.open(stems.vocals)
        let music = try Self.open(stems.music)
        guard vocals.processingFormat.sampleRate == music.processingFormat.sampleRate else {
            throw NSError(domain: "PitchLane.BackingTrack", code: 2, userInfo: [NSLocalizedDescriptionKey: "The stems don't match."])
        }
        file = vocals
        musicFile = music
        connectForFiles()
    }

    func unload() {
        stop()
        file = nil
        musicFile = nil
    }

    /// Starts playing at `fileTime` seconds into the file(s), at host time `hostSeconds`.
    func play(fromFileTime fileTime: Double, atHost hostSeconds: Double) {
        guard let file, let engine, engine.isRunning else { return }
        connectForFiles()
        let when = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: max(0, hostSeconds)))
        player.stop()
        musicPlayer.stop()
        guard Self.schedule(file, on: player, from: fileTime, at: when) else { return }
        if let musicFile, Self.schedule(musicFile, on: musicPlayer, from: fileTime, at: when) {
            musicPlayer.play()
        }
        player.play()
    }

    private static func schedule(_ file: AVAudioFile, on node: AVAudioPlayerNode, from fileTime: Double, at when: AVAudioTime) -> Bool {
        let rate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, fileTime) * rate)
        guard startFrame < file.length else { return false }
        let frames = AVAudioFrameCount(min(Int64(UInt32.max), file.length - startFrame))
        node.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: when, completionHandler: nil)
        return true
    }

    func stop() {
        if player.engine != nil { player.stop() }
        if musicPlayer.engine != nil { musicPlayer.stop() }
    }

    /// Practice speed (0.5...1); pitch is preserved by the time-pitch unit.
    func setRate(_ rate: Double) {
        self.rate = Float(max(0.5, min(2, rate)))
        timePitch.rate = self.rate
    }

    /// Overall backing volume.
    func setVolume(_ volume: Float) {
        stemMixer.outputVolume = max(0, min(1, volume))
    }

    /// Voice and music levels when stems are loaded (ignored for a full mix).
    func setStemVolumes(voice: Float, music: Float) {
        voiceVolume = max(0, min(1, voice))
        musicVolume = max(0, min(1, music))
        applyStemVolumes()
    }

    private func applyStemVolumes() {
        player.volume = hasStems ? voiceVolume : 1
        musicPlayer.volume = musicVolume
    }
}
#endif
