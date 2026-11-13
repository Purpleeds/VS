import Foundation

public struct PitchPipelineConfiguration: Sendable, Equatable {
    public var detector: PitchDetectorConfiguration
    public var stabilizer: PitchStabilizerConfiguration
    /// Time between analysis frames.
    public var hopDuration: Double
    public var accidentals: Accidentals

    public init(
        detector: PitchDetectorConfiguration = .voice,
        stabilizer: PitchStabilizerConfiguration = .init(),
        hopDuration: Double = 0.01,
        accidentals: Accidentals = .sharps
    ) {
        self.detector = detector
        self.stabilizer = stabilizer
        self.hopDuration = hopDuration
        self.accidentals = accidentals
    }
}

extension PitchPipelineConfiguration {
    /// Detector range and noise gate from the user's settings.
    public static func configured(instrument: Bool, noiseGateDBFS: Double, accidentals: Accidentals) -> PitchPipelineConfiguration {
        var stabilizer = PitchStabilizerConfiguration()
        stabilizer.noiseGateDBFS = noiseGateDBFS
        return PitchPipelineConfiguration(
            detector: instrument ? .instrument : .voice,
            stabilizer: stabilizer,
            accidentals: accidentals
        )
    }
}

/// Mic samples in, `PitchFrame`s out: resample -> sliding window -> YIN -> stabiliser.
/// Not thread-safe; drive it from one serial queue. Steady-state processing does not allocate
/// apart from the note-name strings in emitted frames.
public final class PitchPipeline {
    public let inputSampleRate: Double
    public private(set) var configuration: PitchPipelineConfiguration
    public private(set) var timing = AnalysisTiming()

    private var resampler: StreamingResampler
    private let detector: PitchDetector
    private var stabilizer: PitchStabilizer
    private let frameLength: Int
    private let hop: Int
    /// Double-written ring: the newest `frameLength` samples are always contiguous.
    private var window: [Float]
    private var writeIndex = 0
    private var filled = 0
    private var sinceLastFrame = 0
    private var samplesConsumed = 0
    private var resampled: [Float] = []

    public init(inputSampleRate: Double, configuration: PitchPipelineConfiguration = .init()) {
        self.inputSampleRate = inputSampleRate
        self.configuration = configuration
        self.resampler = StreamingResampler(inputRate: inputSampleRate, outputRate: configuration.detector.sampleRate)
        self.detector = PitchDetector(configuration: configuration.detector)
        self.stabilizer = PitchStabilizer(configuration: configuration.stabilizer)
        self.frameLength = configuration.detector.frameLength
        self.hop = max(1, Int((configuration.hopDuration * configuration.detector.sampleRate).rounded()))
        self.window = [Float](repeating: 0, count: frameLength * 2)
        self.resampled.reserveCapacity(8_192)
    }

    /// Analysis frames produced per second.
    public var framesPerSecond: Double { configuration.detector.sampleRate / Double(hop) }
    /// Seconds of audio in each analysis window.
    public var windowDuration: Double { Double(frameLength) / configuration.detector.sampleRate }

    public func setAccidentals(_ accidentals: Accidentals) {
        configuration.accidentals = accidentals
    }

    public func resetTiming() {
        timing = AnalysisTiming()
    }

    public func reset() {
        resampler.reset()
        stabilizer.reset()
        for i in window.indices { window[i] = 0 }
        writeIndex = 0
        filled = 0
        sinceLastFrame = 0
        samplesConsumed = 0
    }

    /// Feeds input-rate samples; calls `emit` for every completed frame, in order.
    public func process(_ samples: UnsafeBufferPointer<Float>, emit: (PitchFrame) -> Void) {
        resampled.removeAll(keepingCapacity: true)
        resampler.process(samples, appendingTo: &resampled)
        let n = frameLength
        for s in resampled {
            window[writeIndex] = s
            window[writeIndex + n] = s
            writeIndex += 1
            if writeIndex == n { writeIndex = 0 }
            samplesConsumed += 1
            sinceLastFrame += 1
            if filled < n { filled += 1 }
            if filled == n && sinceLastFrame >= hop {
                sinceLastFrame = 0
                emit(analyzeCurrentWindow())
            }
        }
    }

    /// Convenience for tests and offline use.
    public func process(_ samples: [Float]) -> [PitchFrame] {
        var frames: [PitchFrame] = []
        samples.withUnsafeBufferPointer { buffer in
            process(buffer) { frames.append($0) }
        }
        return frames
    }

    private func analyzeCurrentWindow() -> PitchFrame {
        let start = ContinuousClock.now
        let start0 = writeIndex
        let n = frameLength
        let estimate = window.withUnsafeBufferPointer { buffer in
            detector.analyze(UnsafeBufferPointer(rebasing: buffer[start0..<(start0 + n)]))
        }
        let stable = stabilizer.process(estimate)
        timing.record((ContinuousClock.now - start).inSeconds)
        let time = (Double(samplesConsumed) - Double(n) / 2) / configuration.detector.sampleRate
        return PitchFrame(
            time: time,
            midi: stable.midi,
            accidentals: configuration.accidentals,
            confidence: estimate.confidence,
            rms: estimate.rms,
            rawFrequency: estimate.frequency,
            unvoicedReason: stable.unvoicedReason
        )
    }
}
