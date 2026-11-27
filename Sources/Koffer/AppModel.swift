import AppKit
import Combine
import SwiftUI
import KofferCore

/// What one job looks like right now, in the terms the UI cares about.
enum JobPhase: Equatable {
    case setup(String)            // rclone missing or sign-in needed
    case off                      // job switched off
    case waitingForDisk(String)   // required volume not plugged in
    case busyElsewhere(String)    // another job is running (its name)
    case working(String)          // preparing / looking at what will change
    case syncing
    case paused(String)
    case attention(String)
    case done
    case notYet
}

/// Icon and optional text for the menu bar.
struct MenuBarState: Equatable {
    var symbol: String
    var text: String?
    var accessibility: String
}

/// What happened after "Delete from this disk…", shown once the decision card is gone.
struct CloudDeletionNote: Equatable {
    var jobID: String
    var text: String
    var isError: Bool
}

/// New / moved / removed / errors for the current run (live) or the last finished one.
struct RunNumbers: Equatable {
    var uploaded: Int
    var moved: Int
    var removed: Int
    var errors: Int
    var isThrottled: Bool
    var isLive: Bool
}

@MainActor
final class AppModel: ObservableObject {

    let engine: SyncEngine
    /// State of the "New backup" window.
    let newBackup: NewBackupModel
    /// "Update Koffer" in Settings.
    let updater: Updater

    private let notifier: Notifier
    private let power: PowerAssertion
    private let historyStore: HistoryStore
    private let volumeWatcher: VolumeWatcher
    private let networkWatcher: NetworkWatcher
    private var engineChanges: AnyCancellable?

    private enum Keys {
        static let selectedJob: String = "selectedJobID"
    }

    // MARK: UI state

    @Published var selectedJobID: String {
        didSet { UserDefaults.standard.set(selectedJobID, forKey: Keys.selectedJob) }
    }
    @Published private(set) var launchAtLogin: Bool
    @Published var loginError: String? = nil
    @Published var showSettings: Bool = false
    // View-local state lives here instead of in SwiftUI's State property wrapper: with newer SDKs that
    // wrapper is a macro, and the Command Line Tools (without Xcode) ship no plugin for it.
    @Published var panelContentHeight: CGFloat = 420
    @Published var confirmForget: Bool = false
    /// The backup the "Forget" confirmation is about (set by right-click, the row menu or Settings).
    @Published var forgetCandidateID: String? = nil
    /// Why "Forget this backup" was refused, shown inline in Settings.
    @Published var forgetRefusal: String? = nil
    /// The in-panel confirmation currently shown (see ConfirmOverlay). System dialogs are not used inside
    /// the menu bar panel: they take focus from it, and the panel closes as soon as they're dismissed.
    @Published var confirmation: PanelConfirmation? = nil
    @Published var confirmEnable: Bool = false
    @Published var confirmEmpty: Bool = false
    @Published var showAllHistory: Bool = false
    /// ChangeKind raw values whose preview group is expanded.
    @Published var expandedKinds: Set<String> = []

    // Deleted in the cloud (v0.3).
    /// The "Move N files to the Trash?" confirmation.
    @Published var confirmCloudDelete: Bool = false
    /// The list of paths in the "Deleted in …" card.
    @Published var cloudDeletionsExpanded: Bool = false
    /// The "Deleted in the cloud" group in the preview.
    @Published var previewCloudDeletedExpanded: Bool = false
    /// True while files are checked again and moved to the Trash.
    @Published private(set) var isApplyingCloudDeletions: Bool = false
    /// Result or error of the last "Delete from this disk…".
    @Published var cloudDeletionNote: CloudDeletionNote? = nil

    // MARK: Init

