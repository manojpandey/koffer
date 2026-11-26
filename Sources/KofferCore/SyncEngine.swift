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

    public init(configURL: URL, logDirectory: URL, rcloneCandidates: [String] = RcloneLocator.defaultCandidates,
                mountDelay: TimeInterval = 10, interruptGrace: TimeInterval = 15,
                homeDirectory: String = NSHomeDirectory(), volumesDirectory: String? = "/Volumes",
                timeZone: TimeZone? = nil, now: @escaping () -> Date = { Date() }) {
        self.configURL = configURL
        self.logDirectory = logDirectory
        self.rcloneCandidates = rcloneCandidates
        self.mountDelay = mountDelay
        self.interruptGrace = interruptGrace
        self.homeDirectory = homeDirectory
        self.volumesDirectory = volumesDirectory
        self.timeZone = timeZone
        self.now = now
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
    public static let rcloneMissingMessage = "rclone is not installed. Install it with: brew install rclone"
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

    /// `automatic` is true for runs Koffer starts on its own (disk plugged in); those get extra caution.
    private func startSync(jobID: String, automatic: Bool) {
        guard !working, !status.isBusy else { return }
        reloadConfig()
        guard let job = self.job(id: jobID) else { return }
        beginWork(job: job)
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            let ran: Bool = await self.performSync(job: job, automatic: automatic)
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
        let runner = RcloneRunner(executablePath: rclone, arguments: args)
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
            let runner = RcloneRunner(executablePath: rclone, arguments: args)
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
    private func performSync(job: SyncJob, automatic: Bool) async -> Bool {
        await stopHelper()
        let startedAt: Date = environment.now()

        guard let rclone = prepare(job: job, notify: true) else { return false }

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
            let runner = RcloneRunner(executablePath: rclone, arguments: aboutArgs)
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
        preview = PreviewResult(jobID: job.id, date: environment.now(), items: parser.changeItems)
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
        let runner = RcloneRunner(executablePath: path, arguments: args, logHandles: logHandles,
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
        guard let job = jobs.first(where: { isAutoEligible($0) && $0.requiredVolume == volume }) else { return }
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
