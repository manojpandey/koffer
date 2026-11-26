import XCTest
@testable import KofferCore

/// v0.2 engine additions: new backups, forgetting backups, installing rclone, signing in again,
/// the connection check and the cloud folder browser.
/// Fake rclone scripts stand in where a real account would be needed; tests that need the real
/// rclone binary are skipped when it is not installed.
final class EngineSetupTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default
    private let home = "/Users/someone"

    override func setUpWithError() throws {
        base = try makeTempDirectory("koffer-setup")
    }

    override func tearDownWithError() throws {
        if let b = base { try? fm.removeItem(at: b) }
    }

    // MARK: - Helpers

    private var configURL: URL { return base.appendingPathComponent("config/config.json") }

    @MainActor
    private func makeEngine(config: KofferConfig, candidates: [String] = [], configPath: String? = nil,
                            brew: [String] = [], downloadURL: URL? = nil, reconnectTimeout: TimeInterval = 300,
                            homeDirectory: String? = nil) throws -> SyncEngine {
        try ConfigStore(fileURL: configURL).save(config)
        let env = EngineEnvironment(configURL: configURL, logDirectory: base.appendingPathComponent("logs"),
                                    rcloneCandidates: candidates, mountDelay: 0.1, interruptGrace: 5,
                                    homeDirectory: homeDirectory ?? home, volumesDirectory: nil,
                                    timeZone: nil, now: { Date() },
                                    rcloneInstallDirectory: base.appendingPathComponent("bin", isDirectory: true),
                                    brewCandidates: brew,
                                    rcloneDownloadURL: downloadURL ?? URL(fileURLWithPath: "/nonexistent/rclone.zip"),
                                    rcloneConfigPath: configPath,
                                    reconnectTimeout: reconnectTimeout,
                                    remotesCheckInterval: 60)
        let services = EngineServices(notifier: FakeNotifier(), power: FakePower(), history: FakeHistory())
        return SyncEngine(services: services, environment: env)
    }

    private func archiveJob() -> SyncJob {
        return SyncJob(id: "archive", name: "Archive", source: "/Volumes/MyDisk/Archive",
                       destination: "onedrive:Backups/Archive", removedRoot: "onedrive:Backups/_Archive_removed",
                       requiredVolume: "MyDisk", autoSyncOnMount: true, enabled: true, previewApproved: true)
    }

    private func savedConfig() throws -> KofferConfig {
        return try ConfigStore(fileURL: configURL).load()
    }

    /// Writes an executable shell script and returns its path.
    private func writeScript(_ name: String, _ body: String) throws -> String {
        let url = base.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)
        return url.path
    }

    /// A stand-in for rclone. Logs its arguments to `calls.log`. `type` is what `listremotes --long` reports for
    /// the remote "Fake:"; `configBody` runs for `rclone config reconnect/update`.
    private func fakeRclone(type: String, configBody: String) throws -> (path: String, log: URL) {
        let log = base.appendingPathComponent("calls.log")
        let body = """
        echo "$*" >> '\(log.path)'
        case "$1" in
          listremotes)
            if [ "$2" = "--long" ]; then echo "Fake: \(type)"; else echo "Fake:"; fi
            exit 0 ;;
          about)
            echo '{"total": 100, "used": 40, "free": 60}'
            exit 0 ;;
          version)
            echo "rclone v1.71.2"
            exit 0 ;;
          config)
            if [ "$2" = "redacted" ]; then
              printf '[Fake]\\ntype = onedrive\\ndrive_id = XXX\\ntoken = XXX\\n'
              exit 0
            fi
            \(configBody) ;;
        esac
        exit 0

        """
        return (try writeScript("fake-rclone", body), log)
    }

    private func calls(_ log: URL) -> [String] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func findRclone() async -> String? {
        if let path = RcloneLocator().locate() { return path }
        let result = await RcloneRunner.capture(executablePath: "/usr/bin/which", arguments: ["rclone"], timeout: 10)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 0 && !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }

    private func requireRclone() async throws -> String {
        guard let rclone = await EngineSetupTests.findRclone() else {
            throw XCTSkip("rclone is not installed; skipping integration tests")
        }
        return rclone
    }

    // MARK: - proposedJob

    @MainActor
    func testProposedJobOnADisk() throws {
        let engine = try makeEngine(config: KofferConfig(jobs: []))
        let job = engine.proposedJob(name: " Archive ", source: "/Volumes/MyDisk/Archive/", remote: "onedrive:",
                                     remotePath: "/Backups/Archive/")
        XCTAssertEqual(job.id, "archive")
        XCTAssertEqual(job.name, "Archive")
        XCTAssertEqual(job.source, "/Volumes/MyDisk/Archive")
        XCTAssertEqual(job.destination, "onedrive:Backups/Archive")
        XCTAssertEqual(job.removedRoot, "onedrive:Backups/_Archive_removed")
        XCTAssertEqual(job.requiredVolume, "MyDisk")
        XCTAssertTrue(job.autoSyncOnMount)
        XCTAssertTrue(job.enabled)
        XCTAssertFalse(job.previewApproved)
        XCTAssertFalse(job.isTest)
        XCTAssertNil(job.extraLogDirectory)
        XCTAssertEqual(job.remoteName, "onedrive:")
    }

    @MainActor
    func testProposedJobVariants() throws {
        let engine = try makeEngine(config: KofferConfig(jobs: []))
        // A folder at the top of the remote: the removed folder is its sibling at the top.
        let top = engine.proposedJob(name: "Archive", source: "/Users/someone/Archive", remote: "onedrive", remotePath: "Archive")
        XCTAssertEqual(top.destination, "onedrive:Archive")
        XCTAssertEqual(top.removedRoot, "onedrive:_Archive_removed")
        XCTAssertNil(top.requiredVolume, "not on an external disk")
        XCTAssertFalse(top.autoSyncOnMount)
        // No name: the folder's own name.
        let unnamed = engine.proposedJob(name: "  ", source: "/Volumes/MyDisk/Private Papers", remote: "gdrive:",
                                         remotePath: "Backups/Papers")
        XCTAssertEqual(unnamed.name, "Private Papers")
        XCTAssertEqual(unnamed.id, "private-papers")
        XCTAssertEqual(unnamed.removedRoot, "gdrive:Backups/_Papers_removed")
        // This computer as the "remote" (full paths).
        let local = engine.proposedJob(name: "Archive", source: "/tmp/x/src", remote: "", remotePath: "/tmp/x/dst/")
        XCTAssertEqual(local.destination, SafetyRules.normalizeLocal("/tmp/x/dst"))
        XCTAssertEqual(local.removedRoot, SafetyRules.normalizeLocal("/tmp/x") + "/_dst_removed")
        // The top of the remote: proposed as asked, refused by addJob.
        let root = engine.proposedJob(name: "Archive", source: "/Volumes/MyDisk/Archive", remote: "onedrive:", remotePath: "/")
        XCTAssertEqual(root.destination, "onedrive:")
    }

    @MainActor
    func testProposedJobIDsAreUnique() throws {
        let engine = try makeEngine(config: KofferConfig(jobs: [SyncJob.testJob(home: home), archiveJob()]))
        XCTAssertEqual(engine.proposedJob(name: "Archive", source: "/Volumes/MyDisk/Other", remote: "onedrive:",
                                          remotePath: "Backups/Other").id, "archive-2")
        XCTAssertEqual(engine.proposedJob(name: "Test", source: "/Volumes/MyDisk/Test", remote: "onedrive:",
                                          remotePath: "Backups/Test").id, "test-2")
        XCTAssertEqual(engine.proposedJob(name: "!!!", source: "/Volumes/MyDisk/Stuff", remote: "onedrive:",
                                          remotePath: "Backups/Stuff").id, "backup")

        let second = engine.proposedJob(name: "Archive", source: "/Volumes/MyDisk/Other", remote: "onedrive:",
                                        remotePath: "Backups/Other")
        XCTAssertEqual(engine.addJob(second), .ok)
        XCTAssertEqual(engine.proposedJob(name: "Archive", source: "/Volumes/MyDisk/More", remote: "onedrive:",
                                          remotePath: "Backups/More").id, "archive-3")
    }

    // MARK: - addJob / removeJob

    @MainActor
    func testAddJobSavesIt() throws {
        let engine = try makeEngine(config: KofferConfig(jobs: [archiveJob()]))
        let job = engine.proposedJob(name: "Photos", source: "/Volumes/MyDisk/Photos", remote: "onedrive:",
                                     remotePath: "Backups/Photos")
        XCTAssertEqual(engine.addJob(job), .ok)
        XCTAssertEqual(engine.jobs.map { $0.id }, ["archive", "photos"])
        XCTAssertEqual(engine.job(id: "photos"), job)
        XCTAssertEqual(try savedConfig().jobs.map { $0.id }, ["archive", "photos"])
        XCTAssertEqual(engine.status, .idle, "adding a job doesn't change the status")
    }

    @MainActor
    func testAddJobRefusals() throws {
        let rule = PrivatePathRule(pathContains: "private papers", forbiddenRemotes: ["onedrive:"])
        let config = KofferConfig(jobs: [archiveJob()], neverSync: ["camera stuff"], privatePaths: [rule])
        let engine = try makeEngine(config: config)
        let before: Data = try Data(contentsOf: configURL)

        func refused(_ job: SyncJob, containing text: String, file: StaticString = #filePath, line: UInt = #line) {
            let verdict = engine.addJob(job)
            XCTAssertFalse(verdict.isOK, "expected a refusal for \(job.source) -> \(job.destination)", file: file, line: line)
            XCTAssertTrue((verdict.reason ?? "").contains(text), verdict.reason ?? "", file: file, line: line)
        }

        // A folder on the never-sync list.
        refused(engine.proposedJob(name: "Camera", source: "/Volumes/MyDisk/Camera Stuff", remote: "onedrive:",
                                   remotePath: "Backups/Camera"), containing: "never-sync")
        // A private folder to a remote it may not go to.
        refused(engine.proposedJob(name: "Papers", source: "/Volumes/MyDisk/Private Papers", remote: "onedrive:",
                                   remotePath: "Backups/Papers"), containing: "private")
        // The same folder to the same place, under another name.
        refused(engine.proposedJob(name: "Archive again", source: "/Volumes/MyDisk/Archive/", remote: "onedrive:",
                                   remotePath: "Backups/Archive"), containing: "already backs up")
        // The top of the remote.
        refused(engine.proposedJob(name: "Everything", source: "/Volumes/MyDisk/Stuff", remote: "onedrive:",
                                   remotePath: ""), containing: "top of")
        // Inside another backup's folder (its sync would move these files to its removed items).
        refused(engine.proposedJob(name: "Sub", source: "/Volumes/MyDisk/Sub", remote: "onedrive:",
                                   remotePath: "Backups/Archive/Sub"), containing: "share a cloud folder")
        // Inside another backup's removed items.
        refused(engine.proposedJob(name: "Sneaky", source: "/Volumes/MyDisk/Sneaky", remote: "onedrive:",
                                   remotePath: "Backups/_Archive_removed/x"), containing: "share a cloud folder")
        // The whole disk, and the home folder.
        refused(engine.proposedJob(name: "Disk", source: "/Volumes/MyDisk", remote: "onedrive:",
                                   remotePath: "Backups/Disk"), containing: "whole disk")
        refused(engine.proposedJob(name: "Home", source: home, remote: "onedrive:", remotePath: "Backups/Home"),
                containing: "home folder")
        // Same id as an existing job.
        var sameID = engine.proposedJob(name: "Other", source: "/Volumes/MyDisk/Other", remote: "onedrive:", remotePath: "Backups/Other")
        sameID.id = "archive"
        refused(sameID, containing: "already a backup")

        XCTAssertEqual(engine.jobs, [archiveJob()], "a refusal changes nothing")
        XCTAssertEqual(try Data(contentsOf: configURL), before, "the settings file is untouched")

        // The private folder may go to another remote.
        let elsewhere = engine.proposedJob(name: "Papers", source: "/Volumes/MyDisk/Private Papers", remote: "gdrive:",
                                           remotePath: "Backups/Papers")
        XCTAssertEqual(engine.addJob(elsewhere), .ok)
    }

    @MainActor
    func testAddJobReadsTheSettingsFileFirst() throws {
        let engine = try makeEngine(config: KofferConfig(jobs: [archiveJob()]))
        // Hand-edited after launch: a new protected folder.
        try ConfigStore(fileURL: configURL).save(KofferConfig(jobs: [archiveJob()], neverSync: ["holiday"]))
        let job = engine.proposedJob(name: "Holiday", source: "/Volumes/MyDisk/Holiday", remote: "onedrive:",
                                     remotePath: "Backups/Holiday")
        XCTAssertFalse(engine.addJob(job).isOK)

        // A broken settings file is never overwritten.
        let garbage = Data("nope".utf8)
        try garbage.write(to: configURL)
        let other = engine.proposedJob(name: "Other", source: "/Volumes/MyDisk/Other", remote: "onedrive:", remotePath: "Backups/Other")
        XCTAssertEqual(engine.addJob(other), .refused(SyncEngine.settingsUnreadableMessage))
        XCTAssertEqual(try Data(contentsOf: configURL), garbage)
    }

    @MainActor
    func testRemoveJobOnlyEditsTheSettings() throws {
        let photos = SyncJob(id: "photos", name: "Photos", source: "/Volumes/MyDisk/Photos",
                             destination: "onedrive:Backups/Photos", removedRoot: "onedrive:Backups/_Photos_removed")
        let engine = try makeEngine(config: KofferConfig(jobs: [archiveJob(), photos], neverSync: ["camera stuff"]))
        XCTAssertEqual(engine.removeJob(id: "archive"), .ok)
        XCTAssertEqual(engine.jobs.map { $0.id }, ["photos"])
        let saved = try savedConfig()
        XCTAssertEqual(saved.jobs.map { $0.id }, ["photos"])
        XCTAssertEqual(saved.neverSync, ["camera stuff"], "the rest of the settings are kept")
        XCTAssertNil(engine.job(id: "archive"))

        XCTAssertFalse(engine.removeJob(id: "archive").isOK, "already gone")
        XCTAssertFalse(engine.removeJob(id: "nope").isOK)
        XCTAssertEqual(engine.status, .idle)
    }

    // MARK: - Installing rclone

    @MainActor
    private func makeZip(containing script: String?) async throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ditto") else {
            throw XCTSkip("/usr/bin/ditto is only on macOS")
        }
        let staging = base.appendingPathComponent("zip-staging/rclone-v9.9.9-osx-arm64", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: nil)
        try Data("Made-up package for tests\n".utf8).write(to: staging.appendingPathComponent("README.txt"))
        if let body = script {
            let binary = staging.appendingPathComponent("rclone")
            try Data(("#!/bin/sh\n" + body).utf8).write(to: binary)
            // Packed without the executable bit: the installer must set it.
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: binary.path)
        }
        let zip = base.appendingPathComponent("rclone-download.zip")
        let result = await RcloneRunner.capture(executablePath: "/usr/bin/ditto",
                                                arguments: ["-c", "-k", "--keepParent", staging.path, zip.path], timeout: 60)
        XCTAssertEqual(result.status, 0, result.stderr)
        return zip
    }

    @MainActor
    func testInstallDownloadsWhenThereIsNoHomebrew() async throws {
        let zip = try await makeZip(containing: "if [ \"$1\" = version ]; then echo 'rclone v9.9.9'; fi\nexit 0\n")
        let binDirectory = base.appendingPathComponent("bin", isDirectory: true)
        let installed = binDirectory.appendingPathComponent("rclone")
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [installed.path],
                                    brew: [base.appendingPathComponent("no-brew-here").path], downloadURL: zip)
        XCTAssertNil(engine.homebrewPath)
        XCTAssertNil(engine.rclonePath)
        XCTAssertEqual(engine.installState, .idle)

        engine.installRclone()
        XCTAssertEqual(engine.installState, .running(SyncEngine.downloadingMessage))
        if let task = engine.installTask { await task.value }

        XCTAssertEqual(engine.installState, .succeeded)
        XCTAssertTrue(fm.isExecutableFile(atPath: installed.path))
        let attributes = try fm.attributesOfItem(atPath: installed.path)
        let mode: Int = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o755)
        XCTAssertEqual(engine.rclonePath, installed.path)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: binDirectory.path), ["rclone"], "no scratch files left behind")
        // Then the connection check ran with the new binary (the fake one lists no remotes).
        if let task = engine.remotesTask { await task.value }
        XCTAssertEqual(engine.remotes, [])
        XCTAssertEqual(engine.status, .idle)
    }

    @MainActor
    func testFailedInstallLeavesNothingBehind() async throws {
        let binDirectory = base.appendingPathComponent("bin", isDirectory: true)
        let installed = binDirectory.appendingPathComponent("rclone")

        // 1. The download is missing.
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [installed.path], brew: [],
                                    downloadURL: base.appendingPathComponent("missing.zip"))
        engine.installRclone()
        if let task = engine.installTask { await task.value }
        guard case .failed(let reason) = engine.installState else { return XCTFail("expected failed, got \(engine.installState)") }
        XCTAssertTrue(reason.contains("Downloading rclone didn't work"), reason)
        XCTAssertFalse(fm.fileExists(atPath: installed.path))
        XCTAssertNil(engine.rclonePath)
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: binDirectory.path)) ?? [], [])

        // 2. The zip has no rclone in it.
        let zip = try await makeZip(containing: nil)
        let engine2 = try makeEngine(config: KofferConfig(jobs: []), candidates: [installed.path], brew: [], downloadURL: zip)
        engine2.installRclone()
        if let task = engine2.installTask { await task.value }
        XCTAssertEqual(engine2.installState, .failed("The download didn't contain rclone."))
        XCTAssertFalse(fm.fileExists(atPath: installed.path))
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: binDirectory.path)) ?? [], [])
    }

    @MainActor
    func testInstallRefusesABinaryThatDoesNotRun() async throws {
        let zip = try await makeZip(containing: "exit 1\n")
        let binDirectory = base.appendingPathComponent("bin", isDirectory: true)
        let installed = binDirectory.appendingPathComponent("rclone")
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [installed.path], brew: [], downloadURL: zip)
        engine.installRclone()
        if let task = engine.installTask { await task.value }
        XCTAssertEqual(engine.installState, .failed("The downloaded rclone doesn't run on this Mac."))
        XCTAssertFalse(fm.fileExists(atPath: installed.path), "never a half-checked binary in place")
    }

    @MainActor
    func testInstallWithHomebrew() async throws {
        // A stand-in for brew that "installs" rclone where the locator looks.
        let target = base.appendingPathComponent("homebrew/bin/rclone")
        let brew = try writeScript("brew", """
        [ "$1" = install ] && [ "$2" = rclone ] || exit 1
        mkdir -p '\(target.deletingLastPathComponent().path)'
        printf '#!/bin/sh\\nexit 0\\n' > '\(target.path)'
        chmod 755 '\(target.path)'
        exit 0

        """)
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [target.path], brew: [brew])
        XCTAssertEqual(engine.homebrewPath, brew)
        engine.installRclone()
        XCTAssertEqual(engine.installState, .running(SyncEngine.homebrewInstallingMessage))
        if let task = engine.installTask { await task.value }
        XCTAssertEqual(engine.installState, .succeeded)
        XCTAssertEqual(engine.rclonePath, target.path)
        if let task = engine.remotesTask { await task.value }
    }

    // MARK: - Signing in again (fake rclone)

    @MainActor
    func testReconnectSucceeds() async throws {
        let fake = try fakeRclone(type: "drive", configBody: "exit 0")
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [fake.path])
        engine.reconnect(remote: "Fake:")
        XCTAssertEqual(engine.reconnectState, .running(SyncEngine.signInWaitingMessage))
        if let task = engine.reconnectTask { await task.value }
        XCTAssertEqual(engine.reconnectState, .succeeded)
        XCTAssertFalse(engine.needsReconnect)
        XCTAssertTrue(calls(fake.log).contains("config reconnect Fake: --auto-confirm"), calls(fake.log).joined(separator: "\n"))
        XCTAssertFalse(calls(fake.log).contains(where: { $0.hasPrefix("config redacted") }), "only asked for OneDrive remotes")
        // Afterwards the connection is checked again.
        if let task = engine.remotesTask { await task.value }
        XCTAssertEqual(engine.remotes, ["Fake:"])
        XCTAssertEqual(engine.remoteStates["Fake:"], .connected(used: 40, total: 100, free: 60))
        XCTAssertEqual(engine.status, .idle)
        XCTAssertNil(engine.statusJobID)
    }

    @MainActor
    func testReconnectKeepsTheOneDriveDrive() async throws {
        let fake = try fakeRclone(type: "onedrive", configBody: "exit 0")
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [fake.path])
        engine.reconnect(remote: "Fake")
        if let task = engine.reconnectTask { await task.value }
        XCTAssertEqual(engine.reconnectState, .succeeded)
        let log = calls(fake.log)
        XCTAssertTrue(log.contains("listremotes --long"), log.joined(separator: "\n"))
        XCTAssertTrue(log.contains("config redacted Fake"), log.joined(separator: "\n"))
        XCTAssertTrue(log.contains("config update Fake config_refresh_token=true config_is_local=true config_type=driveid config_drive_ok=true --no-output --auto-confirm"),
                      log.joined(separator: "\n"))
        XCTAssertFalse(log.contains(where: { $0.hasPrefix("config reconnect") }))
        if let task = engine.remotesTask { await task.value }
    }

    @MainActor
    func testReconnectFailureShowsRclonesLastErrorLine() async throws {
        let fake = try fakeRclone(type: "drive", configBody: """
        echo "2026/01/02 10:00:00 NOTICE: Fatal error: something made-up broke" >&2; exit 1
        """)
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [fake.path])
        engine.reconnect(remote: "Fake:")
        if let task = engine.reconnectTask { await task.value }
        guard case .failed(let reason) = engine.reconnectState else { return XCTFail("expected failed, got \(engine.reconnectState)") }
        XCTAssertTrue(reason.contains("something made-up broke"), reason)
        XCTAssertTrue(reason.hasPrefix("Signing in to Fake didn't work."), reason)
    }

    @MainActor
    func testReconnectTimesOut() async throws {
        let fake = try fakeRclone(type: "drive", configBody: "exec sleep 30")
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [fake.path], reconnectTimeout: 0.5)
        let started = Date()
        engine.reconnect(remote: "Fake:")
        if let task = engine.reconnectTask { await task.value }
        guard case .failed(let reason) = engine.reconnectState else { return XCTFail("expected failed, got \(engine.reconnectState)") }
        XCTAssertTrue(reason.contains("stopped"), reason)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    @MainActor
    func testCancelReconnect() async throws {
        let fake = try fakeRclone(type: "drive", configBody: "exec sleep 30")
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [fake.path])
        let started = Date()
        engine.reconnect(remote: "Fake:")
        // Wait until rclone is really waiting for the browser.
        let deadline = Date().addingTimeInterval(10)
        while !calls(fake.log).contains(where: { $0.hasPrefix("config reconnect") }) && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        engine.cancelReconnect()
        XCTAssertEqual(engine.reconnectState, .idle)
        if let task = engine.reconnectTask { await task.value }
        XCTAssertEqual(engine.reconnectState, .idle)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    @MainActor
    func testReconnectRefusals() throws {
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [])
        engine.reconnect(remote: "Fake:")
        XCTAssertEqual(engine.reconnectState, .failed(SyncEngine.rcloneMissingMessage))
        engine.reconnect(remote: "-x:")
        guard case .failed = engine.reconnectState else { return XCTFail("expected failed") }
        engine.cancelReconnect()
        XCTAssertNotEqual(engine.reconnectState, .idle, "nothing to cancel")
        // Still there for older parts of the UI.
        XCTAssertEqual(engine.reconnectCommand(for: "nope"), "rclone config reconnect onedrive:")
    }

    // MARK: - Connection check (fake rclone)

    @MainActor
    func testAuthFailureOfAJobsRemoteNeedsReconnect() async throws {
        let script = try writeScript("rclone-expired", """
        case "$1" in
          listremotes) echo "onedrive:"; echo "Spare:"; exit 0 ;;
          about) echo "2026/01/02 10:00:00 CRITICAL: Failed to create file system for \\"$2\\": couldn't fetch token: invalid_grant" >&2; exit 1 ;;
        esac
        exit 0

        """)
        // Only "Spare:" fails while no job uses it: no global reconnect.
        let engine = try makeEngine(config: KofferConfig(jobs: [archiveJob()]), candidates: [script])
        XCTAssertFalse(engine.needsReconnect)
        engine.refreshRemotes(force: true)
        if let task = engine.remotesTask { await task.value }
        XCTAssertEqual(engine.remotes, ["onedrive:", "Spare:"])
        XCTAssertEqual(engine.remoteStates["onedrive:"], .failed("OneDrive needs you to sign in again"))
        XCTAssertEqual(engine.remoteStates["Spare:"], .failed("Spare needs you to sign in again"))
        XCTAssertTrue(engine.needsReconnect, "the archive job uses onedrive:")
        XCTAssertEqual(engine.status, .idle)
        XCTAssertNil(engine.activeJobID)
        XCTAssertNil(engine.statusJobID)

        let unrelated = try makeEngine(config: KofferConfig(jobs: [SyncJob(id: "g", name: "G", source: "/Volumes/MyDisk/G",
                                                                             destination: "gdrive:G", removedRoot: "gdrive:_G_removed")]),
                                       candidates: [script])
        unrelated.refreshRemotes(force: true)
        if let task = unrelated.remotesTask { await task.value }
        XCTAssertFalse(unrelated.needsReconnect, "no job uses the failing remotes")
    }

    // MARK: - Real rclone

    @MainActor
    func testRefreshRemotesWithRealRclone() async throws {
        let rclone = try await requireRclone()
        let rcloneConfig = base.appendingPathComponent("rclone.conf")
        // Made-up remotes that need no account: a local disk, memory (can't report space), and a crypt
        // remote without a password (fails without touching the network).
        try Data("[Disk]\ntype = local\n\n[Mem]\ntype = memory\n\n[Locked]\ntype = crypt\nremote = /nonexistent/koffer\n".utf8)
            .write(to: rcloneConfig)
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [rclone], configPath: rcloneConfig.path)
        XCTAssertEqual(engine.remotes, [])

        engine.refreshRemotes(force: false)
        let task = try XCTUnwrap(engine.remotesTask)
        await task.value

        XCTAssertEqual(Set(engine.remotes), Set(["Disk:", "Mem:", "Locked:"]))
        guard case .connected(_, let total, _) = engine.remoteStates["Disk:"] ?? .unknown else {
            return XCTFail("Disk: \(String(describing: engine.remoteStates["Disk:"]))")
        }
        XCTAssertNotNil(total)
        XCTAssertEqual(engine.remoteStates["Mem:"], .connected(used: nil, total: nil, free: nil))
        guard case .failed(let reason) = engine.remoteStates["Locked:"] ?? .unknown else {
            return XCTFail("Locked: \(String(describing: engine.remoteStates["Locked:"]))")
        }
        XCTAssertTrue(reason.contains("password"), reason)
        XCTAssertFalse(engine.needsReconnect)
        XCTAssertEqual(engine.status, .idle)
        XCTAssertNil(engine.activeJobID)
        XCTAssertNil(engine.statusJobID)

        // Checked just now: skipped unless forced.
        engine.refreshRemotes(force: false)
        XCTAssertNil(engine.remotesTask)
        engine.refreshRemotes(force: true)
        XCTAssertNotNil(engine.remotesTask)
        if let again = engine.remotesTask { await again.value }

        // A remote that doesn't use a sign-in: rclone's own words come through.
        engine.reconnect(remote: "Disk:")
        if let r = engine.reconnectTask { await r.value }
        guard case .failed(let why) = engine.reconnectState else { return XCTFail("expected failed, got \(engine.reconnectState)") }
        XCTAssertTrue(why.contains("doesn't support reconnect"), why)
        // An unknown remote.
        engine.reconnect(remote: "Nope:")
        if let r = engine.reconnectTask { await r.value }
        guard case .failed(let why2) = engine.reconnectState else { return XCTFail("expected failed, got \(engine.reconnectState)") }
        XCTAssertTrue(why2.contains("doesn't know Nope"), why2)
        if let r = engine.remotesTask { await r.value }
    }

    @MainActor
    func testListAndCreateFoldersOnALocalPath() async throws {
        let rclone = try await requireRclone()
        let cloud = base.appendingPathComponent("cloud", isDirectory: true)
        for name in ["Beta", "alpha", "Gamma"] {
            try fm.createDirectory(at: cloud.appendingPathComponent(name), withIntermediateDirectories: true, attributes: nil)
        }
        try Data("not a folder".utf8).write(to: cloud.appendingPathComponent("file.txt"))
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [rclone])

        let listed = await engine.listFolders(remote: "", path: cloud.path)
        XCTAssertEqual(try listed.get(), ["alpha", "Beta", "Gamma"])

        let created = await engine.createFolder(remote: "", path: cloud.appendingPathComponent("New Folder").path)
        XCTAssertEqual(try created.get(), true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: cloud.appendingPathComponent("New Folder").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let again = await engine.listFolders(remote: "", path: cloud.path)
        XCTAssertEqual(try again.get(), ["alpha", "Beta", "Gamma", "New Folder"])
        let empty = await engine.listFolders(remote: "", path: cloud.appendingPathComponent("New Folder").path)
        XCTAssertEqual(try empty.get(), [])

        // Refused before rclone runs.
        let dots = await engine.createFolder(remote: "", path: cloud.path + "/../Escape")
        XCTAssertThrowsError(try dots.get())
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("Escape").path))
        let unnamed = await engine.createFolder(remote: "onedrive:", path: "Backups/ ")
        XCTAssertEqual(unnamed, .failure(EngineError("Give the new folder a name.")))
        let relative = await engine.listFolders(remote: "", path: "relative/path")
        XCTAssertThrowsError(try relative.get())

        let missing = await engine.listFolders(remote: "", path: cloud.appendingPathComponent("not-there").path)
        XCTAssertEqual(missing, .failure(EngineError("That folder isn't there any more.")))
        XCTAssertEqual(engine.status, .idle)
    }

    @MainActor
    func testAddJobThenBackUp() async throws {
        let rclone = try await requireRclone()
        let src = base.appendingPathComponent("src", isDirectory: true)
        let dst = base.appendingPathComponent("dst", isDirectory: true)
        try fm.createDirectory(at: src.appendingPathComponent("A"), withIntermediateDirectories: true, attributes: nil)
        try Data("first file".utf8).write(to: src.appendingPathComponent("A/one.txt"))
        try Data("second file".utf8).write(to: src.appendingPathComponent("two.txt"))
        let homeDir = base.appendingPathComponent("home", isDirectory: true)
        try fm.createDirectory(at: homeDir, withIntermediateDirectories: true, attributes: nil)
        let engine = try makeEngine(config: KofferConfig(jobs: []), candidates: [rclone], homeDirectory: homeDir.path)

        let job = engine.proposedJob(name: "Archive", source: src.path, remote: "", remotePath: dst.path)
        XCTAssertEqual(engine.addJob(job), .ok)
        XCTAssertEqual(engine.jobs.map { $0.id }, ["archive"])

        engine.syncNow(jobID: job.id)
        // While it runs: no forgetting it, no folder browsing.
        XCTAssertFalse(engine.removeJob(id: job.id).isOK)
        let busy = await engine.listFolders(remote: "", path: base.path)
        XCTAssertEqual(busy, .failure(EngineError(SyncEngine.waitForBackupMessage)))
        engine.refreshRemotes(force: true)
        XCTAssertNil(engine.remotesTask, "no connection check during a backup")
        await engine.currentTask?.value

        XCTAssertEqual(engine.status, .done)
        XCTAssertEqual(engine.history.first?.uploaded, 2)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("A/one.txt"), encoding: .utf8), "first file")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("two.txt"), encoding: .utf8), "second file")

        // Forgetting it leaves the copy alone.
        XCTAssertEqual(engine.removeJob(id: job.id), .ok)
        XCTAssertEqual(engine.jobs, [])
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("two.txt").path))
        XCTAssertEqual(engine.statusJobID, nil)
        XCTAssertEqual(engine.status, .idle)
    }
}
