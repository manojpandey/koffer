import Foundation

// v0.3: "Deleted in the cloud". Pure types and checks; the engine wiring lives in SyncEngine.swift.

/// Files that were deleted in the cloud copy since the last clean backup but are still on this disk.
/// Nothing happens to them until the owner decides (see `SyncEngine.applyCloudDeletions(jobID:)`).
public struct CloudDeletionReport: Equatable {
    public let jobID: String
    public let detectedAt: Date
    /// Kind `.removed`, path relative to the job's folder, size in bytes. Sorted by path.
    public let items: [ChangeItem]
    public let totalBytes: Int64
    /// Files in the cloud that are neither in the last record nor on this disk (added or renamed in the cloud).
    /// The next backup moves them into the removed-items folder.
    public let extrasCount: Int
    /// A large share of the backup: Koffer won't delete these from the disk; the owner can only put them back.
    public let looksLikeMassRemoval: Bool

    public init(jobID: String, detectedAt: Date, items: [ChangeItem], totalBytes: Int64,
                extrasCount: Int, looksLikeMassRemoval: Bool) {
        self.jobID = jobID
        self.detectedAt = detectedAt
        self.items = items
        self.totalBytes = totalBytes
        self.extrasCount = extrasCount
        self.looksLikeMassRemoval = looksLikeMassRemoval
    }
}

/// What was in the cloud copy right after the last backup that ended cleanly (exit 0, no errors).
struct CloudManifest: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// Relative to the destination folder, as `rclone lsjson -R` prints it.
        var path: String
        /// Bytes; -1 when the service doesn't know.
        var size: Int64
    }

    /// The job's destination when the listing was made. A manifest only counts for a job with this destination.
    var destination: String
    /// When the backup that produced this listing started. A local file changed after this is not a candidate.
    var date: Date
    var files: [Entry]

    /// Bytes of all files with a known size.
    var totalBytes: Int64 {
        var total: Int64 = 0
        for entry in files where entry.size > 0 { total += entry.size }
        return total
    }
}

/// Size and modification date of a regular file on this disk.
struct LocalFileInfo: Equatable {
    var size: Int64
    var modified: Date
}

/// Reads and writes `<directory>/<jobID>.json`.
struct ManifestStore {
    let directory: URL

    func url(jobID: String) -> URL {
        let bad: Set<Character> = ["/", ":", "\\"]
        var name: String = String(jobID.map { bad.contains($0) ? "_" : $0 })
        if name.isEmpty || name.hasPrefix(".") { name = "_" + name }
        return directory.appendingPathComponent(name + ".json", isDirectory: false)
    }

    /// The manifest for this job, or nil when there is none, it can't be read, or it belongs to another destination.
    func load(jobID: String, destination: String) -> CloudManifest? {
        guard let data = try? Data(contentsOf: url(jobID: jobID)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let manifest = try? decoder.decode(CloudManifest.self, from: data) else { return nil }
        guard ManifestStore.sameDestination(manifest.destination, destination) else { return nil }
        return manifest
    }

    /// Written to a temporary file first and renamed into place, so a crash never leaves half a manifest.
    func save(_ manifest: CloudManifest, jobID: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let encoder = JSONEncoder()
        // Seconds with fractions: an ISO date would round to whole seconds and wrongly make fresh files look newer.
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data: Data = try encoder.encode(manifest)
        try data.write(to: url(jobID: jobID), options: [.atomic])
    }

    func remove(jobID: String) {
        try? FileManager.default.removeItem(at: url(jobID: jobID))
    }

    /// "onedrive:Backups/Archive/" and "onedrive:Backups/Archive" are the same place.
    static func sameDestination(_ a: String, _ b: String) -> Bool {
        let ta: String = a.trimmingCharacters(in: .whitespaces)
        let tb: String = b.trimmingCharacters(in: .whitespaces)
        if ta == tb { return true }
        guard let la = RcloneLocation.parse(ta), let lb = RcloneLocation.parse(tb) else { return false }
        return la.remote.lowercased() == lb.remote.lowercased() && la.path == lb.path
    }
}

enum CloudDeletions {
    /// Candidates and the counts that go with them.
    struct Detection: Equatable {
        /// Kind `.removed`, sorted by path.
        var candidates: [ChangeItem]
        /// Local modification date of each candidate when it was found (re-checked before anything is deleted).
        var modified: [String: Date]
        var extrasCount: Int
        var totalBytes: Int64 {
            return candidates.reduce(Int64(0)) { (sum: Int64, item: ChangeItem) -> Int64 in sum + (item.size ?? 0) }
        }
    }

    /// Candidates: in the manifest, gone from the cloud now, and still on this disk as a regular file with the same
    /// size and a modification date not later than the manifest's date. A file changed here since is not a candidate
    /// (the next backup simply uploads it). Extras: in the cloud now, not in the manifest, not on this disk.
    /// `local` returns nil for a path that is missing, not a regular file, or reached through a link.
    static func detect(manifest: CloudManifest, cloud: [CloudManifest.Entry],
                       local: (String) -> LocalFileInfo?) -> Detection {
        var cloudPaths: Set<String> = []
        for entry in cloud { cloudPaths.insert(entry.path) }
        var manifestPaths: Set<String> = []
        for entry in manifest.files { manifestPaths.insert(entry.path) }

        var candidates: [ChangeItem] = []
        var modified: [String: Date] = [:]
        var seen: Set<String> = []
        for entry in manifest.files where !cloudPaths.contains(entry.path) {
            if seen.contains(entry.path) { continue }
            seen.insert(entry.path)
            guard entry.size >= 0, let info = local(entry.path) else { continue }
            guard info.size == entry.size, info.modified <= manifest.date else { continue }
            candidates.append(ChangeItem(kind: .removed, path: entry.path, newPath: nil, size: entry.size))
            modified[entry.path] = info.modified
        }
        candidates.sort { (a: ChangeItem, b: ChangeItem) -> Bool in a.path < b.path }

        var extras: Int = 0
        var counted: Set<String> = []
        for entry in cloud where !manifestPaths.contains(entry.path) {
            if counted.contains(entry.path) { continue }
            counted.insert(entry.path)
            if local(entry.path) == nil { extras += 1 }
        }
        return Detection(candidates: candidates, modified: modified, extrasCount: extras)
    }

