#if canImport(SwiftUI)
import AVFoundation
import Foundation
import PitchLaneCore

/// Hand-off from the audio tap to the pitch pipeline.
/// The tap copies samples into a lock-free ring and pokes a dispatch source; all analysis runs on a private
/// serial queue. Everything below "Queue-confined" is only touched on that queue.
final class PitchAnalyzer: @unchecked Sendable {
    struct Stats: Sendable, Equatable {
        var analysisAverageMs: Double
        var analysisMaxMs: Double
        var framesPerSecond: Double
        var droppedBuffers: Int
        var inputSampleRate: Double
    }

    /// Exact capture time of one point of the analysis stream: stream time (seconds since this pipeline started)
    /// <-> host seconds when that sample was captured.
    struct CaptureAnchor: Sendable, Equatable {
        var streamTime: Double
        var hostSeconds: Double
    }

    struct Batch: Sendable {
        var frames: [PitchFrame]
        var stats: Stats?
        var capture: CaptureAnchor?
    }

    private let queue = DispatchQueue(label: "PitchLane.pitch-analysis", qos: .userInteractive)
    private let ring = AudioCaptureRing(capacity: 1 << 17)
    private let wake: DispatchSourceUserDataAdd

    // Queue-confined.
    private var deliver: (@Sendable (Batch) -> Void)?
    private var pipeline: PitchPipeline?
    private var accidentals: Accidentals = .sharps
    private var scratch = [Float](repeating: 0, count: 4_096)
    private var sessionStats = PitchSessionStats()
    private var statsWindowStart = ContinuousClock.now
    private var framesInWindow = 0
    private var logTiming = AnalysisTiming()
    private var droppedAtLastLog = 0
    private var streamBase = 0
    private var inputRate = 48_000.0

    init() {
        wake = DispatchSource.makeUserDataAddSource(queue: queue)
        wake.setEventHandler { [weak self] in
            self?.drain()
        }
        wake.activate()
    }

    func setDelivery(_ deliver: @escaping @Sendable (Batch) -> Void) {
        queue.async { [self] in
            self.deliver = deliver
        }
    }

    /// The tap block. Runs on the audio thread: copies channel 0 into the ring and wakes the queue.
    /// No allocation, locks or logging in here.
    func makeTapBlock() -> AVAudioNodeTapBlock {
        { @Sendable [self] buffer, when in
            self.ingest(buffer, when: when)
        }
    }

    private func ingest(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let index = ring.producerCount
        if ring.write(channels[0], count: count), when.isHostTimeValid {
            ring.recordCapture(index: index, hostTime: when.hostTime)
        }
        wake.add(data: 1)
    }

    /// Call before installing a tap with a (possibly new) input format, or to change detector settings.
    func prepare(sampleRate: Double, configuration: PitchPipelineConfiguration) {
        queue.async { [self] in
            flushStats()
            ring.discardAll()
            streamBase = ring.consumerCount
            inputRate = sampleRate
            let pipeline = PitchPipeline(inputSampleRate: sampleRate, configuration: configuration)
            self.pipeline = pipeline
            self.accidentals = configuration.accidentals
            sessionStats = PitchSessionStats()
            statsWindowStart = .now
            framesInWindow = 0
            logTiming = AnalysisTiming()
            droppedAtLastLog = ring.droppedChunks
            let range = configuration.detector
            AppLog.info(
                "Analysis ready: input \(Int(sampleRate)) Hz -> \(Int(range.sampleRate)) Hz, "
                    + "window \(Self.format(pipeline.windowDuration * 1_000, 1)) ms, hop \(Self.format(configuration.hopDuration * 1_000, 0)) ms, "
                    + "range \(Int(range.minFrequency.rounded()))-\(Int(range.maxFrequency.rounded())) Hz, "
                    + "gate \(Int(configuration.stabilizer.noiseGateDBFS)) dBFS",
                category: "pitch"
            )
        }
    }

    /// Call after the tap is removed.
    func stop() {
        queue.async { [self] in
            flushStats()
            pipeline = nil
            ring.discardAll()
        }
    }

    func setAccidentals(_ accidentals: Accidentals) {
        queue.async { [self] in
            self.accidentals = accidentals
            pipeline?.setAccidentals(accidentals)
        }
    }

    // MARK: Queue-confined

    private func drain() {
        guard let pipeline else {
            ring.discardAll()
            return
        }
        var frames: [PitchFrame] = []
        var events: [PitchLogEvent] = []
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            while true {
                let n = ring.read(into: base, maxCount: buffer.count)
                if n == 0 { break }
                pipeline.process(UnsafeBufferPointer(start: base, count: n)) { frame in
                    frames.append(frame)
                    events.append(contentsOf: sessionStats.add(frame))
                }
            }
        }
        framesInWindow += frames.count

        var stats: Stats?
        let now = ContinuousClock.now
        let elapsed = Self.seconds(now - statsWindowStart)
        if elapsed >= 0.5 {
            let timing = pipeline.timing
            stats = Stats(
                analysisAverageMs: timing.averageSeconds * 1_000,
                analysisMaxMs: timing.maxSeconds * 1_000,
                framesPerSecond: Double(framesInWindow) / elapsed,
                droppedBuffers: ring.droppedChunks,
                inputSampleRate: pipeline.inputSampleRate
            )
            logTiming.merge(timing)
            pipeline.resetTiming()
            framesInWindow = 0
            statsWindowStart = now
        }

        for event in events { log(event) }
        var capture: CaptureAnchor?
        if let latest = ring.latestCapture(), latest.index >= streamBase {
            capture = CaptureAnchor(
                streamTime: Double(latest.index - streamBase) / inputRate,
                hostSeconds: AVAudioTime.seconds(forHostTime: latest.hostTime)
            )
        }
        if let deliver, !frames.isEmpty || stats != nil {
            deliver(Batch(frames: frames, stats: stats, capture: capture))
        }
    }

    private func flushStats() {
        guard pipeline != nil else { return }
        for event in sessionStats.finish() { log(event) }
    }

    private func log(_ event: PitchLogEvent) {
        switch event {
        case .segment(let segment):
            AppLog.info(segment.description(accidentals: accidentals), category: "pitch")
        case .interval(let interval):
            let dropped = ring.droppedChunks
            let audio = "analysis avg \(Self.format(logTiming.averageSeconds * 1_000, 3)) ms, "
                + "max \(Self.format(logTiming.maxSeconds * 1_000, 3)) ms, dropped +\(dropped - droppedAtLastLog) (total \(dropped))"
            AppLog.info(interval.description + " | " + audio, category: "pitch")
            logTiming = AnalysisTiming()
            droppedAtLastLog = dropped
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }

    static func format(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}
#endif
