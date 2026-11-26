import Foundation

public enum SafetyVerdict: Equatable {
    case ok
    /// Plain-words reason the job or command was refused.
    case refused(String)

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    public var reason: String? {
        if case .refused(let r) = self { return r }
        return nil
    }
}

/// An rclone location split into remote ("onedrive:", or "" for a local path) and path inside it.
public struct RcloneLocation: Equatable {
    public var remote: String
    public var path: String
    public var isLocal: Bool { remote.isEmpty }

    /// "/abs/path" -> local. "name:path" -> remote. Anything else (relative path) -> nil.
    /// Paths with "." or ".." parts are refused (nil): rclone resolves them, so "x:Backup/_removed/.."
    /// would really mean "x:Backup" and slip past the overlap checks.
    public static func parse(_ raw: String) -> RcloneLocation? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.hasPrefix("/") {
            let local: String = SafetyRules.normalizeLocal(s)
            if RcloneLocation.hasDotParts(local) { return nil }
            return RcloneLocation(remote: "", path: local)
        }
        guard let idx = s.firstIndex(of: ":") else { return nil }
        let remote = String(s[...idx])
        if remote.count < 2 { return nil }
        let rest = String(s[s.index(after: idx)...])
        if RcloneLocation.hasDotParts(rest) { return nil }
        // Drop leading, trailing and doubled slashes, as rclone does.
        let parts: [String] = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return RcloneLocation(remote: remote, path: parts.joined(separator: "/"))
    }

    static func hasDotParts(_ path: String) -> Bool {
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t == "." || t == ".." { return true }
        }
        return false
    }

    /// True when `self` is `other` or lies inside it. Case-insensitive (OneDrive and APFS usually are).
    public func isSameOrInside(_ other: RcloneLocation) -> Bool {
        guard remote.lowercased() == other.remote.lowercased() else { return false }
        let a = path.lowercased()
        let b = other.path.lowercased()
        if other.isLocal {
            if b == "/" { return true }
            return a == b || a.hasPrefix(b + "/")
        }
        if b.isEmpty { return true }
        return a == b || a.hasPrefix(b + "/")
    }
}

