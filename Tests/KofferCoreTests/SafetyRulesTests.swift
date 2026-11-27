import XCTest
@testable import KofferCore

final class SafetyRulesTests: XCTestCase {
    private let home = "/Users/someone"

    private func job(source: String = "/Volumes/MyDisk/Archive",
                     destination: String = "onedrive:Archive",
                     removedRoot: String = "onedrive:_Archive_removed") -> SyncJob {
        return SyncJob(id: "a", name: "Archive", source: source, destination: destination, removedRoot: removedRoot,
                       requiredVolume: "MyDisk")
    }

    private func check(_ j: SyncJob, _ config: KofferConfig = KofferConfig(jobs: [])) -> SafetyVerdict {
        return SafetyRules.check(job: j, config: config, homeDirectory: home)
    }

    private func assertRefused(_ v: SafetyVerdict, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(v.isOK, "expected a refusal", file: file, line: line)
        XCTAssertFalse((v.reason ?? "").isEmpty, file: file, line: line)
    }

    func testValidJobIsOK() {
        XCTAssertEqual(check(job()), .ok)
        XCTAssertEqual(check(job(source: "/Volumes/MyDisk/Archive/")), .ok)
        XCTAssertEqual(check(job(source: "/Users/someone/Koffer Test")), .ok)
    }

    func testNeverSyncFragmentIsCaseInsensitive() {
        let config = KofferConfig(jobs: [], neverSync: ["camera stuff", "  "])
        assertRefused(check(job(source: "/Volumes/MyDisk/Camera Stuff"), config))
        assertRefused(check(job(source: "/Volumes/MyDisk/Camera Stuff/2024"), config))
        XCTAssertEqual(check(job(source: "/Volumes/MyDisk/Archive"), config), .ok, "blank fragments are ignored")
    }

    func testPrivatePathForbiddenRemote() {
        let rule = PrivatePathRule(pathContains: "private papers", forbiddenRemotes: ["onedrive:"])
        let config = KofferConfig(jobs: [], privatePaths: [rule])
        assertRefused(check(job(source: "/Volumes/MyDisk/Private Papers"), config))
        assertRefused(check(job(source: "/Volumes/MyDisk/Private Papers", destination: "OneDrive:Papers",
                                removedRoot: "OneDrive:_Papers_removed"), config))
        // Same folder to a different remote is fine.
        XCTAssertEqual(check(job(source: "/Volumes/MyDisk/Private Papers", destination: "gdrive:Papers",
                                 removedRoot: "gdrive:_Papers_removed"), config), .ok)
    }

    func testSourceMustBeAbsolute() {
        assertRefused(check(job(source: "Archive")))
        assertRefused(check(job(source: "~/Archive")))
        assertRefused(check(job(source: "")))
    }

    func testRootVolumeAndHomeAreRefused() {
        assertRefused(check(job(source: "/")))
        assertRefused(check(job(source: "/Volumes")))
        assertRefused(check(job(source: "/Volumes/MyDisk")))
        assertRefused(check(job(source: "/Volumes/MyDisk/")))
        assertRefused(check(job(source: "/Volumes/MyDisk/Archive/..")))
        assertRefused(check(job(source: "/Users/someone")))
        assertRefused(check(job(source: "/Users/someone/")))
        assertRefused(check(job(source: "/Users")))
    }

    func testEmptyDestinationOrRemovedRoot() {
        assertRefused(check(job(destination: "")))
        assertRefused(check(job(removedRoot: "")))
        assertRefused(check(job(destination: "   ")))
    }

    func testDestinationMustHaveAPath() {
        assertRefused(check(job(destination: "onedrive:")))
        assertRefused(check(job(destination: "onedrive:/")))
        assertRefused(check(job(destination: "Archive")))
    }

