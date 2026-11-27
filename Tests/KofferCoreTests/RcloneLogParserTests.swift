import XCTest
@testable import KofferCore

final class RcloneLogParserTests: XCTestCase {

    private func assertCountersMatchFinalStats(_ name: String, backupMoves: Int = 0,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        let parser = try Fixtures.parse(name)
        let stats = try Fixtures.finalStats(name)
        let p = parser.progress
        XCTAssertTrue(parser.sawStats, "no stats in \(name)", file: file, line: line)
        XCTAssertEqual(p.uploaded, statInt(stats, "transfers"), "uploaded", file: file, line: line)
        XCTAssertEqual(p.filesDone, statInt(stats, "transfers"), "filesDone", file: file, line: line)
        XCTAssertEqual(p.filesTotal, statInt(stats, "totalTransfers"), "filesTotal", file: file, line: line)
        XCTAssertEqual(p.bytesDone, statInt64(stats, "bytes"), "bytesDone", file: file, line: line)
        XCTAssertEqual(p.bytesTotal, statInt64(stats, "totalBytes"), "bytesTotal", file: file, line: line)
        XCTAssertEqual(p.checksDone, statInt(stats, "checks"), "checksDone", file: file, line: line)
        XCTAssertEqual(p.checksTotal, statInt(stats, "totalChecks"), "checksTotal", file: file, line: line)
        XCTAssertEqual(p.moved, statInt(stats, "renames") - backupMoves, "moved", file: file, line: line)
        XCTAssertEqual(p.removed, statInt(stats, "deletes"), "removed", file: file, line: line)
        XCTAssertEqual(p.errors, statInt(stats, "errors"), "errors", file: file, line: line)
        let elapsed: Double = (stats["elapsedTime"] as? NSNumber)?.doubleValue ?? -1
        XCTAssertEqual(p.elapsed, elapsed, accuracy: 0.000001, file: file, line: line)
    }

    func testInitialSync() throws {
        try assertCountersMatchFinalStats("01_initial_sync")
        let parser = try Fixtures.parse("01_initial_sync")
        XCTAssertEqual(parser.uploadEvents, try Fixtures.countMessages("01_initial_sync", prefix: "Copied (new)"))
        XCTAssertEqual(parser.progress.uploaded, 32)
        XCTAssertTrue(parser.errorLines.isEmpty)
        XCTAssertTrue(parser.changeItems.isEmpty)
        XCTAssertNil(parser.progress.etaSeconds)
        XCTAssertEqual(parser.progress.currentFiles, [])
    }

    func testDryRunRenameDelete() throws {
        try assertCountersMatchFinalStats("02_dryrun_rename_delete")
        let parser = try Fixtures.parse("02_dryrun_rename_delete")
        let stats = try Fixtures.finalStats("02_dryrun_rename_delete")
        let items = parser.changeItems
        let preview = PreviewResult(jobID: "x", date: Date(), items: items)

        XCTAssertEqual(preview.count(.moved), statInt(stats, "renames"))
        XCTAssertEqual(preview.count(.removed), statInt(stats, "deletes"))
        XCTAssertEqual(preview.count(.new) + preview.count(.replaced), statInt(stats, "totalTransfers"))
        XCTAssertEqual(preview.count(.replaced), 0)

        let newPaths = Set(preview.items(.new).map { $0.path })
        XCTAssertEqual(newPaths, ["B/new.txt", "A/pictures_renamed/img_1.jpg"])
        let removedPaths = Set(preview.items(.removed).map { $0.path })
        XCTAssertEqual(removedPaths, ["B/note.txt", "A/photos/img_1.jpg"])

        let move = preview.items(.moved).first(where: { $0.path == "A/photos/img_10.jpg" })
        XCTAssertEqual(move?.newPath, "A/pictures_renamed/img_10.jpg")
        XCTAssertEqual(move?.size, 20370)

        XCTAssertEqual(parser.dryRunUploadBytes, 4 + 20045)
        XCTAssertEqual(preview.uploadBytes, 4 + 20045)
        // Directory housekeeping lines are not changes.
        XCTAssertFalse(items.contains(where: { $0.path == "A/photos" || $0.path == "A" }))
    }

