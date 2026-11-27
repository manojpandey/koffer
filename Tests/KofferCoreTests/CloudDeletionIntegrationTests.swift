import XCTest
@testable import KofferCore

/// Records what the engine sent to the Trash; the fake Trash is a scratch folder, so tests never touch the real one.
final class FakeTrash {
    let directory: URL
    private(set) var trashed: [String] = []

    init(directory: URL) {
        self.directory = directory
    }

    func move(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let target = directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try fm.moveItem(at: url, to: target)
        trashed.append(url.path)
    }
}

/// v0.3 "deleted in the cloud", end to end with the real rclone against local folders ("remotes").
/// Skipped when rclone is not installed.
final class CloudDeletionIntegrationTests: XCTestCase {
    private var base: URL!
    private var src: URL!
    private var dst: URL!
    private var removed: URL!
    private var manifests: URL!
    private var notifier: FakeNotifier!
    private var historyStore: FakeHistory!
    private var trash: FakeTrash!

    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = try makeTempDirectory("koffer-cloud-int")
        src = base.appendingPathComponent("src", isDirectory: true)
        dst = base.appendingPathComponent("dst", isDirectory: true)
        removed = base.appendingPathComponent("removed", isDirectory: true)
        manifests = base.appendingPathComponent("manifests", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: base.appendingPathComponent("home"), withIntermediateDirectories: true, attributes: nil)
        notifier = FakeNotifier()
        historyStore = FakeHistory()
        trash = FakeTrash(directory: base.appendingPathComponent("Trash", isDirectory: true))
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
                       enabled: true, previewApproved: approved)
    }

    @MainActor
    private func makeEngine(job: SyncJob) async throws -> SyncEngine {
        guard let rclone = await CloudDeletionIntegrationTests.findRclone() else {
            throw XCTSkip("rclone is not installed; skipping integration tests")
        }
        let configURL = base.appendingPathComponent("config/config.json")
        try ConfigStore(fileURL: configURL).save(KofferConfig(jobs: [job]))
        let fakeTrash: FakeTrash = trash
        let env = EngineEnvironment(configURL: configURL, logDirectory: base.appendingPathComponent("logs"),
                                    rcloneCandidates: [rclone], mountDelay: 0.1, interruptGrace: 5,
                                    homeDirectory: base.appendingPathComponent("home").path,
                                    volumesDirectory: nil,
                                    manifestDirectory: manifests,
                                    trashItem: { (url: URL) throws -> Void in try fakeTrash.move(url) })
        let services = EngineServices(notifier: notifier, power: FakePower(), history: historyStore)
        let engine = SyncEngine(services: services, environment: env)
        XCTAssertEqual(engine.rclonePath, rclone)
        return engine
    }

    private func write(_ relative: String, _ text: String) throws {
        let url = src.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try Data(text.utf8).write(to: url)
    }

    /// 5 photos + 1 note = 6 files, each with unique content.
    private func makeSourceFiles() throws {
        for i in 1...5 {
            try write("A/photos/img_\(i).jpg", String(repeating: "photo \(i) ", count: 200 + i))
        }
        try write("B/note.txt", "a small note")
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

    @MainActor
    private func runSync(_ engine: SyncEngine) async {
        engine.syncNow(jobID: "archive")
        await engine.currentTask?.value
    }

    @MainActor
    private func firstSync(_ engine: SyncEngine) async {
        await runSync(engine)
        XCTAssertEqual(engine.status, .done, "first sync status")
        XCTAssertEqual(files(under: dst), files(under: src))
    }

    private func deleteInCloud(_ paths: [String]) throws {
        for p in paths { try fm.removeItem(at: dst.appendingPathComponent(p)) }
    }

    private func manifest() throws -> CloudManifest {
        return try XCTUnwrap(ManifestStore(directory: manifests).load(jobID: "archive", destination: dst.path))
    }

    // MARK: - Tests

    @MainActor
    func testCleanSyncWritesManifest() async throws {
        try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        XCTAssertNil(ManifestStore(directory: manifests).load(jobID: "archive", destination: dst.path))
        await firstSync(engine)

        XCTAssertTrue(fm.fileExists(atPath: manifests.appendingPathComponent("archive.json").path))
        let m = try manifest()
        XCTAssertEqual(m.destination, dst.path)
        XCTAssertEqual(m.files.map { $0.path }.sorted(), files(under: src))
        let note = try XCTUnwrap(m.files.first(where: { $0.path == "B/note.txt" }))
        XCTAssertEqual(note.size, Int64("a small note".utf8.count))
        XCTAssertTrue(engine.cloudDeletions.isEmpty)

        // Forgetting the backup removes its manifest (and nothing else).
        XCTAssertEqual(engine.removeJob(id: "archive"), .ok)
        XCTAssertFalse(fm.fileExists(atPath: manifests.appendingPathComponent("archive.json").path))
        XCTAssertEqual(files(under: dst).count, 6)
    }

    @MainActor
    func testCloudDeletionStopsTheBackupThenPutBackRestoresThem() async throws {
        try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        await firstSync(engine)
        let deleted: [String] = ["A/photos/img_2.jpg", "B/note.txt"]
        try deleteInCloud(deleted)

        await runSync(engine)
        XCTAssertEqual(engine.status, .needsAttention(SyncEngine.cloudDeletionsMessage(job: job())))
        XCTAssertEqual(engine.statusJobID, "archive")
        XCTAssertNil(engine.activeJobID)
        let report = try XCTUnwrap(engine.cloudDeletions["archive"])
        XCTAssertEqual(report.items.map { $0.path }, deleted)
        XCTAssertTrue(report.items.allSatisfy { $0.kind == .removed })
        XCTAssertEqual(report.extrasCount, 0)
        XCTAssertFalse(report.looksLikeMassRemoval)
        let expectedBytes: Int64 = Int64(String(repeating: "photo 2 ", count: 202).utf8.count + "a small note".utf8.count)
        XCTAssertEqual(report.totalBytes, expectedBytes)
        XCTAssertEqual(notifier.cloudFound.count, 1)
        XCTAssertEqual(notifier.cloudFound.first?.1, 2)
        XCTAssertEqual(historyStore.records.count, 1, "the real sync never ran")
        XCTAssertEqual(files(under: dst).count, 4, "nothing was uploaded")
        XCTAssertTrue(files(under: removed).isEmpty)
        XCTAssertEqual(files(under: src).count, 6, "nothing changed on the disk")

        // Back up now again: the same report, no second notification for the same files.
        await runSync(engine)
        XCTAssertEqual(engine.cloudDeletions["archive"], report.withDate(engine.cloudDeletions["archive"]?.detectedAt))
        XCTAssertEqual(notifier.cloudFound.count, 1)
        XCTAssertEqual(files(under: dst).count, 4)

        // "Put them back in ...".
        engine.keepLocalAndRestoreCloud(jobID: "archive")
        await engine.currentTask?.value
        XCTAssertEqual(engine.status, .done)
        XCTAssertNil(engine.cloudDeletions["archive"])
        XCTAssertEqual(files(under: dst), files(under: src))
        XCTAssertEqual(engine.history.first?.uploaded, 2)

        // The manifest was refreshed: the next backup has nothing to ask and nothing to do.
        await runSync(engine)
        XCTAssertEqual(engine.status, .done)
        XCTAssertEqual(engine.history.first?.uploaded, 0)
        XCTAssertEqual(engine.history.first?.removed, 0)
    }

    @MainActor
    func testApplyCloudDeletionsMovesTheLocalFilesToTheTrash() async throws {
        try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        await firstSync(engine)
        let deleted: [String] = ["A/photos/img_2.jpg", "B/note.txt"]
        try deleteInCloud(deleted)
        await runSync(engine)
        XCTAssertNotNil(engine.cloudDeletions["archive"])

        let result = await engine.applyCloudDeletions(jobID: "archive")
        XCTAssertEqual(result, .success(2))
        await engine.currentTask?.value   // the backup that follows

        for p in deleted {
            XCTAssertFalse(fm.fileExists(atPath: src.appendingPathComponent(p).path), "\(p) left the disk")
        }
        XCTAssertEqual(trash.trashed.count, 2)
        XCTAssertEqual(files(under: trash.directory).count, 2, "moved to the Trash, not deleted")
        XCTAssertEqual(files(under: src).count, 4)
        XCTAssertNil(engine.cloudDeletions["archive"])
        XCTAssertEqual(engine.status, .done)
        XCTAssertEqual(engine.history.first?.uploaded, 0, "nothing put back")
        XCTAssertEqual(engine.history.first?.removed, 0, "nothing else moved away")
        XCTAssertEqual(files(under: dst), files(under: src))

        await runSync(engine)
        XCTAssertEqual(engine.status, .done)
        XCTAssertEqual(engine.history.first?.uploaded, 0)
        XCTAssertEqual(engine.history.first?.removed, 0)
        XCTAssertTrue(files(under: removed).isEmpty)
    }

    @MainActor
    func testApplyChecksEachFileAgain() async throws {
        try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        await firstSync(engine)
        try deleteInCloud(["A/photos/img_2.jpg", "B/note.txt"])
        await runSync(engine)
        XCTAssertEqual(engine.cloudDeletions["archive"]?.items.count, 2)

        // Between the report and the decision, the note is edited on this disk.
        try write("B/note.txt", "a longer note, edited after the report")
        let result = await engine.applyCloudDeletions(jobID: "archive")
        XCTAssertEqual(result, .success(1))
        await engine.currentTask?.value

        XCTAssertFalse(fm.fileExists(atPath: src.appendingPathComponent("A/photos/img_2.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: src.appendingPathComponent("B/note.txt").path), "changed file stays")
        XCTAssertEqual(engine.history.first?.uploaded, 1, "and is backed up again")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("B/note.txt"), encoding: .utf8),
                       "a longer note, edited after the report")
    }

    @MainActor
    func testLocallyChangedFilesAreNotCandidatesAndAreUploadedAgain() async throws {
        try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        await firstSync(engine)
        try deleteInCloud(["B/note.txt", "A/photos/img_1.jpg"])
        // Changed here since the backup: another size, and the same size but newer.
        try write("B/note.txt", "a different, longer note")
        let sameSize = String(repeating: "PHOTO 1 ", count: 201)
        XCTAssertEqual(sameSize.utf8.count, String(repeating: "photo 1 ", count: 201).utf8.count)
        try write("A/photos/img_1.jpg", sameSize)

        await runSync(engine)
        XCTAssertNil(engine.cloudDeletions["archive"])
        XCTAssertEqual(engine.status, .done)
        XCTAssertEqual(engine.history.first?.uploaded, 2)
        XCTAssertTrue(notifier.cloudFound.isEmpty)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("B/note.txt"), encoding: .utf8), "a different, longer note")
        XCTAssertEqual(files(under: dst), files(under: src))
    }

    @MainActor
    func testFilesAddedInTheCloudAreCountedAsExtras() async throws {
        try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        await firstSync(engine)
        // Renamed in the cloud: the old name is gone there, the new name is not on this disk.
        try fm.moveItem(at: dst.appendingPathComponent("B/note.txt"), to: dst.appendingPathComponent("B/renamed note.txt"))

        await runSync(engine)
        let report = try XCTUnwrap(engine.cloudDeletions["archive"])
        XCTAssertEqual(report.items.map { $0.path }, ["B/note.txt"])
        XCTAssertEqual(report.extrasCount, 1)
    }

    @MainActor
    func testPreviewListsFilesDeletedInTheCloud() async throws {
        try makeSourceFiles()
        let engine = try await makeEngine(job: job())
        await firstSync(engine)
        try deleteInCloud(["B/note.txt"])

        engine.previewChanges(jobID: "archive")
        await engine.currentTask?.value
        XCTAssertEqual(engine.status, .idle)
        let preview = try XCTUnwrap(engine.preview)
        XCTAssertEqual(preview.cloudDeleted.map { $0.path }, ["B/note.txt"])
        XCTAssertEqual(preview.items(.new).map { $0.path }, ["B/note.txt"], "the dry run would put it back")
        XCTAssertNotNil(engine.cloudDeletions["archive"], "the decision is waiting")
        XCTAssertEqual(files(under: dst).count, 5, "a preview changes nothing")
    }

    @MainActor
    func testMassRemovalCanOnlyBePutBack() async throws {
        for i in 1...60 { try write("Many/file_\(i).txt", "file number \(i)") }
        let engine = try await makeEngine(job: job())
        await firstSync(engine)
        try deleteInCloud((1...60).map { "Many/file_\($0).txt" })

        await runSync(engine)
        let report = try XCTUnwrap(engine.cloudDeletions["archive"])
        XCTAssertEqual(report.items.count, 60)
        XCTAssertTrue(report.looksLikeMassRemoval)

        let result = await engine.applyCloudDeletions(jobID: "archive")
        XCTAssertEqual(result, .failure(EngineError(SyncEngine.massCloudDeletionRefusal)))
        XCTAssertEqual(files(under: src).count, 60, "nothing deleted here")
        XCTAssertTrue(trash.trashed.isEmpty)

        engine.keepLocalAndRestoreCloud(jobID: "archive")
        await engine.currentTask?.value
        XCTAssertEqual(files(under: dst).count, 60)
    }

    @MainActor
    func testAutomaticRunsWaitForTheDecision() async throws {
        try makeSourceFiles()
        let engine = try await makeEngine(job: job(requiredVolume: "MyDisk", autoSync: true, approved: true))
        engine.volumeMounted("MyDisk")
        let deadline = Date().addingTimeInterval(60)
        while engine.history.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            if let task = engine.currentTask { await task.value }
        }
        XCTAssertEqual(engine.status, .done)

        try deleteInCloud(["B/note.txt"])
        await runSync(engine)
        XCTAssertNotNil(engine.cloudDeletions["archive"])

        // "Decide later": the report stays, the status calms down.
        engine.dismissCloudDeletions(jobID: "archive")
        XCTAssertEqual(engine.status, .idle)
        XCTAssertNotNil(engine.cloudDeletions["archive"])

        // Plugging the disk in again must not start a backup that would put the file back.
        engine.volumeUnmounted("MyDisk")
        engine.volumeMounted("MyDisk")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        if let task = engine.currentTask { await task.value }
        XCTAssertEqual(historyStore.records.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("B/note.txt").path))
        XCTAssertEqual(engine.status, .idle)
    }
}

private extension CloudDeletionReport {
    /// The same report with another detection time (re-detection stamps a new one).
    func withDate(_ date: Date?) -> CloudDeletionReport {
        return CloudDeletionReport(jobID: jobID, detectedAt: date ?? detectedAt, items: items, totalBytes: totalBytes,
                                   extrasCount: extrasCount, looksLikeMassRemoval: looksLikeMassRemoval)
    }
}
