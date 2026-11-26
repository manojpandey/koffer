import XCTest
@testable import KofferCore

final class ConfigStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = try makeTempDirectory("koffer-config")
    }

    override func tearDownWithError() throws {
        if let d = dir { try? FileManager.default.removeItem(at: d) }
    }

    func testMissingFileWritesSeed() throws {
        let url = dir.appendingPathComponent("sub/config.json")
        let store = ConfigStore(fileURL: url)
        let config = try store.load()
        XCTAssertEqual(config, KofferConfig())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try ConfigStore(fileURL: url).load(), KofferConfig())
    }

    func testRoundTrip() throws {
        let url = dir.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)
        let job = SyncJob(id: "archive", name: "Archive", source: "/Volumes/MyDisk/Archive",
                          destination: "onedrive:Archive", removedRoot: "onedrive:_Archive_removed",
                          requiredVolume: "MyDisk", autoSyncOnMount: true, previewApproved: true,
                          extraLogDirectory: "/Volumes/MyDisk/Archive/_logs")
        let config = KofferConfig(jobs: [job], neverSync: ["camera stuff"],
                                  privatePaths: [PrivatePathRule(pathContains: "private papers", forbiddenRemotes: ["onedrive:"])])
        try store.save(config)
        XCTAssertEqual(try store.load(), config)
    }

    func testUndecodableFileThrowsAndIsNotOverwritten() throws {
        let url = dir.appendingPathComponent("config.json")
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: url)
        let store = ConfigStore(fileURL: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), garbage)

        let wrongShape = Data(#"{"jobs": [{"id": 5}]}"#.utf8)
        try wrongShape.write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), wrongShape)
    }

    func testHandEditedFileMayOmitOptionalFields() throws {
        let url = dir.appendingPathComponent("config.json")
        let text = #"""
        {
          "jobs": [
            { "id": "a", "name": "Archive", "source": "/Volumes/MyDisk/Archive",
              "destination": "onedrive:Archive", "removedRoot": "onedrive:_Archive_removed",
              "requiredVolume": "MyDisk", "autoSyncOnMount": true }
          ]
        }
        """#
        try Data(text.utf8).write(to: url)
        let config = try ConfigStore(fileURL: url).load()
        XCTAssertEqual(config.jobs.count, 1)
        XCTAssertEqual(config.jobs[0].enabled, true)
        XCTAssertEqual(config.jobs[0].previewApproved, false)
        XCTAssertEqual(config.jobs[0].autoSyncOnMount, true)
        XCTAssertEqual(config.neverSync, [])
        XCTAssertEqual(config.privatePaths, [])
    }

    @MainActor
    func testEngineReportsUnreadableSettings() throws {
        let url = dir.appendingPathComponent("config.json")
        let garbage = Data("nope".utf8)
        try garbage.write(to: url)
        let env = EngineEnvironment(configURL: url, logDirectory: dir.appendingPathComponent("logs"),
                                    rcloneCandidates: [], volumesDirectory: nil)
        let engine = SyncEngine(services: EngineServices(notifier: FakeNotifier(), power: FakePower(), history: FakeHistory()),
                                environment: env)
        XCTAssertEqual(engine.status, .needsAttention("Koffer's settings file can't be read"))
        XCTAssertNil(engine.activeJobID)
        XCTAssertEqual(engine.jobs, [])
        XCTAssertNil(engine.rclonePath)
        engine.setEnabled(false, jobID: "test")
        XCTAssertEqual(try Data(contentsOf: url), garbage, "a broken settings file is never overwritten")
    }
}