    func testRealRenameDelete() throws {
        let name = "03_sync_rename_delete"
        let backupMoves = try Fixtures.countMessages(name, prefix: "Moved into backup dir")
        XCTAssertEqual(backupMoves, 2)
        try assertCountersMatchFinalStats(name, backupMoves: backupMoves)
        let parser = try Fixtures.parse(name)
        let stats = try Fixtures.finalStats(name)
        // rclone counts backup-dir moves as renames; the real moves are the "to:" lines.
        XCTAssertEqual(parser.progress.moved, try Fixtures.countMessages(name, prefix: "Moved (server-side) to: "))
        XCTAssertEqual(parser.moveEvents, parser.progress.moved)
        XCTAssertEqual(parser.backupDirMoves, statInt(stats, "deletes"))
        XCTAssertEqual(parser.progress.uploaded, 2)
        XCTAssertEqual(parser.progress.removed, 2)
    }

    func testRealRunEvents() throws {
        let parser = RcloneLogParser()
        var moves: [RcloneLogEvent] = []
        var removals: [RcloneLogEvent] = []
        var uploads: [RcloneLogEvent] = []
        for line in try Fixtures.lines("03_sync_rename_delete") {
            for event in parser.consume(line: line) {
                switch event {
                case .moved: moves.append(event)
                case .removed: removals.append(event)
                case .uploaded: uploads.append(event)
                default: break
                }
            }
        }
        XCTAssertEqual(moves.count, 29)
        XCTAssertTrue(moves.contains(.moved(from: "A/photos/img_10.jpg", to: "A/pictures_renamed/img_10.jpg")))
        XCTAssertEqual(removals.count, 2)
        XCTAssertTrue(removals.contains(.removed(path: "B/note.txt")))
        XCTAssertTrue(uploads.contains(.uploaded(path: "B/new.txt", replaced: false, size: 4)))
    }

    func testNoop() throws {
        try assertCountersMatchFinalStats("04_noop")
        let parser = try Fixtures.parse("04_noop")
        XCTAssertEqual(parser.progress.uploaded, 0)
        XCTAssertEqual(parser.progress.checksDone, 32)
        XCTAssertTrue(parser.errorLines.isEmpty)
    }

    func testMissingSource() throws {
        try assertCountersMatchFinalStats("05_missing_source")
        let parser = try Fixtures.parse("05_missing_source")
        XCTAssertEqual(parser.progress.errors, 1)
        XCTAssertEqual(parser.errorLines.first, "error reading source root directory: directory not found")
        XCTAssertTrue(parser.errorLines.contains("Failed to sync: directory not found"))
        XCTAssertEqual(parser.lastStatsError, "directory not found")
        XCTAssertFalse(parser.sawAuthProblem)
        let c = ErrorClassifier.classify(exitCode: 3, errorLines: parser.errorLines)
        XCTAssertTrue(c.sourceMissing)
        XCTAssertEqual(c.message, "The disk was unplugged")
    }

    func testInProgressInterrupted() throws {
        let name = "06_in_progress_interrupted"
        try assertCountersMatchFinalStats(name)
        let parser = try Fixtures.parse(name)
        let stats = try Fixtures.finalStats(name)
        let transferring: [[String: Any]] = (stats["transferring"] as? [[String: Any]]) ?? []
        let expectedNames: [String] = transferring.compactMap { $0["name"] as? String }
        XCTAssertEqual(expectedNames.count, 2)
        XCTAssertEqual(parser.progress.currentFiles, expectedNames)
        XCTAssertEqual(parser.progress.etaSeconds, (stats["eta"] as? NSNumber)?.doubleValue)
        XCTAssertEqual(parser.progress.speed, (stats["speed"] as? NSNumber)?.doubleValue ?? -1, accuracy: 0.001)
        XCTAssertNotNil(parser.progress.fraction)
        XCTAssertTrue(parser.errorLines.isEmpty, "an interrupt is not an error: \(parser.errorLines)")
    }

