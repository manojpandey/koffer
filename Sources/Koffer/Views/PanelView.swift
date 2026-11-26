import SwiftUI
import KofferCore

/// The window that drops down from the menu bar. Hugs its content up to `Theme.maxPanelHeight`,
/// then scrolls. The content is measured once (no duplicated view trees, so no duplicated state).
struct PanelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: model.panelContentHeight > Theme.maxPanelHeight) {
            PanelContent()
                .background(
                    GeometryReader { (proxy: GeometryProxy) in
                        Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(width: Theme.panelWidth)
        .frame(height: min(max(model.panelContentHeight, 120), Theme.maxPanelHeight))
        .onPreferenceChange(PanelHeightKey.self) { (height: CGFloat) in
            if abs(height - model.panelContentHeight) > 0.5 {
                DispatchQueue.main.async { model.panelContentHeight = height }
            }
        }
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PanelContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let job = model.selectedJob {
            JobPanel(job: job)
        } else {
            NoJobsView()
        }
    }
}

/// Everything about the selected job, top to bottom.
struct JobPanel: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            JobPanelTop(job: job)
            JobPanelBottom(job: job)
        }
        .padding(Theme.Space.l)
    }
}

private struct JobPanelTop: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HeaderView(job: job)
            if model.hasAttention(for: job) {
                AttentionStack(job: job)
            }
            HeroView(job: job)
            if let numbers = model.numbers(for: job) {
                StatTiles(job: job, numbers: numbers)
            }
            if !model.currentFiles(for: job).isEmpty {
                CurrentFilesView(files: model.currentFiles(for: job))
            }
            ActionsView(job: job)
        }
    }
}

private struct JobPanelBottom: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            if let preview = model.preview(for: job) {
                PreviewSection(preview: preview)
            }
            if !model.history(for: job).isEmpty {
                HistorySection(job: job)
            }
            if model.showSettings {
                SettingsSection(job: job)
            }
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
            FooterView(job: job)
        }
    }
}

struct NoJobsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Koffer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Nothing to back up yet")
                .font(.system(size: 17, weight: .semibold))
            Text("Add a folder to Koffer's settings file, then open this menu again.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Quit Koffer") { model.quit() }
                .buttonStyle(QuietButtonStyle())
        }
        .padding(Theme.Space.l)
    }
}
