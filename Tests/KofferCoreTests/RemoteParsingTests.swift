import XCTest
@testable import KofferCore

/// Pure tests for the v0.2 helpers: rclone output parsing, plain words, command building and safety.
final class RemoteParsingTests: XCTestCase {
    private func assertRefused(_ v: SafetyVerdict, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(v.isOK, "expected a refusal", file: file, line: line)
        XCTAssertFalse((v.reason ?? "").isEmpty, file: file, line: line)
    }

    // MARK: listremotes

    func testParseListRemotes() {
        XCTAssertEqual(RemoteParsing.parseListRemotes("onedrive:\nMy Disk:\n\nnot a remote\n"), ["onedrive:", "My Disk:"])
        XCTAssertEqual(RemoteParsing.parseListRemotes("onedrive:\r\nArchive:\r\n"), ["onedrive:", "Archive:"])
        XCTAssertEqual(RemoteParsing.parseListRemotes(""), [])
        XCTAssertEqual(RemoteParsing.parseListRemotes("onedrive:\nonedrive:\n"), ["onedrive:"], "no duplicates")
        XCTAssertEqual(RemoteParsing.parseListRemotes(":\n"), [])
    }

    func testParseListRemotesLong() {
        // Real rclone v1.71 output pads the type column.
        let text = "MyCloud: onedrive \nDisk:    local    \nPhotos Box: drive\n"
        XCTAssertEqual(RemoteParsing.parseListRemotesLong(text),
                       ["MyCloud:": "onedrive", "Disk:": "local", "Photos Box:": "drive"])
        XCTAssertEqual(RemoteParsing.parseListRemotesLong(""), [:])
    }

    // MARK: about

