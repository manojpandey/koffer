import Foundation

/// Checks that run right before rclone. An empty or missing source must never reach `rclone sync`:
/// that is what protects the cloud copy when a disk is only half mounted.
public enum Preflight {
    /// Names that do not count as content (Finder and Spotlight litter, also excluded from the sync).
    static func isIgnorable(_ name: String) -> Bool {
        if name == ".DS_Store" || name == ".Spotlight-V100" || name == ".Trashes" || name == ".fseventsd"
            || name == ".TemporaryItems" || name == ".DocumentRevisions-V100" {
            return true
        }
        return name.hasPrefix("._")
    }

    public static func checkSource(_ path: String, fileManager: FileManager = .default) -> SafetyVerdict {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .refused("The folder to back up can't be found. Is the disk plugged in?")
        }
        guard isDirectory.boolValue else {
            return .refused("The thing to back up is a file, not a folder.")
        }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: path)
        } catch {
            return .refused("The folder to back up can't be read.")
        }
        let real: [String] = names.filter { !isIgnorable($0) }
        if real.isEmpty {
            return .refused("The folder to back up is empty, so nothing was sent. This protects the cloud copy.")
        }
        return .ok
    }

    /// `free` from `rclone about --json`, nil when missing or unparseable.
    public static func parseAboutFree(_ json: String) -> Int64? {
        guard let dict = jsonObject(json) else { return nil }
        return RcloneLogParser.int64(dict["free"])
    }

    /// `bytes` from `rclone size --json`, nil when missing or unparseable.
    public static func parseSizeBytes(_ json: String) -> Int64? {
        guard let dict = jsonObject(json) else { return nil }
        return RcloneLogParser.int64(dict["bytes"])
    }

    /// Requires free >= upload * 1.10. Unknown free space (nil) passes.
    public static func checkFreeSpace(freeBytes: Int64?, uploadBytes: Int64) -> SafetyVerdict {
        guard let free = freeBytes else { return .ok }
        if uploadBytes <= 0 { return .ok }
        let needed = Int64((Double(uploadBytes) * 1.10).rounded(.up))
        if free >= needed { return .ok }
        return .refused("Not enough space in the cloud: this backup needs about \(Format.bytes(needed)) but only \(Format.bytes(free)) is free.")
    }

    /// What to pass to `rclone about` for a destination: the remote name ("onedrive:"), or for a local
    /// destination the closest folder that already exists.
    public static func aboutTarget(forDestination destination: String, fileManager: FileManager = .default) -> String? {
        guard let loc = RcloneLocation.parse(destination) else { return nil }
        if !loc.isLocal { return loc.remote }
        var path = loc.path
        while !path.isEmpty {
            if fileManager.fileExists(atPath: path) { return path }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { break }
            path = parent
        }
        return "/"
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate log noise before the JSON object.
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end else { return nil }
        let slice = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }
}
