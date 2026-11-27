import Foundation
import Combine

/// The app-provided services the engine calls (faked in tests).
public struct EngineServices {
    public var notifier: Notifying
    public var power: PowerKeeping
    public var history: HistoryStoring

    public init(notifier: Notifying, power: PowerKeeping, history: HistoryStoring) {
        self.notifier = notifier
        self.power = power
        self.history = history
    }
}

/// Paths, binaries and timings the engine uses. `standard()` is what the app uses; tests inject their own.
public struct EngineEnvironment {
    public var configURL: URL
    /// Folder for `<jobID>_<yyyy-MM-dd_HHmm>.log` files.
    public var logDirectory: URL
    /// Where to look for rclone, in order.
    public var rcloneCandidates: [String]
    /// Wait after a volume mounts before auto-syncing.
    public var mountDelay: TimeInterval
    /// Time rclone gets to stop after SIGINT before it is terminated.
    public var interruptGrace: TimeInterval
    public var homeDirectory: String
    /// Folder listing mounted volume names at launch (nil = start with none).
    public var volumesDirectory: String?
    /// Time zone for date stamps (nil = the current one at the moment of use).
    public var timeZone: TimeZone?
    public var now: () -> Date
    /// Where `installRclone()` puts the rclone it downloads (`<this>/rclone`).
    public var rcloneInstallDirectory: URL
    /// Homebrew's `brew`, in order of preference.
    public var brewCandidates: [String]
    /// The official rclone zip for this Mac (tests use a file:// URL).
    public var rcloneDownloadURL: URL
    /// rclone config file passed as RCLONE_CONFIG (nil = rclone's own default). Tests use a scratch file.
    public var rcloneConfigPath: String?
    /// How long `reconnect(remote:)` waits for the sign-in in the browser.
    public var reconnectTimeout: TimeInterval
    /// `refreshRemotes(force: false)` skips the check when the last one is younger than this.
    public var remotesCheckInterval: TimeInterval
    /// v0.3: folder for `<jobID>.json`, what was in the cloud after the last clean backup.
    /// Defaults to `manifests` next to the settings file (~/Library/Application Support/Koffer/manifests).
    public var manifestDirectory: URL
    /// v0.3: moves one local file to the Trash. Production: `FileManager.trashItem`. Koffer only ever calls it on a
    /// file `SafetyRules.localFileInside` has just approved. Tests inject a fake that moves into a scratch folder.
    public var trashItem: (URL) throws -> Void

    public init(configURL: URL, logDirectory: URL, rcloneCandidates: [String] = RcloneLocator.defaultCandidates,
                mountDelay: TimeInterval = 10, interruptGrace: TimeInterval = 15,
                homeDirectory: String = NSHomeDirectory(), volumesDirectory: String? = "/Volumes",
                timeZone: TimeZone? = nil, now: @escaping () -> Date = { Date() },
                rcloneInstallDirectory: URL = RcloneLocator.installDirectory,
                brewCandidates: [String] = EngineEnvironment.defaultBrewCandidates,
                rcloneDownloadURL: URL = EngineEnvironment.defaultRcloneDownloadURL,
                rcloneConfigPath: String? = nil,
                reconnectTimeout: TimeInterval = 300,
                remotesCheckInterval: TimeInterval = 60,
                manifestDirectory: URL? = nil,
                trashItem: @escaping (URL) throws -> Void = EngineEnvironment.moveToTrash) {
        self.configURL = configURL
        self.logDirectory = logDirectory
        self.rcloneCandidates = rcloneCandidates
        self.mountDelay = mountDelay
        self.interruptGrace = interruptGrace
        self.homeDirectory = homeDirectory
        self.volumesDirectory = volumesDirectory
        self.timeZone = timeZone
        self.now = now
        self.rcloneInstallDirectory = rcloneInstallDirectory
        self.brewCandidates = brewCandidates
        self.rcloneDownloadURL = rcloneDownloadURL
        self.rcloneConfigPath = rcloneConfigPath
        self.reconnectTimeout = reconnectTimeout
        self.remotesCheckInterval = remotesCheckInterval
        self.manifestDirectory = manifestDirectory
            ?? configURL.deletingLastPathComponent().appendingPathComponent("manifests", isDirectory: true)
        self.trashItem = trashItem
    }

    /// Moves the item to the user's Trash (never deletes it).
    public static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    public static let defaultBrewCandidates: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// `https://downloads.rclone.org/rclone-current-osx-<arm64|amd64>.zip` for this Mac's CPU.
    public static var defaultRcloneDownloadURL: URL {
        return RemoteParsing.defaultDownloadURL
    }

    public static var defaultLogDirectory: URL {
        let library: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("Koffer", isDirectory: true)
    }

    public static func standard() -> EngineEnvironment {
        return EngineEnvironment(configURL: ConfigStore.defaultURL, logDirectory: EngineEnvironment.defaultLogDirectory)
    }
}

@MainActor
public final class SyncEngine: ObservableObject {
    public static let settingsUnreadableMessage = "Koffer's settings file can't be read"
    public static let rcloneMissingMessage = "rclone isn't installed yet. Use \"Install rclone\" in Koffer's panel."
    public static let waitForBackupMessage = "Wait for the current backup to finish"
    public static let signInWaitingMessage = "Waiting for you to sign in in your browser…"
    public static let homebrewInstallingMessage = "Installing rclone with Homebrew…"
    public static let downloadingMessage = "Downloading rclone…"
    public static let stoppedByYouMessage = "Stopped by you"
    public static let unpluggedMessage = "Disk unplugged. Will resume next time"
    public static let offlineMessage = "No internet. Will resume next time"

    @Published public private(set) var status: EngineStatus = .idle
    @Published public private(set) var progress: SyncProgress = SyncProgress()
    @Published public private(set) var activeJobID: String? = nil
    @Published public private(set) var preview: PreviewResult? = nil
    @Published public private(set) var history: [RunRecord] = []
    @Published public private(set) var jobs: [SyncJob] = []
    @Published public private(set) var removedBytes: [String: Int64] = [:]
    @Published public private(set) var rclonePath: String? = nil
    @Published public private(set) var needsReconnect: Bool = false
    @Published public private(set) var mountedVolumes: Set<String> = []
    /// The job the current `status` is about (nil = not tied to one job, e.g. unreadable settings).
    /// Lets the UI avoid showing one job's "done" or problem on another job.
    @Published public private(set) var statusJobID: String? = nil

    // v0.2: everything through the panel.
    /// Remote names with colon, as `rclone listremotes` prints them (e.g. ["onedrive:"]).
    @Published public private(set) var remotes: [String] = []
    /// Keyed by remote name with colon.
    @Published public private(set) var remoteStates: [String: RemoteState] = [:]
    /// Installing rclone.
    @Published public private(set) var installState: TaskState = .idle
    /// Signing in to a remote again.
    @Published public private(set) var reconnectState: TaskState = .idle

    // v0.3: deleted in the cloud.
    /// Job id -> files deleted in the cloud but still on this disk, waiting for the owner's decision.
    /// While a job has a report, Koffer never starts that job on its own.
    @Published public private(set) var cloudDeletions: [String: CloudDeletionReport] = [:]
    /// Job id -> (path -> local modification date when the deletion was found), re-checked before deleting.
    private var cloudDeletionDates: [String: [String: Date]] = [:]

    public let environment: EngineEnvironment
    private let services: EngineServices
    private let configStore: ConfigStore
    private var config: KofferConfig
    private var configBroken: Bool

    private enum StopReason { case user, volumeGone, offline }

    private struct Outcome {
        var status: EngineStatus
        var run: RunOutcome
        var message: String?
    }

    private var isOnline: Bool = true
    /// A sync, preview or purge is in flight (covers the gaps between rclone processes).
    private var working: Bool = false
    private var runningJob: SyncJob? = nil
    private var stopReason: StopReason? = nil
    private var currentRunner: RcloneRunner? = nil
    private var helperRunner: RcloneRunner? = nil
    private var helperTask: Task<Void, Never>? = nil
    private var mountTasks: [String: Task<Void, Never>] = [:]
    private var pausedOfflineJobID: String? = nil

    // Live progress publishing.
    private var liveParser: RcloneLogParser? = nil
    private var floorFiles: Int = 0
    private var floorBytes: Int64 = 0
    private var lastProgressPublish: Date = .distantPast
    private var trailingPublishScheduled: Bool = false
    private let minPublishInterval: TimeInterval = 0.25

    /// The task of the sync/preview/purge in flight (tests await it).
    internal private(set) var currentTask: Task<Void, Never>? = nil

    // Connection checks, installing, signing in (v0.2).
    /// The connection check in flight (tests await it).
    internal private(set) var remotesTask: Task<Void, Never>? = nil
    private var lastRemotesCheck: Date? = nil
    private var remotesRefreshPending: Bool = false
    /// The rclone installation in flight (tests await it).
    internal private(set) var installTask: Task<Void, Never>? = nil
    /// The sign-in in flight (tests await it).
    internal private(set) var reconnectTask: Task<Void, Never>? = nil
    private var reconnectRunner: RcloneRunner? = nil
    private var reconnectGeneration: Int = 0
    private var reconnectCancelled: Bool = false
    private var reconnectTimedOut: Bool = false

    public convenience init(services: EngineServices) {
        self.init(services: services, environment: EngineEnvironment.standard())
    }

    public init(services: EngineServices, environment: EngineEnvironment) {
        let store = ConfigStore(fileURL: environment.configURL)
        var loaded: KofferConfig = KofferConfig(jobs: [])
        var broken = false
        do {
            loaded = try store.load()
        } catch {
            broken = true
        }
        self.environment = environment
        self.services = services
        self.configStore = store
        self.config = loaded
        self.configBroken = broken

        self.jobs = loaded.jobs
        self.history = services.history.load()
        self.rclonePath = RcloneLocator(candidates: environment.rcloneCandidates).locate()
        self.mountedVolumes = SyncEngine.scanVolumes(environment.volumesDirectory)
        if broken {
            self.status = .needsAttention(SyncEngine.settingsUnreadableMessage)
        }
    }

