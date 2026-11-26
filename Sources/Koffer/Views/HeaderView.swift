import SwiftUI
import KofferCore

/// App name, job picker (when there is more than one job) and the one-line status sentence.
struct HeaderView: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.s) {
                Image(systemName: "suitcase.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Koffer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: Theme.Space.s)
                if model.engine.jobs.count <= 1 {
                    JobHints(job: job)
                }
            }
            if model.engine.jobs.count > 1 {
                JobPicker(selected: job)
            }
            Text(model.statusLine(for: job))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Status: \(model.statusLine(for: job))")
        }
    }
}

/// Pills for up to three jobs, a menu beyond that.
struct JobPicker: View {
    @EnvironmentObject var model: AppModel
    let selected: SyncJob

    var body: some View {
        if model.engine.jobs.count <= 3 {
            HStack(spacing: Theme.Space.xs) {
                ForEach(model.engine.jobs) { (job: SyncJob) in
                    JobPill(job: job, isSelected: job.id == selected.id) { model.select(job) }
                }
                Spacer(minLength: 0)
            }
        } else {
            Picker("Folder", selection: $model.selectedJobID) {
                ForEach(model.engine.jobs) { (job: SyncJob) in
                    Text(menuTitle(job)).tag(job.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    private func menuTitle(_ job: SyncJob) -> String {
        var title: String = job.name
        if job.isTest { title += " (test)" }
        if !job.enabled { title += " (off)" }
        return title
    }
}

struct JobPill: View {
    let job: SyncJob
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.xs) {
                Text(job.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                JobHints(job: job)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(isSelected ? Theme.quietFillPressed : Color.clear))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private var accessibilityText: String {
        var text: String = job.name
        if job.isTest { text += ", test" }
        if !job.enabled { text += ", switched off" }
        return text
    }
}

/// Small "Test" tag and a switched-off hint.
struct JobHints: View {
    let job: SyncJob

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if job.isTest {
                Text("Test")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.5))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Test folder")
            }
            if !job.enabled {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("This job is switched off")
                    .accessibilityLabel("Switched off")
            }
        }
    }
}
