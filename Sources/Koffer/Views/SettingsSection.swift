import SwiftUI
import KofferCore

/// Bottom row: Settings toggle, New backup and Quit.
struct FooterView: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Button { model.toggleSettings(for: job) } label: {
                Label("Settings", systemImage: model.showSettings ? "gearshape.fill" : "gearshape")
            }
            .accessibilityValue(settingsState)
            NewBackupButton(style: .footer)
            Spacer(minLength: Theme.Space.s)
            Button("Quit Koffer") { model.quit() }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private var settingsState: String { model.showSettings ? "Shown" : "Hidden" }
}

/// Per-job switches, launch at login, removed items, and the lid note.
struct SettingsSection: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionTitle("Settings for \(job.name)")
            Toggle("Back up this folder", isOn: enabledBinding)
            if job.requiredVolume != nil {
                Toggle("Back up automatically when the disk is plugged in", isOn: autoBinding)
                    .disabled(!job.enabled)
            }
            RemovedItemsRow(job: job)
            ForgetJobRow(job: job)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            Toggle("Launch at login", isOn: loginBinding)
            if let error = model.loginError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            UpdateRow(updater: model.updater, backupRunning: model.engine.status.isBusy)
            Label("Keep the lid open while backing up", systemImage: "laptopcomputer")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 12))
        .quietCard()
    }

    private var enableMessage: String {
        "Run \u{201C}What will change?\u{201D} first and check the list before the first real backup. "
            + "Nothing is deleted from the cloud: removed files are kept in \(model.removedFolderName(for: job))."
    }

    private var enabledBinding: Binding<Bool> {
        let model: AppModel = self.model
        let job: SyncJob = self.job
        let message: String = self.enableMessage
        return Binding<Bool>(
            get: { model.engine.job(id: job.id)?.enabled ?? job.enabled },
            set: { (on: Bool) in
                if on && !job.isTest {
                    model.confirmation = PanelConfirmation(
                        title: "Switch on \u{201C}\(job.name)\u{201D}?",
                        message: message,
                        confirmTitle: "Switch on",
                        isDestructive: false,
                        action: { model.engine.setEnabled(true, jobID: job.id) }
                    )
                } else {
                    model.engine.setEnabled(on, jobID: job.id)
                }
            }
        )
    }

    private var autoBinding: Binding<Bool> {
        let model: AppModel = self.model
        let job: SyncJob = self.job
        return Binding<Bool>(
            get: { model.engine.job(id: job.id)?.autoSyncOnMount ?? job.autoSyncOnMount },
            set: { (on: Bool) in model.engine.setAutoSync(on, jobID: job.id) }
        )
    }

    private var loginBinding: Binding<Bool> {
        let model: AppModel = self.model
        return Binding<Bool>(
            get: { model.launchAtLogin },
            set: { (on: Bool) in model.setLaunchAtLogin(on) }
        )
    }
}

/// Size of the removed-items folder and a guarded "Empty removed items…".
struct RemovedItemsRow: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        let size: Int64? = model.engine.removedBytes[job.id]
        let sizeText: String = size.map { Format.bytes($0) } ?? "Size not known yet"
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Removed items")
                Text("\(sizeText), kept in \(model.removedFolderName(for: job))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            Button("Empty removed items…") {
                model.confirmation = PanelConfirmation(
                    title: "Empty removed items?",
                    message: "This permanently deletes \(sizeText) of removed files kept in "
                        + "\(model.removedFolderName(for: job)). This can't be undone.",
                    confirmTitle: "Empty \(sizeText)",
                    isDestructive: true,
                    action: { model.engine.emptyRemovedItems(jobID: job.id) }
                )
            }
                .buttonStyle(QuietButtonStyle(compact: true))
                .disabled((size ?? 0) <= 0 || model.engine.status.isBusy)
        }
    }
}

/// "Forget this backup…": removes the job from Koffer only. Nothing in the cloud or on the disk is deleted.
struct ForgetJobRow: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text("Stop backing up this folder")
                Spacer(minLength: Theme.Space.s)
                Button("Forget this backup\u{2026}") { model.askToForget(job) }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .disabled(isRunning)
            }
            if let reason = model.forgetRefusal {
                TaskFailureText(message: reason)
            }
        }
    }

    private var isRunning: Bool {
        model.engine.status.isBusy && model.engine.activeJobID == job.id
    }
}

/// Version line plus "Check for updates" / "Update". Updating rebuilds Koffer from its source folder and restarts it.
struct UpdateRow: View {
    @ObservedObject var updater: Updater
    let backupRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(updater.versionText)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.s)
                actionButton
            }
            if !changes.isEmpty {
                DisclosureGroup("What\u{2019}s new", isExpanded: $updater.showChanges) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(0..<min(changes.count, 20), id: \.self) { (index: Int) in
                            Text("\u{2022} " + changes[index])
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 2)
                }
                .font(.system(size: 11))
            }
            if let message = progressMessage {
                TaskProgressLine(message: message)
            }
            if let message = failureMessage {
                TaskFailureText(message: message)
                Button("Show update log") { updater.showLog() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .onAppear { updater.checkIfStale() }
    }

    @ViewBuilder
    private var actionButton: some View {
        if updater.isWorking {
            EmptyView()
        } else if !changes.isEmpty {
            Button("Update") { updater.install(backupRunning: backupRunning) }
                .buttonStyle(QuietButtonStyle(compact: true))
                .disabled(backupRunning)
                .help(backupRunning ? "Wait for the backup to finish" : "Download, build and restart Koffer")
        } else {
            Button("Check for updates") { updater.check() }
                .buttonStyle(QuietButtonStyle(compact: true))
        }
    }

    private var changes: [String] {
        if case .available(_, let list) = updater.state { return list }
        return []
    }

    private var progressMessage: String? {
        switch updater.state {
        case .checking: return "Checking for updates\u{2026}"
        case .updating(let message): return message
        default: return nil
        }
    }

    private var failureMessage: String? {
        if case .failed(let message) = updater.state { return message }
        return nil
    }

    private var statusText: String {
        switch updater.state {
        case .idle, .checking, .updating, .failed: return "Updates come from GitHub."
        case .upToDate: return "You have the latest version."
        case .available(let count, _): return count == 1 ? "1 update available." : "\(count) updates available."
        }
    }
}