    /// 500 or more files, or 50 or more that are at least a quarter of the files in the manifest.
    static func looksLikeMassRemoval(candidates: Int, manifestCount: Int) -> Bool {
        if candidates >= 500 { return true }
        return candidates >= 50 && candidates * 4 >= manifestCount
    }

    /// `rclone lsjson -R --files-only` output: a JSON array of {"Path", "Size", "IsDir", ...}.
    /// Nil when the text is not such an array.
    static func parseListing(_ json: String) -> [CloudManifest.Entry]? {
        let trimmed: String = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]"), start <= end else { return nil }
        let slice: String = String(trimmed[start...end])
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = object as? [Any] else { return nil }
        var entries: [CloudManifest.Entry] = []
        entries.reserveCapacity(array.count)
        for element in array {
            guard let dict = element as? [String: Any], let path = dict["Path"] as? String, !path.isEmpty else { continue }
            if let isDir = dict["IsDir"] as? Bool, isDir { continue }
            let size: Int64 = RcloneLogParser.int64(dict["Size"]) ?? -1
            entries.append(CloudManifest.Entry(path: path, size: size))
        }
        return entries
    }

    /// Size and modification date of the regular file `relativePath` inside `source`, or nil when
    /// `SafetyRules.localFileInside` refuses it (missing, not a regular file, a link, or outside the folder).
    static func localInfo(relativePath: String, source: String, fileManager: FileManager = .default) -> LocalFileInfo? {
        guard case .success(let url) = SafetyRules.localFileInside(source: source, relativePath: relativePath,
                                                                    fileManager: fileManager) else { return nil }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[FileAttributeKey.size] as? NSNumber)?.int64Value,
              let modified = attributes[FileAttributeKey.modificationDate] as? Date else { return nil }
        return LocalFileInfo(size: size, modified: modified)
    }
}

// MARK: - The one guard in front of every deletion on this disk

extension SafetyRules {
    /// The regular file that `relativePath` names inside `source`, or the reason it may not be touched.
    ///
    /// Refused: an empty or absolute relative path, "." or ".." parts, a source that is not a full path or is "/",
    /// any link along the way (the folders in between must resolve to exactly themselves), anything that ends up
    /// outside the source, and anything that is not a regular file (links, folders, missing files).
    /// Every file Koffer moves to the Trash goes through this check right before the move.
    public static func localFileInside(source: String, relativePath: String,
                                       fileManager: FileManager = .default) -> Result<URL, EngineError> {
        let outside = EngineError("\(relativePath) isn't inside the backed-up folder, so Koffer won't touch it.")
        if relativePath.isEmpty || relativePath.hasPrefix("/") || relativePath.contains("\u{0}") { return .failure(outside) }
        if RcloneLocation.hasDotParts(relativePath) { return .failure(outside) }
        let parts: [String] = relativePath.split(separator: "/", omittingEmptySubsequences: true).map { String($0) }
        guard let last = parts.last else { return .failure(outside) }

        let rawSource: String = source.trimmingCharacters(in: .whitespaces)
        guard rawSource.hasPrefix("/") else { return .failure(outside) }
        let base: String = normalizeLocal((normalizeLocal(rawSource) as NSString).resolvingSymlinksInPath)
        guard base.hasPrefix("/"), base != "/" else { return .failure(outside) }

        let parentParts: [String] = Array(parts.dropLast())
        let lexicalParent: String = parentParts.isEmpty ? base : base + "/" + parentParts.joined(separator: "/")
        let resolvedParent: String = normalizeLocal((lexicalParent as NSString).resolvingSymlinksInPath)
        if !samePath(resolvedParent, normalizeLocal(lexicalParent)) {
            return .failure(EngineError("\(relativePath) is reached through a link, so Koffer won't touch it."))
        }
        let full: String = lexicalParent + "/" + last
        if !isStrictlyInside(full, base) { return .failure(outside) }

        // Not following links: a link is refused even when it points somewhere harmless.
        guard let attributes = try? fileManager.attributesOfItem(atPath: full) else {
            return .failure(EngineError("\(relativePath) isn't on this disk any more."))
        }
        guard let type = attributes[FileAttributeKey.type] as? FileAttributeType, type == FileAttributeType.typeRegular else {
            return .failure(EngineError("\(relativePath) isn't a plain file, so Koffer won't touch it."))
        }
        return .success(URL(fileURLWithPath: full, isDirectory: false))
    }

    /// Standardized, without macOS's "/private" prefix (/var is a link to /private/var), precomposed.
    static func canonicalPath(_ path: String) -> String {
        var p: String = normalizeLocal(path)
        if p.hasPrefix("/private/") { p = String(p.dropFirst("/private".count)) }
        return p.precomposedStringWithCanonicalMapping
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        return canonicalPath(a) == canonicalPath(b)
    }

    /// True when `path` lies below `base` (not equal to it). Both are full paths.
    static func isStrictlyInside(_ path: String, _ base: String) -> Bool {
        let p: String = canonicalPath(path)
        let b: String = canonicalPath(base)
        guard b.hasPrefix("/"), b != "/" else { return false }
        return p.hasPrefix(b + "/") && p.count > b.count + 1
    }
}