    // MARK: - Jobs

    public func job(id: String) -> SyncJob? {
        return jobs.first(where: { $0.id == id })
    }

    public func isAvailable(_ job: SyncJob) -> Bool {
        guard job.enabled else { return false }
        if let volume = job.requiredVolume { return mountedVolumes.contains(volume) }
        return true
    }

    public func setEnabled(_ enabled: Bool, jobID: String) {
        updateJob(jobID) { (job: inout SyncJob) in job.enabled = enabled }
    }

    public func setAutoSync(_ on: Bool, jobID: String) {
        updateJob(jobID) { (job: inout SyncJob) in job.autoSyncOnMount = on }
    }

    // MARK: - Running

    public func syncNow(jobID: String) {
        startSync(jobID: jobID, automatic: false)
    }

    /// `automatic` is true for runs Koffer starts on its own (disk plugged in); those get extra caution
    /// and never start while files deleted in the cloud wait for a decision.
    /// `skipCloudCheck` is true only right after the owner chose to put those files back.
    private func startSync(jobID: String, automatic: Bool, skipCloudCheck: Bool = false) {
        guard !working, !status.isBusy else { return }
        if automatic && cloudDeletions[jobID] != nil { return }
        reloadConfig()
        guard let job = self.job(id: jobID) else { return }
        beginWork(job: job)
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            let ran: Bool = await self.performSync(job: job, automatic: automatic, skipCloudCheck: skipCloudCheck)
            self.finishWork()
            if ran { self.refreshRemovedSize(jobID: job.id) }
        }
    }

    public func previewChanges(jobID: String) {
        guard !working, !status.isBusy else { return }
        reloadConfig()
        guard let job = self.job(id: jobID) else { return }
        beginWork(job: job)
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await self.performPreview(job: job)
            self.finishWork()
        }
    }

    public func cancel() {
        guard working else { return }
        if stopReason == nil { stopReason = .user }
        currentRunner?.interrupt(grace: environment.interruptGrace)
    }

    // MARK: - System events

    public func volumeMounted(_ name: String) {
        mountedVolumes.insert(name)
        mountTasks[name]?.cancel()
        let delay: TimeInterval = environment.mountDelay
        mountTasks[name] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self = self, !Task.isCancelled else { return }
            self.mountTasks[name] = nil
            self.autoStart(volume: name)
        }
    }

    public func volumeUnmounted(_ name: String) {
        mountedVolumes.remove(name)
        mountTasks[name]?.cancel()
        mountTasks[name] = nil
        guard working, let job = runningJob else { return }
        let volumePath = "/Volumes/" + name
        let onVolume: Bool = job.requiredVolume == name
            || job.source == volumePath || job.source.hasPrefix(volumePath + "/")
        if onVolume {
            if stopReason == nil { stopReason = .volumeGone }
            currentRunner?.interrupt(grace: environment.interruptGrace)
        }
    }

    public func networkChanged(isOnline online: Bool) {
        let wasOnline = isOnline
        isOnline = online
        if !online {
            if working, let job = runningJob, needsNetwork(job) {
                if stopReason == nil { stopReason = .offline }
                currentRunner?.interrupt(grace: environment.interruptGrace)
            }
            return
        }
        // Back online: pick up a job that paused for lack of internet.
        if !wasOnline, let id = pausedOfflineJobID, let job = self.job(id: id), isAutoEligible(job) {
            pausedOfflineJobID = nil
            if let volume = job.requiredVolume {
                volumeMounted(volume)
            }
        }
    }

    // MARK: - Removed items

    public func refreshRemovedSize(jobID: String) {
        guard !working, helperTask == nil, let job = self.job(id: jobID) else { return }
        guard RcloneLocation.parse(job.removedRoot) != nil else { return }
        guard let rclone = locateRclone() else { return }
        let args = RcloneCommand.size(path: job.removedRoot)
        guard SafetyRules.assertSafe(arguments: args, removedRoot: job.removedRoot).isOK else { return }
        let runner = makeRunner(rclone, args)
        helperRunner = runner
        helperTask = Task { [weak self] in
            let result = await runner.capture(timeout: 300)
            guard let self = self else { return }
            self.helperRunner = nil
            self.helperTask = nil
            if result.status == 0, let bytes = Preflight.parseSizeBytes(result.stdout) {
                self.removedBytes[jobID] = bytes
            } else if result.status == 3 {
                // The removed-items folder does not exist yet.
                self.removedBytes[jobID] = 0
            }
        }
    }

    public func emptyRemovedItems(jobID: String) {
        guard !working, !status.isBusy, let job = self.job(id: jobID) else { return }
        guard let rclone = locateRclone() else {
            status = .needsAttention(SyncEngine.rcloneMissingMessage)
            return
        }
        if let problem = SyncEngine.purgeProblem(job: job) {
            status = .needsAttention(problem)
            return
        }
        let args = RcloneCommand.purge(path: job.removedRoot)
        if case .refused(let reason) = SafetyRules.assertSafe(arguments: args, removedRoot: job.removedRoot) {
            status = .needsAttention(reason)
            return
        }
        let previous: EngineStatus = status
        let previousJobID: String? = statusJobID
        beginWork(job: job)
        status = .preparing("Emptying removed items")
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await self.stopHelper()
            let runner = self.makeRunner(rclone, args)
            self.currentRunner = runner
            let result = await runner.capture(timeout: nil)
            self.currentRunner = nil
            if result.status == 0 || result.status == 3 {
                self.removedBytes[jobID] = 0
                self.status = previous
                self.statusJobID = previousJobID
            } else if self.stopReason != nil {
                self.status = previous
                self.statusJobID = previousJobID
            } else {
                let lines: [String] = result.stderr.split(separator: "\n").map(String.init)
                let c = ErrorClassifier.classify(exitCode: result.status, errorLines: lines)
                if c.needsReconnect {
                    self.needsReconnect = true
                    self.status = .needsAttention(ErrorClassifier.reconnectMessage)
                } else {
                    self.status = .needsAttention("Couldn't empty removed items. " + c.message)
                }
            }
            self.finishWork()
            self.refreshRemovedSize(jobID: jobID)
        }
    }

    // MARK: - rclone

    public func recheckRclone() {
        rclonePath = RcloneLocator(candidates: environment.rcloneCandidates).locate()
    }

    public func reconnectCommand(for jobID: String) -> String {
        var binary: String = rclonePath ?? "rclone"
        if binary.contains(" ") { binary = "'" + binary + "'" }
        var remote: String = job(id: jobID)?.remoteName ?? ""
        if remote.isEmpty { remote = "onedrive:" }
        return binary + " config reconnect " + remote
    }

    // MARK: - Sync flow

    /// Returns true when the real sync ran (so the removed size may have changed).
    private func performSync(job: SyncJob, automatic: Bool, skipCloudCheck: Bool) async -> Bool {
        await stopHelper()
        let startedAt: Date = environment.now()

        guard let rclone = prepare(job: job, notify: true) else { return false }

        // 0. Files deleted in the cloud since the last backup: ask before putting them back.
        if !skipCloudCheck {
            let held: Bool = await holdForCloudDeletions(job: job, rclone: rclone)
            if held { return false }
        }

        let timeZone: TimeZone = environment.timeZone ?? TimeZone.current
        let stamp: String = RcloneCommand.stamp(for: startedAt, timeZone: timeZone)
        let log: RunLog = openLog(jobID: job.id, stamp: stamp)
        let logHandles: [FileHandle] = log.handle.map { [$0] } ?? []
        defer { log.close() }

        // 1. Dry run: learn what will change, and how much to upload.
        status = .preparing("Looking at what changed")
        progress = SyncProgress()
        let dryArgs: [String] = RcloneCommand.sync(job: job, dryRun: true, date: startedAt, timeZone: timeZone)
        if case .refused(let reason) = SafetyRules.assertSafe(arguments: dryArgs, removedRoot: job.removedRoot) {
            finishEarly(job: job, outcome: Outcome(status: .needsAttention(reason), run: .failed, message: reason), notify: true)
            return false
        }
        let dryParser = RcloneLogParser()
        let dryExit: Int32 = await runRclone(rclone, dryArgs, parser: dryParser, logHandles: logHandles, live: false)
        if stopReason != nil || dryExit != 0 {
            finishEarly(job: job, outcome: outcome(exit: dryExit, parser: dryParser, job: job), notify: true)
            return false
        }
        let items: [ChangeItem] = dryParser.changeItems
        // A source that is a parent of a private or never-sync folder: refuse before anything is sent.
        if case .refused(let reason) = SafetyRules.checkItems(items, job: job, config: config) {
            finishEarly(job: job, outcome: Outcome(status: .needsAttention(reason), run: .failed, message: reason), notify: true)
            return false
        }
        preview = PreviewResult(jobID: job.id, date: environment.now(), items: items)
        // Unattended runs stop when most of the cloud copy would be moved away (wrong disk, half-copied folder).
        let removedCount: Int = items.filter { $0.kind == .removed }.count
        if automatic && SyncEngine.looksLikeMassRemoval(removed: removedCount, checked: dryParser.progress.checksTotal) {
            let message = "This backup would remove \(Format.count(removedCount)) files from the cloud copy, so Koffer didn't start it on its own. Check the disk and \"What will change?\", then press \"Back up now\" if that's right."
            finishEarly(job: job, outcome: Outcome(status: .needsAttention(message), run: .failed, message: message), notify: true)
            return false
        }
        let uploadBytes: Int64 = dryParser.dryRunUploadBytes
        let uploadFiles: Int = items.filter { $0.kind == .new || $0.kind == .replaced }.count

        // 2. Free space in the cloud.
        status = .preparing("Checking free space")
        if uploadBytes > 0, let target = Preflight.aboutTarget(forDestination: job.destination) {
            let aboutArgs: [String] = RcloneCommand.about(remote: target)
            let runner = makeRunner(rclone, aboutArgs)
            currentRunner = runner
            let about = await runner.capture(timeout: 120)
            currentRunner = nil
            if stopReason != nil {
                finishEarly(job: job, outcome: outcome(exit: about.status, parser: RcloneLogParser(), job: job), notify: true)
                return false
            }
            if about.status == 0 {
                let free: Int64? = Preflight.parseAboutFree(about.stdout)
                if case .refused(let reason) = Preflight.checkFreeSpace(freeBytes: free, uploadBytes: uploadBytes) {
                    finishEarly(job: job, outcome: Outcome(status: .needsAttention(reason), run: .failed, message: reason), notify: true)
                    return false
                }
            } else if RcloneLogParser.looksLikeAuthProblem(about.stderr) {
                needsReconnect = true
                let message = ErrorClassifier.reconnectMessage
                finishEarly(job: job, outcome: Outcome(status: .needsAttention(message), run: .failed, message: message), notify: true)
                return false
            }
            // Any other failure of `about`: skip the check (not every remote reports free space).
        }
        if stopReason != nil {
            finishEarly(job: job, outcome: outcome(exit: 0, parser: RcloneLogParser(), job: job), notify: true)
            return false
        }

        // The dry run can take a long time: make sure the disk is still there and the folder is not empty
        // right before the real sync (an empty source would move the whole cloud copy to removed items).
        if let volume = job.requiredVolume, !mountedVolumes.contains(volume) {
            let message = SyncEngine.unpluggedMessage
            finishEarly(job: job, outcome: Outcome(status: .paused(message), run: .paused, message: message), notify: true)
            return false
        }
        if case .refused(let reason) = Preflight.checkSource(job.source) {
            finishEarly(job: job, outcome: Outcome(status: .needsAttention(reason), run: .failed, message: reason), notify: true)
            return false
        }

        // 3. The real sync.
        let realArgs: [String] = RcloneCommand.sync(job: job, dryRun: false, date: startedAt, timeZone: timeZone)
        if case .refused(let reason) = SafetyRules.assertSafe(arguments: realArgs, removedRoot: job.removedRoot) {
            finishEarly(job: job, outcome: Outcome(status: .needsAttention(reason), run: .failed, message: reason), notify: true)
            return false
        }
        services.power.begin(reason: "Backing up \(job.name)")
        services.notifier.syncStarted(job: job)
        status = .syncing
        floorFiles = uploadFiles
        floorBytes = uploadBytes
        var initial = SyncProgress()
        initial.filesTotal = uploadFiles
        initial.bytesTotal = uploadBytes
        progress = initial
        lastProgressPublish = .distantPast

        let parser = RcloneLogParser()
        liveParser = parser
        let exitCode: Int32 = await runRclone(rclone, realArgs, parser: parser, logHandles: logHandles, live: true)
        publishProgress(from: parser, force: true)
        liveParser = nil

        let result: Outcome = outcome(exit: exitCode, parser: parser, job: job)
        // A clean run: remember what is in the cloud now, so deletions made there can be noticed next time.
        if exitCode == 0 && stopReason == nil && parser.progress.errors == 0 && result.status == .done {
            await recordCloudManifest(job: job, rclone: rclone, date: startedAt, logHandle: log.handle)
        }
        let p: SyncProgress = progress
        let record = RunRecord(jobID: job.id, jobName: job.name, startedAt: startedAt, endedAt: environment.now(),
                               outcome: result.run, uploaded: p.uploaded, moved: p.moved, removed: p.removed,
                               errors: p.errors, bytesTransferred: p.bytesDone, message: result.message,
                               logPath: log.url?.path)
        services.history.append(record)
        history = services.history.load()
        status = result.status
        switch result.run {
        case .completed:
            services.notifier.syncFinished(record: record)
        case .paused:
            services.notifier.syncPaused(job: job, reason: result.message ?? "Paused")
        case .failed:
            services.notifier.syncFailed(job: job, reason: result.message ?? "Something went wrong")
        }
        services.power.end()
        log.close()
        copyLogToExtraDirectory(job: job, logURL: log.url)
        return true
    }

    private func performPreview(job: SyncJob) async {
        await stopHelper()
        guard let rclone = prepare(job: job, notify: false) else { return }
        status = .previewing
        guard let cloudDeleted = await previewCloudDeletions(job: job, rclone: rclone) else { return }
        let timeZone: TimeZone = environment.timeZone ?? TimeZone.current
        let args: [String] = RcloneCommand.sync(job: job, dryRun: true, date: environment.now(), timeZone: timeZone)
        if case .refused(let reason) = SafetyRules.assertSafe(arguments: args, removedRoot: job.removedRoot) {
            status = .needsAttention(reason)
            return
        }
        let parser = RcloneLogParser()
        let exitCode: Int32 = await runRclone(rclone, args, parser: parser, logHandles: [], live: false)
        if stopReason != nil || exitCode != 0 {
            status = outcome(exit: exitCode, parser: parser, job: job).status
            return
        }
        if case .refused(let reason) = SafetyRules.checkItems(parser.changeItems, job: job, config: config) {
            status = .needsAttention(reason)
            return
        }
        preview = PreviewResult(jobID: job.id, date: environment.now(), items: parser.changeItems, cloudDeleted: cloudDeleted)
        updateJob(job.id) { (j: inout SyncJob) in j.previewApproved = true }
        status = .idle
    }

    /// Checks shared by sync and preview. Returns the rclone path, or nil after setting status.
    private func prepare(job: SyncJob, notify: Bool) -> String? {
        if configBroken {
            status = .needsAttention(SyncEngine.settingsUnreadableMessage)
            return nil
        }
        if !job.enabled {
            let message = "\(job.name) is turned off"
            finishEarly(job: job, outcome: Outcome(status: .needsAttention(message), run: .failed, message: message), notify: false)
            return nil
        }
        if case .refused(let reason) = SafetyRules.check(job: job, config: config, homeDirectory: environment.homeDirectory) {
            finishEarly(job: job, outcome: Outcome(status: .needsAttention(reason), run: .failed, message: reason), notify: notify)
            return nil
        }
        guard let rclone = locateRclone() else {
            let message = SyncEngine.rcloneMissingMessage
            finishEarly(job: job, outcome: Outcome(status: .needsAttention(message), run: .failed, message: message), notify: notify)
            return nil
        }
        if let volume = job.requiredVolume, !mountedVolumes.contains(volume) {
            let message = "The disk \(volume) isn't plugged in"
            finishEarly(job: job, outcome: Outcome(status: .paused(message), run: .paused, message: message), notify: false)
            return nil
        }
        if !isOnline && needsNetwork(job) {
            pausedOfflineJobID = job.id
            let message = SyncEngine.offlineMessage
            finishEarly(job: job, outcome: Outcome(status: .paused(message), run: .paused, message: message), notify: notify)
            return nil
        }
        if case .refused(let reason) = Preflight.checkSource(job.source) {
            finishEarly(job: job, outcome: Outcome(status: .needsAttention(reason), run: .failed, message: reason), notify: notify)
            return nil
        }
        if stopReason != nil {
            finishEarly(job: job, outcome: outcome(exit: 0, parser: RcloneLogParser(), job: job), notify: false)
            return nil
        }
        return rclone
    }

    /// Ends a run that never reached the real sync: sets status and (optionally) notifies. No history entry.
    private func finishEarly(job: SyncJob, outcome: Outcome, notify: Bool) {
        status = outcome.status
        guard notify else { return }
        switch outcome.run {
        case .completed:
            break
        case .paused:
            let stoppedByUser: Bool = stopReason == .user
            if !stoppedByUser {
                services.notifier.syncPaused(job: job, reason: outcome.message ?? "Paused")
            }
        case .failed:
            services.notifier.syncFailed(job: job, reason: outcome.message ?? "Something went wrong")
        }
    }

    private func outcome(exit: Int32, parser: RcloneLogParser, job: SyncJob) -> Outcome {
        if let reason = stopReason {
            switch reason {
            case .user:
                return Outcome(status: .paused(SyncEngine.stoppedByYouMessage), run: .paused, message: SyncEngine.stoppedByYouMessage)
            case .volumeGone:
                return Outcome(status: .paused(SyncEngine.unpluggedMessage), run: .paused, message: SyncEngine.unpluggedMessage)
            case .offline:
                pausedOfflineJobID = job.id
                return Outcome(status: .paused(SyncEngine.offlineMessage), run: .paused, message: SyncEngine.offlineMessage)
            }
        }
        if exit == 0 {
            needsReconnect = false
            // rclone normally exits non-zero after errors; never call a run with errors "done".
            let errors: Int = parser.progress.errors
            if errors > 0 {
                let files: String = errors == 1 ? "1 file" : "\(Format.count(errors)) files"
                let message = "The backup finished, but \(files) couldn't be sent. The log has the details."
                return Outcome(status: .needsAttention(message), run: .completed, message: message)
            }
            return Outcome(status: .done, run: .completed, message: nil)
        }
        var lines: [String] = parser.errorLines
        if let last = parser.lastStatsError { lines.append(last) }
        let c = ErrorClassifier.classify(exitCode: exit, errorLines: lines,
                                         sawAuthProblem: parser.sawAuthProblem, sawThrottle: parser.sawThrottle)
        if c.needsReconnect {
            needsReconnect = true
            return Outcome(status: .needsAttention(c.message), run: .failed, message: c.message)
        }
        if c.sourceMissing {
            var unplugged = !FileManager.default.fileExists(atPath: job.source)
            if let volume = job.requiredVolume, !mountedVolumes.contains(volume) { unplugged = true }
            if unplugged {
                return Outcome(status: .paused(SyncEngine.unpluggedMessage), run: .paused, message: SyncEngine.unpluggedMessage)
            }
            let message = "rclone could not read the folder to back up"
            return Outcome(status: .needsAttention(message), run: .failed, message: message)
        }
        if c.networkLikely {
            pausedOfflineJobID = job.id
            return Outcome(status: .paused(SyncEngine.offlineMessage), run: .paused, message: SyncEngine.offlineMessage)
        }
        return Outcome(status: .needsAttention(c.message), run: .failed, message: c.message)
    }

    private func runRclone(_ path: String, _ args: [String], parser: RcloneLogParser,
                           logHandles: [FileHandle], live: Bool) async -> Int32 {
        let runner = makeRunner(path, args, logHandles: logHandles,
                                onLine: { [weak self] (line: String) in
            parser.consume(line: line)
            if live { self?.publishProgress(from: parser, force: false) }
        })
        currentRunner = runner
        if stopReason != nil { runner.interrupt(grace: environment.interruptGrace) }
        let exitCode: Int32 = await runner.run()
        currentRunner = nil
        return exitCode
    }

    /// Copies parser state into `progress`, at most ~4 times a second (plus a trailing update).
    private func publishProgress(from parser: RcloneLogParser, force: Bool) {
        let now = Date()
        if !force && now.timeIntervalSince(lastProgressPublish) < minPublishInterval {
            if !trailingPublishScheduled {
                trailingPublishScheduled = true
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard let self = self else { return }
                    self.trailingPublishScheduled = false
                    if let live = self.liveParser, live === parser {
                        self.publishProgress(from: live, force: true)
                    }
                }
            }
            return
        }
        lastProgressPublish = now
        var p: SyncProgress = parser.progress
        if !parser.sawStats {
            p.uploaded = parser.uploadEvents
            p.filesDone = parser.uploadEvents
            p.moved = parser.moveEvents
        }
        p.filesTotal = max(p.filesTotal, floorFiles)
        p.bytesTotal = max(p.bytesTotal, floorBytes)
        if p.etaSeconds == nil && p.speed > 0 && p.bytesTotal > p.bytesDone {
            p.etaSeconds = Double(p.bytesTotal - p.bytesDone) / p.speed
        }
        if p != progress { progress = p }
    }

    // MARK: - Helpers

    private func beginWork(job: SyncJob) {
        working = true
        runningJob = job
        activeJobID = job.id
        statusJobID = job.id
        stopReason = nil
    }

    private func finishWork() {
        working = false
        runningJob = nil
        activeJobID = nil
        stopReason = nil
        currentRunner = nil
        liveParser = nil
    }

    private func stopHelper() async {
        if let runner = helperRunner { runner.terminate() }
        if let task = helperTask { await task.value }
        helperRunner = nil
        helperTask = nil
    }

    /// Every rclone child process is made here, so a test's RCLONE_CONFIG reaches all of them.
    private func makeRunner(_ executable: String, _ arguments: [String], logHandles: [FileHandle] = [],
                            onLine: (@MainActor (String) -> Void)? = nil) -> RcloneRunner {
        let runner = RcloneRunner(executablePath: executable, arguments: arguments, logHandles: logHandles, onLine: onLine)
        if let configPath = environment.rcloneConfigPath {
            runner.environmentOverrides["RCLONE_CONFIG"] = configPath
        }
        return runner
    }

    private func locateRclone() -> String? {
        let path = RcloneLocator(candidates: environment.rcloneCandidates).locate()
        if path != rclonePath { rclonePath = path }
        return path
    }

    private func needsNetwork(_ job: SyncJob) -> Bool {
        let destinationLocal: Bool = RcloneLocation.parse(job.destination)?.isLocal ?? false
        let removedLocal: Bool = RcloneLocation.parse(job.removedRoot)?.isLocal ?? false
        return !(destinationLocal && removedLocal)
    }

    private func isAutoEligible(_ job: SyncJob) -> Bool {
        return job.enabled && job.autoSyncOnMount && job.previewApproved && job.requiredVolume != nil
    }

    private func autoStart(volume: String) {
        guard !working, !status.isBusy, !configBroken, mountedVolumes.contains(volume) else { return }
        reloadConfig()
        guard !configBroken else { return }
        guard let job = jobs.first(where: { isAutoEligible($0) && $0.requiredVolume == volume && cloudDeletions[$0.id] == nil })
        else { return }
        if !isOnline && needsNetwork(job) {
            pausedOfflineJobID = job.id
            return
        }
        startSync(jobID: job.id, automatic: true)
    }

    /// True when an unattended run would move a large share of the cloud copy into removed items.
    /// `checked` is the dry run's `totalChecks`.
    nonisolated static func looksLikeMassRemoval(removed: Int, checked: Int) -> Bool {
        if removed >= 500 { return true }
        return removed >= 20 && removed * 2 >= checked
    }

    /// Picks up hand edits (a job switched off, a new private folder) before anything runs.
    /// A missing file keeps what is in memory; an unreadable one stops everything, as at launch.
    private func reloadConfig() {
        guard !configBroken else { return }
        guard FileManager.default.fileExists(atPath: configStore.fileURL.path) else { return }
        do {
            let fresh: KofferConfig = try configStore.load()
            config = fresh
            if jobs != fresh.jobs { jobs = fresh.jobs }
        } catch {
            configBroken = true
            if !working {
                status = .needsAttention(SyncEngine.settingsUnreadableMessage)
                statusJobID = nil
            }
        }
    }

    /// Re-reads the file (so hand edits are not lost), applies the change and saves.
    private func updateJob(_ id: String, _ change: (inout SyncJob) -> Void) {
        guard !configBroken else { return }
        var fresh: KofferConfig = config
        if FileManager.default.fileExists(atPath: configStore.fileURL.path) {
            do {
                fresh = try configStore.load()
            } catch {
                configBroken = true
                if !working {
                    status = .needsAttention(SyncEngine.settingsUnreadableMessage)
                    statusJobID = nil
                }
                return
            }
        }
        guard let index = fresh.jobs.firstIndex(where: { $0.id == id }) else {
            config = fresh
            jobs = fresh.jobs
            return
        }
        change(&fresh.jobs[index])
        config = fresh
        jobs = fresh.jobs
        do {
            try configStore.save(fresh)
        } catch {
            if !working { status = .needsAttention("Koffer couldn't save its settings") }
        }
    }

    /// Why purging this job's removed-items folder would be unsafe, or nil when it is fine.
    static func purgeProblem(job: SyncJob) -> String? {
        guard let removed = RcloneLocation.parse(job.removedRoot) else {
            return "The removed-items folder is not set up correctly."
        }
        if removed.isLocal ? (removed.path == "/") : removed.path.isEmpty {
            return "Refusing to empty the top of a drive."
        }
        if let destination = RcloneLocation.parse(job.destination) {
            if removed.isSameOrInside(destination) || destination.isSameOrInside(removed) {
                return "The removed-items folder overlaps the backup itself, so it was not emptied."
            }
        }
        if removed.isLocal, let source = RcloneLocation.parse(job.source), source.isLocal {
            if removed.isSameOrInside(source) || source.isSameOrInside(removed) {
                return "The removed-items folder overlaps the folder being backed up, so it was not emptied."
            }
        }
        return nil
    }

    static func scanVolumes(_ directory: String?) -> Set<String> {
        guard let dir = directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return Set(names.filter { !$0.hasPrefix(".") })
    }

    private static func safeFileName(_ s: String) -> String {
        let bad: Set<Character> = ["/", ":", "\\"]
        return String(s.map { bad.contains($0) ? "_" : $0 })
    }

    private func openLog(jobID: String, stamp: String) -> RunLog {
        let fm = FileManager.default
        let dir: URL = environment.logDirectory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            let url = dir.appendingPathComponent("\(SyncEngine.safeFileName(jobID))_\(stamp).log")
            if !fm.fileExists(atPath: url.path) {
                _ = fm.createFile(atPath: url.path, contents: nil, attributes: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            _ = try handle.seekToEnd()
            return RunLog(url: url, handle: handle)
        } catch {
            return RunLog(url: nil, handle: nil)
        }
    }

    /// Copies the finished log into `job.extraLogDirectory`. Failure is ignored on purpose.
    /// Done after the run, so a log folder inside the backed-up folder never changes while rclone reads it.
    private func copyLogToExtraDirectory(job: SyncJob, logURL: URL?) {
        guard let source = logURL,
              let extra = job.extraLogDirectory?.trimmingCharacters(in: .whitespaces), !extra.isEmpty else { return }
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: extra, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            let target = dir.appendingPathComponent(source.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
        } catch {
            // Not fatal: the main log is still in place.
        }
    }
}