    func testRemovedRootAndDestinationMustNotOverlap() {
        assertRefused(check(job(destination: "onedrive:Archive", removedRoot: "onedrive:Archive")))
        assertRefused(check(job(destination: "onedrive:Archive", removedRoot: "onedrive:Archive/_removed")))
        assertRefused(check(job(destination: "onedrive:Archive/Current", removedRoot: "onedrive:Archive")))
        assertRefused(check(job(destination: "onedrive:Archive", removedRoot: "onedrive:archive/")))
        assertRefused(check(job(destination: "onedrive:Archive", removedRoot: "onedrive:")))
        // A sibling whose name merely starts the same is fine.
        XCTAssertEqual(check(job(destination: "onedrive:Archive", removedRoot: "onedrive:Archive_removed")), .ok)
        // Different remotes never overlap.
        XCTAssertEqual(check(job(destination: "onedrive:Archive", removedRoot: "other:Archive")), .ok)
    }

    func testLocalDestinations() {
        XCTAssertEqual(check(job(source: "/tmp/x/src", destination: "/tmp/x/dst", removedRoot: "/tmp/x/removed")), .ok)
        assertRefused(check(job(source: "/tmp/x/src", destination: "/tmp/x/dst", removedRoot: "/tmp/x/dst/old")))
        assertRefused(check(job(source: "/tmp/x/src", destination: "/tmp/x/src/copy", removedRoot: "/tmp/x/removed")))
        assertRefused(check(job(source: "/tmp/x/src", destination: "/", removedRoot: "/tmp/x/removed")))
    }

    // MARK: assertSafe

    func testAssertSafeAcceptsBuiltCommands() {
        let j = job()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(SafetyRules.assertSafe(arguments: RcloneCommand.sync(job: j, dryRun: false, date: date), removedRoot: j.removedRoot), .ok)
        XCTAssertEqual(SafetyRules.assertSafe(arguments: RcloneCommand.sync(job: j, dryRun: true, date: date), removedRoot: j.removedRoot), .ok)
        XCTAssertEqual(SafetyRules.assertSafe(arguments: RcloneCommand.about(remote: "onedrive:"), removedRoot: j.removedRoot), .ok)
        XCTAssertEqual(SafetyRules.assertSafe(arguments: RcloneCommand.size(path: j.removedRoot), removedRoot: j.removedRoot), .ok)
        XCTAssertEqual(SafetyRules.assertSafe(arguments: RcloneCommand.purge(path: j.removedRoot), removedRoot: j.removedRoot), .ok)
        XCTAssertEqual(SafetyRules.assertSafe(arguments: ["purge", "onedrive:_Archive_removed/2026-01-01_1200"], removedRoot: j.removedRoot), .ok)
    }

    func testAssertSafeRejectsDangerousFlags() {
        let j = job()
        var args = RcloneCommand.sync(job: j, dryRun: false)
        args.append("--delete-before")
        assertRefused(SafetyRules.assertSafe(arguments: args, removedRoot: j.removedRoot))
        var args2 = RcloneCommand.sync(job: j, dryRun: false)
        args2.append("--delete-excluded")
        assertRefused(SafetyRules.assertSafe(arguments: args2, removedRoot: j.removedRoot))
        var args3 = RcloneCommand.sync(job: j, dryRun: false)
        args3.append("--DELETE-BEFORE=true")
        assertRefused(SafetyRules.assertSafe(arguments: args3, removedRoot: j.removedRoot))
    }

    func testAssertSafeRenameStrategy() {
        let j = job()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let fast = RcloneCommand.sync(job: j, dryRun: false, date: date, renameStrategy: .modtimeLeaf)
        XCTAssertEqual(SafetyRules.assertSafe(arguments: fast, removedRoot: j.removedRoot), .ok)
        XCTAssertEqual(SafetyRules.assertSafe(arguments: RcloneCommand.sync(job: j, dryRun: true, date: date, renameStrategy: .modtimeLeaf),
                                              removedRoot: j.removedRoot), .ok)
        XCTAssertEqual(SafetyRules.assertSafe(arguments: fast + ["--track-renames-strategy=hash"], removedRoot: j.removedRoot), .ok)
        // Still needs the removed-items folder.
        var noBackup: [String] = fast
        if let i = noBackup.firstIndex(of: "--backup-dir") { noBackup.removeSubrange(i...(i + 1)) }
        assertRefused(SafetyRules.assertSafe(arguments: noBackup, removedRoot: j.removedRoot))
        // Unknown strategies, a missing value, or a strategy without --track-renames.
        assertRefused(SafetyRules.assertSafe(arguments: fast + ["--track-renames-strategy", "size"], removedRoot: j.removedRoot))
        assertRefused(SafetyRules.assertSafe(arguments: fast + ["--track-renames-strategy=modtime,,leaf"], removedRoot: j.removedRoot))
        assertRefused(SafetyRules.assertSafe(arguments: fast + ["--track-renames-strategy"], removedRoot: j.removedRoot))
        let withoutTracking: [String] = fast.filter { $0 != "--track-renames" }
        assertRefused(SafetyRules.assertSafe(arguments: withoutTracking, removedRoot: j.removedRoot))
    }

