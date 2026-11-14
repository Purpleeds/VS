import Foundation

/// The singer's pitch over a whole song, from the separated voice: one value every frame (100 per second), 0 where
/// nothing was sung or the pitch was unclear. Saved per song as `voice-pitch.json` (MIDI × 100 as whole numbers, to
/// keep the file small) so notes can be rewritten from words without analysing the voice again.
public struct PitchTrack: Codable, Sendable, Equatable {
    public static let maximumFrames = 100 * 60 * 30

    /// Frames per second.
    public var frameRate: Double
    /// Song time of the first frame.
    public var start: Double
    /// Fractional MIDI note per frame; 0 = unvoiced.
    public var midi: [Float]

    public init(frameRate: Double, start: Double, midi: [Float]) {
        self.frameRate = frameRate.isFinite && frameRate > 0 ? frameRate : 100
        self.start = start.isFinite ? start : 0
        self.midi = Array(midi.prefix(Self.maximumFrames)).map { $0.isFinite && $0 > 0 && $0 < 140 ? $0 : 0 }
    }

    /// From regularly spaced analysis frames (time, MIDI or nil).
    public init(times: [Double], midi: [Double?]) {
        let count = min(times.count, midi.count)
        let rate: Double
        if count >= 2, times[count - 1] > times[0] {
            // Rounded to 1/1000 frame per second, so 100 frames a second is exactly 100.
            rate = (Double(count - 1) / (times[count - 1] - times[0]) * 1_000).rounded() / 1_000
        } else {
            rate = 100
        }
        self.init(frameRate: rate, start: count > 0 ? times[0] : 0, midi: (0..<count).map { Float(midi[$0] ?? 0) })
    }

    public var isEmpty: Bool { !midi.contains { $0 > 0 } }

    public func time(ofFrame index: Int) -> Double { start + Double(index) / frameRate }

    /// Voiced frames between two song times, in order.
    public func voiced(from: Double, to: Double) -> [(time: Double, midi: Double)] {
        guard !midi.isEmpty, to >= from else { return [] }
        let lo = max(0, Int(((from - start) * frameRate - 1e-6).rounded(.up)))
        let hi = min(midi.count - 1, Int(((to - start) * frameRate + 1e-6).rounded(.down)))
        guard lo <= hi else { return [] }
        return (lo...hi).compactMap { midi[$0] > 0 ? (time(ofFrame: $0), Double(midi[$0])) : nil }
    }

    /// The voiced pitch nearest to `time`, within `within` seconds.
    public func nearestVoiced(to time: Double, within: Double) -> Double? {
        guard !midi.isEmpty else { return nil }
        let centre = Int(((time - start) * frameRate).rounded())
        let reach = Int((within * frameRate).rounded())
        for offset in 0...max(0, reach) {
            for index in [centre - offset, centre + offset] where index >= 0 && index < midi.count && midi[index] > 0 {
                return Double(midi[index])
            }
        }
        return nil
    }

    /// Median of every voiced frame (nil when nothing was voiced).
    public var voicedMedian: Double? {
        let values = midi.filter { $0 > 0 }.sorted()
        return values.isEmpty ? nil : Double(values[values.count / 2])
    }

    private enum CodingKeys: String, CodingKey { case rate, start, cents }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rate = c.lenient(Double.self, forKey: .rate) ?? 100
        let start = c.lenient(Double.self, forKey: .start) ?? 0
        let lossy = (try? c.decodeIfPresent([Lossy<Int>].self, forKey: .cents)) ?? nil
        self.init(frameRate: rate, start: start, midi: (lossy ?? []).map { Float($0.value ?? 0) / 100 })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frameRate, forKey: .rate)
        try c.encode(start, forKey: .start)
        try c.encode(midi.map { Int(($0 * 100).rounded()) }, forKey: .cents)
    }
}
