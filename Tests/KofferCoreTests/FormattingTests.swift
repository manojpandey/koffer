import XCTest
@testable import KofferCore

final class FormattingTests: XCTestCase {

    // MARK: - bytes

    func testBytesZeroAndTiny() {
        XCTAssertEqual(Format.bytes(0), "0 KB")
        XCTAssertEqual(Format.bytes(1), "1 KB")
        XCTAssertEqual(Format.bytes(999), "1 KB")
    }

    func testBytesKilobytes() {
        XCTAssertEqual(Format.bytes(12_000), "12 KB")
        XCTAssertEqual(Format.bytes(12_345), "12 KB")
    }

    func testBytesMegabytes() {
        XCTAssertEqual(Format.bytes(340_000_000), "340 MB")
        XCTAssertEqual(Format.bytes(999_999), "1 MB")
    }

    func testBytesGigabytes() {
        XCTAssertEqual(Format.bytes(1_200_000_000), "1.2 GB")
    }

    func testBytesTerabytes() {
        XCTAssertEqual(Format.bytes(1_050_000_000_000), "1.05 TB")
    }

    // MARK: - speed

    func testSpeed() {
        XCTAssertEqual(Format.speed(340_000_000), "340 MB/s")
        XCTAssertEqual(Format.speed(4_100_000), "4 MB/s")
        XCTAssertEqual(Format.speed(0), "0 KB/s")
        XCTAssertEqual(Format.speed(-5), "0 KB/s")
    }

    // MARK: - duration

    func testDuration() {
        XCTAssertEqual(Format.duration(0), "0s")
        XCTAssertEqual(Format.duration(12), "12s")
        XCTAssertEqual(Format.duration(59.9), "59s")
        XCTAssertEqual(Format.duration(245), "4m 05s")
        XCTAssertEqual(Format.duration(3_600), "1h 0m")
        XCTAssertEqual(Format.duration(11_520), "3h 12m")
        XCTAssertEqual(Format.duration(187_200), "2d 4h")
    }

    // MARK: - eta

    func testEtaEmptyWhenUnknown() {
        XCTAssertEqual(Format.eta(nil), "")
        XCTAssertEqual(Format.eta(Double.infinity), "")
        XCTAssertEqual(Format.eta(Double.nan), "")
        XCTAssertEqual(Format.eta(-5), "")
    }

    func testEtaValues() {
        XCTAssertEqual(Format.eta(0), "less than a minute left")
        XCTAssertEqual(Format.eta(59.9), "less than a minute left")
        XCTAssertEqual(Format.eta(60), "about 1m left")
        XCTAssertEqual(Format.eta(720), "about 12m left")
        XCTAssertEqual(Format.eta(9_600), "about 2h 40m left")
        XCTAssertEqual(Format.eta(187_200), "about 2d 4h left")
    }

    // MARK: - count

    func testCount() {
        XCTAssertEqual(Format.count(0), "0")
        XCTAssertEqual(Format.count(12), "12")
        XCTAssertEqual(Format.count(1_204), "1,204")
        XCTAssertEqual(Format.count(1_234_567), "1,234,567")
    }

    // MARK: - summary

    private func record(uploaded: Int, moved: Int, removed: Int, errors: Int, seconds: TimeInterval) -> RunRecord {
        let start: Date = Date(timeIntervalSince1970: 1_700_000_000)
        return RunRecord(jobID: "archive", jobName: "Archive",
                         startedAt: start, endedAt: start.addingTimeInterval(seconds),
                         outcome: .completed, uploaded: uploaded, moved: moved, removed: removed,
                         errors: errors, bytesTransferred: 0)
    }

    func testSummaryTypical() {
        let r: RunRecord = record(uploaded: 312, moved: 1_204, removed: 0, errors: 0, seconds: 11_520)
        XCTAssertEqual(Format.summary(r), "312 new files, 1,204 moved, 0 errors, 3h 12m")
    }

    func testSummarySingularAndRemoved() {
        let r: RunRecord = record(uploaded: 1, moved: 0, removed: 2, errors: 1, seconds: 12)
        XCTAssertEqual(Format.summary(r), "1 new file, 0 moved, 2 removed, 1 error, 12s")
    }

    // MARK: - relativeDay

    private func makeCalendar(_ zone: String) -> Calendar {
        var cal: Calendar = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        return cal
    }

    private func makeDate(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c: DateComponents = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min; c.second = 0
        return cal.date(from: c)!
    }

    func testRelativeDayToday() {
        let cal: Calendar = makeCalendar("UTC")
        let now: Date = makeDate(cal, 2026, 11, 26, 15, 0)
        let date: Date = makeDate(cal, 2026, 11, 26, 14, 2)
        XCTAssertEqual(Format.relativeDay(date, now: now, calendar: cal), "Today 14:02")
    }

    func testRelativeDayYesterday() {
        let cal: Calendar = makeCalendar("UTC")
        let now: Date = makeDate(cal, 2026, 11, 26, 15, 0)
        let date: Date = makeDate(cal, 2026, 11, 25, 9, 10)
        XCTAssertEqual(Format.relativeDay(date, now: now, calendar: cal), "Yesterday 09:10")
    }

    func testRelativeDayOlder() {
        let cal: Calendar = makeCalendar("UTC")
        let now: Date = makeDate(cal, 2026, 11, 26, 15, 0)
        let date: Date = makeDate(cal, 2026, 11, 12, 18, 30)
        XCTAssertEqual(Format.relativeDay(date, now: now, calendar: cal), "12 Nov 18:30")
    }

    func testRelativeDaySingleDigitDayAndSeptember() {
        let cal: Calendar = makeCalendar("UTC")
        let now: Date = makeDate(cal, 2026, 11, 26, 15, 0)
        let date: Date = makeDate(cal, 2026, 9, 3, 9, 5)
        XCTAssertEqual(Format.relativeDay(date, now: now, calendar: cal), "3 Sep 09:05")
    }

    func testRelativeDayUsesCalendarTimeZone() {
        let utc: Calendar = makeCalendar("UTC")
        let berlin: Calendar = makeCalendar("Europe/Berlin")
        // 23:30 UTC on 25 Nov is 00:30 on 26 Nov in Berlin (UTC+1 in winter).
        let date: Date = makeDate(utc, 2026, 11, 25, 23, 30)
        let now: Date = makeDate(utc, 2026, 11, 26, 12, 0)
        XCTAssertEqual(Format.relativeDay(date, now: now, calendar: berlin), "Today 00:30")
        XCTAssertEqual(Format.relativeDay(date, now: now, calendar: utc), "Yesterday 23:30")
    }

    func testRelativeDayTwoArgumentCallShape() {
        let now: Date = Date()
        let text: String = Format.relativeDay(now, now: now)
        XCTAssertTrue(text.hasPrefix("Today "))
    }
}
