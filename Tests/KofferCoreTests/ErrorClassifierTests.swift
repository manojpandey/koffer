import XCTest
@testable import KofferCore

final class ErrorClassifierTests: XCTestCase {
    func testSuccess() {
        let c = ErrorClassifier.classify(exitCode: 0, errorLines: [])
        XCTAssertEqual(c.message, "")
        XCTAssertFalse(c.needsReconnect || c.sourceMissing || c.networkLikely)
    }

    func testAuth() {
        let c = ErrorClassifier.classify(exitCode: 1, errorLines: ["Failed to create file system: couldn't fetch token: invalid_grant"])
        XCTAssertTrue(c.needsReconnect)
        XCTAssertEqual(c.message, "OneDrive needs you to sign in again")
        XCTAssertTrue(ErrorClassifier.classify(exitCode: 1, errorLines: ["AADSTS700082: The refresh token has expired"]).needsReconnect)
        XCTAssertTrue(ErrorClassifier.classify(exitCode: 1, errorLines: ["x"], sawAuthProblem: true).needsReconnect)
    }

    func testSourceMissing() {
        let c = ErrorClassifier.classify(exitCode: 3, errorLines: ["error reading source root directory: directory not found"])
        XCTAssertTrue(c.sourceMissing)
        XCTAssertEqual(c.message, "The disk was unplugged")
    }

    func testNetwork() {
        let c = ErrorClassifier.classify(exitCode: 1, errorLines: ["Post \"https://graph.example/x\": dial tcp: lookup graph.example: no such host"])
        XCTAssertTrue(c.networkLikely)
        XCTAssertEqual(c.message, "The internet connection dropped")
    }

    func testThrottleFlag() {
        let c = ErrorClassifier.classify(exitCode: 7, errorLines: ["HTTP error 429 (429 Too Many Requests)"])
        XCTAssertTrue(c.throttled)
    }

    func testGenericUsesFirstSpecificLine() {
        let c = ErrorClassifier.classify(exitCode: 1, errorLines: ["Attempt 1/3 failed with 1 errors", "Failed to copy: permission denied", "later"])
        XCTAssertEqual(c.message, "rclone stopped with an error: Failed to copy: permission denied")
        XCTAssertFalse(c.needsReconnect)
        XCTAssertEqual(ErrorClassifier.classify(exitCode: 2, errorLines: []).message, "rclone stopped with an error (code 2)")
    }

    func testFixtureMissingSource() throws {
        let parser = try Fixtures.parse("05_missing_source")
        let c = ErrorClassifier.classify(exitCode: 3, errorLines: parser.errorLines,
                                         sawAuthProblem: parser.sawAuthProblem, sawThrottle: parser.sawThrottle)
        XCTAssertTrue(c.sourceMissing)
        XCTAssertFalse(c.networkLikely)
        XCTAssertFalse(c.needsReconnect)
    }
}
