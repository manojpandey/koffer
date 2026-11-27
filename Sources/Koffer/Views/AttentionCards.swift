import SwiftUI
import KofferCore

/// Cards that ask the user for something. Each says what is wrong and how to fix it.
struct AttentionStack: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if model.engine.rclonePath == nil {
                RcloneMissingCard()
            } else if model.engine.needsReconnect {
                ReconnectCard(job: job)
            }
            if let report = model.cloudDeletionReport(for: job) {
                CloudDeletionCard(job: job, report: report)
            } else if let note = model.noteAboutCloudDeletions(for: job) {
                CloudDeletionNoteCard(note: note)
            }
            if let reason = model.attentionReason(for: job) {
                AttentionCard(symbol: "exclamationmark.triangle.fill", tint: Theme.warning,
                              title: "Needs a look", message: reason) {
                    LastLogButton(job: job)
                }
            }
            if model.showsFirstRunNote(for: job) {
                AttentionCard(symbol: "eye", tint: Color.secondary, title: "Have a look first",
                              message: "Run \u{201C}What will change?\u{201D} once before automatic backups switch on.") {
                    EmptyView()
                }
            }
        }
    }
}

struct AttentionCard<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    let actions: () -> Actions

    init(symbol: String, tint: Color, title: String, message: String,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .background(shape.fill(tint.opacity(0.08)))
        .overlay(shape.strokeBorder(tint.opacity(0.20), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
    }
}

/// The only place the word "rclone" appears. One button installs it; no commands are shown.
struct RcloneMissingCard: View {
    var body: some View {
        AttentionCard(symbol: "wrench.and.screwdriver.fill", tint: Theme.warning, title: "One setup step",
                      message: "Koffer needs a small free helper called rclone to talk to your cloud storage.") {
            RcloneInstallActions()
        }
    }
}

struct RcloneInstallActions: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            switch model.engine.installState {
            case .idle:
                InstallButton(title: "Install rclone")
                InstallSubtitle()
            case .running(let message):
                TaskProgressLine(message: message)
            case .failed(let message):
                TaskFailureText(message: message)
                InstallButton(title: "Try again")
            case .succeeded:
                Text("Installed. Getting it ready\u{2026}")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Check again") { model.engine.recheckRclone() }
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
        }
        .padding(.top, 2)
    }
}

private struct InstallButton: View {
    @EnvironmentObject var model: AppModel
    let title: String

    var body: some View {
        Button(title) { model.engine.installRclone() }
            .buttonStyle(GradientButtonStyle())
    }
}

private struct InstallSubtitle: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Text(model.engine.homebrewPath != nil ? "Installs with Homebrew" : "Downloads it from rclone.org")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
    }
}

/// Small spinner and a plain-words step, e.g. "Waiting for you to sign in in your browser…".
struct TaskProgressLine: View {
    let message: String

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TaskFailureText: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.failure)
    }
}

/// Sign in again, straight from the panel: Koffer opens the browser and waits.
struct ReconnectCard: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        let name: String = model.cloudName(for: job)
        AttentionCard(symbol: "person.crop.circle.badge.exclamationmark", tint: Theme.warning,
                      title: "Sign in to \(name) again",
                      message: "\(name) wants you to confirm it\u{2019}s you. Koffer opens your browser so you can sign in.") {
            ReconnectActions(remote: model.reconnectRemote(for: job))
        }
    }
}

struct ReconnectActions: View {
    @EnvironmentObject var model: AppModel
    let remote: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            switch model.engine.reconnectState {
            case .idle, .succeeded:
                signInButton("Sign in again")
            case .running(let message):
                TaskProgressLine(message: message)
                Button("Cancel") { model.engine.cancelReconnect() }
                    .buttonStyle(QuietButtonStyle(compact: true))
            case .failed(let message):
                TaskFailureText(message: message)
                signInButton("Try again")
            }
        }
    }

    private func signInButton(_ title: String) -> some View {
        Button(title) { model.engine.reconnect(remote: remote) }
            .buttonStyle(QuietButtonStyle(compact: true))
            .disabled(remote.isEmpty || model.engine.status.isBusy)
    }
}

/// "Show log" for the most recent run of this job, when it has one.
struct LastLogButton: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        if let path = model.lastRecord(for: job)?.logPath {
            Button("Show log") { model.revealLog(path) }
                .buttonStyle(QuietButtonStyle(compact: true))
        }
    }
}

// MARK: - Deleted in the cloud (v0.3)