    func testResumeAfterInterrupt() throws {
        try assertCountersMatchFinalStats("07_resume_after_interrupt")
        let parser = try Fixtures.parse("07_resume_after_interrupt")
        XCTAssertEqual(parser.progress.uploaded, 2)
        XCTAssertEqual(parser.progress.bytesDone, 8_000_000)
        XCTAssertEqual(parser.progress.currentFiles, [])
        XCTAssertEqual(parser.progress.fraction, 1)
    }

    func testStatsSnapshotsUpdateProgressStepByStep() throws {
        let parser = RcloneLogParser()
        var snapshots: [Int64] = []
        for line in try Fixtures.lines("06_in_progress_interrupted") {
            if parser.consume(line: line).contains(.stats) { snapshots.append(parser.progress.bytesDone) }
        }
        XCTAssertEqual(snapshots, [548864, 1073152, 1597440])
    }

    /// 08: a real `--dry-run --track-renames` (hash strategy) while rclone hashes files to match a renamed folder.
    /// Stats carry `listed` and a `checking` list of plain path strings; "update modification time" lines are no change.
    func testDryRunWhileHashingReportsListedAndChecking() throws {
        let parser = RcloneLogParser()
        var snapshots: [SyncProgress] = []
        for line in try Fixtures.lines("08_dryrun_hashing") {
            if parser.consume(line: line).contains(.stats) { snapshots.append(parser.progress) }
        }
        XCTAssertEqual(snapshots.count, 8)
        let first = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(first.listed, 626)
        XCTAssertEqual(first.checksDone, 298)
        XCTAssertEqual(first.checksTotal, 310)
        XCTAssertEqual(first.currentChecks.count, 12)
        XCTAssertEqual(first.currentChecks.first, "A/big_12.bin")
        XCTAssertTrue(first.currentFiles.isEmpty, "nothing is transferred in a dry run")
        XCTAssertEqual(first.checksFraction ?? -1, 298.0 / 310.0, accuracy: 0.0001)

        let last = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(last.currentChecks, [], "no checking list once done")
        XCTAssertEqual(last.checksDone, 324)
        XCTAssertEqual(last.checksTotal, 324)
        XCTAssertEqual(last.listed, 626)

        let items = parser.changeItems
        XCTAssertEqual(items.filter { $0.kind == .moved }.count, 12)
        XCTAssertEqual(items.filter { $0.kind == .removed }.map { $0.path }, ["B/s_1.txt", "B/s_2.txt"])
        XCTAssertEqual(items.filter { $0.kind == .new || $0.kind == .replaced }.count, 0,
                       "a changed modification time alone uploads nothing")
        XCTAssertTrue(parser.errorLines.isEmpty, "\(parser.errorLines)")
    }

    func testStatsNamesAcceptStringsAndObjects() {
        let named: [String: Any] = ["name": "c.txt"]
        let unnamed: [String: Any] = ["x": 1]
        let mixed: [Any] = ["a/b.txt", named, 3, unnamed, ""]
        XCTAssertEqual(RcloneLogParser.names(mixed), ["a/b.txt", "c.txt"])
        XCTAssertEqual(RcloneLogParser.names(nil), [])
        XCTAssertEqual(RcloneLogParser.names("not a list"), [])
        XCTAssertNil(SyncProgress().checksFraction)
    }

    func testGarbageIsIgnored() {
        let parser = RcloneLogParser()
        let junk: [String] = ["", "   ", "hello", "{", "{\"stats\": 5}", "[1,2,3]", "{\"msg\": 7, \"level\": []}",
                              "{\"level\":\"info\",\"msg\":\"Copied (new)\"}", "\u{0}\u{1}",
                              "{\"stats\":{\"bytes\":\"many\",\"transferring\":[1, {\"x\":2}, {\"name\":3}]}}"]
        for line in junk { parser.consume(line: line) }
        XCTAssertEqual(parser.progress.uploaded, 0)
        XCTAssertEqual(parser.progress.currentFiles, [])
        XCTAssertTrue(parser.errorLines.isEmpty)
        XCTAssertFalse(parser.sawAuthProblem)
        XCTAssertFalse(parser.sawThrottle)
    }