    init() {
        let notifier = Notifier()
        let power = PowerAssertion()
        let history = HistoryStore()
        let engine = SyncEngine(services: EngineServices(notifier: notifier, power: power, history: history))

        self.notifier = notifier
        self.power = power
        self.historyStore = history
        self.engine = engine
        self.newBackup = NewBackupModel(engine: engine)
        self.updater = Updater()
        self.volumeWatcher = VolumeWatcher(
            onMount: { (name: String) in Task { @MainActor in engine.volumeMounted(name) } },
            onUnmount: { (name: String) in Task { @MainActor in engine.volumeUnmounted(name) } }
        )
        self.networkWatcher = NetworkWatcher(
            onChange: { (online: Bool) in Task { @MainActor in engine.networkChanged(isOnline: online) } }
        )

        let stored: String? = UserDefaults.standard.string(forKey: Keys.selectedJob)
        self.selectedJobID = AppModel.initialSelection(stored: stored, engine: engine)
        self.launchAtLogin = LoginItem.isEnabled

        engineChanges = engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        start()

        if stored == nil {
            // Volumes are known now, so "first available job" is meaningful.
            selectedJobID = AppModel.initialSelection(stored: nil, engine: engine)
        }
    }

    private static func initialSelection(stored: String?, engine: SyncEngine) -> String {
        if let s = stored, engine.job(id: s) != nil { return s }
        if let available = engine.jobs.first(where: { engine.isAvailable($0) }) { return available.id }
        return engine.jobs.first?.id ?? SyncJob.testJobID
    }

    private func start() {
        notifier.requestPermission()
        // Only while the test backup exists: once it has been forgotten, don't recreate its folder.
        if let testJob = engine.job(id: SyncJob.testJobID) {
            TestFolder.createIfMissing(at: testJob.source)
        }
        for name in VolumeWatcher.currentVolumes().sorted() {
            engine.volumeMounted(name)
        }
        volumeWatcher.start()
        networkWatcher.start()
    }

    // MARK: Selection

    var selectedJob: SyncJob? {
        if let job = engine.job(id: selectedJobID) { return job }
        return engine.jobs.first
    }

    func select(_ job: SyncJob) {
        guard job.id != selectedJobID else { return }
        selectedJobID = job.id
        expandedKinds = []
        showAllHistory = false
        forgetRefusal = nil
        cloudDeletionsExpanded = false
        previewCloudDeletedExpanded = false
        if showSettings { refreshRemovedSize(for: job) }
    }

    // MARK: Panel

    /// Called when the panel opens: check the cloud connection (the engine skips it if checked recently).
    func panelAppeared() {
        guard engine.rclonePath != nil else { return }
        engine.refreshRemotes(force: false)
    }

    func refreshConnection() {
        guard engine.rclonePath != nil else { return }
        engine.refreshRemotes(force: true)
    }

    /// Account to sign in to again for this job: its own, else the first known one ("" if none).
    func reconnectRemote(for job: SyncJob?) -> String {
        if let job = job, !job.remoteName.isEmpty { return job.remoteName }
        return engine.remotes.first ?? ""
    }

    /// "OneDrive", "Google Drive", ... for the job's cloud account.
    func cloudName(for job: SyncJob?) -> String {
        let remote: String = reconnectRemote(for: job)
        return remote.isEmpty ? "your cloud storage" : DisplayNames.friendly(remote: remote)
    }

    // MARK: New backup

    /// Prepares the form before the window is shown; keeps an open form as it is.
    func prepareNewBackup() {
        newBackup.wasRequested = true
        if !newBackup.isOpen {
            newBackup.reset(preferredRemote: selectedJob?.remoteName)
        }
        if engine.rclonePath != nil {
            engine.refreshRemotes(force: false)
        }
    }

    /// After "Create backup" succeeded: show the new job in the panel.
    func didCreate(_ job: SyncJob) {
        showSettings = false
        selectedJobID = job.id
        expandedKinds = []
        showAllHistory = false
        forgetRefusal = nil
    }

    // MARK: Forget