/// The log file of one run. `close()` may be called more than once.
final class RunLog {
    let url: URL?
    private(set) var handle: FileHandle?

    init(url: URL?, handle: FileHandle?) {
        self.url = url
        self.handle = handle
    }

    func close() {
        guard let h = handle else { return }
        handle = nil
        try? h.synchronize()
        try? h.close()
    }
}

// MARK: - v0.2: everything through the panel

// In this file (not a separate one) so it can use the engine's private state (`working`, `config`, ...).
extension SyncEngine {

    // MARK: Connection check

    /// `rclone listremotes`, then `rclone about <remote> --json` for each remote, one after the other.
    /// Skipped when the last check is younger than `environment.remotesCheckInterval` (unless `force`),
    /// and never started while a backup, preview or purge is in flight (the states stay as they are).
    /// Never touches `status`, `activeJobID` or `statusJobID`.
    public func refreshRemotes(force: Bool) {
        guard !working, !status.isBusy else { return }
        if remotesTask != nil {
            if force { remotesRefreshPending = true }
            return
        }
        if !force, let last = lastRemotesCheck,
           environment.now().timeIntervalSince(last) < environment.remotesCheckInterval {
            return
        }
        guard let rclone = locateRclone() else { return }
        lastRemotesCheck = environment.now()
        remotesRefreshPending = false
        remotesTask = Task { [weak self] in
            guard let self = self else { return }
            await self.performRemotesRefresh(rclone: rclone)
            self.remotesTask = nil
            if self.remotesRefreshPending {
                self.remotesRefreshPending = false
                self.refreshRemotes(force: true)
            }
        }
    }

