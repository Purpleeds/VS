import XCTest
import PitchLaneCore

final class PitchStabilizerTests: XCTestCase {
    private let loud = 0.1 // -20 dBFS

    private func estimate(_ hz: Double?, confidence: Double = 0.95, rms: Double? = nil, aboveRange: Bool = false) -> PitchEstimate {
        PitchEstimate(frequency: hz, confidence: confidence, rms: rms ?? loud, isAboveRange: aboveRange)
    }

    func testNoiseGate() {
        var stabilizer = PitchStabilizer()
        let result = stabilizer.process(estimate(220, rms: 0.001)) // -60 dBFS
        XCTAssertNil(result.midi)
        XCTAssertEqual(result.unvoicedReason, .belowNoiseGate)
    }

    func testLowConfidenceAndMissingPitch() {
        var stabilizer = PitchStabilizer()
        XCTAssertEqual(stabilizer.process(estimate(220, confidence: 0.6)).unvoicedReason, .lowConfidence)
        XCTAssertEqual(stabilizer.process(estimate(nil)).unvoicedReason, .lowConfidence)
    }

    func testAboveRange() {
        var stabilizer = PitchStabilizer()
        XCTAssertEqual(stabilizer.process(estimate(nil, aboveRange: true)).unvoicedReason, .outOfRange)
    }

    func testSingleFrameOctaveErrorIsRejected() {
        var stabilizer = PitchStabilizer()
        for _ in 0..<10 { _ = stabilizer.process(estimate(220)) }
        let blip = stabilizer.process(estimate(440))
        XCTAssertNil(blip.midi)
        XCTAssertEqual(blip.unvoicedReason, .pendingJump)
        let after = stabilizer.process(estimate(220))
        XCTAssertEqual(after.midi ?? 0, 57, accuracy: 1e-9)
    }

    func testSustainedOctaveJumpIsAcceptedOnThirdFrame() {
        var stabilizer = PitchStabilizer()
        for _ in 0..<10 { _ = stabilizer.process(estimate(220)) }
        XCTAssertNil(stabilizer.process(estimate(440)).midi)
        XCTAssertNil(stabilizer.process(estimate(440)).midi)
        let third = stabilizer.process(estimate(440))
        XCTAssertEqual(third.midi ?? 0, 69, accuracy: 1e-9)
        // History was replaced, so the next frame is not dragged back toward A3.
        XCTAssertEqual(stabilizer.process(estimate(440)).midi ?? 0, 69, accuracy: 1e-9)
    }

    func testDisagreeingJumpFramesDoNotConfirm() {
        var stabilizer = PitchStabilizer()
        for _ in 0..<10 { _ = stabilizer.process(estimate(220)) }
        // Alternating octave-up / twelfth-up errors never agree with each other.
        for hz in [440.0, 660, 440, 660, 440, 660] {
            XCTAssertNil(stabilizer.process(estimate(hz)).midi, "\(hz) accepted")
        }
    }

    func testHistoryResetsAfterSilenceSoNewNoteIsImmediate() {
        var stabilizer = PitchStabilizer()
        for _ in 0..<10 { _ = stabilizer.process(estimate(220)) }
        for _ in 0..<3 { _ = stabilizer.process(estimate(220, rms: 0.0001)) }
        XCTAssertEqual(stabilizer.process(estimate(880)).midi ?? 0, 81, accuracy: 1e-9)
    }

    func testShortDropoutKeepsHistory() {
        var stabilizer = PitchStabilizer()
        for _ in 0..<10 { _ = stabilizer.process(estimate(220)) }
        _ = stabilizer.process(estimate(220, rms: 0.0001)) // one quiet frame
        XCTAssertEqual(stabilizer.process(estimate(880)).unvoicedReason, .pendingJump)
    }

    func testMedianRemovesSingleSpike() {
        var stabilizer = PitchStabilizer()
        var outputs: [Double] = []
        let a3 = 220.0
        let spike = PitchMath.frequency(fromMIDI: 59) // two semitones up: below the jump guard
        for hz in [a3, a3, a3, a3, a3, spike, a3, a3, a3] {
            outputs.append(stabilizer.process(estimate(hz)).midi ?? .nan)
        }
        for value in outputs {
            XCTAssertEqual(value, 57, accuracy: 1e-9)
        }
    }

    func testMedianFollowsRealStepWithinThreeFrames() {
        var stabilizer = PitchStabilizer()
        for _ in 0..<5 { _ = stabilizer.process(estimate(220)) }
        let b3 = PitchMath.frequency(fromMIDI: 59)
        let first = stabilizer.process(estimate(b3)).midi ?? 0
        let second = stabilizer.process(estimate(b3)).midi ?? 0
        let third = stabilizer.process(estimate(b3)).midi ?? 0
        XCTAssertEqual(first, 57, accuracy: 1e-9)
        XCTAssertEqual(second, 57, accuracy: 1e-9)
        XCTAssertEqual(third, 59, accuracy: 1e-9)
    }
}
