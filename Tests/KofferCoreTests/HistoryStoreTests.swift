import XCTest
@testable import KofferCore

final class HistoryStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        let dir: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("KofferHistoryTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        tempDir = dir
    }

    override func tearDownWithError() throws {
        if let dir: URL = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // Whole-second dates, because the file stores ISO-8601 without fractions.
    private let base: Date = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeRecord(_ index: Int) -> RunRecord {
        let start: Date = base.addingTimeInterval(TimeInterval(index * 60))
        return RunRecord(jobID: "archive", jobName: "Archive",
                         startedAt: start, endedAt: start.addingTimeInterval(30),
                         outcome: .completed, uploaded: index, moved: 2, removed: 1, errors: 0,
                         bytesTransferred: Int64(index) * 1000, message: nil, logPath: "/tmp/archive_\(index).log")
    }

    private func storeURL() -> URL {
        return tempDir.appendingPathComponent("history.json", isDirectory: false)
    }

    func testLoadFromMissingFileReturnsEmpty() {
        let store: HistoryStore = HistoryStore(fileURL: storeURL())
        XCTAssertEqual(store.load().count, 0)
    }

    func testAppendThenLoadRoundTrips() {
        let store: HistoryStore = HistoryStore(fileURL: storeURL())
        let record: RunRecord = makeRecord(1)
        store.append(record)
        let loaded: [RunRecord] = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, record)
    }

    func testAppendCreatesMissingFolder() {
        let url: URL = tempDir
            .appendingPathComponent("deeper", isDirectory: true)
            .appendingPathComponent("again", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
        let store: HistoryStore = HistoryStore(fileURL: url)
        store.append(makeRecord(1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.load().count, 1)
    }

    func testLoadIsNewestFirstRegardlessOfAppendOrder() {
        let store: HistoryStore = HistoryStore(fileURL: storeURL())
        store.append(makeRecord(2))
        store.append(makeRecord(5))
        store.append(makeRecord(1))
        let loaded: [RunRecord] = store.load()
        XCTAssertEqual(loaded.map { $0.uploaded }, [5, 2, 1])
    }

    func testTrimsToTwentyKeepingNewest() {
        let store: HistoryStore = HistoryStore(fileURL: storeURL())
        for i in 0..<25 {
            store.append(makeRecord(i))
        }
        let loaded: [RunRecord] = store.load()
        XCTAssertEqual(loaded.count, 20)
        XCTAssertEqual(loaded.first?.uploaded, 24)
        XCTAssertEqual(loaded.last?.uploaded, 5)
    }

    func testSurvivesNewInstance() {
        let first: HistoryStore = HistoryStore(fileURL: storeURL())
        first.append(makeRecord(3))
        let second: HistoryStore = HistoryStore(fileURL: storeURL())
        XCTAssertEqual(second.load().count, 1)
        XCTAssertEqual(second.load().first?.uploaded, 3)
    }

    func testAppendingSameIDReplacesInsteadOfDuplicating() {
        let store: HistoryStore = HistoryStore(fileURL: storeURL())
        let record: RunRecord = makeRecord(1)
        store.append(record)
        store.append(record)
        XCTAssertEqual(store.load().count, 1)
    }

    func testCorruptFileLoadsAsEmpty() throws {
        let url: URL = storeURL()
        try "this is not json {{{".write(to: url, atomically: true, encoding: .utf8)
        let store: HistoryStore = HistoryStore(fileURL: url)
        XCTAssertEqual(store.load().count, 0)
    }

    func testAppendRecoversFromCorruptFile() throws {
        let url: URL = storeURL()
        try "garbage".write(to: url, atomically: true, encoding: .utf8)
        let store: HistoryStore = HistoryStore(fileURL: url)
        store.append(makeRecord(7))
        let loaded: [RunRecord] = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.uploaded, 7)
    }

    func testFileIsPrettyPrintedWithISO8601Dates() throws {
        let url: URL = storeURL()
        let store: HistoryStore = HistoryStore(fileURL: url)
        store.append(makeRecord(0))
        let text: String = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\n"))
        // 1_700_000_000 is 2023-11-14T22:13:20Z
        XCTAssertTrue(text.contains("2023-11-14T22:13:20Z"))
    }

    func testDefaultFileURLEndsWithKofferHistory() {
        let url: URL = HistoryStore.defaultFileURL()
        XCTAssertEqual(url.lastPathComponent, "history.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Koffer")
    }
}
