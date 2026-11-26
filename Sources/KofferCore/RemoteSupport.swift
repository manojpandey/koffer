import Foundation

// v0.2 types: connection checks, the cloud folder browser, installing rclone and signing in again.

/// A plain-words problem the UI can show as is.
public struct EngineError: Error, Equatable {
    public let message: String
    public init(_ message: String) {
        self.message = message
    }
}

/// What Koffer knows about one rclone remote's connection.
public enum RemoteState: Equatable {
    case unknown
    case checking
    /// Any of the numbers may be missing: not every service reports them.
    case connected(used: Int64?, total: Int64?, free: Int64?)
    /// Plain words; e.g. "OneDrive needs you to sign in again".
    case failed(String)
}

/// A longer task the UI shows progress for (installing rclone, signing in again).
public enum TaskState: Equatable {
    case idle
    case running(String)
    case failed(String)
    case succeeded
}

/// Pure helpers for the v0.2 engine additions: parsing rclone's output and turning it into plain words.
enum RemoteParsing {
    // MARK: Parsing

    /// `rclone listremotes`: one "name:" per line. Lines without the trailing colon are ignored.
    static func parseListRemotes(_ text: String) -> [String] {
        var result: [String] = []
        for raw in text.split(whereSeparator: { (c: Character) -> Bool in c.isNewline }) {
            let line: String = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.count >= 2, line.hasSuffix(":") else { continue }
            let name: String = String(line.dropLast())
            if name.contains(":") { continue }
            if !result.contains(line) { result.append(line) }
        }
        return result
    }

    /// `rclone listremotes --long`: "name:   type" per line. Returns remote (with colon) -> type.
    /// Remote names may contain spaces but never a colon, so the first colon ends the name.
    static func parseListRemotesLong(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(whereSeparator: { (c: Character) -> Bool in c.isNewline }) {
            let line: String = String(raw)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name: String = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            let type: String = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[name + ":"] = type
        }
        return result
    }

    /// `rclone about <remote> --json`: `{"total":..., "used":..., "free":...}`, any key may be missing.
    /// Nil when the text holds no JSON object.
    static func parseAbout(_ json: String) -> (used: Int64?, total: Int64?, free: Int64?)? {
        guard let dict = jsonValue(json, opening: "{", closing: "}") as? [String: Any] else { return nil }
        return (RcloneLogParser.int64(dict["used"]), RcloneLogParser.int64(dict["total"]), RcloneLogParser.int64(dict["free"]))
    }

    /// `rclone lsjson --dirs-only`: a JSON array of objects with "Name" (and "IsDir").
    /// Returns folder names sorted case-insensitively; nil when the text is not such an array.
    static func parseFolderNames(_ json: String) -> [String]? {
        guard let array = jsonValue(json, opening: "[", closing: "]") as? [Any] else { return nil }
        var names: [String] = []
        for entry in array {
            guard let dict = entry as? [String: Any], let name = dict["Name"] as? String, !name.isEmpty else { continue }
            if let isDir = dict["IsDir"] as? Bool, !isDir { continue }
            names.append(name)
        }
        return names.sorted { (a: String, b: String) -> Bool in
            let order: ComparisonResult = a.caseInsensitiveCompare(b)
            if order == .orderedSame { return a < b }
            return order == .orderedAscending
        }
    }

    /// `rclone config redacted <name>`: true when the section has a non-empty `drive_id` line.
    static func redactedConfigHasDriveID(_ text: String) -> Bool {
        for raw in text.split(whereSeparator: { (c: Character) -> Bool in c.isNewline }) {
            let line: String = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("drive_id"), let eq = line.firstIndex(of: "=") else { continue }
            let key: String = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value: String = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if key == "drive_id" && !value.isEmpty { return true }
        }
        return false
    }