    private func performRemotesRefresh(rclone: String) async {
        let listArgs: [String] = RcloneCommand.listRemotes()
        guard SafetyRules.assertSafe(arguments: listArgs, removedRoot: "").isOK else { return }
        let list = await makeRunner(rclone, listArgs).capture(timeout: 60)
        if list.status != 0 {
            let line: String = RemoteParsing.lastErrorLine(list.stderr) ?? "rclone stopped with code \(list.status)"
            let message: String = "Koffer couldn't read rclone's list of connections: " + line
            var failed: [String: RemoteState] = [:]
            for r in remotes { failed[r] = .failed(message) }
            remoteStates = failed
            return
        }
        let names: [String] = RemoteParsing.parseListRemotes(list.stdout)
        if names != remotes { remotes = names }
        let previous: [String: RemoteState] = remoteStates
        var states: [String: RemoteState] = [:]
        for r in names { states[r] = .checking }
        remoteStates = states

        var authFailed: Set<String> = []
        var connected: Set<String> = []
        for r in names {
            if working {
                // A backup started meanwhile: leave the rest as they were.
                states[r] = previous[r] ?? .unknown
                remoteStates[r] = states[r]
                continue
            }
            let args: [String] = RcloneCommand.about(remote: r)
            if case .refused(let reason) = SafetyRules.assertSafe(arguments: args, removedRoot: "") {
                remoteStates[r] = .failed(reason)
                continue
            }
            let result = await makeRunner(rclone, args).capture(timeout: 60)
            let mapped = RemoteParsing.remoteState(remote: r, status: result.status, stdout: result.stdout, stderr: result.stderr)
            remoteStates[r] = mapped.state
            if mapped.isAuthProblem {
                authFailed.insert(SafetyRules.remoteKey(r))
            } else if case .connected = mapped.state {
                connected.insert(SafetyRules.remoteKey(r))
            }
        }

        // `needsReconnect` is about the remotes the backups use; a stale remote nobody uses must not block them.
        var jobRemotes: Set<String> = []
        for j in jobs {
            let key: String = SafetyRules.remoteKey(j.remoteName)
            if !key.isEmpty { jobRemotes.insert(key) }
        }
        if !authFailed.intersection(jobRemotes).isEmpty {
            needsReconnect = true
        } else if needsReconnect && !jobRemotes.isEmpty && jobRemotes.isSubset(of: connected) {
            needsReconnect = false
        }
    }

