import XCTest
import PitchLaneCore

final class JSONFileStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PitchLaneTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testMissingFileLoadsNil() throws {
        let store = JSONFileStore<AppSettings>(url: directory.appendingPathComponent("settings.json"))
        XCTAssertNil(try store.load())
    }

    func testRoundTripCreatesIntermediateDirectories() throws {
        let store = JSONFileStore<AppSettings>(url: directory.appendingPathComponent("a/b/settings.json"))
        try store.save(AppSettings(debugOverlay: true))
        XCTAssertEqual(try store.load(), AppSettings(debugOverlay: true))
    }

    func testCorruptFileThrows() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try JSONFileStore<AppSettings>(url: url).load())
    }

    func testSettingsDecodeFillsMissingKeysWithDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, AppSettings())
        XCTAssertFalse(settings.debugOverlay)
        XCTAssertEqual(settings.accidentals, .sharps)
    }

    func testSettingsAccidentalsRoundTripAndUnknownValueFallsBack() throws {
        let data = try JSONEncoder().encode(AppSettings(debugOverlay: true, accidentals: .flats))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), AppSettings(debugOverlay: true, accidentals: .flats))
        let odd = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"accidentals":"quarterTones"}"#.utf8))
        XCTAssertEqual(odd.accidentals, .sharps)
    }
}
