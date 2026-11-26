import Foundation

// Shared value types. Every module codes against these; change them only via docs/CONTRACT.md.

/// One folder -> destination pair.
public struct SyncJob: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Absolute local folder, e.g. /Volumes/MyDisk/Archive
    public var source: String
    /// rclone destination, e.g. onedrive:Archive
    public var destination: String
    /// rclone folder that receives dated subfolders of removed/overwritten files, e.g. onedrive:_Archive_removed
    public var removedRoot: String
    /// Volume name that must be mounted for this job (nil = not tied to a volume).
    public var requiredVolume: String?
    /// Start automatically when `requiredVolume` mounts.
    public var autoSyncOnMount: Bool
    /// Disabled jobs never run, not even manually.
    public var enabled: Bool
    /// Set true after the user has looked at a preview for this job. Auto-sync requires it.
    public var previewApproved: Bool
    /// Optional second folder (local path) where a copy of each run log is written.
    public var extraLogDirectory: String?
    /// True for the built-in small test job.
    public var isTest: Bool

    public init(id: String, name: String, source: String, destination: String, removedRoot: String,
                requiredVolume: String? = nil, autoSyncOnMount: Bool = false, enabled: Bool = true,
                previewApproved: Bool = false, extraLogDirectory: String? = nil, isTest: Bool = false) {
        self.id = id; self.name = name; self.source = source; self.destination = destination
        self.removedRoot = removedRoot; self.requiredVolume = requiredVolume
        self.autoSyncOnMount = autoSyncOnMount; self.enabled = enabled
        self.previewApproved = previewApproved; self.extraLogDirectory = extraLogDirectory; self.isTest = isTest
    }

    /// The rclone remote name including the colon, e.g. "onedrive:".
    public var remoteName: String {
        guard let idx = destination.firstIndex(of: ":") else { return "" }
        return String(destination[...idx])
    }
}

public extension SyncJob {
    static let testJobID = "test"

    /// Small safe job used to prove everything works against the real OneDrive.
    static func testJob(home: String = NSHomeDirectory()) -> SyncJob {
        SyncJob(id: testJobID, name: "Test folder",
                source: home + "/Koffer Test",
                destination: "onedrive:_koffer_test",
                removedRoot: "onedrive:_koffer_test_removed",
                requiredVolume: nil, autoSyncOnMount: false, enabled: true, isTest: true)
    }

    static func builtIn() -> [SyncJob] { [testJob()] }
}

/// A local path fragment that must never be sent to certain remotes (e.g. private finance folders).
public struct PrivatePathRule: Codable, Hashable {
    /// Case-insensitive substring matched against the job's source path.
    public var pathContains: String
    /// Remote names with colon (e.g. "onedrive:") this path must never go to.
    public var forbiddenRemotes: [String]
    public init(pathContains: String, forbiddenRemotes: [String]) {
        self.pathContains = pathContains; self.forbiddenRemotes = forbiddenRemotes
    }
}

/// Everything user-specific lives here, in ~/Library/Application Support/Koffer/config.json,
/// never in source code. First launch seeds it with the test job only.
public struct KofferConfig: Codable, Equatable {
    public var jobs: [SyncJob]
    /// Case-insensitive path fragments that may never be a job source or inside one (folders to leave alone).
    public var neverSync: [String]
    public var privatePaths: [PrivatePathRule]
    public init(jobs: [SyncJob] = SyncJob.builtIn(), neverSync: [String] = [], privatePaths: [PrivatePathRule] = []) {
        self.jobs = jobs; self.neverSync = neverSync; self.privatePaths = privatePaths
    }
}

public enum EngineStatus: Equatable {
    case idle
    /// Pre-flight checks; the string is a short plain-words description ("Checking free space").
    case preparing(String)
    case previewing
    case syncing
    /// Stopped cleanly and will resume next time; the string says why.
    case paused(String)
    /// Last run finished without errors.
    case done
    /// Something needs the user; the string is the reason in plain words.
    case needsAttention(String)

    public var isBusy: Bool {
        switch self {
        case .preparing, .previewing, .syncing: return true
        default: return false
        }
    }
}

