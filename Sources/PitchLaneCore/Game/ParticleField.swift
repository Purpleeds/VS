import Foundation

/// A fixed-size pool of short-lived sparks for the lane (hit bursts, the on-pitch comet tail, confetti).
///
/// Allocation-free after init: emitting overwrites the oldest slot. Particles are not simulated per frame; the
/// renderer computes each position from its birth: `origin + velocity * age + gravity * age² / 2`. The origin is
/// in lane coordinates (song time, MIDI) so sparks drift with the notes; velocity and gravity are in points.
public struct ParticleField: Sendable {
    public enum Kind: UInt8, Sendable {
        case spark
        case burst
        case golden
        case confetti
    }

    public struct Particle: Sendable, Equatable {
        public var originTime: Double
        public var originMidi: Double
        public var vx: Double
        public var vy: Double
        public var birth: Double
        public var life: Double
        public var size: Double
        public var kind: Kind
        /// 0...1, for picking a colour from a palette.
        public var hue: Double

        static let empty = Particle(originTime: 0, originMidi: 0, vx: 0, vy: 0, birth: -.infinity, life: 0, size: 0, kind: .spark, hue: 0)

        /// Fraction of life left at `now` (0 = gone).
        public func remaining(at now: Double) -> Double {
            let age = now - birth
            guard life > 0, age >= 0, age < life else { return 0 }
            return 1 - age / life
        }
    }

    public let capacity: Int
    /// Points per second², positive = down.
    public var gravity: Double
    private var storage: [Particle]
    private var next = 0
    private var random: UInt64

    public init(capacity: Int = 256, gravity: Double = 420, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.capacity = max(1, capacity)
        self.gravity = gravity
        storage = Array(repeating: .empty, count: max(1, capacity))
        random = seed == 0 ? 1 : seed
    }

    public mutating func reset() {
        for i in storage.indices { storage[i] = .empty }
        next = 0
    }

    /// Emits `count` particles from (time, midi) at `now`, spraying within `spread` radians around `angle`
    /// (0 = right, -π/2 = up) at `speed` ± 50 %.
    public mutating func emit(
        count: Int,
        time: Double,
        midi: Double,
        now: Double,
        kind: Kind,
        angle: Double = -Double.pi / 2,
        spread: Double = Double.pi,
        speed: Double = 160,
        life: Double = 0.6,
        size: Double = 3
    ) {
        guard count > 0, time.isFinite, midi.isFinite, now.isFinite else { return }
        for _ in 0..<min(count, capacity) {
            let direction = angle + (unit() - 0.5) * spread
            let velocity = speed * (0.5 + unit())
            storage[next] = Particle(
                originTime: time,
                originMidi: midi,
                vx: cos(direction) * velocity,
                vy: sin(direction) * velocity,
                birth: now,
                life: life * (0.7 + 0.6 * unit()),
                size: size * (0.6 + 0.8 * unit()),
                kind: kind,
                hue: unit()
            )
            next = (next + 1) % capacity
        }
    }

    /// Calls `body` for each particle alive at `now`, with its age and remaining fraction.
    public func forEachLive(at now: Double, _ body: (Particle, _ age: Double, _ remaining: Double) -> Void) {
        for particle in storage {
            let remaining = particle.remaining(at: now)
            if remaining > 0 { body(particle, now - particle.birth, remaining) }
        }
    }

    public func liveCount(at now: Double) -> Int {
        storage.reduce(0) { $0 + ($1.remaining(at: now) > 0 ? 1 : 0) }
    }

    /// Offset in points from the origin after `age` seconds.
    public func offset(of particle: Particle, age: Double) -> (dx: Double, dy: Double) {
        (particle.vx * age, particle.vy * age + 0.5 * gravity * age * age)
    }

    /// Uniform in [0, 1) (xorshift64*).
    private mutating func unit() -> Double {
        random ^= random >> 12
        random ^= random << 25
        random ^= random >> 27
        let value = random &* 2_685_821_657_736_338_717
        return Double(value >> 11) / Double(1 << 53)
    }
}

/// Combo counts worth celebrating on the lane.
public enum ComboMilestone {
    public static let values = [10, 25, 50, 75, 100, 150, 200, 300, 500]

    /// The milestone reached when the combo goes from `old` to `new`, if any (the highest one crossed).
    public static func crossed(from old: Int, to new: Int) -> Int? {
        guard new > old else { return nil }
        return values.last { $0 > old && $0 <= new }
    }
}
