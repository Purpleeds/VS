import XCTest
import PitchLaneCore

final class LogFileStoreTests: XCTestCase {
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

    private func makeStore(maxBytes: Int = LogFileStore.defaultMaxBytes) -> LogFileStore {
        LogFileStore(
            directory: directory,
            maxBytes: maxBytes,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func text(_ url: URL) -> String {
        String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
    }

    func testFirstLaunchStatus() {
        XCTAssertEqual(makeStore().beginSession(), .firstLaunch)
    }

    func testCleanExitIsDetected() {
        let first = makeStore()
        first.beginSession()
        first.markClean()
        XCTAssertEqual(makeStore().beginSession(), .endedCleanly)
    }

    func testMissingCleanMarkerMeansUncleanExit() {
        makeStore().beginSession()
        XCTAssertEqual(makeStore().beginSession(), .endedUncleanly)
    }

    func testReturningToForegroundAfterCleanMarkReArmsDetection() {
        let first = makeStore()
        first.beginSession()
        first.markClean()
        first.markRunning()
        XCTAssertEqual(makeStore().beginSession(), .endedUncleanly)
    }

    func testLineFormat() {
        let store = makeStore()
        store.beginSession()
        store.append(.warning, category: "audio", "hello\nworld")
        let contents = text(store.currentURL)
        XCTAssertTrue(contents.hasPrefix("2023-11-"), contents)
        XCTAssertTrue(contents.contains("[WARN] [audio] hello | world\n"), contents)
        XCTAssertEqual(contents.filter { $0 == "\n" }.count, 1)
    }

    func testRotationKeepsOnlyPreviousSession() {
        let a = makeStore()
        a.beginSession()
        a.append(.info, category: "t", "session A")
        a.markClean()

        let b = makeStore()
        b.beginSession()
        b.append(.info, category: "t", "session B")
        XCTAssertTrue(text(b.previousURL).contains("session A"))
        XCTAssertFalse(text(b.currentURL).contains("session A"))
        b.markClean()

        let c = makeStore()
        c.beginSession()
        c.append(.info, category: "t", "session C")
        XCTAssertTrue(text(c.previousURL).contains("session B"))
        XCTAssertFalse(text(c.previousURL).contains("session A"))
    }

    func testSizeCapTrimsOldestLinesAndNeverTouchesPreviousSession() {
        let a = makeStore(maxBytes: 4096)
        a.beginSession()
        a.append(.info, category: "t", "previous session marker")
        a.markClean()

        let store = makeStore(maxBytes: 4096)
        store.beginSession()
        for i in 0..<300 {
            store.append(.info, category: "t", "line number \(i) with some padding to take up space")
        }
        let current = text(store.currentURL)
        XCTAssertLessThanOrEqual(current.utf8.count, 4096)
        XCTAssertTrue(current.contains("line number 299"))
        XCTAssertFalse(current.contains("line number 0 "))
        XCTAssertTrue(current.contains("log truncated"))
        XCTAssertTrue(text(store.previousURL).contains("previous session marker"))
    }

    func testReadAllIncludesBothSessions() {
        let a = makeStore()
        a.beginSession()
        a.append(.info, category: "t", "old")
        a.markClean()
        let b = makeStore()
        b.beginSession()
        b.append(.info, category: "t", "new")
        let all = b.readAll()
        XCTAssertTrue(all.contains("===== PREVIOUS SESSION ====="))
        XCTAssertTrue(all.contains("===== CURRENT SESSION ====="))
        XCTAssertLessThan(
            all.range(of: "old")!.lowerBound,
            all.range(of: "new")!.lowerBound
        )
    }

    func testAppendRecreatesDeletedFile() {
        let store = makeStore()
        store.beginSession()
        try? FileManager.default.removeItem(at: store.currentURL)
        store.append(.error, category: "t", "after delete")
        XCTAssertTrue(text(store.currentURL).contains("after delete"))
    }

    func testClearRemovesBothSessionsButKeepsCleanExitDetection() {
        let a = makeStore()
        a.beginSession()
        a.append(.info, category: "t", "old secret")
        a.markClean()
        let b = makeStore()
        b.beginSession()
        b.append(.info, category: "t", "new secret")
        b.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.previousURL.path))
        XCTAssertFalse(b.readAll().contains("secret"))
        b.append(.info, category: "t", "after clear")
        XCTAssertTrue(text(b.currentURL).contains("after clear"))
        // Session state survives: this session is still "running", so the next launch reports unclean.
        XCTAssertEqual(makeStore().beginSession(), .endedUncleanly)
    }
}
