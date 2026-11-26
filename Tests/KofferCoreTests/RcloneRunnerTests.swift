import XCTest
@testable import KofferCore

final class RcloneRunnerTests: XCTestCase {
    func testLineSplitterCarriesPartialLines() {
        let s = LineSplitter()
        XCTAssertEqual(s.append(Data("ab".utf8)), [])
        XCTAssertEqual(s.append(Data("c\nde\r\nf".utf8)), ["abc", "de"])
        XCTAssertEqual(s.append(Data("\n\n".utf8)), ["f", ""])
        XCTAssertEqual(s.append(Data("tail".utf8)), [])
        XCTAssertEqual(s.flush(), ["tail"])
        XCTAssertEqual(s.flush(), [])
    }

    @MainActor
    func testRunDeliversLinesInOrderAndTeesToLog() async throws {
        let dir = try makeTempDirectory("koffer-runner")
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("run.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: nil)
        let handle = try FileHandle(forWritingTo: logURL)

        var received: [String] = []
        let script = "i=0; while [ $i -lt 300 ]; do echo line$i 1>&2; i=$((i+1)); done; printf 'out\\n'; printf 'partial' 1>&2; exit 3"
        let runner = RcloneRunner(executablePath: "/bin/sh", arguments: ["-c", script], logHandles: [handle],
                                  onLine: { (line: String) in received.append(line) })
        let status = await runner.run()
        try handle.close()

        XCTAssertEqual(status, 3)
        let errLines = received.filter { $0.hasPrefix("line") }
        XCTAssertEqual(errLines, (0..<300).map { "line\($0)" })
        XCTAssertTrue(received.contains("out"))
        XCTAssertTrue(received.contains("partial"))
        let logged = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(logged.contains("line299\n"))
        XCTAssertTrue(logged.contains("partial"))
    }

    func testCaptureCollectsBothStreams() async {
        let result = await RcloneRunner.capture(executablePath: "/bin/sh",
                                                arguments: ["-c", "echo '{\"free\": 5}'; echo oops 1>&2"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(Preflight.parseAboutFree(result.stdout), 5)
        XCTAssertTrue(result.stderr.contains("oops"))
    }

    func testMissingExecutable() async {
        let result = await RcloneRunner.capture(executablePath: "/nope/rclone", arguments: [])
        XCTAssertEqual(result.status, -1)
    }

    @MainActor
    func testInterruptStopsTheProcess() async {
        let runner = RcloneRunner(executablePath: "/bin/sleep", arguments: ["30"])
        let started = Date()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            runner.interrupt(grace: 2)
        }
        let status = await runner.run()
        XCTAssertNotEqual(status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
