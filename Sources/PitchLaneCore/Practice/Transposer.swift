import Foundation

extension Song {
    /// A copy with every pitch shifted by `semitones` (clamped to MIDI 0...127). Timing is unchanged.
    public func transposed(by semitones: Int) -> Song {
        guard semitones != 0 else { return self }
        var copy = self
        copy.notes = notes.map { note in
            var shifted = note
            shifted.pitch = min(127, max(0, note.pitch + semitones))
            return shifted
        }
        return copy
    }

    /// The notes that start inside [start, end), as their own song (for scoring one loop pass).
    /// Also returns, for each new note, its index in the original song. A first note that slid in from the
    /// previous note becomes a plain note.
    public func section(from start: Double, to end: Double) -> (song: Song, originalIndices: [Int]) {
        var kept: [SongNote] = []
        var indices: [Int] = []
        for (index, note) in notes.enumerated() where note.start >= start && note.start < end {
            var copy = note
            if kept.isEmpty { copy.slidesFromPrevious = false }
            kept.append(copy)
            indices.append(index)
        }
        var section = self
        section.notes = kept
        section.lineBreaks = lineBreaks.filter { $0 > start && $0 < end }
        return (section, indices)
    }

    /// The first `duration` seconds from `start`, shifted so `start` becomes 0.2 s (for audio previews).
    public func excerpt(from start: Double, duration: Double) -> Song {
        let shift = 0.2 - start
        var copy = self
        copy.notes = notes.filter { $0.end > start && $0.start < start + duration }.map { note in
            var moved = note
            moved.start += shift
            return moved
        }
        if let first = copy.notes.first, first.start < 0.2 {
            copy.notes[0].duration -= (0.2 - first.start)
            copy.notes[0].start = 0.2
            copy.notes[0].slidesFromPrevious = false
        }
        copy.lineBreaks = []
        copy.tempo = []
        copy.backingAudioFile = nil
        copy.videoFile = nil
        return copy
    }

    /// Phrase time ranges (line by line; with no line breaks, split at pauses of a second or more).
    public func phraseRanges(pad: Double = 0.2) -> [ClosedRange<Double>] {
        let scored = notes
        guard !scored.isEmpty else { return [] }
        var groups: [[SongNote]] = [[]]
        var breakIndex = 0
        let breaks = lineBreaks
        for (i, note) in scored.enumerated() {
            var startsNew = false
            while breakIndex < breaks.count, breaks[breakIndex] <= note.start + 1e-9 {
                if !groups[groups.count - 1].isEmpty { startsNew = true }
                breakIndex += 1
            }
            if breaks.isEmpty, i > 0, note.start - scored[i - 1].end >= 1 { startsNew = true }
            if startsNew { groups.append([]) }
            groups[groups.count - 1].append(note)
        }
        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            return max(0, first.start - pad)...(last.end + pad)
        }
    }
}

/// How a song's range sits against the singer's range, and what shift would help.
public enum SongFit: Sendable, Equatable {
    case fits
    /// Notes below/above the range, counted in notes (not seconds).
    case outside(below: Int, above: Int)
}

public enum SongTransposer {
    public static func fit(of song: Song, shift: Int = 0, in range: VocalRange) -> SongFit {
        var below = 0
        var above = 0
        for note in song.notes where note.isScored {
            let pitch = note.pitch + shift
            if pitch < range.low { below += 1 }
            if pitch > range.high { above += 1 }
        }
        return below == 0 && above == 0 ? .fits : .outside(below: below, above: above)
    }

    /// Number of scored notes outside the range after shifting.
    public static func notesOutside(_ song: Song, shift: Int, range: VocalRange) -> Int {
        if case .outside(let below, let above) = fit(of: song, shift: shift, in: range) { return below + above }
        return 0
    }

    /// Best shift within +/- `limit` semitones: fewest notes outside the range, then the smallest move,
    /// preferring whole octaves. Returns nil when the song has no scored notes.
    public static func bestShift(for song: Song, in range: VocalRange, limit: Int = 24) -> Int? {
        guard song.notes.contains(where: \.isScored) else { return nil }
        var best: (shift: Int, outside: Int)?
        for shift in -limit...limit {
            let outside = notesOutside(song, shift: shift, range: range)
            let better: Bool
            if let current = best {
                if outside != current.outside {
                    better = outside < current.outside
                } else if abs(shift) != abs(current.shift) {
                    better = abs(shift) < abs(current.shift)
                } else {
                    better = shift > current.shift
                }
            } else {
                better = true
            }
            if better { best = (shift, outside) }
        }
        // Prefer a whole octave if it is just as good as the best arbitrary shift.
        if let found = best, found.shift % 12 != 0 {
            let octaves = stride(from: -limit / 12 * 12, through: limit / 12 * 12, by: 12)
                .map { (shift: $0, outside: notesOutside(song, shift: $0, range: range)) }
                .min { ($0.outside, abs($0.shift)) < ($1.outside, abs($1.shift)) }
            if let octave = octaves, octave.outside == found.outside { return octave.shift }
        }
        return best?.shift
    }

    /// "+1 octave", "-5 semitones", "No shift".
    public static func shiftText(_ shift: Int) -> String {
        if shift == 0 { return "No shift" }
        let sign = shift > 0 ? "+" : "-"
        let magnitude = abs(shift)
        if magnitude % 12 == 0 {
            let octaves = magnitude / 12
            return "\(sign)\(octaves) octave\(octaves == 1 ? "" : "s")"
        }
        return "\(sign)\(magnitude) semitone\(magnitude == 1 ? "" : "s")"
    }
}