    func testConsumeTextSplitsLines() throws {
        let text = try Fixtures.lines("01_initial_sync").joined(separator: "\n")
        let parser = RcloneLogParser()
        parser.consume(text: text)
        XCTAssertEqual(parser.progress.uploaded, 32)
    }

    func testReplacementIsListedOnce() {
        let lines: [String] = [
            #"{"level":"notice","msg":"Skipped move into backup dir as --dry-run is set (size 10)","skipped":"move into backup dir","size":10,"object":"Docs/a.txt"}"#,
            #"{"level":"notice","msg":"Skipped copy as --dry-run is set (size 12)","skipped":"copy","size":12,"object":"Docs/a.txt"}"#,
            #"{"level":"notice","msg":"Skipped copy as --dry-run is set (size 5)","skipped":"copy","size":5,"object":"Docs/b.txt"}"#,
            #"{"level":"notice","msg":"Skipped move into backup dir as --dry-run is set (size 7)","skipped":"move into backup dir","size":7,"object":"Old/c.txt"}"#,
        ]
        let parser = RcloneLogParser()
        for l in lines { parser.consume(line: l) }
        let items = parser.changeItems
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.filter { $0.kind == .replaced }.map { $0.path }, ["Docs/a.txt"])
        XCTAssertEqual(items.filter { $0.kind == .replaced }.first?.size, 12)
        XCTAssertEqual(items.filter { $0.kind == .new }.map { $0.path }, ["Docs/b.txt"])
        XCTAssertEqual(items.filter { $0.kind == .removed }.map { $0.path }, ["Old/c.txt"])
        XCTAssertEqual(parser.dryRunUploadBytes, 17)
    }

    func testReplacedUploadEvent() {
        let parser = RcloneLogParser()
        let events = parser.consume(line: #"{"level":"info","msg":"Copied (replaced existing)","size":9,"object":"x/y.txt"}"#)
        XCTAssertEqual(events, [.uploaded(path: "x/y.txt", replaced: true, size: 9)])
    }

    func testThrottleDetectionAndRecovery() {
        let parser = RcloneLogParser()
        // A file name containing 429 is not throttling.
        parser.consume(line: #"{"level":"info","msg":"Copied (new)","size":1,"object":"Photos/IMG_4290.jpg"}"#)
        parser.consume(line: #"{"level":"info","msg":"Moved (server-side) to: B/img_429.jpg","object":"A/img_429.jpg"}"#)
        XCTAssertFalse(parser.sawThrottle)

        let events = parser.consume(line: #"{"level":"notice","msg":"Too many requests. Trying again in 30 seconds."}"#)
        XCTAssertTrue(events.contains(where: { if case .throttled = $0 { return true }; return false }))
        XCTAssertTrue(parser.progress.isThrottled)

        parser.consume(line: #"{"level":"error","msg":"HTTP error 429 (429 Too Many Requests) returned body"}"#)
        parser.consume(line: #"{"level":"info","msg":"stats","stats":{"bytes":0}}"#)
        XCTAssertTrue(parser.progress.isThrottled, "still throttled: a throttle line arrived since the last stats")
        parser.consume(line: #"{"level":"info","msg":"stats","stats":{"bytes":100}}"#)
        XCTAssertFalse(parser.progress.isThrottled, "bytes moved again with no new complaints")
        XCTAssertTrue(parser.sawThrottle)
    }

    func testAuthProblemDetected() {
        let parser = RcloneLogParser()
        let events = parser.consume(line: #"{"level":"error","msg":"Failed to create file system for \"remote:\": couldn't fetch token: invalid_grant: AADSTS70000"}"#)
        XCTAssertTrue(parser.sawAuthProblem)
        XCTAssertTrue(events.contains(where: { if case .authProblem = $0 { return true }; return false }))
        XCTAssertEqual(parser.errorLines.count, 1)

        let plain = RcloneLogParser()
        plain.consume(line: "2026/01/01 10:00:00 CRITICAL: Failed to create file system: couldn't fetch token - maybe it has expired? - refresh with \"rclone config reconnect remote:\"")
        XCTAssertTrue(plain.sawAuthProblem)
        XCTAssertEqual(plain.errorLines.count, 1)
    }
}