    /// A folder command hit an expired sign-in.
    private func noteAuthProblem(remote: String) {
        let key: String = SafetyRules.remoteKey(remote)
        if key.isEmpty { return }
        let name: String = remote.hasSuffix(":") ? remote : remote + ":"
        remoteStates[name] = .failed(RemoteParsing.reconnectMessage(name))
        if jobs.contains(where: { SafetyRules.remoteKey($0.remoteName) == key }) {
            needsReconnect = true
        }
    }

    // MARK: Cloud folders

    /// Names of the folders directly inside `remote` + `path`, sorted case-insensitively.
    /// `remote` is "onedrive:" (path relative to its top, "" = the top) or "" for this computer (path is a full path).
    public func listFolders(remote: String, path: String) async -> Result<[String], EngineError> {
        if working || status.isBusy { return .failure(EngineError(SyncEngine.waitForBackupMessage)) }
        guard let target = RemoteParsing.target(remote: remote, path: path) else {
            return .failure(EngineError("That folder can't be opened. Folder names \".\" and \"..\" aren't allowed."))
        }
        guard let rclone = locateRclone() else { return .failure(EngineError(SyncEngine.rcloneMissingMessage)) }
        let args: [String] = RcloneCommand.listFolders(target: target)
        if case .refused(let reason) = SafetyRules.assertSafe(arguments: args, removedRoot: "") {
            return .failure(EngineError(reason))
        }
        let result = await makeRunner(rclone, args).capture(timeout: 120)
        if result.status == 0 {
            if let names = RemoteParsing.parseFolderNames(result.stdout) { return .success(names) }
            return .failure(EngineError("Koffer couldn't read the list of folders."))
        }
        let mapped = RemoteParsing.folderError(remote: remote, status: result.status, stderr: result.stderr,
                                               action: "open that folder")
        if mapped.isAuthProblem { noteAuthProblem(remote: remote) }
        return .failure(mapped.error)
    }

    /// `rclone mkdir <remote><path>`. Success is `.success(true)`; an existing folder is fine too.
    public func createFolder(remote: String, path: String) async -> Result<Bool, EngineError> {
        if working || status.isBusy { return .failure(EngineError(SyncEngine.waitForBackupMessage)) }
        if RemoteParsing.hasEmptyPart(path) { return .failure(EngineError("Give the new folder a name.")) }
        guard let target = RemoteParsing.target(remote: remote, path: path) else {
            return .failure(EngineError("That folder name can't be used. \".\" and \"..\" aren't allowed."))
        }
        guard let rclone = locateRclone() else { return .failure(EngineError(SyncEngine.rcloneMissingMessage)) }
        let args: [String] = RcloneCommand.mkdir(target: target)
        if case .refused(let reason) = SafetyRules.assertSafe(arguments: args, removedRoot: "") {
            return .failure(EngineError(reason))
        }
        let result = await makeRunner(rclone, args).capture(timeout: 120)
        if result.status == 0 { return .success(true) }
        let mapped = RemoteParsing.folderError(remote: remote, status: result.status, stderr: result.stderr,
                                               action: "create the folder")
        if mapped.isAuthProblem { noteAuthProblem(remote: remote) }
        return .failure(mapped.error)
    }

    // MARK: New backups

    /// A ready-to-add job: destination = remote + remotePath; removed items go to the sibling folder
    /// "_<last part>_removed"; tied to the disk when the folder is under /Volumes/<name>/; a unique id from the name.
    /// `remote` "" means this computer (then `remotePath` is a full path).
    public func proposedJob(name: String, source: String, remote: String, remotePath: String) -> SyncJob {
        let cleanSource: String = SafetyRules.normalizeLocal(source.trimmingCharacters(in: .whitespaces))
        let trimmedName: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var jobName: String = trimmedName
        if jobName.isEmpty {
            jobName = (cleanSource as NSString).lastPathComponent
            if jobName.isEmpty || jobName == "/" { jobName = "Backup" }
        }

        var remoteName: String = remote.trimmingCharacters(in: .whitespaces)
        if !remoteName.isEmpty && !remoteName.hasSuffix(":") { remoteName += ":" }
        let destination: String
        let removedRoot: String
        if remoteName.isEmpty {
            let dest: String = SafetyRules.normalizeLocal(remotePath.trimmingCharacters(in: .whitespaces))
            destination = dest
            var last: String = (dest as NSString).lastPathComponent
            if last.isEmpty || last == "/" { last = RemoteParsing.slug(jobName) }
            var parent: String = (dest as NSString).deletingLastPathComponent
            if parent.isEmpty { parent = "/" }
            removedRoot = RcloneCommand.join(parent, "_" + last + "_removed")
        } else {
            var parts: [String] = remotePath.split(separator: "/", omittingEmptySubsequences: true).map { String($0) }
            destination = remoteName + parts.joined(separator: "/")
            let last: String = parts.last ?? RemoteParsing.slug(jobName)
            if !parts.isEmpty { parts.removeLast() }
            parts.append("_" + last + "_removed")
            removedRoot = remoteName + parts.joined(separator: "/")
        }

        var volume: String? = nil
        let components: [String] = cleanSource.split(separator: "/").map { String($0) }
        if components.count >= 2 && components[0] == "Volumes" && !components[1].isEmpty {
            volume = components[1]
        }

        var taken: Set<String> = [SyncJob.testJobID]
        for j in jobs { taken.insert(j.id) }
        for j in config.jobs { taken.insert(j.id) }
        let base: String = RemoteParsing.slug(jobName)
        var id: String = base
        var n: Int = 2
        while taken.contains(id) {
            id = base + "-" + String(n)
            n += 1
        }

        return SyncJob(id: id, name: jobName, source: cleanSource, destination: destination, removedRoot: removedRoot,
                       requiredVolume: volume, autoSyncOnMount: volume != nil, enabled: true, previewApproved: false,
                       extraLogDirectory: nil, isTest: false)
    }

