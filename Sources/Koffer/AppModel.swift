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
    // View-local state lives here instead of in `@State`: with newer SDKs `@State` is a macro, and the
    // Command Line Tools (without Xcode) ship no plugin for it, so `@State` would not compile there.
    @Published var panelContentHeight: CGFloat = 420
    @Published var commandCopied: Bool = false
    @Published var confirmEnable: Bool = false
    @Published var confirmEmpty: Bool = false
    @Published var showAllHistory: Bool = false
    /// ChangeKind raw values whose preview group is expanded.
    @Published var expandedKinds: Set<String> = []

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
        let testSource: String = engine.job(id: SyncJob.testJobID)?.source ?? SyncJob.testJob().source
        TestFolder.createIfMissing(at: testSource)
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
        if showSettings { refreshRemovedSize(for: job) }
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
        let root: String = job.removedRoot
        let afterColon: String
        if let idx = root.firstIndex(of: ":") {
            afterColon = String(root[root.index(after: idx)...])
        } else {
            afterColon = root
        }
        let parts: [Substring] = afterColon.split(separator: "/")
        if let last = parts.last { return String(last) }
        return afterColon.isEmpty ? "the removed folder" : afterColon
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
        if engine.needsReconnect { return .setup("Sign in to OneDrive again") }
        if !job.enabled { return .off }
        if let volume = job.requiredVolume, !engine.mountedVolumes.contains(volume) {
            return .waitingForDisk(volume)
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
        case .off: return "This job is switched off"
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

    func attentionReason(for job: SyncJob) -> String? {
        if case .attention(let reason) = phase(for: job) { return reason }
        return nil
    }

    func showsFirstRunNote(for job: SyncJob) -> Bool {
        !job.isTest && job.enabled && !job.previewApproved
    }

    func hasAttention(for job: SyncJob) -> Bool {
        engine.rclonePath == nil || engine.needsReconnect
            || attentionReason(for: job) != nil || showsFirstRunNote(for: job)
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
        if engine.needsReconnect { return "Reconnect OneDrive first." }
        if !job.enabled { return "This job is switched off. You can switch it on in Settings." }
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
