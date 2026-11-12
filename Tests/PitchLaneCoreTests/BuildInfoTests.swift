import XCTest
import PitchLaneCore

final class BuildInfoTests: XCTestCase {
    func testReadsInfoDictionary() {
        let info = BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
        ])
        XCTAssertEqual(info.version, "1.2.3")
        XCTAssertEqual(info.build, "42")
        XCTAssertEqual(info.display, "v1.2.3 (42)")
        XCTAssertEqual(info.buildLabel, "build 42")
    }

    func testMissingKeysFallBack() {
        XCTAssertEqual(BuildInfo(infoDictionary: nil), BuildInfo(version: "0.0.0", build: "0"))
        XCTAssertEqual(BuildInfo(infoDictionary: ["CFBundleVersion": 7]).build, "0")
    }
}