    /// Checks the job (safety rules against the settings on disk, no duplicates, no shared cloud folders),
    /// then saves it. A refusal changes nothing.
    public func addJob(_ job: SyncJob) -> SafetyVerdict {
        reloadConfig()
        if configBroken { return .refused(SyncEngine.settingsUnreadableMessage) }
        if job.id.trimmingCharacters(in: .whitespaces).isEmpty || job.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return .refused("The backup needs a name.")
        }
        if case .refused(let reason) = SafetyRules.check(job: job, config: config, homeDirectory: environment.homeDirectory) {
            return .refused(reason)
        }
        if let problem = SyncEngine.conflictWithExistingJobs(job, existing: config.jobs) {
            return .refused(problem)
        }
        var fresh: KofferConfig = config
        fresh.jobs.append(job)
        do {
            try configStore.save(fresh)
        } catch {
            return .refused("Koffer couldn't save its settings, so the backup wasn't added.")
        }
        config = fresh
        jobs = fresh.jobs
        return .ok
    }

    /// Forgets a job in the settings only. Nothing in the cloud is touched. Refused while that job runs.
    public func removeJob(id: String) -> SafetyVerdict {
        if working, let running = runningJob, running.id == id {
            return .refused("Stop this backup first, then forget it.")
        }
        if configBroken { return .refused(SyncEngine.settingsUnreadableMessage) }
        var fresh: KofferConfig = config
        if FileManager.default.fileExists(atPath: configStore.fileURL.path) {
            do {
                fresh = try configStore.load()
            } catch {
                configBroken = true
                if !working {
                    status = .needsAttention(SyncEngine.settingsUnreadableMessage)
                    statusJobID = nil
                }
                return .refused(SyncEngine.settingsUnreadableMessage)
            }
        }
        guard let index = fresh.jobs.firstIndex(where: { $0.id == id }) else {
            config = fresh
            if jobs != fresh.jobs { jobs = fresh.jobs }
            return .refused("Koffer doesn't know that backup.")
        }
        fresh.jobs.remove(at: index)
        do {
            try configStore.save(fresh)
        } catch {
            return .refused("Koffer couldn't save its settings, so the backup wasn't forgotten.")
        }
        config = fresh
        jobs = fresh.jobs
        removedBytes[id] = nil
        cloudDeletions[id] = nil
        cloudDeletionDates[id] = nil
        manifestStore.remove(jobID: id)
        if preview?.jobID == id { preview = nil }
        if pausedOfflineJobID == id { pausedOfflineJobID = nil }
        if !working && statusJobID == id {
            status = .idle
            statusJobID = nil
        }
        return .ok
    }

    /// Why `job` can't sit next to the existing jobs, or nil. Duplicates first, then shared cloud folders:
    /// one job's sync would move another job's files into its removed items.
    static func conflictWithExistingJobs(_ job: SyncJob, existing: [SyncJob]) -> String? {
        guard let newDestination = RcloneLocation.parse(job.destination),
              let newRemoved = RcloneLocation.parse(job.removedRoot) else {
            return "The destination is not a valid rclone path (remote:folder)."
        }
        let newSource: String = SafetyRules.normalizeLocal(job.source.trimmingCharacters(in: .whitespaces)).lowercased()
        for other in existing {
            guard let otherDestination = RcloneLocation.parse(other.destination) else { continue }
            let otherSource: String = SafetyRules.normalizeLocal(other.source.trimmingCharacters(in: .whitespaces)).lowercased()
            let sameDestination: Bool = otherDestination.isSameOrInside(newDestination) && newDestination.isSameOrInside(otherDestination)
            if otherSource == newSource && sameDestination {
                return "\"\(other.name)\" already backs up this folder to the same place."
            }
        }
        for other in existing where other.id == job.id {
            return "There is already a backup with this id (\"\(other.name)\"). Pick another name."
        }
        for other in existing {
            var theirs: [RcloneLocation] = []
            if let d = RcloneLocation.parse(other.destination) { theirs.append(d) }
            if let r = RcloneLocation.parse(other.removedRoot) { theirs.append(r) }
            for mine in [newDestination, newRemoved] {
                for t in theirs where mine.isSameOrInside(t) || t.isSameOrInside(mine) {
                    return "This would share a cloud folder with \"\(other.name)\". Pick a separate folder."
                }
            }
        }
        return nil
    }

    // MARK: Installing rclone

    /// `/opt/homebrew/bin/brew` or `/usr/local/bin/brew` (see `environment.brewCandidates`) when executable.
    public var homebrewPath: String? {
        for path in environment.brewCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// With Homebrew: `brew install rclone`. Otherwise (or if Homebrew fails): download the official zip,
    /// unpack it with ditto, check the binary runs, and only then move it to
    /// `environment.rcloneInstallDirectory/rclone` (mode 755). Ends with `recheckRclone()` and `refreshRemotes(force: true)`.
    public func installRclone() {
        if case .running = installState { return }
        installState = .running(homebrewPath != nil ? SyncEngine.homebrewInstallingMessage : SyncEngine.downloadingMessage)
        installTask = Task { [weak self] in
            guard let self = self else { return }
            await self.performInstall()
            self.installTask = nil
        }
    }

    private func performInstall() async {
        var brewProblem: String? = nil
        if let brew = homebrewPath {
            installState = .running(SyncEngine.homebrewInstallingMessage)
            let runner = RcloneRunner(executablePath: brew, arguments: ["install", "rclone"])
            runner.environmentOverrides = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"]
            let result = await runner.capture(timeout: 1800)
            if result.status == 0 {
                recheckRclone()
                if rclonePath != nil {
                    finishInstall()
                    return
                }
                brewProblem = "Homebrew finished, but Koffer can't find its rclone."
            } else {
                let line: String? = RemoteParsing.lastErrorLine(result.stderr) ?? RemoteParsing.lastErrorLine(result.stdout)
                brewProblem = "Homebrew couldn't install rclone" + (line.map { ": " + $0 } ?? ".")
            }
        }
        installState = .running(SyncEngine.downloadingMessage)
        if let problem = await downloadAndInstallRclone() {
            if let b = brewProblem {
                installState = .failed(b + " Downloading it didn't work either: " + problem)
            } else {
                installState = .failed(problem)
            }
            return
        }
        recheckRclone()
        if rclonePath == nil {
            installState = .failed("rclone was installed, but Koffer can't find it.")
            return
        }
        finishInstall()
    }

    private func finishInstall() {
        installState = .succeeded
        refreshRemotes(force: true)
    }

    /// Returns nil on success, otherwise plain words. Never leaves a half-written binary in place:
    /// everything happens in a scratch folder next to the target, and the checked binary is renamed in one step.
    private func downloadAndInstallRclone() async -> String? {
        let fm = FileManager.default
        let binDirectory: URL = environment.rcloneInstallDirectory
        let work: URL = binDirectory.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return "Koffer couldn't create its folder for rclone."
        }
        defer { try? fm.removeItem(at: work) }

        let data: Data
        do {
            data = try await SyncEngine.downloadData(from: environment.rcloneDownloadURL)
        } catch let e as EngineError {
            return e.message
        } catch {
            return "Downloading rclone didn't work: \(error.localizedDescription)"
        }
        let zip: URL = work.appendingPathComponent("rclone.zip")
        do {
            try data.write(to: zip, options: [.atomic])
        } catch {
            return "Koffer couldn't save the download."
        }

        let unpacked: URL = work.appendingPathComponent("unpacked", isDirectory: true)
        let ditto = await RcloneRunner.capture(executablePath: "/usr/bin/ditto",
                                               arguments: ["-x", "-k", zip.path, unpacked.path], timeout: 300)
        if ditto.status != 0 {
            let line: String? = RemoteParsing.lastErrorLine(ditto.stderr)
            return "The download couldn't be unpacked" + (line.map { ": " + $0 } ?? ".")
        }
        guard let found = RemoteParsing.findBinary(in: unpacked, fileManager: fm) else {
            return "The download didn't contain rclone."
        }

        let staged: URL = work.appendingPathComponent("rclone-checked")
        do {
            try fm.moveItem(at: found, to: staged)
            try fm.setAttributes([FileAttributeKey.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: staged.path)
        } catch {
            return "Koffer couldn't prepare rclone."
        }
        // Make sure it really runs on this Mac before it replaces anything.
        let versionArgs: [String] = RcloneCommand.version()
        guard SafetyRules.assertSafe(arguments: versionArgs, removedRoot: "").isOK else { return "Koffer couldn't check rclone." }
        let check = await RcloneRunner.capture(executablePath: staged.path, arguments: versionArgs, timeout: 60)
        if check.status != 0 {
            return "The downloaded rclone doesn't run on this Mac."
        }
        let destination: URL = binDirectory.appendingPathComponent("rclone")
        if rename(staged.path, destination.path) != 0 {
            return "Koffer couldn't put rclone in place."
        }
        return nil
    }

    /// file:// URLs are read directly (tests); anything else goes through URLSession.
    nonisolated static func downloadData(from url: URL) async throws -> Data {
        if url.isFileURL {
            do {
                return try Data(contentsOf: url)
            } catch {
                throw EngineError("Downloading rclone didn't work: the file isn't there.")
            }
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw EngineError("Downloading rclone didn't work (the server answered \(http.statusCode)).")
        }
        return data
    }

    // MARK: Signing in again

    /// Signs in to `remote` ("onedrive:") again without Terminal. See `performReconnect` for how.
    public func reconnect(remote: String) {
        if case .running = reconnectState { return }
        let trimmed: String = remote.trimmingCharacters(in: .whitespaces)
        let name: String = trimmed.hasSuffix(":") ? trimmed : trimmed + ":"
        guard SafetyRules.isPlainRemoteName(name) else {
            reconnectState = .failed("That is not a connection Koffer can sign in to.")
            return
        }
        if working || status.isBusy {
            reconnectState = .failed(SyncEngine.waitForBackupMessage)
            return
        }
        guard let rclone = locateRclone() else {
            reconnectState = .failed(SyncEngine.rcloneMissingMessage)
            return
        }
        reconnectGeneration += 1
        let generation: Int = reconnectGeneration
        reconnectCancelled = false
        reconnectTimedOut = false
        reconnectState = .running(SyncEngine.signInWaitingMessage)
        // A cancelled sign-in may still be letting go of rclone's local port: wait for it first.
        let previous: Task<Void, Never>? = reconnectTask
        reconnectTask = Task { [weak self] in
            if let p = previous { await p.value }
            guard let self = self else { return }
            await self.performReconnect(rclone: rclone, remote: name, generation: generation)
            if generation == self.reconnectGeneration { self.reconnectTask = nil }
        }
    }

    /// Stops a sign-in that is waiting for the browser. reconnectState goes back to .idle.
    public func cancelReconnect() {
        guard case .running = reconnectState else { return }
        reconnectCancelled = true
        reconnectState = .idle
        reconnectRunner?.interrupt(grace: 3)
    }

    /// How signing in again works (checked against rclone v1.71.2; see the notes at the end of this comment).
    ///
    /// 1. `rclone listremotes --long` gives the remote's type. For a `onedrive` remote whose settings have a
    ///    `drive_id` (`rclone config redacted <name>`, which prints secrets as XXX), Koffer runs
    ///    `rclone config update <name> config_refresh_token=true config_is_local=true config_type=driveid
    ///    config_drive_ok=true --no-output --auto-confirm`, which signs in again and keeps the same drive.
    ///    Every other remote: `rclone config reconnect <name>: --auto-confirm`.
    /// 2. With `--auto-confirm` rclone asks nothing: it takes each question's default ("Already have a token -
    ///    refresh?" yes, "Use web browser to automatically authenticate?" yes), starts its own web server on
    ///    127.0.0.1:53682, opens the default browser itself (`open` on macOS) and prints "Waiting for code...".
    ///    stdin is /dev/null, so even an unexpected question gets end-of-input, which rclone reads as "default".
    /// 3. Koffer waits for the process: exit 0 = signed in (rclone has saved the new token). Non-zero = failed,
    ///    with rclone's last error line. After `environment.reconnectTimeout` (5 min) or `cancelReconnect()`,
    ///    Koffer sends SIGINT (rclone exits 130 and saves nothing), then SIGTERM after 3 s.
    ///
    /// Verified with the real binary against a scratch config (`--config /tmp/...`) holding a made-up onedrive
    /// remote with a fake token, no browser available:
    /// - `config reconnect` has no `--non-interactive`/`--continue`/`--state`/`--result` ("unknown flag",
    ///   exit 2); that JSON question protocol exists only on `config create`/`config update`, where each answer
    ///   is a separate rclone run and the browser step blocks inside one of them anyway. Not worth the moving parts.
    /// - Without flags and with stdin closed, rclone prints the y/n questions, takes the defaults and reaches
    ///   "Waiting for code..."; with `--auto-confirm` it prints no questions at all and reaches the same point.
    /// - The `config update` form above logs "Override value found" for each config_* answer and reaches
    ///   "Waiting for code..."; the config file is unchanged afterwards (config_* keys are never saved).
    /// - SIGINT while waiting: exit 130, config file unchanged.
    /// - A second sign-in while one waits: exit 2, "failed to start auth webserver: listen tcp 127.0.0.1:53682:
    ///   bind: address already in use". Unknown remote: exit 2, "didn't find section in config file".
    ///   Non-OAuth remote (local): exit 2, "backend doesn't support reconnect or authorize".
    /// Not verified here (needs a real account and a browser): the OAuth round trip itself, i.e. that after the
    /// browser sign-in rclone exits 0, and that OneDrive's follow-up questions (drive type, drive id, "Drive OK?")
    /// are answered as the rclone v1.71.2 source says (`config_type=driveid` -> drive id defaults to the current
    /// `drive_id` -> auto-confirmed; `driveid_final` re-reads the drive type).
    private func performReconnect(rclone: String, remote: String, generation: Int) async {
        var args: [String] = RcloneCommand.reconnect(remote: remote)
        let longArgs: [String] = RcloneCommand.listRemotes(long: true)
        if SafetyRules.assertSafe(arguments: longArgs, removedRoot: "").isOK {
            let list = await makeRunner(rclone, longArgs).capture(timeout: 30)
            let types: [String: String] = list.status == 0 ? RemoteParsing.parseListRemotesLong(list.stdout) : [:]
            if (types[remote] ?? "").lowercased() == "onedrive" {
                let redactedArgs: [String] = RcloneCommand.configRedacted(remote: remote)
                if SafetyRules.assertSafe(arguments: redactedArgs, removedRoot: "").isOK {
                    let redacted = await makeRunner(rclone, redactedArgs).capture(timeout: 30)
                    if redacted.status == 0 && RemoteParsing.redactedConfigHasDriveID(redacted.stdout) {
                        args = RcloneCommand.reconnectKeepingOneDriveDrive(remote: remote)
                    }
                }
            }
        }
        guard generation == reconnectGeneration, !reconnectCancelled else { return }
        if case .refused(let reason) = SafetyRules.assertSafe(arguments: args, removedRoot: "") {
            reconnectState = .failed(reason)
            return
        }

        let runner: RcloneRunner = makeRunner(rclone, args)
        reconnectRunner = runner
        let timeout: TimeInterval = max(0, environment.reconnectTimeout)
        let timer: Task<Void, Never> = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self = self else { return }
            if generation == self.reconnectGeneration { self.reconnectTimedOut = true }
            runner.interrupt(grace: 3)
        }
        let result = await runner.capture(timeout: nil)
        timer.cancel()
        if reconnectRunner === runner { reconnectRunner = nil }
        guard generation == reconnectGeneration else { return }
        if reconnectCancelled {
            reconnectState = .idle
            return
        }
        if reconnectTimedOut {
            let minutes: Int = max(1, Int((timeout / 60).rounded()))
            let unit: String = minutes == 1 ? "minute" : "minutes"
            reconnectState = .failed("Koffer waited \(minutes) \(unit) for the sign-in in your browser and stopped. Try again.")
            return
        }
        if result.status == 0 {
            reconnectState = .succeeded
            needsReconnect = false
            if case .failed = remoteStates[remote] ?? .unknown { remoteStates[remote] = .unknown }
            refreshRemotes(force: true)
        } else {
            reconnectState = .failed(RemoteParsing.reconnectFailure(remote: remote, status: result.status, stderr: result.stderr))
        }
    }
}