    func testParseAbout() {
        let full = RemoteParsing.parseAbout(#"{"total":1000,"used":400,"free":600,"trashed":0}"#)
        XCTAssertNotNil(full)
        XCTAssertEqual(full?.used, 400)
        XCTAssertEqual(full?.total, 1000)
        XCTAssertEqual(full?.free, 600)
        // Real output is pretty-printed with tabs.
        let pretty = RemoteParsing.parseAbout("{\n\t\"total\": 270553174016,\n\t\"used\": 13099053056,\n\t\"free\": 32047714304\n}\n")
        XCTAssertEqual(pretty?.total, 270_553_174_016)
        XCTAssertEqual(pretty?.free, 32_047_714_304)
        let partial = RemoteParsing.parseAbout(#"{"used":5}"#)
        XCTAssertEqual(partial?.used, 5)
        XCTAssertNotNil(partial)
        XCTAssertNil(partial?.total)
        XCTAssertNil(partial?.free)
        XCTAssertNil(RemoteParsing.parseAbout("garbage"))
    }

    func testRemoteStateFromAbout() {
        let ok = RemoteParsing.remoteState(remote: "onedrive:", status: 0, stdout: #"{"total":10,"used":4,"free":6}"#, stderr: "")
        XCTAssertEqual(ok.state, .connected(used: 4, total: 10, free: 6))
        XCTAssertFalse(ok.isAuthProblem)

        let noAbout = RemoteParsing.remoteState(remote: "Mem:", status: 1, stdout: "",
                                                stderr: "2026/01/02 10:00:00 NOTICE: Failed to about: Memory root '' doesn't support about\n")
        XCTAssertEqual(noAbout.state, .connected(used: nil, total: nil, free: nil), "the connection works, it just can't report space")

        let auth = RemoteParsing.remoteState(remote: "onedrive:", status: 1, stdout: "",
                                             stderr: "2026/01/02 10:00:00 CRITICAL: Failed to create file system for \"onedrive:\": failed to get root: couldn't fetch token: invalid_grant: maybe token expired?\n")
        XCTAssertEqual(auth.state, .failed("OneDrive needs you to sign in again"))
        XCTAssertTrue(auth.isAuthProblem)
        let otherAuth = RemoteParsing.remoteState(remote: "Photos Box:", status: 1, stdout: "", stderr: "token expired")
        XCTAssertEqual(otherAuth.state, .failed("Photos Box needs you to sign in again"))

        let offline = RemoteParsing.remoteState(remote: "onedrive:", status: 1, stdout: "",
                                                stderr: "ERROR : dial tcp: lookup graph.example: no such host\n")
        guard case .failed(let offlineText) = offline.state else { return XCTFail("expected failed") }
        XCTAssertTrue(offlineText.contains("internet"), offlineText)
        XCTAssertFalse(offline.isAuthProblem)

        let other = RemoteParsing.remoteState(remote: "Locked:", status: 1, stdout: "",
                                              stderr: "2026/01/02 10:00:00 CRITICAL: Failed to create file system for \"Locked:\": password not set in config file\n")
        guard case .failed(let otherText) = other.state else { return XCTFail("expected failed") }
        XCTAssertTrue(otherText.hasPrefix("Couldn't check Locked"), otherText)
        XCTAssertTrue(otherText.contains("password not set in config file"), otherText)
        XCTAssertFalse(otherText.contains("CRITICAL"), otherText)
        XCTAssertFalse(otherText.contains("2026/01/02"), otherText)

        let gone = RemoteParsing.remoteState(remote: "Old:", status: 1, stdout: "",
                                             stderr: "CRITICAL: Failed to create file system for \"Old:\": didn't find section in config file (\"Old\")")
        guard case .failed(let goneText) = gone.state else { return XCTFail("expected failed") }
        XCTAssertTrue(goneText.contains("Old"), goneText)
    }

    // MARK: lsjson

    func testParseFolderNames() {
        // Real rclone v1.71 output of `lsjson --dirs-only --no-mimetype --no-modtime`.
        let json = """
        [
        {"Path":"Beta","Name":"Beta","Size":4096,"ModTime":"","IsDir":true},
        {"Path":"Gamma","Name":"Gamma","Size":4096,"ModTime":"","IsDir":true},
        {"Path":"New Folder","Name":"New Folder","Size":4096,"ModTime":"","IsDir":true},
        {"Path":"alpha","Name":"alpha","Size":4096,"ModTime":"","IsDir":true}
        ]
        """
        XCTAssertEqual(RemoteParsing.parseFolderNames(json), ["alpha", "Beta", "Gamma", "New Folder"])
        XCTAssertEqual(RemoteParsing.parseFolderNames("[\n]\n"), [])
        XCTAssertEqual(RemoteParsing.parseFolderNames(#"[{"Name":"a.txt","IsDir":false},{"Name":"Archive","IsDir":true},{"Name":"archive"}]"#),
                       ["Archive", "archive"])
        XCTAssertNil(RemoteParsing.parseFolderNames("garbage"))
        XCTAssertNil(RemoteParsing.parseFolderNames(#"{"Name":"x"}"#))
    }

    func testFolderErrors() {
        let missing = RemoteParsing.folderError(remote: "onedrive:", status: 3,
                                                stderr: "ERROR : error listing: directory not found\n", action: "open that folder")
        XCTAssertEqual(missing.error, EngineError("That folder isn't there any more."))
        let auth = RemoteParsing.folderError(remote: "onedrive:", status: 1, stderr: "couldn't fetch token", action: "open that folder")
        XCTAssertTrue(auth.isAuthProblem)
        XCTAssertEqual(auth.error.message, "OneDrive needs you to sign in again")
        let other = RemoteParsing.folderError(remote: "onedrive:", status: 1,
                                              stderr: "2026/01/02 10:00:00 ERROR : Attempt 1/3 failed with 1 errors and: name is too long\n",
                                              action: "create the folder")
        XCTAssertTrue(other.error.message.hasPrefix("Couldn't create the folder: "), other.error.message)
        XCTAssertTrue(other.error.message.contains("name is too long"), other.error.message)
    }

    // MARK: error lines

    func testLastErrorLineOfAFailedReconnect() {
        // Real rclone v1.71 output when another sign-in is still waiting.
        let stderr = """
        2026/11/26 22:28:37 NOTICE: Make sure your Redirect URL is set to "http://localhost:53682/" in your custom config.
        Error: config failed to refresh token: failed to start auth webserver: listen tcp 127.0.0.1:53682: bind: address already in use
        Usage:
          rclone config reconnect remote: [flags]

        Flags:
          -h, --help   help for reconnect

        Use "rclone [command] --help" for more information about a command.
        Use "rclone help flags" for to see the global flags.
        Use "rclone help backends" for a list of supported services.

        2026/11/26 22:28:37 NOTICE: Fatal error: config failed to refresh token: failed to start auth webserver: listen tcp 127.0.0.1:53682: bind: address already in use
        """
        XCTAssertEqual(RemoteParsing.lastErrorLine(stderr),
                       "config failed to refresh token: failed to start auth webserver: listen tcp 127.0.0.1:53682: bind: address already in use")
        let message = RemoteParsing.reconnectFailure(remote: "onedrive:", status: 2, stderr: stderr)
        XCTAssertTrue(message.hasPrefix("Another sign-in is still waiting"), message)
        XCTAssertTrue(message.contains("rclone said: config failed to refresh token"), message)

        let local = "Error: backend doesn't support reconnect or authorize\nUsage:\n  rclone config reconnect remote: [flags]\n"
        XCTAssertEqual(RemoteParsing.lastErrorLine(local), "backend doesn't support reconnect or authorize")
        XCTAssertTrue(RemoteParsing.reconnectFailure(remote: "Disk:", status: 2, stderr: local).contains("Disk doesn't use a sign-in"))

        XCTAssertNil(RemoteParsing.lastErrorLine(""))
        XCTAssertEqual(RemoteParsing.lastErrorLine("2026/01/02 10:00:00 NOTICE: Failed to about: x doesn't support about"),
                       "Failed to about: x doesn't support about")
        XCTAssertTrue(RemoteParsing.reconnectFailure(remote: "onedrive:", status: 1, stderr: "").contains("code 1"))
    }

    func testRedactedConfigDriveID() {
        let redacted = "[MyCloud]\ntype = onedrive\ndrive_id = XXX\ndrive_type = personal\ntoken = XXX\n### Double check the config for sensitive info before posting publicly\n"
        XCTAssertTrue(RemoteParsing.redactedConfigHasDriveID(redacted))
        XCTAssertFalse(RemoteParsing.redactedConfigHasDriveID("[MyCloud]\ntype = onedrive\ndrive_type = personal\n"))
        XCTAssertFalse(RemoteParsing.redactedConfigHasDriveID("[MyCloud]\ndrive_id =\n"))
        XCTAssertFalse(RemoteParsing.redactedConfigHasDriveID("[MyCloud]\ndrive_id_other = x\n"))
    }

    func testDisplayNames() {
        XCTAssertEqual(RemoteParsing.displayName("onedrive:"), "OneDrive")
        XCTAssertEqual(RemoteParsing.displayName("OneDrive"), "OneDrive")
        XCTAssertEqual(RemoteParsing.displayName("Photos Box:"), "Photos Box")
        XCTAssertEqual(RemoteParsing.reconnectMessage("onedrive:"), ErrorClassifier.reconnectMessage)
    }

    // MARK: paths

    func testTargets() {
        XCTAssertEqual(RemoteParsing.target(remote: "onedrive:", path: "/Backups//Archive/"), "onedrive:Backups/Archive")
        XCTAssertEqual(RemoteParsing.target(remote: "onedrive:", path: ""), "onedrive:")
        XCTAssertEqual(RemoteParsing.target(remote: "My Disk:", path: "Archive"), "My Disk:Archive")
        XCTAssertNil(RemoteParsing.target(remote: "onedrive:", path: "Backups/../Elsewhere"))
        XCTAssertNil(RemoteParsing.target(remote: "onedrive:", path: "./Archive"))
        XCTAssertNil(RemoteParsing.target(remote: "onedrive:", path: ".."))
        XCTAssertNil(RemoteParsing.target(remote: "onedrive", path: "Archive"), "remote needs its colon")
        XCTAssertNil(RemoteParsing.target(remote: "-x:", path: "Archive"), "would look like a flag")
        XCTAssertNil(RemoteParsing.target(remote: "a/b:", path: "Archive"))
        XCTAssertNil(RemoteParsing.target(remote: "", path: "relative/path"))
        XCTAssertEqual(RemoteParsing.target(remote: "", path: "/tmp/Archive/"), SafetyRules.normalizeLocal("/tmp/Archive"))
        XCTAssertNil(RemoteParsing.target(remote: "", path: "/tmp/Archive/.."))
    }

    func testEmptyFolderNames() {
        XCTAssertTrue(RemoteParsing.hasEmptyPart(""))
        XCTAssertTrue(RemoteParsing.hasEmptyPart("/"))
        XCTAssertTrue(RemoteParsing.hasEmptyPart("   "))
        XCTAssertTrue(RemoteParsing.hasEmptyPart("Backups/ /New"))
        XCTAssertTrue(RemoteParsing.hasEmptyPart("Backups//New"))
        XCTAssertTrue(RemoteParsing.hasEmptyPart("Backups/ "), "a name of only spaces")
        XCTAssertFalse(RemoteParsing.hasEmptyPart("Backups/New Folder"))
        XCTAssertFalse(RemoteParsing.hasEmptyPart("/Backups/New/"))
    }

    func testSlug() {
        XCTAssertEqual(RemoteParsing.slug("Archive"), "archive")
        XCTAssertEqual(RemoteParsing.slug("  Private Papers 2024! "), "private-papers-2024")
        XCTAssertEqual(RemoteParsing.slug("Ärchiv"), "rchiv")
        XCTAssertEqual(RemoteParsing.slug("!!!"), "backup")
        XCTAssertEqual(RemoteParsing.slug(""), "backup")
    }

    func testDefaultDownloadURL() {
        let url = EngineEnvironment.defaultRcloneDownloadURL.absoluteString
        XCTAssertTrue(url == "https://downloads.rclone.org/rclone-current-osx-arm64.zip"
                      || url == "https://downloads.rclone.org/rclone-current-osx-amd64.zip", url)
        XCTAssertEqual(EngineEnvironment.defaultBrewCandidates, ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
    }

    func testFindBinaryInUnpackedZip() throws {
        let dir = try makeTempDirectory("koffer-find")
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = dir.appendingPathComponent("rclone-v9.9.9-osx-arm64", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true, attributes: nil)
        try Data("x".utf8).write(to: inner.appendingPathComponent("README.txt"))
        XCTAssertNil(RemoteParsing.findBinary(in: dir))
        try Data("#!/bin/sh\n".utf8).write(to: inner.appendingPathComponent("rclone"))
        XCTAssertEqual(RemoteParsing.findBinary(in: dir)?.lastPathComponent, "rclone")
        XCTAssertEqual(RemoteParsing.findBinary(in: dir)?.deletingLastPathComponent().lastPathComponent, "rclone-v9.9.9-osx-arm64")
    }

    // MARK: commands + assertSafe

    func testNewCommands() {
        XCTAssertEqual(RcloneCommand.listRemotes(), ["listremotes"])
        XCTAssertEqual(RcloneCommand.listRemotes(long: true), ["listremotes", "--long"])
        XCTAssertEqual(RcloneCommand.listFolders(target: "onedrive:Backups"),
                       ["lsjson", "onedrive:Backups", "--dirs-only", "--no-mimetype", "--no-modtime"])
        XCTAssertEqual(RcloneCommand.mkdir(target: "onedrive:Backups/New"), ["mkdir", "onedrive:Backups/New"])
        XCTAssertEqual(RcloneCommand.version(), ["version"])
        XCTAssertEqual(RcloneCommand.configRedacted(remote: "onedrive:"), ["config", "redacted", "onedrive"])
        XCTAssertEqual(RcloneCommand.reconnect(remote: "onedrive:"), ["config", "reconnect", "onedrive:", "--auto-confirm"])
        XCTAssertEqual(RcloneCommand.reconnect(remote: "onedrive"), ["config", "reconnect", "onedrive:", "--auto-confirm"])
        XCTAssertEqual(RcloneCommand.reconnectKeepingOneDriveDrive(remote: "onedrive:"),
                       ["config", "update", "onedrive", "config_refresh_token=true", "config_is_local=true",
                        "config_type=driveid", "config_drive_ok=true", "--no-output", "--auto-confirm"])
        XCTAssertEqual(RcloneCommand.configName("onedrive::"), "onedrive")
    }

    func testAssertSafeAllowsTheNewCommands() {
        let root = "onedrive:_Archive_removed"
        let allowed: [[String]] = [
            RcloneCommand.listRemotes(), RcloneCommand.listRemotes(long: true),
            RcloneCommand.listFolders(target: "onedrive:Backups"), RcloneCommand.listFolders(target: "/tmp/x"),
            RcloneCommand.mkdir(target: "onedrive:Backups/New Folder"), RcloneCommand.mkdir(target: "/tmp/x/New"),
            RcloneCommand.about(remote: "onedrive:"), RcloneCommand.size(path: root), RcloneCommand.version(),
            RcloneCommand.configRedacted(remote: "onedrive:"),
            RcloneCommand.reconnect(remote: "onedrive:"), RcloneCommand.reconnect(remote: "Photos Box:"),
            RcloneCommand.reconnectKeepingOneDriveDrive(remote: "onedrive:"),
        ]
        for args in allowed {
            XCTAssertEqual(SafetyRules.assertSafe(arguments: args, removedRoot: root), .ok, args.joined(separator: " "))
            XCTAssertEqual(SafetyRules.assertSafe(arguments: args, removedRoot: ""), .ok, args.joined(separator: " "))
        }
    }

    func testAssertSafeStillRefusesDestructiveCommands() {
        let root = "onedrive:_Archive_removed"
        let refused: [[String]] = [
            ["mkdir"], ["mkdir", "onedrive:a", "onedrive:b"], ["mkdir", "relative/path"], ["mkdir", "onedrive:x/.."],
            ["rmdir", "onedrive:Archive"], ["rmdirs", "onedrive:Archive"], ["delete", "onedrive:Archive"],
            ["deletefile", "onedrive:Archive/a"], ["move", "onedrive:Archive", "onedrive:Other"],
            ["copy", "/tmp/x", "onedrive:Archive"], ["cleanup", "onedrive:"], ["dedupe", "onedrive:Archive"],
            ["config"], ["config", "dump"], ["config", "show", "onedrive"], ["config", "delete", "onedrive"],
            ["config", "create", "x", "onedrive"], ["config", "disconnect", "onedrive:"], ["config", "password", "onedrive", "pass", "x"],
            ["config", "reconnect", "onedrive"], ["config", "reconnect", "onedrive:", "--config", "/tmp/other.conf"],
            ["config", "reconnect", "-v:"], ["config", "reconnect", "a/b:"],
            ["config", "update", "onedrive"], ["config", "update", "onedrive:", "config_type=driveid"],
            ["config", "update", "onedrive", "drive_id=abc"], ["config", "update", "onedrive", "token=x"],
            ["config", "update", "onedrive", "config_type=driveid", "--obscure"],
            ["config", "redacted", "onedrive", "--extra"],
            ["lsjson", "onedrive:", "--delete-excluded"], ["mkdir", "onedrive:x", "--delete-before"],
            ["purge", "onedrive:Archive"],
        ]
        for args in refused {
            assertRefused(SafetyRules.assertSafe(arguments: args, removedRoot: root))
        }
        // purge is still allowed on the removed-items folder, and only there.
        XCTAssertEqual(SafetyRules.assertSafe(arguments: ["purge", root], removedRoot: root), .ok)
        assertRefused(SafetyRules.assertSafe(arguments: ["purge", root], removedRoot: ""))
    }

    func testPlainRemoteNames() {
        XCTAssertTrue(SafetyRules.isPlainRemoteName("onedrive:"))
        XCTAssertTrue(SafetyRules.isPlainRemoteName("onedrive"))
        XCTAssertTrue(SafetyRules.isPlainRemoteName("Photos Box:"))
        XCTAssertFalse(SafetyRules.isPlainRemoteName(":"))
        XCTAssertFalse(SafetyRules.isPlainRemoteName(""))
        XCTAssertFalse(SafetyRules.isPlainRemoteName("-x"))
        XCTAssertFalse(SafetyRules.isPlainRemoteName(" onedrive:"))
        XCTAssertFalse(SafetyRules.isPlainRemoteName("a:b:"))
        XCTAssertFalse(SafetyRules.isPlainRemoteName("a/b"))
        XCTAssertFalse(SafetyRules.isPlainRemoteName("a=b"))
    }

    func testEngineErrorAndStates() {
        XCTAssertEqual(EngineError("x"), EngineError("x"))
        XCTAssertNotEqual(EngineError("x"), EngineError("y"))
        XCTAssertEqual(EngineError("x").message, "x")
        XCTAssertNotEqual(RemoteState.checking, RemoteState.unknown)
        XCTAssertEqual(RemoteState.connected(used: nil, total: 1, free: nil), RemoteState.connected(used: nil, total: 1, free: nil))
        XCTAssertNotEqual(TaskState.running("a"), TaskState.running("b"))
        XCTAssertEqual(TaskState.succeeded, TaskState.succeeded)
    }
}