    func askToForget(_ job: SyncJob) {
        forgetRefusal = nil
        forgetCandidateID = job.id
        let message: String = "Koffer stops looking after \(DisplayNames.abbreviated(job.source)). "
            + "Nothing is deleted: the folder on this Mac, \(job.destination) and "
            + "\(removedFolderName(for: job)) all stay as they are."
        confirmation = PanelConfirmation(
            title: "Forget \u{201C}\(job.name)\u{201D}?",
            message: message,
            confirmTitle: "Forget backup",
            isDestructive: false,
            action: { [weak self] in self?.forgetCandidate() },
            cancel: { [weak self] in self?.forgetCandidateID = nil }
        )
    }

    func forgetCandidate() {
        guard let id = forgetCandidateID, let job = engine.job(id: id) else { return }
        forgetCandidateID = nil
        forget(job)
    }

    func forget(_ job: SyncJob) {
        let verdict: SafetyVerdict = engine.removeJob(id: job.id)
        if let reason = verdict.reason {
            forgetRefusal = reason
            return
        }
        forgetRefusal = nil
        showSettings = false
        selectedJobID = AppModel.initialSelection(stored: nil, engine: engine)
    }

    // MARK: Settings

    func toggleSettings(for job: SyncJob) {
        showSettings.toggle()
        if showSettings { refreshRemovedSize(for: job) }
    }