// MARK: - v0.3: deleted in the cloud

/// Listing the cloud copy with `rclone lsjson -R --files-only`.
enum CloudListingResult {
    case files([CloudManifest.Entry])
    /// `stderr` for auth detection, `message` in plain words.
    case failed(stderr: String, message: String)
}

/// Comparing the cloud copy with the last manifest.
enum CloudCheckResult {
    /// No manifest yet (or one for another destination): nothing to compare with.
    case noManifest
    /// Listed fine; nothing deleted in the cloud that is still here.
    case clean
    /// Candidates found, with each one's local modification date.
    case found(CloudDeletionReport, [String: Date])
    case listingFailed(stderr: String, message: String)
}

// In this file so it can use the engine's private state (`working`, `config`, `currentRunner`, ...).
extension SyncEngine {
    public static let checkingCloudMessage = "Checking the cloud copy"
    public static let massCloudDeletionRefusal = "That's a large part of this backup, so Koffer won't delete these files from this disk. Put them back, or delete them on this disk directly."

    /// "OneDrive", another remote's name, or "the backup copy" for a backup to a folder on this Mac.
    nonisolated public static func cloudDisplayName(_ job: SyncJob) -> String {
        if job.remoteName.isEmpty { return "the backup copy" }
        return RemoteParsing.displayName(job.remoteName)
    }

    /// The status text while a job's cloud deletions wait for a decision.
    nonisolated public static func cloudDeletionsMessage(job: SyncJob) -> String {
        return "Some files were deleted in \(cloudDisplayName(job)). Choose what to do."
    }

    var manifestStore: ManifestStore {
        return ManifestStore(directory: environment.manifestDirectory)
    }

    // MARK: Decisions

    /// "Put them back": forgets the report and runs a normal backup that skips the cloud check once,
    /// so the files are uploaded again. Does nothing while another run is busy.
    public func keepLocalAndRestoreCloud(jobID: String) {
        guard !working, !status.isBusy else { return }
        guard job(id: jobID) != nil else { return }
        clearCloudDeletions(jobID: jobID)
        startSync(jobID: jobID, automatic: false, skipCloudCheck: true)
    }

    /// "Decide later": keeps the report (so Koffer still won't back this job up on its own) and only
    /// takes the job's status back to idle.
    public func dismissCloudDeletions(jobID: String) {
        guard !working, !status.isBusy else { return }
        if statusJobID == jobID {
            status = .idle
        }
    }

    /// "Delete from this disk": checks every file again right now (still gone from the cloud, same size and
    /// modification date here), moves the ones that pass to the Trash, one by one, then forgets the report and
    /// runs a normal backup (which records the cloud again). Never hard-deletes. Stops at the first file that
    /// can't be moved. Refused for a report that looks like a mass removal, and while another run is busy.
    /// Success = the number of files moved to the Trash.
    public func applyCloudDeletions(jobID: String) async -> Result<Int, EngineError> {
        if working || status.isBusy { return .failure(EngineError(SyncEngine.waitForBackupMessage)) }
        guard let report = cloudDeletions[jobID] else {
            return .failure(EngineError("There's nothing waiting to be deleted for this backup."))
        }
        if report.looksLikeMassRemoval { return .failure(EngineError(SyncEngine.massCloudDeletionRefusal)) }
        reloadConfig()
        if configBroken { return .failure(EngineError(SyncEngine.settingsUnreadableMessage)) }
        guard let job = self.job(id: jobID) else { return .failure(EngineError("Koffer doesn't know that backup.")) }
        if !job.enabled { return .failure(EngineError("\(job.name) is turned off")) }
        if case .refused(let reason) = SafetyRules.check(job: job, config: config, homeDirectory: environment.homeDirectory) {
            return .failure(EngineError(reason))
        }
        if let volume = job.requiredVolume, !mountedVolumes.contains(volume) {
            return .failure(EngineError("The disk \(volume) isn't plugged in"))
        }
        if !isOnline && needsNetwork(job) {
            return .failure(EngineError("No internet, so Koffer can't check \(SyncEngine.cloudDisplayName(job)). Nothing was deleted."))
        }
        if case .refused(let reason) = Preflight.checkSource(job.source) { return .failure(EngineError(reason)) }
        guard let rclone = locateRclone() else { return .failure(EngineError(SyncEngine.rcloneMissingMessage)) }

        let pendingMessage: String = SyncEngine.cloudDeletionsMessage(job: job)
        let dates: [String: Date] = cloudDeletionDates[jobID] ?? [:]
        beginWork(job: job)
        await stopHelper()
        status = .preparing(SyncEngine.checkingCloudMessage)

        // 1. Still gone from the cloud?
        let listing: CloudListingResult = await listCloud(job: job, rclone: rclone)
        var cloudNow: Set<String> = []
        switch listing {
        case .files(let entries):
            for entry in entries { cloudNow.insert(entry.path) }
        case .failed(let stderr, let message):
            let stopped: Bool = stopReason != nil
            finishWork()
            statusJobID = jobID
            if !stopped && RcloneLogParser.looksLikeAuthProblem(stderr) {
                needsReconnect = true
                status = .needsAttention(ErrorClassifier.reconnectMessage)
                return .failure(EngineError(ErrorClassifier.reconnectMessage + ". Nothing was deleted."))
            }
            status = .needsAttention(pendingMessage)
            if stopped { return .failure(EngineError("Stopped. Nothing was deleted.")) }
            return .failure(EngineError("Koffer couldn't check \(SyncEngine.cloudDisplayName(job)) right now, so nothing was deleted. " + message))
        }
        if stopReason != nil {
            finishWork()
            statusJobID = jobID
            status = .needsAttention(pendingMessage)
            return .failure(EngineError("Stopped. Nothing was deleted."))
        }

        // 2. Still the same file here?
        var verified: [ChangeItem] = []
        for item in report.items {
            if cloudNow.contains(item.path) { continue }
            guard let expected = dates[item.path], let size = item.size,
                  let info = CloudDeletions.localInfo(relativePath: item.path, source: job.source) else { continue }
            if info.size != size || info.modified != expected { continue }
            verified.append(item)
        }

        // 3. To the Trash, one by one.
        var moved: Set<String> = []
        for item in verified {
            if let problem = trashOne(relativePath: item.path, job: job) {
                // Keep what is left waiting, without the files already in the Trash.
                let remaining: [ChangeItem] = report.items.filter { !moved.contains($0.path) }
                var remainingDates: [String: Date] = dates
                for path in moved { remainingDates[path] = nil }
                let bytes: Int64 = remaining.reduce(Int64(0)) { (sum: Int64, i: ChangeItem) -> Int64 in sum + (i.size ?? 0) }
                cloudDeletions[jobID] = CloudDeletionReport(jobID: jobID, detectedAt: report.detectedAt, items: remaining,
                                                            totalBytes: bytes, extrasCount: report.extrasCount,
                                                            looksLikeMassRemoval: report.looksLikeMassRemoval)
                cloudDeletionDates[jobID] = remainingDates
                finishWork()
                statusJobID = jobID
                status = .needsAttention(pendingMessage)
                var reason: String = problem
                while reason.hasSuffix(".") { reason.removeLast() }
                return .failure(EngineError("Couldn't move \(item.path) to the Trash: \(reason). Nothing else was changed after it."))
            }
            moved.insert(item.path)
        }

        // 4. Done: forget the report and back up (the files that changed or came back are simply backed up).
        clearCloudDeletions(jobID: jobID)
        finishWork()
        status = .idle
        startSync(jobID: jobID, automatic: false)
        return .success(moved.count)
    }

