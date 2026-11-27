import XCTest
@testable import KofferCore

final class RcloneCommandTests: XCTestCase {
    private let utc: TimeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
    // 2026-03-04 05:06:07 UTC
    private let date = Date(timeIntervalSince1970: 1_772_600_767)

    private let job = SyncJob(id: "a", name: "Archive", source: "/Volumes/My Disk/Archive Folder",
                              destination: "onedrive:Archive", removedRoot: "onedrive:_Archive_removed")

    func testStamp() {
        XCTAssertEqual(RcloneCommand.stamp(for: date, timeZone: utc), "2026-03-04_0506")
        let berlin = TimeZone(identifier: "Europe/Berlin") ?? utc
        XCTAssertEqual(RcloneCommand.stamp(for: date, timeZone: berlin), "2026-03-04_0606")
    }

    func testSyncArgumentsExact() {
        let args = RcloneCommand.sync(job: job, dryRun: false, date: date, timeZone: utc)
        XCTAssertEqual(args, [
            "sync", "/Volumes/My Disk/Archive Folder", "onedrive:Archive",
            "--track-renames",
            "--backup-dir", "onedrive:_Archive_removed/2026-03-04_0506",
            "--exclude", ".DS_Store", "--exclude", "._*", "--exclude", ".Spotlight-V100/**", "--exclude", ".Trashes/**",
            "--transfers", "4", "--checkers", "16",
            "--use-json-log", "--stats", "2s", "--log-level", "INFO",
        ])
        XCTAssertFalse(args.contains("--delete-before"))
        XCTAssertFalse(args.contains("--dry-run"))
    }

    func testDryRunAddsOnlyDryRun() {
        let real = RcloneCommand.sync(job: job, dryRun: false, date: date, timeZone: utc)
        let dry = RcloneCommand.sync(job: job, dryRun: true, date: date, timeZone: utc)
        XCTAssertEqual(dry, real + ["--dry-run"])
        XCTAssertFalse(dry.contains("--delete-before"))
    }

    // MARK: v0.4: rename strategy

    func testRenameStrategyDecision() {
        XCTAssertEqual(RenameStrategy.forJob(hasCleanRecord: false), .hash)
        XCTAssertEqual(RenameStrategy.forJob(hasCleanRecord: true), .modtimeLeaf)
    }

    func testHashStrategyKeepsTheAgreedCommand() {
        let plain = RcloneCommand.sync(job: job, dryRun: false, date: date, timeZone: utc)
        let hash = RcloneCommand.sync(job: job, dryRun: false, date: date, timeZone: utc, renameStrategy: .hash)
        XCTAssertEqual(hash, plain)
        XCTAssertFalse(hash.contains("--track-renames-strategy"))
    }

    func testModtimeLeafStrategyArgumentsExact() {
        let real = RcloneCommand.sync(job: job, dryRun: false, date: date, timeZone: utc, renameStrategy: .modtimeLeaf)
        XCTAssertEqual(real, [
            "sync", "/Volumes/My Disk/Archive Folder", "onedrive:Archive",
            "--track-renames", "--track-renames-strategy", "modtime,leaf",
            "--backup-dir", "onedrive:_Archive_removed/2026-03-04_0506",
            "--exclude", ".DS_Store", "--exclude", "._*", "--exclude", ".Spotlight-V100/**", "--exclude", ".Trashes/**",
            "--transfers", "4", "--checkers", "16",
            "--use-json-log", "--stats", "2s", "--log-level", "INFO",
        ])
        let dry = RcloneCommand.sync(job: job, dryRun: true, date: date, timeZone: utc, renameStrategy: .modtimeLeaf)
        XCTAssertEqual(dry, real + ["--dry-run"])
        XCTAssertEqual(SafetyRules.assertSafe(arguments: real, removedRoot: job.removedRoot), .ok)
        XCTAssertEqual(SafetyRules.assertSafe(arguments: dry, removedRoot: job.removedRoot), .ok)
    }

    // MARK: v0.4: OneDrive delta listing

