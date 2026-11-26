import XCTest
@testable import KofferCore

/// Drives the real SyncEngine and a real rclone binary against plain local folders
/// (rclone treats absolute paths as its local backend, so no cloud account is needed).
/// Skipped when rclone is not installed.
final class SyncEngineIntegrationTests: XCTestCase {
    private var base: URL!
    private var src: URL!
    private var dst: URL!
    private var removed: URL!
    private var notifier: FakeNotifier!
    private var power: FakePower!
    private var historyStore: FakeHistory!

    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = try makeTempDirectory("koffer-int")
        src = base.appendingPathComponent("src", isDirectory: true)
        dst = base.appendingPathComponent("dst", isDirectory: true)
        removed = base.appendingPathComponent("removed", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: base.appendingPathComponent("home"), withIntermediateDirectories: true, attributes: nil)
        notifier = FakeNotifier()
        power = FakePower()
        historyStore = FakeHistory()
    }

    override func tearDownWithError() throws {
        if let b = base { try? fm.removeItem(at: b) }
    }

    // MARK: - Helpers

    private static func findRclone() async -> String? {
        if let path = RcloneLocator().locate() { return path }
        let result = await RcloneRunner.capture(executablePath: "/usr/bin/which", arguments: ["rclone"], timeout: 10)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 0 && !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }

    private func job(requiredVolume: String? = nil, autoSync: Bool = false, approved: Bool = false) -> SyncJob {
        return SyncJob(id: "archive", name: "Archive", source: src.path, destination: dst.path,
                       removedRoot: removed.path, requiredVolume: requiredVolume, autoSyncOnMount: autoSync,
                       enabled: true, previewApproved: approved, extraLogDirectory: base.appendingPathComponent("extra-logs").path)
    }

    @MainActor
    private func makeEngine(job: SyncJob) async throws -> SyncEngine {
        guard let rclone = await SyncEngineIntegrationTests.findRclone() else {
            throw XCTSkip("rclone is not installed; skipping integration tests")
        }
        let configURL = base.appendingPathComponent("config/config.json")
        try ConfigStore(fileURL: configURL).save(KofferConfig(jobs: [job]))
        let env = EngineEnvironment(configURL: configURL, logDirectory: base.appendingPathComponent("logs"),
                                    rcloneCandidates: [rclone], mountDelay: 0.1, interruptGrace: 5,
                                    homeDirectory: base.appendingPathComponent("home").path,
                                    volumesDirectory: nil)
        let services = EngineServices(notifier: notifier, power: power, history: historyStore)
        let engine = SyncEngine(services: services, environment: env)
        XCTAssertEqual(engine.rclonePath, rclone)
        XCTAssertEqual(engine.jobs.count, 1)
        return engine
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = src.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try Data(text.utf8).write(to: url)
    }

    /// 5 photos + 1 note = 6 files, each with unique content.
    private func makeSourceFiles() throws -> Int {
        for i in 1...5 {
            try write("A/photos/img_\(i).jpg", String(repeating: "photo \(i) ", count: 200 + i))
        }
        try write("B/note.txt", "a small note")
        return 6
    }

    private func files(under root: URL) -> [String] {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: nil) else { return [] }
        var out: [String] = []
        let prefix = root.resolvingSymlinksInPath().path + "/"
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                let full = url.resolvingSymlinksInPath().path
                out.append(full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full)
            }
        }
        return out.sorted()
    }

    private func removedFolderIsEmpty() -> Bool {
        return files(under: removed).isEmpty
    }

    @MainActor
    private func runSync(_ engine: SyncEngine, jobID: String = "archive") async {
        engine.syncNow(jobID: jobID)
        await engine.currentTask?.value
    }

    @MainActor
    private func firstSync(_ engine: SyncEngine, expectedFiles: Int) async {
        await runSync(engine)
        XCTAssertEqual(engine.status, .done, "first sync status")
        XCTAssertNil(engine.activeJobID)
        XCTAssertEqual(historyStore.records.count, 1)
        XCTAssertEqual(engine.history.first?.uploaded, expectedFiles)
        XCTAssertEqual(engine.history.first?.outcome, .completed)
        XCTAssertEqual(files(under: dst).count, expectedFiles)
    }

    // MARK: - Tests

    @MainActor
    func testFirstSyncUploadsEverything() async throws {
        let n = try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        await firstSync(engine, expectedFiles: n)

        XCTAssertEqual(notifier.started, ["archive"])
        XCTAssertEqual(notifier.finished.count, 1)
        XCTAssertEqual(power.begins, 1)
        XCTAssertEqual(power.ends, 1)
        XCTAssertEqual(engine.progress.uploaded, n)
        XCTAssertEqual(engine.progress.filesTotal, n)
        XCTAssertEqual(files(under: dst), files(under: src))

        // The log file exists and holds rclone's JSON lines; a copy lands in the extra folder.
        let logPath = try XCTUnwrap(engine.history.first?.logPath)
        let logText = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(logText.contains("Copied (new)"))
        XCTAssertTrue(URL(fileURLWithPath: logPath).lastPathComponent.hasPrefix("archive_"))
        XCTAssertTrue(fm.fileExists(atPath: base.appendingPathComponent("extra-logs")
            .appendingPathComponent(URL(fileURLWithPath: logPath).lastPathComponent).path))

        // A second run with nothing changed uploads nothing.
        await runSync(engine)
        XCTAssertEqual(engine.status, .done)
        XCTAssertEqual(engine.history.first?.uploaded, 0)
        XCTAssertEqual(engine.history.count, 2)
    }

    @MainActor
    func testRenamedFolderIsMovedNotUploaded() async throws {
        let n = try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        await firstSync(engine, expectedFiles: n)

        try fm.moveItem(at: src.appendingPathComponent("A/photos"), to: src.appendingPathComponent("A/pictures"))
        await runSync(engine)
        XCTAssertEqual(engine.status, .done)
        let record = try XCTUnwrap(engine.history.first)
        XCTAssertEqual(record.moved, 5)
        XCTAssertEqual(record.uploaded, 0)
        XCTAssertEqual(record.removed, 0)
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("A/pictures/img_3.jpg").path))
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("A/photos/img_3.jpg").path))
    }

    @MainActor
    func testDeletedFileGoesToRemovedFolder() async throws {
        let n = try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        await firstSync(engine, expectedFiles: n)

        try fm.removeItem(at: src.appendingPathComponent("B/note.txt"))
        await runSync(engine)
        XCTAssertEqual(engine.status, .done)
        let record = try XCTUnwrap(engine.history.first)
        XCTAssertEqual(record.removed, 1)
        XCTAssertEqual(record.moved, 0)
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("B/note.txt").path))

        let stamps = try fm.contentsOfDirectory(atPath: removed.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(stamps.count, 1)
        let stamp = try XCTUnwrap(stamps.first)
        XCTAssertNotNil(stamp.range(of: #"^\d{4}-\d{2}-\d{2}_\d{4}$"#, options: .regularExpression), stamp)
        let kept = removed.appendingPathComponent(stamp).appendingPathComponent("B/note.txt")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "a small note")
    }

    @MainActor
    func testEmptySourceIsRefusedBeforeRclone() async throws {
        let n = try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        await firstSync(engine, expectedFiles: n)
        let before = files(under: dst)

        // Simulate a half-mounted disk: the folder is there but empty (Finder litter only).
        try fm.removeItem(at: src)
        try fm.createDirectory(at: src, withIntermediateDirectories: true, attributes: nil)
        try Data().write(to: src.appendingPathComponent(".DS_Store"))
        let logsBefore = try fm.contentsOfDirectory(atPath: base.appendingPathComponent("logs").path).count

        await runSync(engine)
        guard case .needsAttention(let reason) = engine.status else {
            return XCTFail("expected needsAttention, got \(engine.status)")
        }
        XCTAssertTrue(reason.lowercased().contains("empty"), reason)
        XCTAssertNil(engine.activeJobID)
        XCTAssertEqual(files(under: dst), before, "destination untouched")
        XCTAssertEqual(historyStore.records.count, 1, "no run happened")
        XCTAssertEqual(notifier.failed.count, 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base.appendingPathComponent("logs").path).count, logsBefore,
                       "rclone never started, so no new log")
        XCTAssertTrue(removedFolderIsEmpty(), "nothing moved into the removed folder")
    }

    @MainActor
    func testPreviewFillsPreviewAndChangesNothing() async throws {
        let n = try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        await firstSync(engine, expectedFiles: n)
        XCTAssertEqual(engine.job(id: "archive")?.previewApproved, false)

        try write("B/new.txt", "brand new")
        try fm.removeItem(at: src.appendingPathComponent("A/photos/img_2.jpg"))
        let before = files(under: dst)

        engine.previewChanges(jobID: "archive")
        await engine.currentTask?.value

        XCTAssertEqual(engine.status, .idle)
        XCTAssertNil(engine.activeJobID)
        let preview = try XCTUnwrap(engine.preview)
        XCTAssertEqual(preview.jobID, "archive")
        XCTAssertEqual(preview.count(.new), 1)
        XCTAssertEqual(preview.items(.new).first?.path, "B/new.txt")
        XCTAssertEqual(preview.count(.removed), 1)
        XCTAssertEqual(preview.items(.removed).first?.path, "A/photos/img_2.jpg")
        XCTAssertEqual(preview.count(.moved), 0)
        XCTAssertEqual(preview.count(.replaced), 0)
        XCTAssertEqual(preview.uploadBytes, Int64("brand new".utf8.count))

        XCTAssertEqual(files(under: dst), before, "a preview changes nothing")
        XCTAssertTrue(removedFolderIsEmpty(), "nothing moved into the removed folder")
        XCTAssertEqual(engine.history.count, 1, "previews are not runs")
        XCTAssertEqual(engine.job(id: "archive")?.previewApproved, true)
        // ... and the approval was saved to disk.
        let saved = try ConfigStore(fileURL: base.appendingPathComponent("config/config.json")).load()
        XCTAssertEqual(saved.jobs.first?.previewApproved, true)
    }

    @MainActor
    func testVolumeMountAutoStartsApprovedJob() async throws {
        let n = try makeSourceFiles()
        let engine = try await makeEngine(job: job(requiredVolume: "MyDisk", autoSync: true, approved: true))
        let j = try XCTUnwrap(engine.job(id: "archive"))
        XCTAssertFalse(engine.isAvailable(j))

        engine.volumeMounted("MyDisk")
        XCTAssertTrue(engine.mountedVolumes.contains("MyDisk"), "inserted right away, before the delay")
        XCTAssertTrue(engine.isAvailable(j))

        let deadline = Date().addingTimeInterval(60)
        while engine.history.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let task = engine.currentTask { await task.value }
        }
        XCTAssertEqual(engine.history.first?.uploaded, n)
        XCTAssertEqual(engine.status, .done)

        engine.volumeUnmounted("MyDisk")
        XCTAssertFalse(engine.mountedVolumes.contains("MyDisk"))
        XCTAssertFalse(engine.isAvailable(j))
    }

    @MainActor
    func testRemovedSizeAndEmpty() async throws {
        _ = try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        await firstSync(engine, expectedFiles: 6)
        try fm.removeItem(at: src.appendingPathComponent("B/note.txt"))
        await runSync(engine)
        XCTAssertTrue(fm.fileExists(atPath: removed.path))

        // Wait for the background size refresh started after the run.
        let deadline = Date().addingTimeInterval(30)
        while (engine.removedBytes["archive"] ?? 0) == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(engine.removedBytes["archive"], Int64("a small note".utf8.count))

        engine.emptyRemovedItems(jobID: "archive")
        await engine.currentTask?.value
        XCTAssertEqual(engine.removedBytes["archive"], 0)
        XCTAssertFalse(fm.fileExists(atPath: removed.path))
        XCTAssertEqual(files(under: dst).count, 5, "the backup itself is untouched")
        XCTAssertEqual(engine.status, .done)
    }
}
