import Foundation

/// Plain-words number and date formatting used everywhere the user sees a number.
/// Decimal units like Finder: 1 KB = 1000 bytes.
public enum Format {

    // MARK: - Sizes

    /// "0 KB", "12 KB", "340 MB", "1.2 GB", "1.05 TB".
    public static func bytes(_ n: Int64) -> String {
        if n <= 0 { return "0 KB" }
        if n < 1000 { return "1 KB" }

        let value: Double = Double(n)

        let kb: Double = (value / 1_000.0).rounded()
        if kb < 1000 { return "\(Int(kb)) KB" }

        let mb: Double = (value / 1_000_000.0).rounded()
        if mb < 1000 { return "\(Int(mb)) MB" }

        let gb: Double = value / 1_000_000_000.0
        if (gb * 10.0).rounded() < 10_000.0 {
            return String(format: "%.1f GB", gb)
        }

        let tb: Double = value / 1_000_000_000_000.0
        return String(format: "%.2f TB", tb)
    }

    /// "4 MB/s"
    public static func speed(_ bytesPerSecond: Double) -> String {
        var v: Double = bytesPerSecond
        if !v.isFinite || v < 0 { v = 0 }
        if v > 9.0e18 { v = 9.0e18 }
        return bytes(Int64(v)) + "/s"
    }

    // MARK: - Time

    /// "12s", "4m 05s", "3h 12m", "2d 4h"
    public static func duration(_ t: TimeInterval) -> String {
        let total: Int = wholeSeconds(t)
        let days: Int = total / 86_400
        let hours: Int = (total % 86_400) / 3_600
        let minutes: Int = (total % 3_600) / 60
        let seconds: Int = total % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 {
            let secondsText: String = seconds < 10 ? "0\(seconds)" : "\(seconds)"
            return "\(minutes)m \(secondsText)s"
        }
        return "\(seconds)s"
    }

    /// "about 2h 40m left", "less than a minute left", or "" when unknown.
    public static func eta(_ seconds: Double?) -> String {
        guard let s: Double = seconds, s.isFinite, s >= 0 else { return "" }
        if s < 60 { return "less than a minute left" }

        let total: Int = wholeSeconds(s)
        let days: Int = total / 86_400
        let hours: Int = (total % 86_400) / 3_600
        let minutes: Int = (total % 3_600) / 60

        let text: String
        if days > 0 {
            text = "\(days)d \(hours)h"
        } else if hours > 0 {
            text = "\(hours)h \(minutes)m"
        } else {
            text = "\(minutes)m"
        }
        return "about " + text + " left"
    }

    // MARK: - Counts

    /// "1,204" (always a comma, whatever the Mac's region is).
    public static func count(_ n: Int) -> String {
        let formatter: NumberFormatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.maximumFractionDigits = 0
        if let text: String = formatter.string(from: NSNumber(value: n)) {
            return text
        }
        return String(n)
    }

    /// "312 new files, 1,204 moved, 0 errors, 3h 12m"
    public static func summary(_ r: RunRecord) -> String {
        let newPart: String = r.uploaded == 1 ? "1 new file" : count(r.uploaded) + " new files"
        var text: String = newPart + ", " + count(r.moved) + " moved"
        if r.removed > 0 {
            text += ", " + count(r.removed) + " removed"
        }
        let errorsPart: String = r.errors == 1 ? "1 error" : count(r.errors) + " errors"
        text += ", " + errorsPart
        text += ", " + duration(r.duration)
        return text
    }

    // MARK: - Dates

    /// "Today 14:02", "Yesterday 09:10", otherwise "12 Nov 18:30" (24-hour clock).
    /// Pass a calendar to control the time zone (tests do); the default is the current one.
    public static func relativeDay(_ date: Date, now: Date, calendar: Calendar = Calendar.current) -> String {
        let timeFormatter: DateFormatter = makeFormatter("HH:mm", calendar: calendar)

        if calendar.isDate(date, inSameDayAs: now) {
            return "Today " + timeFormatter.string(from: date)
        }
        if let yesterday: Date = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday " + timeFormatter.string(from: date)
        }
        let fullFormatter: DateFormatter = makeFormatter("d MMM HH:mm", calendar: calendar)
        return fullFormatter.string(from: date)
    }

    // MARK: - Private

    private static func makeFormatter(_ pattern: String, calendar: Calendar) -> DateFormatter {
        let formatter: DateFormatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // Fixed locale so month names ("Sep") and the 24-hour clock never vary by region.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }

    private static func wholeSeconds(_ t: Double) -> Int {
        if !t.isFinite || t <= 0 { return 0 }
        if t > 1.0e12 { return 1_000_000_000_000 }
        return Int(t.rounded(.down))
    }
}
