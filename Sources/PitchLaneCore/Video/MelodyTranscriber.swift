import Foundation

/// Turns a stream of stabilised pitch frames (e.g. from a video's soundtrack) into singable notes.
///
/// Frames arrive in time order (100 per second from `PitchPipeline`). A note grows while voiced frames stay
/// within `toleranceSemitones` of its running median; short gaps are bridged; a sustained move to another
/// pitch (`changeFrames` agreeing frames) starts a new note; blips shorter than `minimumNoteDuration` are
/// dropped. Each note gets the nearest semitone of its median. Results are rough on full mixes (accompaniment
/// confuses any single-pitch detector), so the importer says so.
public struct MelodyTranscriber: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var toleranceSemitones: Double = 0.75
        public var changeFrames: Int = 4
        public var maximumGap: Double = 0.07
        public var minimumNoteDuration: Double = 0.1
        /// Same-pitch notes closer than this are merged into one.
        public var mergeGap: Double = 0.08
        /// A silence this long starts a new lyric line.
        public var lineBreakGap: Double = 1.2
        public var frameDuration: Double = 0.01

        public init() {}
    }

    public let configuration: Configuration
    private var notes: [SongNote] = []
    private var current: [Double] = []
    private var currentStart = 0.0
    private var currentEnd = 0.0
    private var pending: [Double] = []
    private var pendingStart = 0.0
    private var lastVoiced = -Double.infinity
    private var scratch: [Double] = []
    public private(set) var framesSeen = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Feeds one frame; `midi` nil = unvoiced.
    public mutating func add(time: Double, midi: Double?) {
        framesSeen += 1
        guard time.isFinite else { return }
        guard let midi, midi.isFinite else {
            if !current.isEmpty, time - lastVoiced > configuration.maximumGap {
                closeCurrent()
            }
            pending.removeAll(keepingCapacity: true)
            return
        }
        if !current.isEmpty, time - lastVoiced > configuration.maximumGap {
            closeCurrent()
        }
        lastVoiced = time
        if current.isEmpty {
            start(at: time, with: midi)
            return
        }
        let reference = median(current.suffix(15))
        if abs(midi - reference) <= configuration.toleranceSemitones {
            pending.removeAll(keepingCapacity: true)
            current.append(midi)
            currentEnd = time + configuration.frameDuration
            return
        }
        // A different pitch: only a sustained, self-consistent move starts a new note.
        if let last = pending.last, abs(midi - last) > configuration.toleranceSemitones {
            pending.removeAll(keepingCapacity: true)
        }
        if pending.isEmpty { pendingStart = time }
        pending.append(midi)
        if pending.count >= configuration.changeFrames {
            let moved = pending
            let movedStart = pendingStart
            pending.removeAll(keepingCapacity: true)
            currentEnd = min(currentEnd, movedStart)
            closeCurrent()
            current = moved
            currentStart = movedStart
            currentEnd = time + configuration.frameDuration
        }
    }

    /// Closes the last note and returns all notes (sorted, merged, capped at `SongLimits.maximumNotes`).
    public mutating func finish() -> [SongNote] {
        closeCurrent()
        var merged: [SongNote] = []
        for note in notes {
            if var last = merged.last, last.pitch == note.pitch, note.start - last.end < configuration.mergeGap {
                last.duration = note.end - last.start
                merged[merged.count - 1] = last
            } else {
                merged.append(note)
            }
        }
        return Array(merged.prefix(SongLimits.maximumNotes))
    }

    /// Line breaks before every note that follows a long silence.
    public static func lineBreaks(for notes: [SongNote], gap: Double = Configuration().lineBreakGap) -> [Double] {
        zip(notes, notes.dropFirst()).compactMap { previous, next in next.start - previous.end >= gap ? next.start : nil }
    }

    private mutating func start(at time: Double, with midi: Double) {
        current = [midi]
        currentStart = time
        currentEnd = time + configuration.frameDuration
        pending.removeAll(keepingCapacity: true)
    }

    private mutating func closeCurrent() {
        defer {
            current.removeAll(keepingCapacity: true)
            pending.removeAll(keepingCapacity: true)
        }
        guard !current.isEmpty else { return }
        let duration = currentEnd - currentStart
        guard duration >= configuration.minimumNoteDuration else { return }
        let pitch = Int(median(current[...]).rounded())
        guard SongLimits.pitchRange.contains(pitch), SongLimits.isSensible(start: currentStart, duration: duration) else { return }
        notes.append(SongNote(start: currentStart, duration: duration, pitch: pitch))
    }

    private mutating func median(_ values: ArraySlice<Double>) -> Double {
        scratch.removeAll(keepingCapacity: true)
        scratch.append(contentsOf: values)
        scratch.sort()
        let n = scratch.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? scratch[n / 2] : (scratch[n / 2 - 1] + scratch[n / 2]) / 2
    }
}