/// Pure checks that run before anything touches rclone.
public enum SafetyRules {
    static func normalizeLocal(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Validates a job against the config. `homeDirectory` is injectable for tests.
    public static func check(job: SyncJob, config: KofferConfig,
                             homeDirectory: String = NSHomeDirectory()) -> SafetyVerdict {
        let rawSource = job.source.trimmingCharacters(in: .whitespaces)
        guard rawSource.hasPrefix("/") else {
            return .refused("The folder to back up must be a full path starting with /.")
        }
        let source = normalizeLocal(rawSource)
        // rclone follows a symlink given as the source, so check where it really points as well.
        let resolved = normalizeLocal((source as NSString).resolvingSymlinksInPath)
        let candidates: [String] = resolved == source ? [source] : [source, resolved]

        for candidate in candidates {
            let lowerSource = candidate.lowercased()

            // Folders the user wants left alone.
            for fragment in config.neverSync {
                let f = fragment.trimmingCharacters(in: .whitespaces).lowercased()
                if f.isEmpty { continue }
                if lowerSource.contains(f) {
                    return .refused("This folder is on the never-sync list (\(fragment)).")
                }
            }

            // Private folders that must never go to certain remotes.
            for rule in privateRules(for: job, config: config) where lowerSource.contains(rule) {
                return .refused("This folder is private and may not be sent to \(job.remoteName).")
            }

            // Whole disks, the home folder and other too-broad sources.
            let components: [String] = candidate.split(separator: "/").map(String.init)
            if components.isEmpty {
                return .refused("Backing up the whole computer is not allowed. Pick a folder.")
            }
            if components.count == 1 {
                return .refused("That folder is too broad to back up. Pick a folder inside it.")
            }
            if components[0].lowercased() == "volumes" && components.count <= 2 {
                return .refused("Backing up a whole disk is not allowed. Pick a folder on it.")
            }
            let home = normalizeLocal(homeDirectory).lowercased()
            if !home.isEmpty && lowerSource == home {
                return .refused("Backing up your whole home folder is not allowed. Pick a folder inside it.")
            }
        }

        // Destination and removed-items folder.
        let destinationRaw = job.destination.trimmingCharacters(in: .whitespaces)
        let removedRaw = job.removedRoot.trimmingCharacters(in: .whitespaces)
        if destinationRaw.isEmpty {
            return .refused("The job has no destination.")
        }
        if removedRaw.isEmpty {
            return .refused("The job has no folder for removed items.")
        }
        guard let destination = RcloneLocation.parse(destinationRaw) else {
            return .refused("The destination is not a valid rclone path (remote:folder).")
        }
        guard let removed = RcloneLocation.parse(removedRaw) else {
            return .refused("The removed-items folder is not a valid rclone path (remote:folder).")
        }
        if !destination.isLocal && destination.path.isEmpty {
            return .refused("Syncing to the top of \(destination.remote) is not allowed. Use a folder, like \(destination.remote)Backup.")
        }
        if destination.isLocal && destination.path == "/" {
            return .refused("Syncing to the top of the disk is not allowed.")
        }
        if !removed.isLocal && removed.path.isEmpty {
            return .refused("The removed-items folder can't be the top of \(removed.remote).")
        }
        if removed.isSameOrInside(destination) || destination.isSameOrInside(removed) {
            return .refused("The removed-items folder must be separate from the destination, not inside it.")
        }
        // A local destination must not overlap the source either.
        if destination.isLocal {
            let src = RcloneLocation(remote: "", path: source)
            if destination.isSameOrInside(src) || src.isSameOrInside(destination) {
                return .refused("The destination can't be inside the folder being backed up.")
            }
        }
        return .ok
    }

    /// "OneDrive:" and "onedrive" both become "onedrive", so a hand-written rule matches either way.
    static func remoteKey(_ remote: String) -> String {
        var r = remote.trimmingCharacters(in: .whitespaces).lowercased()
        while r.hasSuffix(":") { r.removeLast() }
        return r
    }

    /// Lower-cased private-path fragments that may not go to this job's remote.
    static func privateRules(for job: SyncJob, config: KofferConfig) -> [String] {
        let remote = remoteKey(job.remoteName)
        if remote.isEmpty { return [] }
        var result: [String] = []
        for rule in config.privatePaths {
            let f = rule.pathContains.trimmingCharacters(in: .whitespaces).lowercased()
            if f.isEmpty { continue }
            let forbidden: [String] = rule.forbiddenRemotes.map { remoteKey($0) }
            if forbidden.contains(remote) { result.append(f) }
        }
        return result
    }

    /// Checks every file a dry run would send (new, replaced, moved) against the never-sync list and the
    /// private folders. This catches a source that is a parent of a protected folder.
    public static func checkItems(_ items: [ChangeItem], job: SyncJob, config: KofferConfig) -> SafetyVerdict {
        var never: [String] = []
        for fragment in config.neverSync {
            let f = fragment.trimmingCharacters(in: .whitespaces).lowercased()
            if !f.isEmpty { never.append(f) }
        }
        let privateFragments: [String] = privateRules(for: job, config: config)
        if never.isEmpty && privateFragments.isEmpty { return .ok }

        let source = normalizeLocal(job.source.trimmingCharacters(in: .whitespaces))
        let resolved = normalizeLocal((source as NSString).resolvingSymlinksInPath)
        var bases: [String] = [source.lowercased()]
        if resolved != source { bases.append(resolved.lowercased()) }

        for item in items where item.kind != .removed {
            var paths: [String] = [item.path]
            if let n = item.newPath { paths.append(n) }
            for rel in paths {
                for base in bases {
                    let full = base + "/" + rel.lowercased()
                    for f in never where full.contains(f) {
                        return .refused("Nothing was sent: \(rel) is in a folder on the never-sync list (\(f)).")
                    }
                    for f in privateFragments where full.contains(f) {
                        return .refused("Nothing was sent: \(rel) is in a private folder that may not go to \(job.remoteName).")
                    }
                }
            }
        }
        return .ok
    }

    /// Final check on the exact argument list before it goes to rclone.
    public static func assertSafe(arguments: [String], removedRoot: String) -> SafetyVerdict {
        guard let verb = arguments.first else { return .refused("Empty rclone command.") }
        let lowered: [String] = arguments.map { $0.lowercased() }
        if lowered.contains("--delete-before") || lowered.contains(where: { $0.hasPrefix("--delete-before=") }) {
            return .refused("Refusing to run rclone with --delete-before.")
        }
        if lowered.contains("--delete-excluded") || lowered.contains(where: { $0.hasPrefix("--delete-excluded=") }) {
            return .refused("Refusing to run rclone with --delete-excluded.")
        }
        switch verb {
        case "sync":
            guard let idx = arguments.firstIndex(of: "--backup-dir"), idx + 1 < arguments.count else {
                return .refused("Refusing to sync without a folder for removed items.")
            }
            guard let root = RcloneLocation.parse(removedRoot),
                  let backup = RcloneLocation.parse(arguments[idx + 1]),
                  backup.isSameOrInside(root) else {
                return .refused("The removed-items folder in the command does not match the job.")
            }
            return .ok
        case "about", "size", "version", "lsjson":
            return .ok
        case "purge":
            guard arguments.count >= 2 else { return .refused("Purge without a target.") }
            let target = arguments[1]
            guard let root = RcloneLocation.parse(removedRoot), let t = RcloneLocation.parse(target) else {
                return .refused("Refusing to purge an unknown path.")
            }
            if !root.isLocal && root.path.isEmpty {
                return .refused("Refusing to purge the top of \(root.remote).")
            }
            if root.isLocal && root.path == "/" {
                return .refused("Refusing to purge the top of the disk.")
            }
            if t.isSameOrInside(root) { return .ok }
            return .refused("Refusing to delete anything outside the removed-items folder.")
        default:
            return .refused("Koffer does not run 'rclone \(verb)'.")
        }
    }
}
