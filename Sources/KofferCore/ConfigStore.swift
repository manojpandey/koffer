import Foundation

public enum ConfigStoreError: Error, Equatable {
    /// The file exists but could not be read or decoded. It is left untouched.
    case unreadable(String)
    /// The file could not be written.
    case writeFailed(String)
}

/// Loads and saves `KofferConfig` (hand-editable JSON).
/// A missing file is seeded with `KofferConfig()`. A file that fails to decode is never overwritten.
public final class ConfigStore {
    public let fileURL: URL

    public static var defaultURL: URL {
        let base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Koffer", isDirectory: true).appendingPathComponent("config.json")
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? ConfigStore.defaultURL
    }

    /// Reads the config. Missing file -> writes and returns the seed. Undecodable -> throws `.unreadable`.
    public func load() throws -> KofferConfig {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            let seed = KofferConfig()
            try save(seed)
            return seed
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ConfigStoreError.unreadable("Could not read \(fileURL.path): \(error.localizedDescription)")
        }
        return try ConfigStore.decode(data)
    }

    /// Writes the config atomically, creating the folder if needed.
    public func save(_ config: KofferConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data: Data = try encoder.encode(config)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true, attributes: nil)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw ConfigStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Lenient decoding so a hand-edited file may leave out the optional and boolean fields.
    /// Required per job: id, name, source, destination, removedRoot.
    public static func decode(_ data: Data) throws -> KofferConfig {
        let decoder = JSONDecoder()
        let raw: LenientConfig
        do {
            raw = try decoder.decode(LenientConfig.self, from: data)
        } catch {
            throw ConfigStoreError.unreadable("The settings file is not valid: \(error.localizedDescription)")
        }
        // A misspelt key ("privatepaths") would otherwise be ignored and silently drop a protection.
        if let unknown = ConfigStore.unknownKey(in: data) {
            throw ConfigStoreError.unreadable("The settings file has a setting Koffer doesn't know: \"\(unknown)\". Keys starting with _ are fine for notes.")
        }
        let jobs: [SyncJob] = (raw.jobs ?? []).map { (j: LenientJob) -> SyncJob in
            SyncJob(id: j.id, name: j.name, source: j.source, destination: j.destination,
                    removedRoot: j.removedRoot, requiredVolume: j.requiredVolume,
                    autoSyncOnMount: j.autoSyncOnMount ?? false, enabled: j.enabled ?? true,
                    previewApproved: j.previewApproved ?? false, extraLogDirectory: j.extraLogDirectory,
                    isTest: j.isTest ?? false)
        }
        let rules: [PrivatePathRule] = (raw.privatePaths ?? []).map { (r: LenientRule) -> PrivatePathRule in
            PrivatePathRule(pathContains: r.pathContains, forbiddenRemotes: r.forbiddenRemotes ?? [])
        }
        return KofferConfig(jobs: jobs, neverSync: raw.neverSync ?? [], privatePaths: rules)
    }
}

extension ConfigStore {
    static let configKeys: Set<String> = ["jobs", "neverSync", "privatePaths"]
    static let jobKeys: Set<String> = ["id", "name", "source", "destination", "removedRoot", "requiredVolume",
                                       "autoSyncOnMount", "enabled", "previewApproved", "extraLogDirectory", "isTest"]
    static let ruleKeys: Set<String> = ["pathContains", "forbiddenRemotes"]

    /// The first key the settings file uses that Koffer does not know (keys starting with "_" are notes).
    static func unknownKey(in data: Data) -> String? {
        let parsed: Any? = try? JSONSerialization.jsonObject(with: data, options: [])
        guard let top = parsed as? [String: Any] else { return nil }
        if let bad = firstUnknown(top, allowed: configKeys) { return bad }
        if let jobs = top["jobs"] as? [Any] {
            for entry in jobs {
                if let dict = entry as? [String: Any], let bad = firstUnknown(dict, allowed: jobKeys) { return bad }
            }
        }
        if let rules = top["privatePaths"] as? [Any] {
            for entry in rules {
                if let dict = entry as? [String: Any], let bad = firstUnknown(dict, allowed: ruleKeys) { return bad }
            }
        }
        return nil
    }

    private static func firstUnknown(_ dict: [String: Any], allowed: Set<String>) -> String? {
        for key in dict.keys.sorted() where !allowed.contains(key) && !key.hasPrefix("_") {
            return key
        }
        return nil
    }
}

private struct LenientConfig: Decodable {
    var jobs: [LenientJob]?
    var neverSync: [String]?
    var privatePaths: [LenientRule]?
}

private struct LenientJob: Decodable {
    var id: String
    var name: String
    var source: String
    var destination: String
    var removedRoot: String
    var requiredVolume: String?
    var autoSyncOnMount: Bool?
    var enabled: Bool?
    var previewApproved: Bool?
    var extraLogDirectory: String?
    var isTest: Bool?
}

private struct LenientRule: Decodable {
    var pathContains: String
    var forbiddenRemotes: [String]?
}
