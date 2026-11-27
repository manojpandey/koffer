import XCTest
@testable import KofferCore

/// A clock tests can move forward.
final class TestClock {
    var now: Date = Date()
}

/// v0.4 "big folders": live, logged previews; Stop during a preview; reusing a fresh preview for "Back up now";
/// the rename strategy; OneDrive delta listings. The real rclone runs against local folders; fake rclone
/// scripts stand in where a slow run or a OneDrive remote is needed.
final class BigFolderTests: XCTestCase {
    private var base: URL!
    private var src: URL!
    private var dst: URL!
    private var removed: URL!
    private var notifier: FakeNotifier!
    private var historyStore: FakeHistory!
    private var clock: TestClock!

    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = try makeTempDirectory("koffer-big")
        src = base.appendingPathComponent("src", isDirectory: true)
        dst = base.appendingPathComponent("dst", isDirectory: true)
        removed = base.appendingPathComponent("removed", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: base.appendingPathComponent("home"), withIntermediateDirectories: true, attributes: nil)
        notifier = FakeNotifier()
        historyStore = FakeHistory()
        clock = TestClock()
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

    private var logs: URL { return base.appendingPathComponent("logs", isDirectory: true) }

    private func job(requiredVolume: String? = nil, autoSync: Bool = false, approved: Bool = false) -> SyncJob {
        return SyncJob(id: "archive", name: "Archive", source: src.path, destination: dst.path,
                       removedRoot: removed.path, requiredVolume: requiredVolume, autoSyncOnMount: autoSync,
                       enabled: true, previewApproved: approved)
    }

    @MainActor
    private func makeEngine(job: SyncJob, rclone: String) throws -> SyncEngine {
        let configURL = base.appendingPathComponent("config/config.json")
        try ConfigStore(fileURL: configURL).save(KofferConfig(jobs: [job]))
        let testClock: TestClock = clock
        let env = EngineEnvironment(configURL: configURL, logDirectory: logs,
                                    rcloneCandidates: [rclone], mountDelay: 0.1, interruptGrace: 5,
                                    homeDirectory: base.appendingPathComponent("home").path,
                                    volumesDirectory: nil,
                                    now: { () -> Date in testClock.now },
                                    manifestDirectory: base.appendingPathComponent("manifests", isDirectory: true))
        let services = EngineServices(notifier: notifier, power: FakePower(), history: historyStore)
        return SyncEngine(services: services, environment: env)
    }

    @MainActor
    private func makeRealEngine(job: SyncJob) async throws -> SyncEngine {
        guard let rclone = await BigFolderTests.findRclone() else {
            throw XCTSkip("rclone is not installed; skipping integration tests")
        }
        return try makeEngine(job: job, rclone: rclone)
    }