/// Live numbers for the run in flight. All byte values are bytes; speed is bytes/second.
public struct SyncProgress: Equatable {
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    public var filesDone: Int = 0
    public var filesTotal: Int = 0
    public var checksDone: Int = 0
    public var checksTotal: Int = 0
    public var speed: Double = 0
    public var etaSeconds: Double? = nil
    public var elapsed: TimeInterval = 0
    /// Paths (relative to the job root) being transferred right now.
    public var currentFiles: [String] = []
    public var uploaded: Int = 0
    public var moved: Int = 0
    public var removed: Int = 0
    public var errors: Int = 0
    /// True while OneDrive is rate-limiting us (HTTP 429) and rclone is backing off.
    public var isThrottled: Bool = false

    public init() {}

    /// 0...1 by bytes; nil while totals are unknown.
    public var fraction: Double? {
        guard bytesTotal > 0 else { return nil }
        return min(1, max(0, Double(bytesDone) / Double(bytesTotal)))
    }
}

public enum ChangeKind: String, Codable { case new, replaced, moved, removed }

public struct ChangeItem: Codable, Identifiable, Hashable {
    public var id: String { kind.rawValue + "|" + path + "|" + (newPath ?? "") }
    public var kind: ChangeKind
    /// Path relative to the job root (for `.moved`, the old path).
    public var path: String
    public var newPath: String?
    public var size: Int64?
    public init(kind: ChangeKind, path: String, newPath: String? = nil, size: Int64? = nil) {
        self.kind = kind; self.path = path; self.newPath = newPath; self.size = size
    }
}

/// Result of a "What will change?" dry run.
public struct PreviewResult: Equatable {
    public var jobID: String
    public var date: Date
    public var items: [ChangeItem]
    public init(jobID: String, date: Date, items: [ChangeItem]) {
        self.jobID = jobID; self.date = date; self.items = items
    }
    public func items(_ kind: ChangeKind) -> [ChangeItem] { items.filter { $0.kind == kind } }
    public func count(_ kind: ChangeKind) -> Int { items(kind).count }
    /// Bytes that would actually be uploaded (new + replaced).
    public var uploadBytes: Int64 {
        items.filter { $0.kind == .new || $0.kind == .replaced }.reduce(0) { $0 + ($1.size ?? 0) }
    }
    public var isEmpty: Bool { items.isEmpty }
}

public enum RunOutcome: String, Codable { case completed, paused, failed }

/// One finished (or stopped) real run, kept in history.
public struct RunRecord: Codable, Identifiable, Hashable {
    public var id: UUID
    public var jobID: String
    public var jobName: String
    public var startedAt: Date
    public var endedAt: Date
    public var outcome: RunOutcome
    public var uploaded: Int
    public var moved: Int
    public var removed: Int
    public var errors: Int
    public var bytesTransferred: Int64
    /// Plain-words reason for paused/failed runs.
    public var message: String?
    /// Absolute path of the full log file.
    public var logPath: String?

    public init(id: UUID = UUID(), jobID: String, jobName: String, startedAt: Date, endedAt: Date,
                outcome: RunOutcome, uploaded: Int, moved: Int, removed: Int, errors: Int,
                bytesTransferred: Int64, message: String? = nil, logPath: String? = nil) {
        self.id = id; self.jobID = jobID; self.jobName = jobName; self.startedAt = startedAt
        self.endedAt = endedAt; self.outcome = outcome; self.uploaded = uploaded; self.moved = moved
        self.removed = removed; self.errors = errors; self.bytesTransferred = bytesTransferred
        self.message = message; self.logPath = logPath
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

// MARK: - Services the engine calls. Implemented in the app target (Sources/Koffer), faked in tests.

public protocol Notifying: AnyObject {
    func syncStarted(job: SyncJob)
    func syncFinished(record: RunRecord)
    func syncPaused(job: SyncJob, reason: String)
    func syncFailed(job: SyncJob, reason: String)
}

public protocol PowerKeeping: AnyObject {
    /// Prevent idle sleep until `end()`.
    func begin(reason: String)
    func end()
}

public protocol HistoryStoring: AnyObject {
    /// Newest first, at most 20.
    func load() -> [RunRecord]
    func append(_ record: RunRecord)
}
