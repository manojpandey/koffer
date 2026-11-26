import XCTest
@testable import KofferCore

final class PreflightTests: XCTestCase {
    func testSourceChecks() throws {
        let dir = try makeTempDirectory("koffer-preflight")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default

        XCTAssertFalse(Preflight.checkSource(dir.appendingPathComponent("missing").path).isOK)

        let file = dir.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(Preflight.checkSource(file.path).isOK)

        let empty = dir.appendingPathComponent("empty")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true, attributes: nil)
        XCTAssertFalse(Preflight.checkSource(empty.path).isOK)
        // Finder litter does not count as content.
        try Data().write(to: empty.appendingPathComponent(".DS_Store"))
        try Data().write(to: empty.appendingPathComponent("._thing"))
        XCTAssertFalse(Preflight.checkSource(empty.path).isOK)

        try Data("hi".utf8).write(to: empty.appendingPathComponent("real.txt"))
        XCTAssertEqual(Preflight.checkSource(empty.path), .ok)
    }

    func testAboutAndSizeParsing() {
        XCTAssertEqual(Preflight.parseAboutFree(#"{"total":100,"used":40,"free":60,"trashed":0}"#), 60)
        XCTAssertNil(Preflight.parseAboutFree(#"{"total":100,"used":40}"#))
        XCTAssertNil(Preflight.parseAboutFree("garbage"))
        XCTAssertEqual(Preflight.parseSizeBytes(#"{"count":3,"bytes":1234,"sizeless":0}"#), 1234)
        XCTAssertEqual(Preflight.parseSizeBytes("notice line\n{\"count\":0,\"bytes\":0}\n"), 0)
    }

    func testFreeSpaceRule() {
        XCTAssertEqual(Preflight.checkFreeSpace(freeBytes: nil, uploadBytes: 1_000), .ok)
        XCTAssertEqual(Preflight.checkFreeSpace(freeBytes: 1_100, uploadBytes: 1_000), .ok)
        XCTAssertFalse(Preflight.checkFreeSpace(freeBytes: 1_099, uploadBytes: 1_000).isOK)
        XCTAssertEqual(Preflight.checkFreeSpace(freeBytes: 0, uploadBytes: 0), .ok)
    }

    func testAboutTarget() throws {
        XCTAssertEqual(Preflight.aboutTarget(forDestination: "onedrive:Archive/x"), "onedrive:")
        let dir = try makeTempDirectory("koffer-about")
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = Preflight.aboutTarget(forDestination: dir.appendingPathComponent("not/yet/there").path)
        XCTAssertEqual(target, SafetyRules.normalizeLocal(dir.path))
    }
}