    /// Writes an executable shell script and returns its path.
    private func writeScript(_ name: String, _ body: String) throws -> String {
        let url = base.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)
        return url.path
    }

    /// A stand-in for rclone whose sync prints one stats line (as a real dry run does while it hashes) and then
    /// waits, so the test can look at the live progress and press Stop.
    private func slowRclone() throws -> String {
        let stats = #"{"time":"2026-01-01T10:00:00Z","level":"notice","msg":"stats","stats":{"bytes":0,"totalBytes":0,"transfers":0,"totalTransfers":0,"checks":5,"totalChecks":40,"listed":1234,"checking":["A/one.bin"],"errors":0,"elapsedTime":1.0}}"#
        return try writeScript("slow-rclone", """
        case "$1" in
          sync)
            echo '\(stats)' >&2
            exec sleep 30 ;;
        esac
        exit 0

        """)
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = src.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try Data(text.utf8).write(to: url)
    }

    private func makeSourceFiles() throws {
        for i in 1...5 {
            try write("A/photos/img_\(i).jpg", String(repeating: "photo \(i) ", count: 200 + i))
        }
        try write("B/note.txt", "a small note")
    }

    private func logFiles(containing fragment: String) -> [String] {
        let names: [String] = (try? fm.contentsOfDirectory(atPath: logs.path)) ?? []
        return names.filter { $0.contains(fragment) }.sorted()
    }

    @MainActor
    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @MainActor
    private func runSync(_ engine: SyncEngine) async {
        engine.syncNow(jobID: "archive")
        await engine.currentTask?.value
    }

    @MainActor
    private func runPreview(_ engine: SyncEngine) async {
        engine.previewChanges(jobID: "archive")
        await engine.currentTask?.value
    }

    // MARK: - Live, logged previews and Stop

    @MainActor
    func testPreviewShowsLiveProgressAndStopsCleanly() async throws {
        try write("A/one.bin", "one")
        let engine = try makeEngine(job: job(), rclone: try slowRclone())
        engine.previewChanges(jobID: "archive")
        XCTAssertNotNil(engine.busySince)

        let sawProgress: Bool = await waitUntil(10) { engine.progress.listed > 0 }
        XCTAssertTrue(sawProgress, "the dry run publishes stats while it runs")
        XCTAssertEqual(engine.status, .previewing)
        XCTAssertEqual(engine.activeJobID, "archive")
        XCTAssertEqual(engine.progress.listed, 1234)
        XCTAssertEqual(engine.progress.checksDone, 5)
        XCTAssertEqual(engine.progress.checksTotal, 40)
        XCTAssertEqual(engine.progress.currentChecks, ["A/one.bin"])
        XCTAssertTrue(engine.isFirstCheck, "no clean backup yet: rclone compares contents")

        engine.cancel()
        await engine.currentTask?.value
        XCTAssertEqual(engine.status, .idle, "a stopped preview is not a paused backup")
        XCTAssertNil(engine.preview, "nothing published")
        XCTAssertNil(engine.activeJobID)
        XCTAssertNil(engine.busySince)
        XCTAssertFalse(engine.isFirstCheck)
        XCTAssertTrue(historyStore.records.isEmpty, "previews never go into the history")
        XCTAssertTrue(notifier.paused.isEmpty && notifier.failed.isEmpty)
        XCTAssertEqual(engine.job(id: "archive")?.previewApproved, false)
        XCTAssertEqual(engine.dryRunCount, 1)

        // The preview has its own log with rclone's lines.
        let previewLogs: [String] = logFiles(containing: "_preview_")
        XCTAssertEqual(previewLogs.count, 1)
        let name: String = try XCTUnwrap(previewLogs.first)
        XCTAssertTrue(name.hasPrefix("archive_preview_"), name)
        XCTAssertNotNil(name.range(of: #"^archive_preview_\d{4}-\d{2}-\d{2}_\d{4}\.log$"#, options: .regularExpression), name)
        let text = try String(contentsOf: logs.appendingPathComponent(name), encoding: .utf8)
        XCTAssertTrue(text.contains("\"listed\":1234"), text)
    }

    @MainActor
    func testStopBeforeThePreviewStartsIsAlsoIdle() async throws {
        try write("A/one.bin", "one")
        let engine = try makeEngine(job: job(), rclone: try slowRclone())
        engine.previewChanges(jobID: "archive")
        engine.cancel()
        await engine.currentTask?.value
        XCTAssertEqual(engine.status, .idle)
        XCTAssertNil(engine.preview)
        XCTAssertTrue(historyStore.records.isEmpty)
    }

    @MainActor
    func testBackUpNowShowsItsDryRunLive() async throws {
        try write("A/one.bin", "one")
        let engine = try makeEngine(job: job(), rclone: try slowRclone())
        engine.syncNow(jobID: "archive")
        let sawProgress: Bool = await waitUntil(10) { engine.progress.listed > 0 }
        XCTAssertTrue(sawProgress)
        XCTAssertEqual(engine.status, .preparing(SyncEngine.lookingMessage))
        XCTAssertEqual(engine.progress.currentChecks, ["A/one.bin"])

        engine.cancel()
        await engine.currentTask?.value
        XCTAssertEqual(engine.status, .paused(SyncEngine.stoppedByYouMessage), "a stopped backup stays paused, as before")
        XCTAssertTrue(historyStore.records.isEmpty, "the real sync never ran")
        XCTAssertTrue(logFiles(containing: "_preview_").isEmpty, "a backup's dry run goes into the backup's own log")
    }

    @MainActor
    func testPreviewWithRealRcloneWritesALogAndFillsProgress() async throws {
        try makeSourceFiles()
        let engine = try await makeRealEngine(job: job())
        await runPreview(engine)
        XCTAssertEqual(engine.status, .idle)
        XCTAssertEqual(engine.preview?.count(.new), 6)
        XCTAssertGreaterThan(engine.progress.listed, 0, "the last stats line was published")
        XCTAssertEqual(logFiles(containing: "_preview_").count, 1)
        XCTAssertTrue(historyStore.records.isEmpty)
    }

    // MARK: - Rename strategy

    @MainActor
    func testRenameStrategyFollowsTheCloudRecord() async throws {
        try makeSourceFiles()
        let engine = try await makeRealEngine(job: job())
        XCTAssertEqual(engine.renameStrategy(for: job()), .hash, "no clean backup yet")
        await runSync(engine)
        XCTAssertEqual(engine.status, .done)
        XCTAssertEqual(engine.renameStrategy(for: job()), .modtimeLeaf, "a clean backup recorded the cloud")

        // With modtime,leaf a renamed folder is still a server-side move.
        try fm.moveItem(at: src.appendingPathComponent("A/photos"), to: src.appendingPathComponent("A/pictures"))
        await runPreview(engine)
        XCTAssertEqual(engine.preview?.count(.moved), 5)
        XCTAssertEqual(engine.preview?.count(.new), 0)
        await runSync(engine)
        XCTAssertEqual(engine.status, .done)
        XCTAssertEqual(engine.history.first?.moved, 5)
        XCTAssertEqual(engine.history.first?.uploaded, 0)
    }

    // MARK: - Reusing a fresh preview

    @MainActor
    func testBackUpNowReusesAFreshPreview() async throws {
        try makeSourceFiles()
        let engine = try await makeRealEngine(job: job())
        await runSync(engine)
        XCTAssertEqual(engine.status, .done)
        XCTAssertEqual(engine.dryRunCount, 1)

        try write("B/new.txt", "brand new")
        clock.now = clock.now.addingTimeInterval(30)
        await runPreview(engine)
        XCTAssertEqual(engine.preview?.count(.new), 1)
        XCTAssertEqual(engine.dryRunCount, 2)

        clock.now = clock.now.addingTimeInterval(9 * 60)
        await runSync(engine)
        XCTAssertEqual(engine.status, .done)
        XCTAssertEqual(engine.dryRunCount, 2, "no second dry run")
        XCTAssertEqual(engine.history.first?.uploaded, 1)
        XCTAssertEqual(engine.progress.filesTotal, 1, "totals came from the preview")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("B/new.txt"), encoding: .utf8), "brand new")
        let logPath: String = try XCTUnwrap(engine.history.first?.logPath)
        let logText = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(logText.contains("What will change?"), "the backup's log says the preview was used")

        // Used once: the next backup looks for itself.
        clock.now = clock.now.addingTimeInterval(10)
        await runSync(engine)
        XCTAssertEqual(engine.dryRunCount, 3)
        XCTAssertEqual(engine.history.first?.uploaded, 0)
    }

    @MainActor
    func testAnOldPreviewIsNotReused() async throws {
        try makeSourceFiles()
        let engine = try await makeRealEngine(job: job())
        await runPreview(engine)
        XCTAssertEqual(engine.dryRunCount, 1)
        clock.now = clock.now.addingTimeInterval(SyncEngine.previewReuseWindow + 1)
        await runSync(engine)
        XCTAssertEqual(engine.status, .done)
        XCTAssertEqual(engine.dryRunCount, 2, "more than 10 minutes later: look again")
        XCTAssertEqual(engine.history.first?.uploaded, 6)
    }

    @MainActor
    func testAPreviewFromBeforeAnUnplugIsNotReused() async throws {
        try makeSourceFiles()
        let engine = try await makeRealEngine(job: job(requiredVolume: "MyDisk"))
        engine.volumeMounted("MyDisk")
        await runPreview(engine)
        XCTAssertEqual(engine.status, .idle)
        XCTAssertEqual(engine.dryRunCount, 1)

        clock.now = clock.now.addingTimeInterval(5)
        engine.volumeUnmounted("MyDisk")
        engine.volumeMounted("MyDisk")
        await runSync(engine)
        XCTAssertEqual(engine.status, .done)
        XCTAssertEqual(engine.dryRunCount, 2, "the disk was unplugged since the preview")
    }

    @MainActor
    func testAutomaticRunsAlwaysLookForThemselves() async throws {
        try makeSourceFiles()
        let engine = try await makeRealEngine(job: job(requiredVolume: "MyDisk", autoSync: true, approved: true))
        engine.volumeMounted("MyDisk")
        let first: Bool = await waitUntil(60) { historyStore.records.count == 1 && engine.currentTask != nil && !engine.status.isBusy }
        XCTAssertTrue(first)
        if let task = engine.currentTask { await task.value }
        XCTAssertEqual(engine.dryRunCount, 1)

        await runPreview(engine)
        XCTAssertEqual(engine.dryRunCount, 2)

        engine.volumeMounted("MyDisk")   // plugged in again (e.g. after a wake): an automatic run
        let second: Bool = await waitUntil(60) { historyStore.records.count == 2 && !engine.status.isBusy }
        XCTAssertTrue(second)
        if let task = engine.currentTask { await task.value }
        XCTAssertEqual(engine.dryRunCount, 3, "automatic runs never use a preview")
    }

    @MainActor
    func testReuseRules() {
        let job = SyncJob(id: "archive", name: "Archive", source: "/Volumes/MyDisk/Archive", destination: "onedrive:Archive",
                          removedRoot: "onedrive:_Archive_removed", requiredVolume: "MyDisk")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let finished: Date = t0.addingTimeInterval(120)
        let run = PreviewRun(jobID: "archive", source: job.source, destination: job.destination, removedRoot: job.removedRoot,
                             startedAt: t0, finishedAt: finished, items: [], checksTotal: 10, hadCloudDeletions: false,
                             renameStrategy: .modtimeLeaf)
        let window: TimeInterval = SyncEngine.previewReuseWindow
        func reuse(_ r: PreviewRun, _ j: SyncJob, now: Date, strategy: RenameStrategy = .modtimeLeaf,
                   pending: Bool = false, unplugged: [String: Date] = [:]) -> Bool {
            return SyncEngine.canReuse(r, job: j, strategy: strategy, now: now, reportPending: pending,
                                       unmountedAt: unplugged, window: window)
        }

        XCTAssertTrue(reuse(run, job, now: finished.addingTimeInterval(599)))
        XCTAssertFalse(reuse(run, job, now: finished.addingTimeInterval(600)), "10 minutes is too old")
        XCTAssertFalse(reuse(run, job, now: finished.addingTimeInterval(-1)), "a clock that went backwards")
        XCTAssertFalse(reuse(run, job, now: finished, strategy: .hash))
        XCTAssertFalse(reuse(run, job, now: finished, pending: true), "files deleted in the cloud wait for a decision")
        var withDeletions: PreviewRun = run
        withDeletions.hadCloudDeletions = true
        XCTAssertFalse(reuse(withDeletions, job, now: finished))

        XCTAssertFalse(reuse(run, job, now: finished, unplugged: ["MyDisk": t0.addingTimeInterval(30)]), "unplugged during the preview")
        XCTAssertFalse(reuse(run, job, now: finished, unplugged: ["MyDisk": finished.addingTimeInterval(10)]), "unplugged after it")
        XCTAssertTrue(reuse(run, job, now: finished, unplugged: ["MyDisk": t0.addingTimeInterval(-1)]), "unplugged before it started")
        XCTAssertTrue(reuse(run, job, now: finished, unplugged: ["OtherDisk": finished]))

        var moved: SyncJob = job
        moved.source = "/Volumes/MyDisk/Archive 2"
        XCTAssertFalse(reuse(run, moved, now: finished))
        var elsewhere: SyncJob = job
        elsewhere.destination = "onedrive:Archive2"
        XCTAssertFalse(reuse(run, elsewhere, now: finished))
        var otherRemoved: SyncJob = job
        otherRemoved.removedRoot = "onedrive:_Archive_old"
        XCTAssertFalse(reuse(run, otherRemoved, now: finished))
        var otherJob: SyncJob = job
        otherJob.id = "photos"
        XCTAssertFalse(reuse(run, otherJob, now: finished))

        // No required volume, but the folder is on a disk: that disk counts too.
        var loose: SyncJob = job
        loose.requiredVolume = nil
        XCTAssertEqual(SyncEngine.volumes(of: loose), ["MyDisk"])
        XCTAssertFalse(reuse(run, loose, now: finished, unplugged: ["MyDisk": finished]))
        XCTAssertEqual(SyncEngine.volumes(of: SyncJob(id: "t", name: "T", source: "/Users/someone/Koffer Test",
                                                      destination: "onedrive:t", removedRoot: "onedrive:_t")), [])
    }

    // MARK: - OneDrive delta listings and remote types

    @MainActor
    func testCloudListingUsesOneDriveDeltaOnOneDriveOnly() async throws {
        let calls = base.appendingPathComponent("calls.log")
        let script = try writeScript("fake-rclone", """
        echo "$*" >> '\(calls.path)'
        case "$1" in
          listremotes)
            if [ "$2" = "--long" ]; then echo "Fake: onedrive"; echo "Other: drive"; else echo "Fake:"; echo "Other:"; fi
            exit 0 ;;
          about)
            echo '{"total": 100, "used": 40, "free": 60}'
            exit 0 ;;
          lsjson)
            echo '[{"Path":"a.txt","Name":"a.txt","Size":3,"IsDir":false}]'
            exit 0 ;;
        esac
        exit 0

        """)
        let oneDrive = SyncJob(id: "archive", name: "Archive", source: "/Volumes/MyDisk/Archive",
                               destination: "Fake:Backups/Archive", removedRoot: "Fake:Backups/_Archive_removed")
        let other = SyncJob(id: "photos", name: "Photos", source: "/Volumes/MyDisk/Photos",
                            destination: "Other:Photos", removedRoot: "Other:_Photos_removed")
        let engine = try makeEngine(job: oneDrive, rclone: script)
        func lines() -> [String] {
            let text: String = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map { String($0) }
        }

        let listed: CloudListingResult = await engine.listCloud(job: oneDrive, rclone: script)
        guard case .files(let entries) = listed else { return XCTFail("expected files, got \(listed)") }
        XCTAssertEqual(entries.map { $0.path }, ["a.txt"])
        _ = await engine.listCloud(job: other, rclone: script)
        _ = await engine.listCloud(job: oneDrive, rclone: script)
        let plain: String = RcloneCommand.listFiles(target: "Fake:Backups/Archive").joined(separator: " ")
        XCTAssertEqual(lines(), [
            "listremotes --long",
            plain + " --onedrive-delta",
            RcloneCommand.listFiles(target: "Other:Photos").joined(separator: " "),
            plain + " --onedrive-delta",
        ], "the remote types are learned once")
        XCTAssertEqual(engine.cloudListingCount, 3)

        // After a connection check the drive's size is known: a backup that is a small part of it lists folder by folder.
        engine.refreshRemotes(force: true)
        if let task = engine.remotesTask { await task.value }
        XCTAssertEqual(engine.remoteStates["Fake:"], .connected(used: 40, total: 100, free: 60))
        try? fm.removeItem(at: calls)
        let small: [String] = await engine.listFilesArguments(job: oneDrive, rclone: script, backupBytes: 10)
        XCTAssertFalse(small.contains("--onedrive-delta"))
        let big: [String] = await engine.listFilesArguments(job: oneDrive, rclone: script, backupBytes: 30)
        XCTAssertTrue(big.contains("--onedrive-delta"))
        XCTAssertEqual(lines(), ["listremotes --long"], "the connection check made Koffer learn the types again, once")

        // A folder on this Mac never asks rclone for remote types.
        let local: [String] = await engine.listFilesArguments(job: job(), rclone: script, backupBytes: nil)
        XCTAssertEqual(local, RcloneCommand.listFiles(target: dst.path))
        XCTAssertEqual(lines(), ["listremotes --long"])
    }
}
