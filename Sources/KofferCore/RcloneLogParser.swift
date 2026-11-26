import Foundation

/// One thing the parser noticed in a line of rclone's JSON log.
public enum RcloneLogEvent: Equatable {
    /// A stats object was read; `SyncProgress` was updated.
    case stats
    /// A file was uploaded. `replaced` is true when it overwrote an existing cloud file.
    case uploaded(path: String, replaced: Bool, size: Int64?)
    /// A file was moved server-side (from --track-renames).
    case moved(from: String, to: String)
    /// A file was moved into the removed-items folder.
    case removed(path: String)
    /// The cloud is rate-limiting us; rclone backs off on its own.
    case throttled(String)
    /// The login looks expired or revoked.
    case authProblem(String)
    /// An error line (message only).
    case error(String)
    /// A dry-run line ("would ..."). Copies come through as `.new`; classification happens in `changeItems`.
    case dryRunItem(ChangeItem)
}

/// Line-oriented, tolerant parser for `rclone --use-json-log`. Never throws; unknown lines are ignored.
/// Not thread-safe: feed it from one place (the engine does this on the main actor).
public final class RcloneLogParser {
    public private(set) var progress: SyncProgress = SyncProgress()
    /// Error messages in the order seen.
    public private(set) var errorLines: [String] = []
    public private(set) var sawAuthProblem: Bool = false
    public private(set) var sawThrottle: Bool = false
    /// True once any stats object has been read.
    public private(set) var sawStats: Bool = false
    /// `lastError` from the most recent stats object, if any.
    public private(set) var lastStatsError: String?
    /// Real-run "Moved into backup dir" lines. rclone counts these as renames too, so they are
    /// subtracted from `stats.renames` to get the number of real moves.
    public private(set) var backupDirMoves: Int = 0
    /// Counts of per-file events seen (useful when no stats line arrived).
    public private(set) var uploadEvents: Int = 0
    public private(set) var moveEvents: Int = 0

    // Dry-run bookkeeping. `dryOrder` keeps first appearance as "C|path", "B|path", "D|path", "M|path".
    private var dryOrder: [String] = []
    private var dryOrderSet: Set<String> = []
    private var dryCopyPaths: Set<String> = []
    private var dryBackupPaths: Set<String> = []
    private var dryDeletePaths: Set<String> = []
    private var drySizes: [String: Int64] = [:]   // key = "C|path" etc.
    private var dryMoves: [ChangeItem] = []

    private var bytesAtThrottle: Int64 = 0
    private var throttleLinesSinceStats: Int = 0
    private var lastRenames: Int = 0

    public init() {}

    // MARK: - Feeding

