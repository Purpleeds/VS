import XCTest
import PitchLaneCore

final class PitchHistoryTests: XCTestCase {
    func testKeepsOnlyTheLastDuration() throws {
        var history = PitchHistory(duration: 5)
        for i in 0..<1_000 {
            history.append(time: Double(i) * 0.01, midi: i.isMultiple(of: 3) ? nil : 60)
        }
        let first = try XCTUnwrap(history.points.first)
        let last = try XCTUnwrap(history.points.last)
        XCTAssertGreaterThanOrEqual(first.time, last.time - 5 - 1e-9)
        XCTAssertLessThanOrEqual(history.points.count, 502)
        XCTAssertEqual(history.latestTime ?? 0, 9.99, accuracy: 1e-9)
    }

    func testTimeGoingBackwardsStartsOver() {
        var history = PitchHistory(duration: 5)
        history.append(time: 3, midi: 60)
        history.append(time: 0.1, midi: 62)
        XCTAssertEqual(history.points, [PitchHistory.Point(time: 0.1, midi: 62)])
    }

    func testVoicedRange() {
        var history = PitchHistory()
        XCTAssertNil(history.voicedRange)
        history.append(time: 0, midi: nil)
        XCTAssertNil(history.voicedRange)
        history.append(time: 0.01, midi: 60)
        history.append(time: 0.02, midi: 64.5)
        XCTAssertEqual(history.voicedRange, 60...64.5)
    }

    func testGraphScaleMinimumSpanAndBounds() {
        var history = PitchHistory()
        history.append(time: 0, midi: 60)
        let range = PitchGraphScale.range(for: history, current: nil, bounds: 36...84)
        XCTAssertEqual(range.upperBound - range.lowerBound, 12, accuracy: 1e-9)
        XCTAssertTrue(range.contains(60))

        var low = PitchHistory()
        low.append(time: 0, midi: 37)
        let clamped = PitchGraphScale.range(for: low, current: nil, bounds: 36...84)
        XCTAssertEqual(clamped.lowerBound, 36)
        XCTAssertEqual(clamped.upperBound, 48)

        let empty = PitchGraphScale.range(for: PitchHistory(), current: nil, bounds: 36...84)
        XCTAssertEqual(empty, 54...66)
    }

    func testGraphScaleIsSticky() {
        var history = PitchHistory()
        history.append(time: 0, midi: 60)
        let first = PitchGraphScale.range(for: history, current: nil, bounds: 36...84)
        history.append(time: 0.01, midi: 62)
        XCTAssertEqual(PitchGraphScale.range(for: history, current: first, bounds: 36...84), first)
        // Line nears the top edge -> range moves.
        history.append(time: 0.02, midi: first.upperBound - 0.5)
        let moved = PitchGraphScale.range(for: history, current: first, bounds: 36...84)
        XCTAssertNotEqual(moved, first)
        XCTAssertLessThanOrEqual(moved.lowerBound, 59)
        XCTAssertGreaterThanOrEqual(moved.upperBound, first.upperBound + 0.5)
    }

    func testGraphScaleShrinksWhenFarTooBig() {
        var history = PitchHistory()
        history.append(time: 0, midi: 60)
        let shrunk = PitchGraphScale.range(for: history, current: 36...84, bounds: 36...84)
        XCTAssertEqual(shrunk.upperBound - shrunk.lowerBound, 12, accuracy: 1e-9)
    }
}
