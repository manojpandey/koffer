import Foundation

public struct ErrorClassification: Equatable {
    /// One plain-words sentence for the user. Empty when the run succeeded.
    public var message: String
    public var needsReconnect: Bool
    public var sourceMissing: Bool
    public var networkLikely: Bool
    public var throttled: Bool

    public init(message: String, needsReconnect: Bool = false, sourceMissing: Bool = false,
                networkLikely: Bool = false, throttled: Bool = false) {
        self.message = message; self.needsReconnect = needsReconnect; self.sourceMissing = sourceMissing
        self.networkLikely = networkLikely; self.throttled = throttled
    }
}

/// Turns an rclone exit code and its error lines into one sentence and a few flags.
public enum ErrorClassifier {
    public static let reconnectMessage = "OneDrive needs you to sign in again"
    public static let unpluggedMessage = "The disk was unplugged"
    public static let networkMessage = "The internet connection dropped"

    static let networkNeedles: [String] = [
        "no such host", "connection refused", "connection reset", "network is unreachable",
        "network is down", "i/o timeout", "tls handshake timeout", "dial tcp", "context deadline exceeded",
        "temporary failure in name resolution", "no route to host", "broken pipe", "unexpected eof",
        "the internet connection appears to be offline", "server misbehaving",
    ]

    static let spaceNeedles: [String] = ["quotalimitreached", "insufficient storage", "insufficientstorage",
                                         "quota exceeded", "not enough space", "no space left"]

    public static func classify(exitCode: Int32, errorLines: [String], sawAuthProblem: Bool = false,
                                sawThrottle: Bool = false) -> ErrorClassification {
        let joined = errorLines.joined(separator: "\n").lowercased()
        let auth = sawAuthProblem || RcloneLogParser.looksLikeAuthProblem(joined)
        let throttled = sawThrottle || RcloneLogParser.looksLikeThrottle(joined)
        let sourceMissing = joined.contains("error reading source root directory")
            || (exitCode == 3 && joined.contains("directory not found"))
        var network = false
        for n in networkNeedles where joined.contains(n) { network = true; break }
        var full = false
        for n in spaceNeedles where joined.contains(n) { full = true; break }

        if exitCode == 0 {
            return ErrorClassification(message: "", throttled: throttled)
        }
        if auth {
            return ErrorClassification(message: reconnectMessage, needsReconnect: true, throttled: throttled)
        }
        if sourceMissing {
            return ErrorClassification(message: unpluggedMessage, sourceMissing: true, throttled: throttled)
        }
        if network {
            return ErrorClassification(message: networkMessage, networkLikely: true, throttled: throttled)
        }
        if full {
            return ErrorClassification(message: "The cloud storage is full", throttled: throttled)
        }
        if let first = firstMeaningfulLine(errorLines) {
            return ErrorClassification(message: "rclone stopped with an error: \(first)", throttled: throttled)
        }
        if throttled {
            return ErrorClassification(message: "OneDrive kept slowing us down. Try again later", throttled: true)
        }
        return ErrorClassification(message: "rclone stopped with an error (code \(exitCode))", throttled: throttled)
    }

    /// The first error line that says something specific (skips the generic retry/summary lines).
    static func firstMeaningfulLine(_ lines: [String]) -> String? {
        let generic: [String] = ["attempt ", "not deleting files as there were io errors",
                                 "not deleting directories as there were io errors"]
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let lower = line.lowercased()
            var isGeneric = false
            for g in generic where lower.hasPrefix(g) { isGeneric = true; break }
            if !isGeneric { return line }
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { return line }
        }
        return nil
    }
}
