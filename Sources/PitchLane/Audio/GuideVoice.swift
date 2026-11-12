#if canImport(SwiftUI)
import AVFoundation
import Synchronization
import PitchLaneCore

/// Render-thread side of playback: plays the guide synth and publishes the output clock.
///
/// The source node's render callback runs on every output cycle (silent or not), so its
/// (sample time, host time) pair is the master clock: the output sample timeline. Everything the render
/// thread reads is atomic or handed over through an atomic slot flip; it never allocates, locks or logs.
final class GuideVoice: @unchecked Sendable {
    let sampleRate: Double

    /// (anchor render seconds bits, anchor song time bits). Song time NaN = no song; render +inf = paused.
    private let timeline = Atomic<WordPair>(WordPair(first: 0, second: UInt(Double.nan.bitPattern)))
    private let volumeBits = Atomic<UInt32>(0)
    /// Which renderer slot the audio thread uses: 0, 1, or -1 for none.
    private let activeSlot = Atomic<Int>(-1)
    /// (sample time bits, host time) of the latest render cycle; (0, 0) until the first one.
    private let anchor = Atomic<WordPair>(WordPair(first: 0, second: 0))

    // Written by the main thread only while inactive; read by the audio thread only while active.
    private var slotA: GuideToneRenderer?
    private var slotB: GuideToneRenderer?
    /// Main-thread bookkeeping: the slot written by the last install. The next install writes the other one,
    /// so a slot the render thread may still be reading is never overwritten right after an uninstall.
    private var lastWrittenSlot = 1

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    // MARK: Main thread

    /// Hands a renderer to the audio thread (nil = silence). Don't call twice within a few milliseconds.
    func install(_ renderer: GuideToneRenderer?) {
        guard let renderer else {
            activeSlot.store(-1, ordering: .releasing)
            return
        }
        let target = lastWrittenSlot == 0 ? 1 : 0
        if target == 0 { slotA = renderer } else { slotB = renderer }
        lastWrittenSlot = target
        activeSlot.store(target, ordering: .releasing)
    }

    func setTimeline(anchorRender: Double, anchorSong: Double) {
        timeline.store(WordPair(first: UInt(anchorRender.bitPattern), second: UInt(anchorSong.bitPattern)), ordering: .releasing)
    }

    func stopTimeline() {
        timeline.store(WordPair(first: 0, second: UInt(Double.nan.bitPattern)), ordering: .releasing)
    }

    func setVolume(_ volume: Float) {
        volumeBits.store(max(0, min(1, volume)).bitPattern, ordering: .relaxed)
    }

    /// The latest output-clock reading, or nil before the first render cycle.
    func outputAnchor() -> OutputClockAnchor? {
        let pair = anchor.load(ordering: .acquiring)
        guard pair.second != 0 else { return nil }
        return OutputClockAnchor(
            sampleTime: Double(bitPattern: UInt64(pair.first)),
            hostSeconds: AVAudioTime.seconds(forHostTime: UInt64(pair.second)),
            sampleRate: sampleRate
        )
    }

    // MARK: Audio thread

    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        { @Sendable [self] isSilence, timestamp, frameCount, bufferList in
            self.render(isSilence: isSilence, timestamp: timestamp, frameCount: frameCount, bufferList: bufferList)
        }
    }

    private func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AVAudioFrameCount,
        bufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let stamp = timestamp.pointee
        if stamp.mFlags.contains(.sampleHostTimeValid) {
            anchor.store(WordPair(first: UInt(stamp.mSampleTime.bitPattern), second: UInt(stamp.mHostTime)), ordering: .releasing)
        }
        let frames = Int(frameCount)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count > 0, let raw = buffers[0].mData else { return 0 }
        let out = raw.assumingMemoryBound(to: Float.self)

        let slot = activeSlot.load(ordering: .acquiring)
        let renderer: GuideToneRenderer? = slot == 0 ? slotA : (slot == 1 ? slotB : nil)
        let line = timeline.load(ordering: .acquiring)
        let anchorRender = Double(bitPattern: UInt64(line.first))
        let anchorSong = Double(bitPattern: UInt64(line.second))

        if let renderer, !anchorSong.isNaN, stamp.mFlags.contains(.sampleTimeValid) {
            let renderSeconds = stamp.mSampleTime / sampleRate
            let advancing = renderSeconds >= anchorRender
            let songTime = advancing ? anchorSong + (renderSeconds - anchorRender) : anchorSong
            renderer.render(
                into: out,
                frameCount: frames,
                sampleRate: sampleRate,
                songTime: songTime,
                advancing: advancing,
                volume: Float(bitPattern: volumeBits.load(ordering: .relaxed))
            )
        } else {
            out.update(repeating: 0, count: frames)
            isSilence.pointee = ObjCBool(true)
        }
        for index in 1..<max(1, buffers.count) {
            if let other = buffers[index].mData {
                other.assumingMemoryBound(to: Float.self).update(from: out, count: frames)
            }
        }
        return 0
    }
}
#endif
