import Foundation

/// Builds rclone argument arrays. Arguments go straight to Process (no shell), so spaces are fine.
public enum RcloneCommand {
    public static let excludes: [String] = [".DS_Store", "._*", ".Spotlight-V100/**", ".Trashes/**"]

    /// "yyyy-MM-dd_HHmm" in the given time zone (Gregorian calendar, so it is stable whatever the user's calendar is).
    public static func stamp(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c: DateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let year: Int = c.year ?? 1970
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        return String(format: "%04d-%02d-%02d_%02d%02d", year, month, day, hour, minute)
    }

    /// Joins a folder and a child name without doubling slashes ("onedrive:" + "x" -> "onedrive:x").
    public static func join(_ base: String, _ child: String) -> String {
        var b = base
        while b.count > 1 && b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix(":") || b.hasSuffix("/") { return b + child }
        return b + "/" + child
    }

    public static func backupDir(removedRoot: String, date: Date, timeZone: TimeZone = .current) -> String {
        return join(removedRoot, stamp(for: date, timeZone: timeZone))
    }

    /// The sync command, exactly as agreed. Never contains --delete-before.
    public static func sync(job: SyncJob, dryRun: Bool, date: Date = Date(), timeZone: TimeZone = .current) -> [String] {
        var args: [String] = ["sync", job.source, job.destination,
                              "--track-renames",
                              "--backup-dir", backupDir(removedRoot: job.removedRoot, date: date, timeZone: timeZone)]
        for pattern in excludes {
            args.append("--exclude")
            args.append(pattern)
        }
        args.append(contentsOf: ["--transfers", "4", "--checkers", "16",
                                 "--use-json-log", "--stats", "2s", "--log-level", "INFO"])
        if dryRun { args.append("--dry-run") }
        return args
    }

    /// `rclone about <remote> --json`
    public static func about(remote: String) -> [String] {
        return ["about", remote, "--json"]
    }

    /// `rclone size <path> --json`
    public static func size(path: String) -> [String] {
        return ["size", path, "--json"]
    }

    /// `rclone purge <path>`
    public static func purge(path: String) -> [String] {
        return ["purge", path]
    }
}