    func testListFilesWithAndWithoutOneDriveDelta() {
        let plain = RcloneCommand.listFiles(target: "onedrive:Archive")
        XCTAssertEqual(plain, ["lsjson", "onedrive:Archive", "-R", "--files-only", "--no-mimetype", "--no-modtime",
                               "--exclude", ".DS_Store", "--exclude", "._*", "--exclude", ".Spotlight-V100/**",
                               "--exclude", ".Trashes/**"])
        XCTAssertEqual(RcloneCommand.listFiles(target: "onedrive:Archive", oneDriveDelta: false), plain)
        let delta = RcloneCommand.listFiles(target: "onedrive:Archive", oneDriveDelta: true)
        XCTAssertEqual(delta, plain + ["--onedrive-delta"])
        XCTAssertEqual(SafetyRules.assertSafe(arguments: delta, removedRoot: job.removedRoot), .ok)
    }

    func testWantsOneDriveDelta() {
        XCTAssertTrue(RcloneCommand.wantsOneDriveDelta(remoteType: "onedrive", backupBytes: nil, driveUsedBytes: nil))
        XCTAssertTrue(RcloneCommand.wantsOneDriveDelta(remoteType: "OneDrive", backupBytes: 900, driveUsedBytes: nil))
        XCTAssertTrue(RcloneCommand.wantsOneDriveDelta(remoteType: "onedrive", backupBytes: nil, driveUsedBytes: 1000))
        XCTAssertTrue(RcloneCommand.wantsOneDriveDelta(remoteType: "onedrive", backupBytes: 860, driveUsedBytes: 1000))
        XCTAssertTrue(RcloneCommand.wantsOneDriveDelta(remoteType: "onedrive", backupBytes: 500, driveUsedBytes: 1000))
        XCTAssertFalse(RcloneCommand.wantsOneDriveDelta(remoteType: "onedrive", backupBytes: 100, driveUsedBytes: 1000),
                       "a small part of a big drive: walking the whole drive costs more")
        XCTAssertFalse(RcloneCommand.wantsOneDriveDelta(remoteType: "drive", backupBytes: nil, driveUsedBytes: nil))
        XCTAssertFalse(RcloneCommand.wantsOneDriveDelta(remoteType: "local", backupBytes: 900, driveUsedBytes: 1000))
        XCTAssertFalse(RcloneCommand.wantsOneDriveDelta(remoteType: nil, backupBytes: nil, driveUsedBytes: nil))
    }

    func testLogFileNames() {
        XCTAssertEqual(SyncEngine.logFileName(jobID: "archive", stamp: "2026-03-04_0506", kind: nil), "archive_2026-03-04_0506.log")
        XCTAssertEqual(SyncEngine.logFileName(jobID: "archive", stamp: "2026-03-04_0506", kind: "preview"),
                       "archive_preview_2026-03-04_0506.log")
        XCTAssertEqual(SyncEngine.logFileName(jobID: "a/b:c", stamp: "x", kind: nil), "a_b_c_x.log")
    }

    func testBackupDirJoining() {
        XCTAssertEqual(RcloneCommand.backupDir(removedRoot: "onedrive:_x/", date: date, timeZone: utc), "onedrive:_x/2026-03-04_0506")
        XCTAssertEqual(RcloneCommand.backupDir(removedRoot: "/tmp/removed", date: date, timeZone: utc), "/tmp/removed/2026-03-04_0506")
        XCTAssertEqual(RcloneCommand.join("remote:", "x"), "remote:x")
    }

    func testOtherCommands() {
        XCTAssertEqual(RcloneCommand.about(remote: "onedrive:"), ["about", "onedrive:", "--json"])
        XCTAssertEqual(RcloneCommand.size(path: "onedrive:_x"), ["size", "onedrive:_x", "--json"])
        XCTAssertEqual(RcloneCommand.purge(path: "onedrive:_x"), ["purge", "onedrive:_x"])
    }

    func testLocatorUsesFirstExecutable() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notExec = dir.appendingPathComponent("plain").path
        let exec = dir.appendingPathComponent("rclone").path
        FileManager.default.createFile(atPath: notExec, contents: Data("x".utf8), attributes: [.posixPermissions: 0o644])
        FileManager.default.createFile(atPath: exec, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(RcloneLocator(candidates: ["/nope/rclone", dir.path, notExec, exec]).locate(), exec)
        XCTAssertNil(RcloneLocator(candidates: ["/nope/rclone"]).locate())
        XCTAssertEqual(RcloneLocator.defaultCandidates, ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone",
                                                         RcloneLocator.installedBinaryPath])
        XCTAssertTrue(RcloneLocator.installedBinaryPath.hasSuffix("/Library/Application Support/Koffer/bin/rclone"))
    }
}
