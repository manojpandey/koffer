import XCTest
@testable import KofferCore

/// v0.3 "deleted in the cloud": candidate computation, thresholds, the manifest file, and the guard in front of
/// every deletion on the local disk. Pure (temp folders only, no rclone).
final class CloudDeletionsTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!

    override func setUpWithError() throws {
        base = try makeTempDirectory("koffer-cloud")
    }

    override func tearDownWithError() throws {
        if let b = base { try? fm.removeItem(at: b) }
    }

    private func entry(_ path: String, _ size: Int64) -> CloudManifest.Entry {
        return CloudManifest.Entry(path: path, size: size)
    }

    // MARK: - Candidates

    func testCandidatesNeedSameSizeAndNoNewerDate() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let manifest = CloudManifest(destination: "onedrive:Archive", date: date, files: [
            entry("A/same.jpg", 10),        // gone in the cloud, unchanged here -> candidate
            entry("A/bigger.jpg", 20),      // gone, but the local file has another size -> not
            entry("A/newer.jpg", 30),       // gone, but changed here after the backup -> not
            entry("A/missing.jpg", 40),     // gone here too -> not
            entry("A/exact-date.jpg", 50),  // modified exactly at the manifest date -> candidate
            entry("B/kept.txt", 5),         // still in the cloud -> not
            entry("B/unknown-size.bin", -1) // the service doesn't know the size -> never a candidate
        ])
        let cloud: [CloudManifest.Entry] = [
            entry("B/kept.txt", 5),
            entry("C/added-in-cloud.txt", 7),   // not in the manifest, not here -> extra
            entry("C/renamed.jpg", 10),         // not in the manifest, not here -> extra
            entry("D/new-here-too.txt", 3)      // not in the manifest, but here -> not an extra
        ]
        let local: [String: LocalFileInfo] = [
            "A/same.jpg": LocalFileInfo(size: 10, modified: date.addingTimeInterval(-60)),
            "A/bigger.jpg": LocalFileInfo(size: 21, modified: date.addingTimeInterval(-60)),
            "A/newer.jpg": LocalFileInfo(size: 30, modified: date.addingTimeInterval(1)),
            "A/exact-date.jpg": LocalFileInfo(size: 50, modified: date),
            "B/kept.txt": LocalFileInfo(size: 5, modified: date.addingTimeInterval(-60)),
            "B/unknown-size.bin": LocalFileInfo(size: 0, modified: date.addingTimeInterval(-60)),
            "D/new-here-too.txt": LocalFileInfo(size: 3, modified: date.addingTimeInterval(-60))
        ]
        let detection = CloudDeletions.detect(manifest: manifest, cloud: cloud) { (path: String) -> LocalFileInfo? in
            return local[path]
        }
        XCTAssertEqual(detection.candidates.map { $0.path }, ["A/exact-date.jpg", "A/same.jpg"])
        XCTAssertTrue(detection.candidates.allSatisfy { $0.kind == .removed })
        XCTAssertEqual(detection.candidates.map { $0.size ?? -1 }, [50, 10])
        XCTAssertEqual(detection.totalBytes, 60)
        XCTAssertEqual(detection.extrasCount, 2)
        XCTAssertEqual(detection.modified["A/same.jpg"], date.addingTimeInterval(-60))
        XCTAssertNil(detection.modified["A/newer.jpg"])
    }

    func testNothingDeletedMeansNoCandidates() {
        let date = Date()
        let files: [CloudManifest.Entry] = [entry("a", 1), entry("b", 2)]
        let manifest = CloudManifest(destination: "/x", date: date, files: files)
        let detection = CloudDeletions.detect(manifest: manifest, cloud: files) { (_: String) -> LocalFileInfo? in
            return LocalFileInfo(size: 1, modified: date.addingTimeInterval(-5))
        }
        XCTAssertTrue(detection.candidates.isEmpty)
        XCTAssertEqual(detection.extrasCount, 0)
    }

    func testMassRemovalThresholds() {
        XCTAssertTrue(CloudDeletions.looksLikeMassRemoval(candidates: 500, manifestCount: 1_000_000))
        XCTAssertFalse(CloudDeletions.looksLikeMassRemoval(candidates: 499, manifestCount: 1_000_000))
        XCTAssertTrue(CloudDeletions.looksLikeMassRemoval(candidates: 50, manifestCount: 200))   // exactly 25 %
        XCTAssertFalse(CloudDeletions.looksLikeMassRemoval(candidates: 50, manifestCount: 201))
        XCTAssertFalse(CloudDeletions.looksLikeMassRemoval(candidates: 49, manifestCount: 49))   // all, but few
        XCTAssertTrue(CloudDeletions.looksLikeMassRemoval(candidates: 60, manifestCount: 60))
        XCTAssertFalse(CloudDeletions.looksLikeMassRemoval(candidates: 2, manifestCount: 6))
    }

    func testParseListing() throws {
        let json = """
        [
        {"Path":"B c.txt","Name":"B c.txt","Size":6,"ModTime":"","IsDir":false},
        {"Path":"A/sub","Name":"sub","Size":-1,"ModTime":"","IsDir":true},
        {"Path":"A/sub/a.txt","Name":"a.txt","Size":3,"ModTime":"","IsDir":false},
        {"Path":"G/doc","Name":"doc","Size":-1,"ModTime":"","IsDir":false}
        ]
        """
        let entries = try XCTUnwrap(CloudDeletions.parseListing(json))
        XCTAssertEqual(entries, [entry("B c.txt", 6), entry("A/sub/a.txt", 3), entry("G/doc", -1)])
        XCTAssertEqual(CloudDeletions.parseListing("[\n]\n")?.count, 0)
        XCTAssertNil(CloudDeletions.parseListing("not json"))
    }

    // MARK: - Manifest file

    func testManifestRoundTripAndDestinationMismatchIsIgnored() throws {
        let store = ManifestStore(directory: base.appendingPathComponent("manifests", isDirectory: true))
        let date = Date(timeIntervalSince1970: 1_800_000_123.456)
        let manifest = CloudManifest(destination: "onedrive:Backups/Archive", date: date,
                                     files: [entry("A/one.jpg", 12), entry("B/two.txt", 3)])
        try store.save(manifest, jobID: "archive")
        XCTAssertTrue(fm.fileExists(atPath: base.appendingPathComponent("manifests/archive.json").path))

        let loaded = try XCTUnwrap(store.load(jobID: "archive", destination: "onedrive:Backups/Archive"))
        XCTAssertEqual(loaded.files, manifest.files)
        XCTAssertEqual(loaded.destination, manifest.destination)
        XCTAssertEqual(loaded.date.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.000_01,
                       "fractions of a second survive, so fresh files don't look newer than the backup")
        XCTAssertNotNil(store.load(jobID: "archive", destination: "onedrive:Backups/Archive/"), "same place")

        // The job now points somewhere else: the old manifest says nothing about the new place.
        XCTAssertNil(store.load(jobID: "archive", destination: "onedrive:Backups/Other"))
        XCTAssertNil(store.load(jobID: "archive", destination: "/Volumes/MyDisk/Backup"))
        XCTAssertNil(store.load(jobID: "other", destination: "onedrive:Backups/Archive"))

        store.remove(jobID: "archive")
        XCTAssertNil(store.load(jobID: "archive", destination: "onedrive:Backups/Archive"))
    }

    func testUnreadableManifestIsIgnored() throws {
        let dir = base.appendingPathComponent("manifests", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        try Data("{ half a file".utf8).write(to: dir.appendingPathComponent("archive.json"))
        XCTAssertNil(ManifestStore(directory: dir).load(jobID: "archive", destination: "onedrive:Archive"))
    }

    func testListFilesCommandIsReadOnlyAndExcludesLikeTheSync() {
        let args = RcloneCommand.listFiles(target: "onedrive:Backups/Archive")
        XCTAssertEqual(Array(args.prefix(6)), ["lsjson", "onedrive:Backups/Archive", "-R", "--files-only", "--no-mimetype", "--no-modtime"])
        for pattern in RcloneCommand.excludes {
            XCTAssertTrue(args.contains(pattern), pattern)
        }
        XCTAssertEqual(SafetyRules.assertSafe(arguments: args, removedRoot: "onedrive:Backups/_Archive_removed"), .ok)
    }

    func testDefaultManifestDirectorySitsNextToTheSettings() {
        let env = EngineEnvironment(configURL: URL(fileURLWithPath: "/tmp/somewhere/Koffer/config.json"),
                                    logDirectory: URL(fileURLWithPath: "/tmp/somewhere/logs"))
        XCTAssertEqual(env.manifestDirectory.path, "/tmp/somewhere/Koffer/manifests")
    }

    func testNotifierDefaultIsANoOp() {
        let notifier: Notifying = MinimalNotifier()
        notifier.cloudDeletionsFound(job: SyncJob(id: "a", name: "A", source: "/a/b", destination: "x:y", removedRoot: "x:z"), count: 3)
    }

    func testPreviewResultInitStaysSourceCompatible() {
        let p = PreviewResult(jobID: "a", date: Date(), items: [])
        XCTAssertTrue(p.cloudDeleted.isEmpty)
    }

    // MARK: - The guard in front of every deletion

    /// src/A/file.txt, src/Dir/, src/Link -> outside/, src/filelink.txt -> outside/secret.txt, outside/secret.txt
    private func makeTree() throws -> (src: URL, outside: URL) {
        let src = base.appendingPathComponent("src", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: src.appendingPathComponent("A"), withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: src.appendingPathComponent("Dir"), withIntermediateDirectories: true, attributes: nil)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true, attributes: nil)
        try Data("inside".utf8).write(to: src.appendingPathComponent("A/file.txt"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: src.appendingPathComponent("Link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: src.appendingPathComponent("filelink.txt"),
                                  withDestinationURL: outside.appendingPathComponent("secret.txt"))
        return (src, outside)
    }

    private func assertRefused(_ result: Result<URL, EngineError>, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        if case .success(let url) = result {
            XCTFail("\(message): expected a refusal, got \(url.path)", file: file, line: line)
        }
    }

    func testGuardAllowsAPlainFileInsideTheSource() throws {
        let tree = try makeTree()
        let result = SafetyRules.localFileInside(source: tree.src.path, relativePath: "A/file.txt")
        guard case .success(let url) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertTrue(url.path.hasSuffix("/src/A/file.txt"), url.path)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "inside")

        // A source given through a link is fine (rclone follows it too); the file is the same.
        let viaLink = base.appendingPathComponent("srclink")
        try fm.createSymbolicLink(at: viaLink, withDestinationURL: tree.src)
        guard case .success(let url2) = SafetyRules.localFileInside(source: viaLink.path, relativePath: "A/file.txt") else {
            return XCTFail("expected success through a linked source")
        }
        XCTAssertEqual(try String(contentsOf: url2, encoding: .utf8), "inside")
    }

    func testGuardRefusesDotDot() throws {
        let tree = try makeTree()
        assertRefused(SafetyRules.localFileInside(source: tree.src.path, relativePath: "../outside/secret.txt"), "..")
        assertRefused(SafetyRules.localFileInside(source: tree.src.path, relativePath: "A/../../outside/secret.txt"), "A/../..")
        assertRefused(SafetyRules.localFileInside(source: tree.src.path, relativePath: "A/./file.txt"), ".")
        assertRefused(SafetyRules.localFileInside(source: tree.src.path, relativePath: ".."), "bare ..")
        XCTAssertTrue(fm.fileExists(atPath: tree.outside.appendingPathComponent("secret.txt").path))
    }

    func testGuardRefusesLinksThatEscape() throws {
        let tree = try makeTree()
        assertRefused(SafetyRules.localFileInside(source: tree.src.path, relativePath: "Link/secret.txt"), "folder link")
        assertRefused(SafetyRules.localFileInside(source: tree.src.path, relativePath: "filelink.txt"), "file link")
        assertRefused(SafetyRules.localFileInside(source: tree.src.path, relativePath: "Link"), "the link itself")
    }

    func testGuardRefusesAbsolutePathsAndOddTargets() throws {
        let tree = try makeTree()
        let secret: String = tree.outside.appendingPathComponent("secret.txt").path
        assertRefused(SafetyRules.localFileInside(source: tree.src.path, relativePath: secret), "absolute path outside")
        assertRefused(SafetyRules.localFileInside(source: tree.src.path, relativePath: "/etc/hosts"), "absolute system path")
        assertRefused(SafetyRules.localFileInside(source: tree.src.path, relativePath: ""), "empty")
        assertRefused(SafetyRules.localFileInside(source: tree.src.path, relativePath: "Dir"), "a folder")
        assertRefused(SafetyRules.localFileInside(source: tree.src.path, relativePath: "A/missing.txt"), "missing")
        assertRefused(SafetyRules.localFileInside(source: "/", relativePath: "etc/hosts"), "source is /")
        assertRefused(SafetyRules.localFileInside(source: "relative/src", relativePath: "A/file.txt"), "relative source")
    }

    func testLocalInfoOnlyForPlainFiles() throws {
        let tree = try makeTree()
        let info = try XCTUnwrap(CloudDeletions.localInfo(relativePath: "A/file.txt", source: tree.src.path))
        XCTAssertEqual(info.size, Int64("inside".utf8.count))
        XCTAssertNil(CloudDeletions.localInfo(relativePath: "filelink.txt", source: tree.src.path))
        XCTAssertNil(CloudDeletions.localInfo(relativePath: "Link/secret.txt", source: tree.src.path))
        XCTAssertNil(CloudDeletions.localInfo(relativePath: "Dir", source: tree.src.path))
        XCTAssertNil(CloudDeletions.localInfo(relativePath: "nope.txt", source: tree.src.path))
    }

    func testMissingDestinationMeansEmptyOnlyWhenItsParentIsThere() throws {
        XCTAssertTrue(SyncEngine.missingDestinationMeansEmpty("onedrive:Backups/Archive"))
        XCTAssertTrue(SyncEngine.missingDestinationMeansEmpty(base.appendingPathComponent("gone").path))
        XCTAssertFalse(SyncEngine.missingDestinationMeansEmpty("/Volumes/NotPluggedIn-\(UUID().uuidString)/Backup"))
        XCTAssertFalse(SyncEngine.missingDestinationMeansEmpty("not a location"))
    }
}