/// Files deleted in the cloud copy that are still on this disk. Nothing happens to them until the owner picks
/// one of the three buttons; until then Koffer doesn't back this folder up on its own.
struct CloudDeletionCard: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob
    let report: CloudDeletionReport

    var body: some View {
        AttentionCard(symbol: "icloud.slash", tint: Theme.warning, title: "Deleted in \(cloudName)",
                      message: sentence) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                DisclosureGroup(isExpanded: $model.cloudDeletionsExpanded) {
                    ChangeList(kind: .removed, items: report.items)
                } label: {
                    Text(listLabel)
                        .font(.system(size: 12, weight: .medium))
                }
                if report.extrasCount > 0 {
                    Text(extrasNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if report.looksLikeMassRemoval {
                    Text(massNote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = model.noteAboutCloudDeletions(for: job) {
                    if note.isError {
                        TaskFailureText(message: note.text)
                    } else {
                        Text(note.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if model.isApplyingCloudDeletions {
                    TaskProgressLine(message: "Moving files to the Trash\u{2026}")
                } else {
                    CloudDeletionButtons(job: job, report: report, cloudName: cloudName)
                }
            }
        }
    }

    private var cloudName: String {
        if job.remoteName.isEmpty { return SyncEngine.cloudDisplayName(job) }
        return model.cloudName(for: job)
    }

    private var listLabel: String {
        report.items.count == 1 ? "Show the file" : "Show the \(Format.count(report.items.count)) files"
    }

    private var filesText: String {
        report.items.count == 1 ? "1 file" : "\(Format.count(report.items.count)) files"
    }

    private var sentence: String {
        let verb: String = report.items.count == 1 ? "was" : "were"
        return "\(filesText) (\(Format.bytes(report.totalBytes))) \(verb) deleted in \(cloudName) since the last backup. "
            + "They\u{2019}re still on this disk."
    }

    private var extrasNote: String {
        let files: String = report.extrasCount == 1 ? "1 file was" : "\(Format.count(report.extrasCount)) files were"
        return "\(files) also added or renamed in \(cloudName). The next backup gives renamed files their old name back "
            + "and moves new ones to \(model.removedFolderName(for: job))."
    }

    private var massNote: String {
        "That\u{2019}s a large part of this backup. If the folder was moved or deleted in \(cloudName) by mistake, "
            + "put them back. To delete this many files, delete them on this disk directly."
    }

    private var confirmTitle: String {
        "Move \(filesText) to the Trash on \(model.diskName(for: job))?"
    }
}

private struct CloudDeletionButtons: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob
    let report: CloudDeletionReport
    let cloudName: String

    var body: some View {
        let busy: Bool = model.engine.status.isBusy
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !report.looksLikeMassRemoval {
                Button("Delete from this disk\u{2026}") {
                    let count: String = report.items.count == 1 ? "1 file" : "\(Format.count(report.items.count)) files"
                    model.confirmation = PanelConfirmation(
                        title: "Move \(count) to the Trash on \(model.diskName(for: job))?",
                        message: "Each file is checked again first. You can restore them from the Trash.",
                        confirmTitle: "Move to Trash",
                        isDestructive: true,
                        action: { model.applyCloudDeletions(for: job) }
                    )
                }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .disabled(busy || !model.canRun(job))
                    .help("Moves these files to the Trash, after checking each one again.")
            }
            Button("Put them back in \(cloudName)") { model.restoreCloudDeletions(for: job) }
                .buttonStyle(QuietButtonStyle(compact: true))
                .disabled(busy || !model.canRun(job))
                .help("Backs up now and uploads these files again.")
            Button("Decide later") { model.decideCloudDeletionsLater(for: job) }
                .buttonStyle(QuietButtonStyle(compact: true))
                .disabled(busy)
                .help("Koffer won't back this folder up on its own until you choose.")
        }
        .padding(.top, 2)
    }
}

/// What "Delete from this disk…" did, once the decision card is gone.
struct CloudDeletionNoteCard: View {
    @EnvironmentObject var model: AppModel
    let note: CloudDeletionNote

    var body: some View {
        AttentionCard(symbol: note.isError ? "exclamationmark.triangle.fill" : "trash",
                      tint: note.isError ? Theme.warning : Color.secondary,
                      title: note.isError ? "Couldn\u{2019}t finish" : "Moved to the Trash",
                      message: note.text) {
            Button("OK") { model.dismissCloudDeletionNote() }
                .buttonStyle(QuietButtonStyle(compact: true))
        }
    }
}
