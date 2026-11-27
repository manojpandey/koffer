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

    /// `rclone listremotes` (one "name:" per line), or with `--long` ("name: type" per line).
    public static func listRemotes(long: Bool = false) -> [String] {
        return long ? ["listremotes", "--long"] : ["listremotes"]
    }

    /// `rclone lsjson <target> --dirs-only` (the folders directly inside target).
    public static func listFolders(target: String) -> [String] {
        return ["lsjson", target, "--dirs-only", "--no-mimetype", "--no-modtime"]
    }

    /// `rclone lsjson <target> -R --files-only --no-mimetype --no-modtime` plus the sync's excludes:
    /// every file in the backup with its path and size (v0.3 "deleted in the cloud"). Read-only.
    /// Exit 3 with "directory not found" when the folder itself is gone.
    public static func listFiles(target: String) -> [String] {
        var args: [String] = ["lsjson", target, "-R", "--files-only", "--no-mimetype", "--no-modtime"]
        for pattern in excludes {
            args.append("--exclude")
            args.append(pattern)
        }
        return args
    }

    /// `rclone mkdir <target>`
    public static func mkdir(target: String) -> [String] {
        return ["mkdir", target]
    }

    /// `rclone version`
    public static func version() -> [String] {
        return ["version"]
    }

    /// `rclone config redacted <name>`: the remote's settings with every secret replaced by XXX.
    /// `remote` may be given with or without the colon.
    public static func configRedacted(remote: String) -> [String] {
        return ["config", "redacted", RcloneCommand.configName(remote)]
    }

    /// `rclone config reconnect <remote:> --auto-confirm`: signs in again, taking the default answer
    /// to every question (refresh the token: yes; use a web browser: yes).
    public static func reconnect(remote: String) -> [String] {
        return ["config", "reconnect", RcloneCommand.configName(remote) + ":", "--auto-confirm"]
    }

    /// Sign-in for a OneDrive remote that keeps the drive it already uses.
    ///
    /// `config reconnect --auto-confirm` would answer "which drive?" with the first drive Microsoft lists,
    /// which is not always the one the remote was set up with. `config update` with only `config_*` answers
    /// (rclone never saves those keys; they only answer its questions) refreshes the token the same way
    /// ("If the remote uses OAuth the token will be updated", `rclone config update --help`), and
    /// `config_type=driveid` makes rclone ask for the drive ID with the current `drive_id` as the default,
    /// which auto-confirm then takes.
    public static func reconnectKeepingOneDriveDrive(remote: String) -> [String] {
        return ["config", "update", RcloneCommand.configName(remote),
                "config_refresh_token=true", "config_is_local=true", "config_type=driveid",
                "config_drive_ok=true", "--no-output", "--auto-confirm"]
    }

    /// "onedrive:" -> "onedrive"
    public static func configName(_ remote: String) -> String {
        var r: String = remote.trimmingCharacters(in: .whitespaces)
        while r.hasSuffix(":") { r.removeLast() }
        return r
    }
}