    /// Feeds one line (without the newline). Returns what it noticed.
    @discardableResult
    public func consume(line rawLine: String) -> [RcloneLogEvent] {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return [] }
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            return consumePlain(line)
        }
        return consumeJSON(dict)
    }

    /// Feeds a whole chunk of text (several lines).
    @discardableResult
    public func consume(text: String) -> [RcloneLogEvent] {
        var events: [RcloneLogEvent] = []
        for part in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            events.append(contentsOf: consume(line: String(part)))
        }
        return events
    }

    // MARK: - Results

    /// Dry-run changes. A copy whose path also goes "into backup dir" is a replacement (listed once);
    /// other backup-dir moves are removals.
    public var changeItems: [ChangeItem] {
        var uploads: [ChangeItem] = []
        var removals: [ChangeItem] = []
        for key in dryOrder {
            let path = String(key.dropFirst(2))
            let size: Int64? = drySizes[key]
            if key.hasPrefix("C|") {
                let kind: ChangeKind = dryBackupPaths.contains(path) ? .replaced : .new
                uploads.append(ChangeItem(kind: kind, path: path, size: size))
            } else if key.hasPrefix("B|") {
                if dryCopyPaths.contains(path) { continue }
                removals.append(ChangeItem(kind: .removed, path: path, size: size))
            } else if key.hasPrefix("D|") {
                if dryCopyPaths.contains(path) || dryBackupPaths.contains(path) { continue }
                removals.append(ChangeItem(kind: .removed, path: path, size: size))
            }
        }
        // New/replaced first, then moves in the order rclone reported them, then removals.
        var result: [ChangeItem] = uploads
        result.append(contentsOf: dryMoves)
        result.append(contentsOf: removals)
        return result
    }

    /// Bytes a dry run says would be uploaded (new + replaced).
    public var dryRunUploadBytes: Int64 {
        return changeItems.filter { $0.kind == .new || $0.kind == .replaced }.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
    }

    // MARK: - Internals

    private func consumePlain(_ line: String) -> [RcloneLogEvent] {
        var events: [RcloneLogEvent] = []
        if RcloneLogParser.looksLikeAuthProblem(line) {
            sawAuthProblem = true
            events.append(.authProblem(line))
        }
        if RcloneLogParser.looksLikeThrottle(line) {
            noteThrottle()
            events.append(.throttled(line))
        }
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("fatal") {
            errorLines.append(line)
            events.append(.error(line))
        }
        return events
    }

    private func consumeJSON(_ dict: [String: Any]) -> [RcloneLogEvent] {
        var events: [RcloneLogEvent] = []
        let msg: String = (dict["msg"] as? String) ?? ""
        let level: String = ((dict["level"] as? String) ?? "").lowercased()
        let object: String? = dict["object"] as? String
        let size: Int64? = RcloneLogParser.int64(dict["size"])

        if let stats = dict["stats"] as? [String: Any] {
            applyStats(stats)
            events.append(.stats)
            return events
        }

        // Dry-run lines carry a "skipped" field.
        if let skipped = dict["skipped"] as? String, let path = object {
            if let item = noteDryRun(skipped: skipped, path: path, size: size) {
                events.append(.dryRunItem(item))
            }
            return events
        }

        // Per-file lines of a real run.
        if let path = object {
            if msg == "Copied (new)" {
                uploadEvents += 1
                events.append(.uploaded(path: path, replaced: false, size: size))
                return events
            }
            if msg == "Copied (replaced existing)" {
                uploadEvents += 1
                events.append(.uploaded(path: path, replaced: true, size: size))
                return events
            }
            if msg.hasPrefix("Moved (server-side) to: ") {
                let to = String(msg.dropFirst("Moved (server-side) to: ".count))
                moveEvents += 1
                events.append(.moved(from: path, to: to))
                return events
            }
            if msg == "Moved into backup dir" {
                backupDirMoves += 1
                events.append(.removed(path: path))
                return events
            }
            if msg == "Deleted" {
                events.append(.removed(path: path))
                return events
            }
            if msg.hasPrefix("Moved (server-side)") || msg.hasPrefix("Renamed from")
                || msg.hasPrefix("Set directory modification time") || msg.hasPrefix("Removing directory")
                || msg.hasPrefix("Making map for") || msg.hasPrefix("Finished making map") {
                return events
            }
        }

        let isErrorLevel = level == "error" || level == "critical" || level == "alert" || level == "emergency" || level == "fatal"
        let isWarnLevel = level == "warning" || level == "notice"
        let checkText = msg + " " + (object ?? "")
        if isErrorLevel || isWarnLevel || level.isEmpty {
            if RcloneLogParser.looksLikeAuthProblem(checkText) {
                sawAuthProblem = true
                events.append(.authProblem(msg))
            }
            if RcloneLogParser.looksLikeThrottle(checkText) {
                noteThrottle()
                events.append(.throttled(msg))
            }
        }
        if isErrorLevel || msg.hasPrefix("Failed to ") {
            let text = msg.isEmpty ? checkText.trimmingCharacters(in: .whitespaces) : msg
            if !text.isEmpty {
                errorLines.append(text)
                events.append(.error(text))
            }
        }
        return events
    }

    private func noteThrottle() {
        sawThrottle = true
        if !progress.isThrottled { bytesAtThrottle = progress.bytesDone }
        progress.isThrottled = true
        throttleLinesSinceStats += 1
    }

    private func noteDryRun(skipped: String, path: String, size: Int64?) -> ChangeItem? {
        if skipped == "copy" {
            remember(key: "C|" + path, size: size)
            dryCopyPaths.insert(path)
            return ChangeItem(kind: .new, path: path, size: size)
        }
        if skipped.hasPrefix("move to ") {
            let to = String(skipped.dropFirst("move to ".count))
            let item = ChangeItem(kind: .moved, path: path, newPath: to, size: size)
            dryMoves.append(item)
            return item
        }
        if skipped == "move into backup dir" {
            remember(key: "B|" + path, size: size)
            dryBackupPaths.insert(path)
            return ChangeItem(kind: .removed, path: path, size: size)
        }
        if skipped == "delete" {
            remember(key: "D|" + path, size: size)
            dryDeletePaths.insert(path)
            return ChangeItem(kind: .removed, path: path, size: size)
        }
        return nil
    }

    private func remember(key: String, size: Int64?) {
        if !dryOrderSet.contains(key) {
            dryOrderSet.insert(key)
            dryOrder.append(key)
        }
        if let s = size { drySizes[key] = s }
    }

    private func applyStats(_ s: [String: Any]) {
        sawStats = true
        var p = progress
        if let v = RcloneLogParser.int64(s["bytes"]) { p.bytesDone = v }
        if let v = RcloneLogParser.int64(s["totalBytes"]) { p.bytesTotal = v }
        if let v = RcloneLogParser.int(s["transfers"]) { p.filesDone = v; p.uploaded = v }
        if let v = RcloneLogParser.int(s["totalTransfers"]) { p.filesTotal = v }
        if let v = RcloneLogParser.int(s["checks"]) { p.checksDone = v }
        if let v = RcloneLogParser.int(s["totalChecks"]) { p.checksTotal = v }
        if let v = RcloneLogParser.double(s["speed"]) { p.speed = v }
        p.etaSeconds = RcloneLogParser.double(s["eta"])
        if let v = RcloneLogParser.double(s["elapsedTime"]) { p.elapsed = v }
        if let v = RcloneLogParser.int(s["renames"]) { lastRenames = v }
        p.moved = max(0, lastRenames - backupDirMoves)
        if let v = RcloneLogParser.int(s["deletes"]) { p.removed = v }
        if let v = RcloneLogParser.int(s["errors"]) { p.errors = v }
        if let e = s["lastError"] as? String, !e.isEmpty { lastStatsError = e }
        var names: [String] = []
        if let list = s["transferring"] as? [Any] {
            for entry in list {
                if let d = entry as? [String: Any], let name = d["name"] as? String { names.append(name) }
            }
        }
        p.currentFiles = names
        // Throttling ends once bytes move again with no new throttle complaints.
        if p.isThrottled && throttleLinesSinceStats == 0 && p.bytesDone > bytesAtThrottle {
            p.isThrottled = false
        }
        throttleLinesSinceStats = 0
        progress = p
    }

    // MARK: - Pattern helpers (also used by ErrorClassifier)

    static func looksLikeAuthProblem(_ text: String) -> Bool {
        let t = text.lowercased()
        let needles: [String] = ["invalid_grant", "couldn't fetch token", "could not fetch token", "token expired",
                                 "aadsts", "unauthenticated", "invalidauthenticationtoken", "token has expired"]
        for n in needles where t.contains(n) { return true }
        return false
    }

    static func looksLikeThrottle(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.contains("too many requests") || t.contains("throttl") || t.contains("pacer: low level retry") {
            return true
        }
        // "429" as a standalone number (not part of a file name like img_4291.jpg).
        let chars: [Character] = Array(t)
        if chars.count < 3 { return false }
        var i = 0
        while i + 3 <= chars.count {
            if chars[i] == "4" && chars[i + 1] == "2" && chars[i + 2] == "9" {
                let before: Character? = i > 0 ? chars[i - 1] : nil
                let after: Character? = i + 3 < chars.count ? chars[i + 3] : nil
                if !isNameCharacter(before) && !isNameCharacter(after) { return true }
            }
            i += 1
        }
        return false
    }

    private static func isNameCharacter(_ c: Character?) -> Bool {
        guard let ch = c else { return false }
        return ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == "-" || ch == "/"
    }

    static func double(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func int64(_ any: Any?) -> Int64? {
        guard let d = double(any) else { return nil }
        if d >= Double(Int64.max) || d <= Double(Int64.min) { return nil }
        return Int64(d.rounded())
    }

    static func int(_ any: Any?) -> Int? {
        guard let v = int64(any) else { return nil }
        if v > Int64(Int.max) || v < Int64(Int.min) { return nil }
        return Int(v)
    }
}