    func refreshRemovedSize(for job: SyncJob) {
        guard engine.rclonePath != nil, !engine.status.isBusy else { return }
        engine.refreshRemovedSize(jobID: job.id)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on)
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription)"
        }
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: Derived job state

    func history(for job: SyncJob) -> [RunRecord] {
        engine.history.filter { $0.jobID == job.id }
    }

    func lastRecord(for job: SyncJob) -> RunRecord? {
        history(for: job).first
    }

    func preview(for job: SyncJob) -> PreviewResult? {
        guard let p = engine.preview, p.jobID == job.id else { return nil }
        return p
    }

    /// Last path component of the removed-items folder, e.g. "onedrive:_x_removed" -> "_x_removed".
    func removedFolderName(for job: SyncJob) -> String {
        DisplayNames.lastComponent(ofCloudPath: job.removedRoot)
    }

    private func isMine(_ job: SyncJob) -> Bool {
        engine.activeJobID == nil || engine.activeJobID == job.id
    }

    /// True when the engine's last status belongs to this job (or to no job in particular),
    /// so one job's "Everything is backed up" or problem is never shown on another job.
    private func statusIsAbout(_ job: SyncJob) -> Bool {
        guard let id = engine.statusJobID else { return true }
        return id == job.id
    }

    private var activeJobName: String {
        guard let id = engine.activeJobID, let job = engine.job(id: id) else { return "another folder" }
        return job.name
    }

    func phase(for job: SyncJob) -> JobPhase {
        let status: EngineStatus = engine.status
        if status.isBusy {
            if !isMine(job) { return .busyElsewhere(activeJobName) }
            switch status {
            case .syncing: return .syncing
            case .previewing: return .working("Looking at what will change…")
            case .preparing(let step): return .working(step)
            case .idle, .paused, .done, .needsAttention: break
            }
        }
        if engine.rclonePath == nil { return .setup("One setup step first") }
        if engine.needsReconnect { return .setup("Sign in to \(cloudName(for: job)) again") }
        if !job.enabled { return .off }
        if let volume = job.requiredVolume, !engine.mountedVolumes.contains(volume) {
            return .waitingForDisk(volume)
        }
        // Files deleted in the cloud wait for a decision, even after "Decide later".
        if engine.cloudDeletions[job.id] != nil {
            return .attention(SyncEngine.cloudDeletionsMessage(job: job))
        }
        if statusIsAbout(job) {
            switch status {
            case .paused(let why): return .paused(why)
            case .needsAttention(let why): return .attention(why)
            case .done: return .done
            case .idle, .preparing, .previewing, .syncing: break
            }
        }
        return phaseFromHistory(job)
    }

    private func phaseFromHistory(_ job: SyncJob) -> JobPhase {
        guard let last = lastRecord(for: job) else { return .notYet }
        switch last.outcome {
        case .completed:
            if last.errors > 0 {
                let files: String = last.errors == 1 ? "1 file" : "\(Format.count(last.errors)) files"
                return .attention("The last backup finished, but \(files) couldn't be sent. The log has the details.")
            }
            return .done
        case .paused:
            return .paused(last.message ?? "")
        case .failed:
            return .attention(last.message ?? "The last backup didn't finish.")
        }
    }

    func statusLine(for job: SyncJob) -> String {
        switch phase(for: job) {
        case .setup(let text): return text
        case .off: return "Switched off. Nothing is backed up"
        case .waitingForDisk(let volume): return "Plug in \(volume) to back up"
        case .busyElsewhere(let name): return "Busy backing up \(name)"
        case .working(let step): return step
        case .syncing: return "Backing up…"
        case .paused: return "Paused. Will resume next time"
        case .attention: return "Needs your attention"
        case .done: return "Everything is backed up"
        case .notYet: return "Not backed up yet"
        }
    }

    /// The reason for the generic "Needs a look" card. Nil for the cloud-deletion message: that has its own card.
    func attentionReason(for job: SyncJob) -> String? {
        if case .attention(let reason) = phase(for: job) {
            if engine.cloudDeletions[job.id] != nil && reason == SyncEngine.cloudDeletionsMessage(job: job) { return nil }
            return reason
        }
        return nil
    }

    func showsFirstRunNote(for job: SyncJob) -> Bool {
        !job.isTest && job.enabled && !job.previewApproved
    }

    func hasAttention(for job: SyncJob) -> Bool {
        engine.rclonePath == nil || engine.needsReconnect
            || attentionReason(for: job) != nil || showsFirstRunNote(for: job)
            || cloudDeletionReport(for: job) != nil || noteAboutCloudDeletions(for: job) != nil
    }

    // MARK: Deleted in the cloud

    func cloudDeletionReport(for job: SyncJob) -> CloudDeletionReport? {
        engine.cloudDeletions[job.id]
    }

    func noteAboutCloudDeletions(for job: SyncJob) -> CloudDeletionNote? {
        guard let note = cloudDeletionNote, note.jobID == job.id else { return nil }
        return note
    }

    /// Where the files would go to the Trash from: the job's disk, or "this Mac".
    func diskName(for job: SyncJob) -> String {
        if let volume = job.requiredVolume, !volume.isEmpty { return volume }
        let parts: [String] = job.source.split(separator: "/").map { String($0) }
        if parts.count >= 2 && parts[0] == "Volumes" && !parts[1].isEmpty { return parts[1] }
        return "this Mac"
    }

    /// "Delete from this disk…" after the confirmation: moves the files to the Trash, then backs up.
    func applyCloudDeletions(for job: SyncJob) {
        guard !isApplyingCloudDeletions, let report = engine.cloudDeletions[job.id] else { return }
        let expected: Int = report.items.count
        let jobID: String = job.id
        isApplyingCloudDeletions = true
        cloudDeletionNote = nil
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let result: Result<Int, EngineError> = await self.engine.applyCloudDeletions(jobID: jobID)
            self.isApplyingCloudDeletions = false
            switch result {
            case .success(let moved):
                self.cloudDeletionNote = CloudDeletionNote(jobID: jobID, text: AppModel.trashSummary(moved: moved, expected: expected),
                                                           isError: false)
            case .failure(let error):
                self.cloudDeletionNote = CloudDeletionNote(jobID: jobID, text: error.message, isError: true)
            }
        }
    }

    /// "Put them back in …".
    func restoreCloudDeletions(for job: SyncJob) {
        cloudDeletionNote = nil
        engine.keepLocalAndRestoreCloud(jobID: job.id)
    }

    /// "Decide later".
    func decideCloudDeletionsLater(for job: SyncJob) {
        cloudDeletionNote = nil
        cloudDeletionsExpanded = false
        engine.dismissCloudDeletions(jobID: job.id)
    }

    func dismissCloudDeletionNote() {
        cloudDeletionNote = nil
    }

    static func trashSummary(moved: Int, expected: Int) -> String {
        let files: String = moved == 1 ? "1 file" : "\(Format.count(moved)) files"
        var text: String = "Moved \(files) to the Trash. You can restore them from there."
        if moved < expected {
            let rest: Int = expected - moved
            let others: String = rest == 1 ? "1 other file" : "\(Format.count(rest)) other files"
            text += " \(others) changed or came back in the meantime, so they stay and are backed up again."
        }
        return text
    }

    func numbers(for job: SyncJob) -> RunNumbers? {
        if engine.activeJobID == job.id && engine.status == .syncing {
            let p: SyncProgress = engine.progress
            return RunNumbers(uploaded: p.uploaded, moved: p.moved, removed: p.removed,
                              errors: p.errors, isThrottled: p.isThrottled, isLive: true)
        }
        guard let r = lastRecord(for: job) else { return nil }
        return RunNumbers(uploaded: r.uploaded, moved: r.moved, removed: r.removed,
                          errors: r.errors, isThrottled: false, isLive: false)
    }

    func currentFiles(for job: SyncJob) -> [String] {
        guard engine.activeJobID == job.id, engine.status == .syncing else { return [] }
        return Array(engine.progress.currentFiles.prefix(2))
    }

    /// True when "Back up now" / "What will change?" can start for this job.
    func canRun(_ job: SyncJob) -> Bool {
        engine.rclonePath != nil && !engine.needsReconnect && engine.isAvailable(job)
    }

    /// Plain-words reason the actions are unavailable, or nil.
    func unavailableReason(for job: SyncJob) -> String? {
        if engine.status.isBusy {
            return isMine(job) ? nil : "Koffer is busy with \(activeJobName). Stop it to start this one."
        }
        if engine.rclonePath == nil { return "Finish the setup step above first." }
        if engine.needsReconnect { return "Sign in to \(cloudName(for: job)) again first." }
        if !job.enabled { return "This backup is switched off. Right-click it and choose Switch on." }
        if let volume = job.requiredVolume, !engine.mountedVolumes.contains(volume) {
            return "Plug in \(volume) first."
        }
        if !engine.isAvailable(job) { return "This folder isn't available right now." }
        return nil
    }

    // MARK: Menu bar

    var menuBarState: MenuBarState {
        let needsSetup: Bool = engine.rclonePath == nil || engine.needsReconnect
        switch engine.status {
        case .syncing:
            if let f = engine.progress.fraction {
                let pct: Int = Int((f * 100).rounded(.down))
                return MenuBarState(symbol: "suitcase.fill", text: "\(pct)%",
                                    accessibility: "Koffer, backing up, \(pct) percent")
            }
            return MenuBarState(symbol: "suitcase.fill", text: nil, accessibility: "Koffer, backing up")
        case .preparing, .previewing:
            return MenuBarState(symbol: "suitcase.fill", text: nil, accessibility: "Koffer, getting ready")
        case .needsAttention:
            return MenuBarState(symbol: "exclamationmark.triangle", text: nil, accessibility: "Koffer, needs your attention")
        case .paused:
            if needsSetup { return attentionState }
            return MenuBarState(symbol: "pause.circle", text: nil, accessibility: "Koffer, paused")
        case .done:
            if needsSetup { return attentionState }
            return MenuBarState(symbol: "checkmark.circle", text: nil, accessibility: "Koffer, everything is backed up")
        case .idle:
            if needsSetup { return attentionState }
            return MenuBarState(symbol: "suitcase", text: nil, accessibility: "Koffer")
        }
    }

    private var attentionState: MenuBarState {
        MenuBarState(symbol: "exclamationmark.triangle", text: nil, accessibility: "Koffer, needs your attention")
    }

    // MARK: Actions

    func revealLog(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyToClipboard(_ text: String) {
        let board: NSPasteboard = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}

/// A question asked inside the panel instead of in a system dialog.
struct PanelConfirmation {
    let title: String
    let message: String
    let confirmTitle: String
    let isDestructive: Bool
    let action: () -> Void
    var cancel: () -> Void = {}
}
