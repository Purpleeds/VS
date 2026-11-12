import XCTest
import PitchLaneCore

final class PitchSessionStatsTests: XCTestCase {
    private func frame(_ time: Double, midi: Double?, reason: UnvoicedReason? = nil, rms: Double = 0.1) -> PitchFrame {
        PitchFrame(time: time, midi: midi, accidentals: .sharps, confidence: midi == nil ? 0.2 : 0.9, rms: rms,
                   rawFrequency: nil, unvoicedReason: reason)
    }

    func testSegmentIsReportedWhenVoicingStops() throws {
        var stats = PitchSessionStats(reportInterval: 100)
        var events: [PitchLogEvent] = []
        var t = 0.0
        for _ in 0..<50 { events += stats.add(frame(t, midi: 57.1)); t += 0.01 }
        events += stats.add(frame(t, midi: nil)); t += 0.01          // 1-frame dropout is bridged
        for _ in 0..<50 { events += stats.add(frame(t, midi: 58.9)); t += 0.01 }
        XCTAssertTrue(events.isEmpty)
        for _ in 0..<3 { events += stats.add(frame(t, midi: nil, reason: .belowNoiseGate)); t += 0.01 }

        XCTAssertEqual(events.count, 1)
        guard case .segment(let segment) = try XCTUnwrap(events.first) else { return XCTFail("expected segment") }
        XCTAssertEqual(segment.frameCount, 100)
        XCTAssertEqual(segment.duration, 1.01, accuracy: 1e-6)
        XCTAssertEqual(segment.minMIDI, 57.1, accuracy: 1e-9)
        XCTAssertEqual(segment.maxMIDI, 58.9, accuracy: 1e-9)
        XCTAssertEqual(segment.medianMIDI, 58.0, accuracy: 1e-9)
        XCTAssertEqual(segment.meanConfidence, 0.9, accuracy: 1e-9)
        let text = segment.description(accidentals: .sharps)
        XCTAssertTrue(text.contains("median A♯3 +0c") || text.contains("median A♯3 -0c"), text)
        XCTAssertTrue(text.contains("range A3..B3"), text)
        XCTAssertTrue(segment.description(accidentals: .flats).contains("B♭3"))
    }

    func testShortBlipsAreCountedNotLogged() {
        var stats = PitchSessionStats(reportInterval: 1)
        var events: [PitchLogEvent] = []
        var t = 0.0
        for _ in 0..<5 { events += stats.add(frame(t, midi: 60)); t += 0.01 }
        for _ in 0..<200 { events += stats.add(frame(t, midi: nil, reason: .lowConfidence)); t += 0.01 }
        let intervals = events.compactMap { event -> IntervalSummary? in
            if case .interval(let summary) = event { return summary }
            return nil
        }
        XCTAssertEqual(events.filter { if case .segment = $0 { return true } else { return false } }.count, 0)
        XCTAssertEqual(intervals.first?.blipCount, 1)
    }

    func testIntervalSummary() throws {
        var stats = PitchSessionStats(reportInterval: 1)
        var events: [PitchLogEvent] = []
        for i in 0..<100 {
            let t = Double(i) * 0.01
            let reason: UnvoicedReason = i.isMultiple(of: 2) ? .belowNoiseGate : .outOfRange
            events += stats.add(i < 60 ? frame(t, midi: 60, rms: 0.1) : frame(t, midi: nil, reason: reason, rms: 0.01))
        }
        events += stats.add(frame(1.5, midi: nil, reason: .belowNoiseGate))
        let interval = try XCTUnwrap(events.compactMap { event -> IntervalSummary? in
            if case .interval(let summary) = event { return summary }
            return nil
        }.first)
        XCTAssertEqual(interval.frameCount, 100)
        XCTAssertEqual(interval.voicedCount, 60)
        XCTAssertEqual(interval.voicedFraction, 0.6, accuracy: 1e-9)
        XCTAssertEqual(interval.unvoicedCounts[.belowNoiseGate], 20)
        XCTAssertEqual(interval.unvoicedCounts[.outOfRange], 20)
        XCTAssertEqual(interval.maxLevelDBFS, -20, accuracy: 1e-9)
        XCTAssertEqual(interval.minLevelDBFS, -40, accuracy: 1e-9)
        XCTAssertTrue(interval.description.contains("voiced 60%"), interval.description)
        XCTAssertTrue(interval.description.contains("outOfRange 20"), interval.description)
    }

    func testFinishFlushesOpenSegmentAndInterval() {
        var stats = PitchSessionStats()
        var t = 0.0
        for _ in 0..<40 { _ = stats.add(frame(t, midi: 64)); t += 0.01 }
        let events = stats.finish()
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(stats.finish().isEmpty)
    }
}