    func testOneDriveDeltaOnlyOnListings() {
        let j = job()
        let root = j.removedRoot
        XCTAssertEqual(SafetyRules.assertSafe(arguments: RcloneCommand.listFiles(target: j.destination, oneDriveDelta: true),
                                              removedRoot: root), .ok)
        var sync = RcloneCommand.sync(job: j, dryRun: true, date: Date(timeIntervalSince1970: 1_700_000_000))
        sync.append("--onedrive-delta")
        assertRefused(SafetyRules.assertSafe(arguments: sync, removedRoot: root))
        assertRefused(SafetyRules.assertSafe(arguments: ["size", root, "--json", "--onedrive-delta"], removedRoot: root))
        assertRefused(SafetyRules.assertSafe(arguments: ["purge", root, "--ONEDRIVE-DELTA=true"], removedRoot: root))
        assertRefused(SafetyRules.assertSafe(arguments: ["about", "onedrive:", "--onedrive-delta"], removedRoot: root))
    }

    func testAssertSafeRejectsPurgeOutsideRemovedRoot() {
        let root = "onedrive:_Archive_removed"
        assertRefused(SafetyRules.assertSafe(arguments: ["purge", "onedrive:Archive"], removedRoot: root))
        assertRefused(SafetyRules.assertSafe(arguments: ["purge", "onedrive:"], removedRoot: root))
        assertRefused(SafetyRules.assertSafe(arguments: ["purge", "onedrive:_Archive_removed_more"], removedRoot: root))
        assertRefused(SafetyRules.assertSafe(arguments: ["purge"], removedRoot: root))
        assertRefused(SafetyRules.assertSafe(arguments: ["purge", "onedrive:"], removedRoot: "onedrive:"))
    }

    func testAssertSafeRejectsOtherVerbsAndMissingBackupDir() {
        let root = "onedrive:_Archive_removed"
        assertRefused(SafetyRules.assertSafe(arguments: ["delete", "onedrive:Archive"], removedRoot: root))
        assertRefused(SafetyRules.assertSafe(arguments: ["deletefile", "onedrive:Archive/a"], removedRoot: root))
        assertRefused(SafetyRules.assertSafe(arguments: [], removedRoot: root))
        assertRefused(SafetyRules.assertSafe(arguments: ["sync", "/Volumes/MyDisk/Archive", "onedrive:Archive"], removedRoot: root))
        assertRefused(SafetyRules.assertSafe(arguments: ["sync", "/a/b", "onedrive:Archive", "--backup-dir", "onedrive:Elsewhere"], removedRoot: root))
    }

    func testDotPartsAreRefused() {
        // rclone resolves "..", so this removed-items folder would really be the parent of the backup.
        XCTAssertNil(RcloneLocation.parse("onedrive:Backup/_removed/.."))
        XCTAssertNil(RcloneLocation.parse("onedrive:./Archive"))
        XCTAssertEqual(RcloneLocation.parse("onedrive:Backup//Archive/"), RcloneLocation(remote: "onedrive:", path: "Backup/Archive"))
        XCTAssertEqual(RcloneLocation.parse("onedrive:Archive..old"), RcloneLocation(remote: "onedrive:", path: "Archive..old"))
        assertRefused(check(job(destination: "onedrive:Backup/Archive", removedRoot: "onedrive:Backup/_removed/..")))
        assertRefused(check(job(destination: "onedrive:Backup/x/../Archive", removedRoot: "onedrive:Backup/_removed")))
        assertRefused(SafetyRules.assertSafe(arguments: ["purge", "onedrive:Backup/_removed/.."],
                                             removedRoot: "onedrive:Backup/_removed/.."))
    }

