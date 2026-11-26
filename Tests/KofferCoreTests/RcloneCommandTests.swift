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