    private static func jsonValue(_ text: String, opening: Character, closing: Character) -> Any? {
        let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate log noise around the JSON.
        guard let start = trimmed.firstIndex(of: opening), let end = trimmed.lastIndex(of: closing), start <= end else { return nil }
        let slice: String = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    // MARK: Plain words

    /// "onedrive:" -> "OneDrive", "Photos Box:" -> "Photos Box".
    static func displayName(_ remote: String) -> String {
        let name: String = RcloneCommand.configName(remote)
        if name.isEmpty { return "this computer" }
        if name.lowercased() == "onedrive" { return "OneDrive" }
        return name
    }

    static func reconnectMessage(_ remote: String) -> String {
        let name: String = displayName(remote)
        if name == "OneDrive" { return ErrorClassifier.reconnectMessage }
        return "\(name) needs you to sign in again"
    }

    static func looksLikeNetworkProblem(_ text: String) -> Bool {
        let t: String = text.lowercased()
        for n in ErrorClassifier.networkNeedles where t.contains(n) { return true }
        return false
    }

    /// The most useful error line of rclone's plain-text stderr, without date and log level.
    /// Prefers "Fatal error: ...", then ERROR/CRITICAL lines, then "Error: ...", then the last line that is not usage help.
    static func lastErrorLine(_ stderr: String) -> String? {
        let lines: [String] = stderr.split(whereSeparator: { (c: Character) -> Bool in c.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines.reversed() {
            if let r = line.range(of: "Fatal error:") {
                let text: String = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return text }
            }
        }
        for line in lines.reversed() {
            if line.contains("CRITICAL:") || line.contains("ERROR :") || line.contains("ERROR:") {
                return stripLogPrefix(line)
            }
        }
        for line in lines.reversed() where line.hasPrefix("Error:") {
            let text: String = String(line.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        let usageNoise: [String] = ["Usage:", "Flags:", "-h, --help", "Use \"rclone", "rclone config"]
        for line in lines.reversed() {
            var noise = false
            for n in usageNoise where line.hasPrefix(n) { noise = true; break }
            if !noise { return stripLogPrefix(line) }
        }
        return nil
    }

    /// "2026/01/02 10:00:00 NOTICE: Failed to about: x" -> "Failed to about: x"
    static func stripLogPrefix(_ line: String) -> String {
        var text: String = line
        let levels: [String] = ["CRITICAL:", "ERROR :", "ERROR:", "NOTICE:", "WARNING:", "INFO  :", "INFO:", "DEBUG :", "DEBUG:"]
        for level in levels {
            if let r = text.range(of: level) {
                let prefix: String = String(text[..<r.lowerBound])
                // Only strip when what comes before is the timestamp ("2026/01/02 10:00:00 ") or nothing.
                if prefix.isEmpty || prefix.first?.isNumber == true {
                    text = String(text[r.upperBound...])
                    break
                }
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Turns the result of `rclone about <remote> --json` into a connection state.
    /// `isAuthProblem` is true when the failure means the user has to sign in again.
    static func remoteState(remote: String, status: Int32, stdout: String, stderr: String) -> (state: RemoteState, isAuthProblem: Bool) {
        if status == 0 {
            if let about = parseAbout(stdout) {
                return (.connected(used: about.used, total: about.total, free: about.free), false)
            }
            return (.connected(used: nil, total: nil, free: nil), false)
        }
        let all: String = stderr + "\n" + stdout
        if RcloneLogParser.looksLikeAuthProblem(all) {
            return (.failed(reconnectMessage(remote)), true)
        }
        let lower: String = all.lowercased()
        // Some services can't report space. The connection itself worked.
        if lower.contains("doesn't support about") || lower.contains("does not support about") {
            return (.connected(used: nil, total: nil, free: nil), false)
        }
        let name: String = displayName(remote)
        if status == -1 {
            return (.failed("Koffer couldn't start rclone to check \(name)"), false)
        }
        if looksLikeNetworkProblem(all) {
            return (.failed("Can't reach \(name) right now. Check the internet connection."), false)
        }
        if lower.contains("didn't find section in config file") {
            return (.failed("rclone doesn't know \(name) any more. Set it up again."), false)
        }
        if let line = lastErrorLine(stderr) {
            return (.failed("Couldn't check \(name): \(line)"), false)
        }
        return (.failed("Couldn't check \(name) (rclone stopped with code \(status))"), false)
    }

    /// Plain words for a failed `lsjson` / `mkdir`. `isAuthProblem` as above.
    static func folderError(remote: String, status: Int32, stderr: String, action: String) -> (error: EngineError, isAuthProblem: Bool) {
        if RcloneLogParser.looksLikeAuthProblem(stderr) {
            return (EngineError(reconnectMessage(remote)), true)
        }
        let name: String = displayName(remote)
        if status == -1 {
            return (EngineError("Koffer couldn't start rclone"), false)
        }
        if looksLikeNetworkProblem(stderr) {
            return (EngineError("Can't reach \(name) right now. Check the internet connection."), false)
        }
        if status == 3 || stderr.lowercased().contains("directory not found") {
            return (EngineError("That folder isn't there any more."), false)
        }
        if let line = lastErrorLine(stderr) {
            return (EngineError("Couldn't \(action): \(line)"), false)
        }
        return (EngineError("Couldn't \(action) (rclone stopped with code \(status))"), false)
    }

    /// Plain words for a failed sign-in, including rclone's own last error line.
    static func reconnectFailure(remote: String, status: Int32, stderr: String) -> String {
        let name: String = displayName(remote)
        let line: String? = lastErrorLine(stderr)
        var message: String = "Signing in to \(name) didn't work."
        let lower: String = stderr.lowercased()
        if lower.contains("address already in use") {
            message = "Another sign-in is still waiting in your browser. Close it, then try again."
        } else if lower.contains("doesn't support reconnect") {
            message = "\(name) doesn't use a sign-in, so there is nothing to renew."
        } else if lower.contains("didn't find section in config file") {
            message = "rclone doesn't know \(name) any more. Set it up again."
        } else if status == -1 {
            message = "Koffer couldn't start rclone to sign in."
        }
        if let l = line {
            return message + " rclone said: " + l
        }
        return message + " (rclone stopped with code \(status))"
    }

    // MARK: Paths

    /// Joins a remote ("onedrive:", or "" for this computer) and a folder path into an rclone target.
    /// Returns nil for a missing/invalid remote name, a relative local path, or "." / ".." parts.
    static func target(remote rawRemote: String, path rawPath: String) -> String? {
        let remote: String = rawRemote.trimmingCharacters(in: .whitespaces)
        let path: String = rawPath.trimmingCharacters(in: .whitespaces)
        if RcloneLocation.hasDotParts(path) { return nil }
        if remote.isEmpty {
            guard path.hasPrefix("/") else { return nil }
            guard let loc = RcloneLocation.parse(path), loc.isLocal else { return nil }
            return loc.path
        }
        guard remote.hasSuffix(":"), SafetyRules.isPlainRemoteName(remote) else { return nil }
        let parts: [String] = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let joined: String = remote + parts.joined(separator: "/")
        guard RcloneLocation.parse(joined) != nil else { return nil }
        return joined
    }

    /// True when some part of the folder path is empty or only spaces ("Backups/ /x", "Backups//x").
    static func hasEmptyPart(_ rawPath: String) -> Bool {
        var path: String = rawPath
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        if path.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            if part.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        }
        return false
    }

    /// "Private Papers 2024!" -> "private-papers-2024"; "" -> "backup".
    static func slug(_ name: String) -> String {
        var out: String = ""
        var lastWasDash = false
        for scalar in name.lowercased().unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash && !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "backup" : out
    }

    // MARK: Installing rclone

    /// The official download for this Mac's CPU.
    static var defaultDownloadURL: URL {
        #if arch(arm64)
        let cpu = "arm64"
        #else
        let cpu = "amd64"
        #endif
        return URL(string: "https://downloads.rclone.org/rclone-current-osx-\(cpu).zip")!
    }

    /// The first regular file called "rclone" under `directory` (the official zip has one folder with it inside).
    static func findBinary(in directory: URL, fileManager: FileManager = .default) -> URL? {
        guard let e = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [], errorHandler: nil) else { return nil }
        var found: [URL] = []
        for case let url as URL in e where url.lastPathComponent == "rclone" {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { found.append(url) }
        }
        // Shallowest first.
        found.sort { $0.pathComponents.count < $1.pathComponents.count }
        return found.first
    }
}
