import AppKit
import SwiftUI
import KofferCore

/// Every folder Koffer looks after, one row each: status glyph, name, and when it was last backed up.
/// Click a row to see it below; right-click (or the "…" button) for actions, including Forget.
struct BackupsList: View {
    @EnvironmentObject var model: AppModel
    let selected: SyncJob

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.engine.jobs) { (job: SyncJob) in
                BackupRow(job: job, isSelected: job.id == selected.id)
            }
            NewBackupRow()
        }
    }
}

struct BackupRow: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(glyphStyle)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(job.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(job.enabled ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            RowMenuButton(job: job)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(isSelected ? Theme.quietFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.select(job) }
        .contextMenu { BackupActions(job: job) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.name), \(detail)")
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private var detail: String {
        var parts: [String] = []
        if job.isTest { parts.append("Test") }
        if !job.enabled {
            parts.append("Off")
        } else if let last = model.lastRecord(for: job) {
            parts.append(Format.relativeDay(last.endedAt, now: Date()))
        } else {
            parts.append("Not yet")
        }
        return parts.joined(separator: " · ")
    }

    private var glyph: String {
        switch model.phase(for: job) {
        case .off: return "circle.dashed"
        case .done: return "checkmark.circle"
        case .syncing, .working: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .attention, .setup: return "exclamationmark.circle"
        case .waitingForDisk: return "externaldrive"
        case .busyElsewhere, .notYet: return "circle"
        }
    }

    private var glyphStyle: Color {
        switch model.phase(for: job) {
        case .attention, .setup: return Theme.warning
        case .done, .syncing, .working: return Color.primary
        default: return Color.secondary
        }
    }
}

/// The small "…" at the end of each row: the same actions as right-click, for people who don't right-click.
struct RowMenuButton: View {
    let job: SyncJob

    var body: some View {
        Menu {
            BackupActions(job: job)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions for \(job.name)")
        .accessibilityLabel("Actions for \(job.name)")
    }
}

/// Menu items shared by right-click and the "…" button.
struct BackupActions: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        Button("Back up now") { model.select(job); model.engine.syncNow(jobID: job.id) }
            .disabled(!model.canRun(job))
        Button("What will change?") { model.select(job); model.engine.previewChanges(jobID: job.id) }
            .disabled(!model.canRun(job))
        Divider()
        if job.enabled {
            Button("Switch off") { model.engine.setEnabled(false, jobID: job.id) }
        } else {
            Button("Switch on\u{2026}") { model.select(job); model.showSettings = true }
        }
        Button("Show folder in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.source)])
        }
        Divider()
        Button("Forget this backup\u{2026}") { model.askToForget(job) }
            .disabled(model.engine.status.isBusy && model.engine.activeJobID == job.id)
    }
}

struct NewBackupRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            model.prepareNewBackup()
            openWindow(id: NewBackupView.windowID)
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16)
                Text("New backup\u{2026}")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
