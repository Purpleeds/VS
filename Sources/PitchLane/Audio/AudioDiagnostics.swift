#if canImport(SwiftUI)
import SwiftUI

/// Low-rate (2 Hz) numbers for the debug overlay, kept apart from the 100 Hz pitch stream so the
/// overlay doesn't redraw on every frame.
@MainActor
final class AudioDiagnostics: ObservableObject {
    struct Snapshot: Equatable {
        var isRunning = false
        var analysisAverageMs = 0.0
        var analysisMaxMs = 0.0
        var framesPerSecond = 0.0
        var droppedBuffers = 0
        var inputSampleRate = 0.0
        var ioBufferMs = 0.0
        /// Game screen render rate; nil when no game is on screen.
        var gameFPS: Double?
        var gameWorstFrameMs = 0.0
    }

    @Published private(set) var snapshot = Snapshot()

    func update(_ stats: PitchAnalyzer.Stats) {
        var next = snapshot
        next.analysisAverageMs = stats.analysisAverageMs
        next.analysisMaxMs = stats.analysisMaxMs
        next.framesPerSecond = stats.framesPerSecond
        next.droppedBuffers = stats.droppedBuffers
        next.inputSampleRate = stats.inputSampleRate
        snapshot = next
    }

    func setGameFrameStats(fps: Double, worstFrameMs: Double) {
        var next = snapshot
        next.gameFPS = fps
        next.gameWorstFrameMs = worstFrameMs
        snapshot = next
    }

    func clearGameFrameStats() {
        var next = snapshot
        next.gameFPS = nil
        next.gameWorstFrameMs = 0
        snapshot = next
    }

    func setRunning(_ running: Bool, sampleRate: Double = 0, ioBufferMs: Double = 0) {
        var next = snapshot
        next.isRunning = running
        if running {
            next.inputSampleRate = sampleRate
            next.ioBufferMs = ioBufferMs
        } else {
            next.framesPerSecond = 0
        }
        snapshot = next
    }
}
#endif
