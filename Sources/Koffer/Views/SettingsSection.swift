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
            Toggle("Switch this job on", isOn: enabledBinding)
            if job.requiredVolume != nil {
                Toggle("Back up automatically when the disk is plugged in", isOn: autoBinding)
                    .disabled(!job.enabled)
            }
            RemovedItemsRow(job: job)
            if !job.isTest {
                ForgetJobRow(job: job)
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            Toggle("Launch at login", isOn: loginBinding)
            if let error = model.loginError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label("Keep the lid open while backing up", systemImage: "laptopcomputer")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 12))
        .quietCard()
        .confirmationDialog("Switch on \u{201C}\(job.name)\u{201D}?", isPresented: $model.confirmEnable,
                            titleVisibility: .visible) {
            Button("Switch on") { model.engine.setEnabled(true, jobID: job.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(enableMessage)
        }
    }

    private var enableMessage: String {
        "Run \u{201C}What will change?\u{201D} first and check the list before the first real backup. "
            + "Nothing is deleted from the cloud: removed files are kept in \(model.removedFolderName(for: job))."
    }

    private var enabledBinding: Binding<Bool> {
        let model: AppModel = self.model
        let job: SyncJob = self.job
        return Binding<Bool>(
            get: { model.engine.job(id: job.id)?.enabled ?? job.enabled },
            set: { (on: Bool) in
                if on && !job.isTest {
                    model.confirmEnable = true
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
            Button("Empty removed items…") { model.confirmEmpty = true }
                .buttonStyle(QuietButtonStyle(compact: true))
                .disabled((size ?? 0) <= 0 || model.engine.status.isBusy)
        }
        .confirmationDialog("Empty removed items?", isPresented: $model.confirmEmpty, titleVisibility: .visible) {
            Button("Empty \(sizeText)", role: .destructive) { model.engine.emptyRemovedItems(jobID: job.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes \(sizeText) of removed files kept in \(model.removedFolderName(for: job)). This can't be undone.")
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
                Button("Forget this backup\u{2026}") { model.confirmForget = true }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .disabled(isRunning)
            }
            if let reason = model.forgetRefusal {
                TaskFailureText(message: reason)
            }
        }
        .confirmationDialog("Forget \u{201C}\(job.name)\u{201D}?", isPresented: $model.confirmForget,
                            titleVisibility: .visible) {
            Button("Forget backup") { model.forget(job) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(forgetMessage)
        }
    }

    private var isRunning: Bool {
        model.engine.status.isBusy && model.engine.activeJobID == job.id
    }

    private var forgetMessage: String {
        "Koffer stops backing up \(DisplayNames.abbreviated(job.source)). "
            + "Nothing in the cloud or on the disk is deleted: \(job.destination) "
            + "and \(model.removedFolderName(for: job)) stay as they are."
    }
}
