#if canImport(SwiftUI)
import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer FIFO of Float samples.
/// Producer: the audio tap (never blocks, locks or allocates). Consumer: the analysis queue.
/// When the consumer falls behind, whole incoming chunks are dropped and counted.
final class AudioCaptureRing: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeTotal = Atomic<Int>(0)
    private let readTotal = Atomic<Int>(0)
    private let dropCount = Atomic<Int>(0)
    /// (index of the first sample of the latest captured buffer, its capture host time).
    private let capture = Atomic<WordPair>(WordPair(first: 0, second: 0))

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Producer only. Returns false (and counts a drop) if the chunk doesn't fit.
    @discardableResult
    func write(_ source: UnsafePointer<Float>, count: Int) -> Bool {
        let written = writeTotal.load(ordering: .relaxed)
        let read = readTotal.load(ordering: .acquiring)
        guard count > 0, count <= capacity - (written - read) else {
            _ = dropCount.add(1, ordering: .relaxed)
            return false
        }
        let start = written % capacity
        let first = min(count, capacity - start)
        (storage + start).update(from: source, count: first)
        if first < count {
            storage.update(from: source + first, count: count - first)
        }
        writeTotal.store(written + count, ordering: .releasing)
        return true
    }

    /// Producer only: how many samples have been written so far (= index of the next sample).
    var producerCount: Int { writeTotal.load(ordering: .relaxed) }

    /// Producer only: remember when the buffer starting at sample `index` was captured.
    func recordCapture(index: Int, hostTime: UInt64) {
        capture.store(WordPair(first: UInt(index), second: UInt(hostTime)), ordering: .releasing)
    }

    /// Latest (sample index, capture host time), if any.
    func latestCapture() -> (index: Int, hostTime: UInt64)? {
        let pair = capture.load(ordering: .acquiring)
        guard pair.second != 0 else { return nil }
        return (Int(pair.first), UInt64(pair.second))
    }

    /// Consumer only: total samples read so far.
    var consumerCount: Int { readTotal.load(ordering: .relaxed) }

    /// Consumer only. Copies up to `maxCount` samples; returns how many.
    func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let read = readTotal.load(ordering: .relaxed)
        let written = writeTotal.load(ordering: .acquiring)
        let n = min(maxCount, written - read)
        guard n > 0 else { return 0 }
        let start = read % capacity
        let first = min(n, capacity - start)
        destination.update(from: storage + start, count: first)
        if first < n {
            (destination + first).update(from: storage, count: n - first)
        }
        readTotal.store(read + n, ordering: .releasing)
        return n
    }

    /// Consumer only: forget everything currently buffered.
    func discardAll() {
        readTotal.store(writeTotal.load(ordering: .acquiring), ordering: .releasing)
    }

    /// Total chunks dropped since launch.
    var droppedChunks: Int { dropCount.load(ordering: .relaxed) }
}
#endif