    /// The only place Koffer removes anything from this disk: `SafetyRules.localFileInside` right before
    /// `environment.trashItem` (the Trash, never a hard delete). Nil on success, otherwise the reason.
    private func trashOne(relativePath: String, job: SyncJob) -> String? {
        switch SafetyRules.localFileInside(source: job.source, relativePath: relativePath) {
        case .failure(let error):
            return error.message
        case .success(let url):
            do {
                try environment.trashItem(url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }

    private func clearCloudDeletions(jobID: String) {
        if cloudDeletions[jobID] != nil { cloudDeletions[jobID] = nil }
        cloudDeletionDates[jobID] = nil
    }

    // MARK: Checking

    /// Before a real backup. Returns true when the backup must stop here (status is set).
    /// Stops when files were deleted in the cloud (report published, owner notified when the list is new),
    /// on an expired sign-in, and when the cloud can't be listed while a report is still waiting.
    func holdForCloudDeletions(job: SyncJob, rclone: String) async -> Bool {
        status = .preparing(SyncEngine.checkingCloudMessage)
        let check: CloudCheckResult = await checkCloudDeletions(job: job, rclone: rclone)
        if stopReason != nil {
            finishEarly(job: job, outcome: outcome(exit: 0, parser: RcloneLogParser(), job: job), notify: true)
            return true
        }
        let message: String = SyncEngine.cloudDeletionsMessage(job: job)
        switch check {
        case .noManifest, .clean:
            clearCloudDeletions(jobID: job.id)
            return false
        case .found(let report, let dates):
            let isNew: Bool = cloudDeletions[job.id]?.items != report.items
            cloudDeletions[job.id] = report
            cloudDeletionDates[job.id] = dates
            finishEarly(job: job, outcome: Outcome(status: .needsAttention(message), run: .failed, message: message), notify: false)
            if isNew { services.notifier.cloudDeletionsFound(job: job, count: report.items.count) }
            return true
        case .listingFailed(let stderr, _):
            if RcloneLogParser.looksLikeAuthProblem(stderr) {
                needsReconnect = true
                let reconnect: String = ErrorClassifier.reconnectMessage
                finishEarly(job: job, outcome: Outcome(status: .needsAttention(reconnect), run: .failed, message: reconnect), notify: true)
                return true
            }
            if cloudDeletions[job.id] != nil {
                // The owner hasn't decided yet; don't put the files back just because the check failed.
                finishEarly(job: job, outcome: Outcome(status: .needsAttention(message), run: .failed, message: message), notify: false)
                return true
            }
            // Anything else: the dry run reports the real problem.
            return false
        }
    }

    /// Before a preview. Returns the files deleted in the cloud (also published as a report), or nil when the
    /// preview must stop (status is set).
    func previewCloudDeletions(job: SyncJob, rclone: String) async -> [ChangeItem]? {
        let check: CloudCheckResult = await checkCloudDeletions(job: job, rclone: rclone)
        if stopReason != nil {
            status = outcome(exit: 0, parser: RcloneLogParser(), job: job).status
            return nil
        }
        switch check {
        case .noManifest, .clean:
            clearCloudDeletions(jobID: job.id)
            return []
        case .found(let report, let dates):
            cloudDeletions[job.id] = report
            cloudDeletionDates[job.id] = dates
            return report.items
        case .listingFailed(let stderr, _):
            if RcloneLogParser.looksLikeAuthProblem(stderr) {
                needsReconnect = true
                status = .needsAttention(ErrorClassifier.reconnectMessage)
                return nil
            }
            return cloudDeletions[job.id]?.items ?? []
        }
    }

    /// Lists the cloud and compares it with the manifest (only when there is one for this destination).
    func checkCloudDeletions(job: SyncJob, rclone: String) async -> CloudCheckResult {
        guard let manifest = manifestStore.load(jobID: job.id, destination: job.destination) else { return .noManifest }
        let listing: CloudListingResult = await listCloud(job: job, rclone: rclone)
        switch listing {
        case .failed(let stderr, let message):
            return .listingFailed(stderr: stderr, message: message)
        case .files(let cloud):
            let source: String = job.source
            let detection: CloudDeletions.Detection = CloudDeletions.detect(manifest: manifest, cloud: cloud) { (path: String) -> LocalFileInfo? in
                return CloudDeletions.localInfo(relativePath: path, source: source)
            }
            if detection.candidates.isEmpty { return .clean }
            let mass: Bool = CloudDeletions.looksLikeMassRemoval(candidates: detection.candidates.count,
                                                                 manifestCount: manifest.files.count)
            let report = CloudDeletionReport(jobID: job.id, detectedAt: environment.now(), items: detection.candidates,
                                             totalBytes: detection.totalBytes, extrasCount: detection.extrasCount,
                                             looksLikeMassRemoval: mass)
            return .found(report, detection.modified)
        }
    }

    /// `rclone lsjson <destination> -R --files-only ...` with the sync's excludes. Stoppable like a sync
    /// (it runs as `currentRunner`). A destination folder that is gone counts as empty, except for a folder on
    /// this Mac whose parent is missing too (an unplugged disk is not "everything deleted").
    func listCloud(job: SyncJob, rclone: String) async -> CloudListingResult {
        let args: [String] = RcloneCommand.listFiles(target: job.destination)
        if case .refused(let reason) = SafetyRules.assertSafe(arguments: args, removedRoot: job.removedRoot) {
            return .failed(stderr: "", message: reason)
        }
        let runner: RcloneRunner = makeRunner(rclone, args)
        currentRunner = runner
        if stopReason != nil { runner.interrupt(grace: environment.interruptGrace) }
        let result = await runner.capture(timeout: 3600)
        if currentRunner === runner { currentRunner = nil }
        if stopReason != nil {
            return .failed(stderr: result.stderr, message: "Stopped.")
        }
        if result.status == 0 {
            if let entries = CloudDeletions.parseListing(result.stdout) { return .files(entries) }
            return .failed(stderr: result.stderr, message: "Koffer couldn't read the list of files in \(SyncEngine.cloudDisplayName(job)).")
        }
        if result.status == 3 && result.stderr.lowercased().contains("directory not found")
            && SyncEngine.missingDestinationMeansEmpty(job.destination) {
            return .files([])
        }
        let line: String = RemoteParsing.lastErrorLine(result.stderr) ?? "rclone stopped with code \(result.status)"
        return .failed(stderr: result.stderr, message: line)
    }

    nonisolated static func missingDestinationMeansEmpty(_ destination: String, fileManager: FileManager = .default) -> Bool {
        guard let location = RcloneLocation.parse(destination) else { return false }
        if !location.isLocal { return true }
        let parent: String = (location.path as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: parent, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// After a clean backup: saves what is in the cloud now as `<manifestDirectory>/<jobID>.json`.
    /// If listing or saving fails the old manifest stays, a note goes into the run's log, and the run is not affected.
    func recordCloudManifest(job: SyncJob, rclone: String, date: Date, logHandle: FileHandle?) async {
        let listing: CloudListingResult = await listCloud(job: job, rclone: rclone)
        switch listing {
        case .files(let entries):
            let manifest = CloudManifest(destination: job.destination, date: date, files: entries)
            do {
                try manifestStore.save(manifest, jobID: job.id)
            } catch {
                writeLogNote(logHandle, "Koffer couldn't save its record of the cloud copy (\(error.localizedDescription)). The previous record was kept.")
            }
        case .failed(_, let message):
            writeLogNote(logHandle, "Koffer couldn't list the cloud copy after this backup (\(message)). The previous record was kept.")
        }
    }

    /// One JSON line in the run's log, shaped like rclone's own lines.
    private func writeLogNote(_ handle: FileHandle?, _ text: String) {
        guard let h = handle else { return }
        let formatter = ISO8601DateFormatter()
        let object: [String: Any] = ["time": formatter.string(from: environment.now()), "level": "warning",
                                     "msg": text, "source": "koffer"]
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return }
        data.append(0x0A)
        do { try h.write(contentsOf: data) } catch { /* a log write failure must not stop the run */ }
    }
}