    func testForbiddenRemoteMatchesWithOrWithoutColon() {
        let rule = PrivatePathRule(pathContains: "Private Papers", forbiddenRemotes: ["OneDrive"])
        let config = KofferConfig(jobs: [], privatePaths: [rule])
        assertRefused(check(job(source: "/Volumes/MyDisk/Private Papers"), config))
    }

    func testDryRunItemsInsideProtectedFolderAreRefused() {
        let rule = PrivatePathRule(pathContains: "private papers", forbiddenRemotes: ["onedrive:"])
        let config = KofferConfig(jobs: [], neverSync: ["camera stuff"], privatePaths: [rule])
        let parent = job(source: "/Volumes/MyDisk/Stuff")
        XCTAssertEqual(check(parent, config), .ok, "the parent itself is not protected")
        let fine: [ChangeItem] = [ChangeItem(kind: .new, path: "A/photo.jpg"),
                                  ChangeItem(kind: .removed, path: "Private Papers/old.pdf")]
        XCTAssertEqual(SafetyRules.checkItems(fine, job: parent, config: config), .ok, "removals send nothing")
        assertRefused(SafetyRules.checkItems([ChangeItem(kind: .new, path: "Private Papers/tax.pdf")], job: parent, config: config))
        assertRefused(SafetyRules.checkItems([ChangeItem(kind: .replaced, path: "x/Camera Stuff/a.jpg")], job: parent, config: config))
        assertRefused(SafetyRules.checkItems([ChangeItem(kind: .moved, path: "a.pdf", newPath: "Private Papers/a.pdf")],
                                             job: parent, config: config))
        // Private folders may still go to a remote that is not forbidden.
        let other = job(source: "/Volumes/MyDisk/Stuff", destination: "gdrive:Stuff", removedRoot: "gdrive:_Stuff_removed")
        XCTAssertEqual(SafetyRules.checkItems([ChangeItem(kind: .new, path: "Private Papers/tax.pdf")], job: other,
                                              config: KofferConfig(jobs: [], privatePaths: [rule])), .ok)
    }

    func testSymlinkedSourceIsCheckedWhereItPoints() throws {
        let dir = try makeTempDirectory("koffer-safety")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("Private Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: nil)
        let link = dir.appendingPathComponent("innocent").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target.path)
        let rule = PrivatePathRule(pathContains: "private papers", forbiddenRemotes: ["onedrive:"])
        let config = KofferConfig(jobs: [], privatePaths: [rule])
        assertRefused(check(job(source: link), config))
    }

    func testMassRemovalHeuristic() {
        XCTAssertFalse(SyncEngine.looksLikeMassRemoval(removed: 0, checked: 0))
        XCTAssertFalse(SyncEngine.looksLikeMassRemoval(removed: 3, checked: 3), "tiny folders are left alone")
        XCTAssertFalse(SyncEngine.looksLikeMassRemoval(removed: 30, checked: 10_000))
        XCTAssertTrue(SyncEngine.looksLikeMassRemoval(removed: 30, checked: 40))
        XCTAssertTrue(SyncEngine.looksLikeMassRemoval(removed: 500, checked: 1_000_000))
    }

    func testLocationParsing() {
        XCTAssertEqual(RcloneLocation.parse("onedrive:Archive/"), RcloneLocation(remote: "onedrive:", path: "Archive"))
        XCTAssertEqual(RcloneLocation.parse("/tmp/a/"), RcloneLocation(remote: "", path: "/tmp/a"))
        XCTAssertNil(RcloneLocation.parse("relative/path"))
        XCTAssertNil(RcloneLocation.parse(":nope"))
        XCTAssertNil(RcloneLocation.parse(""))
    }
}
