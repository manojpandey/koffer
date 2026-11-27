import SwiftUI
import KofferCore

/// "Back up now" (becomes "Stop" while busy) and "What will change?".
struct ActionsView: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        let busy: Bool = model.engine.status.isBusy
        let ready: Bool = model.canRun(job)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                if busy {
                    Button { model.engine.cancel() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .help(stopHelp)
                } else {
                    Button("Back up now") { model.engine.syncNow(jobID: job.id) }
                        .buttonStyle(GradientButtonStyle())
                        .disabled(!ready)
                }
                Button("What will change?") { model.engine.previewChanges(jobID: job.id) }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!ready || busy)
                    .help("Shows what the next backup would do, without changing anything.")
            }
            if let reason = model.unavailableReason(for: job) {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stopHelp: String {
        if model.lookingProgress(for: job) != nil {
            return "Stops looking. Nothing has been changed yet."
        }
        return "Stops cleanly. The next backup picks up where this one stopped."
    }
}

// MARK: - Button styles

/// The one prominent button: golden-hour gradient (deep stops so white text stays readable).
struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GradientButtonBody(configuration: configuration)
    }
}

private struct GradientButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onInk(scheme))
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(shape.fill(Theme.ink))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1.0) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(Animation.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet neutral button used for everything that is not the primary action.
struct QuietButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, compact: compact)
    }
}

private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(
            cornerRadius: compact ? Theme.Radius.small : Theme.Radius.button, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 11 : 13, weight: .medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, compact ? Theme.Space.s : Theme.Space.m)
            .frame(maxWidth: compact ? nil : CGFloat.infinity, minHeight: compact ? 22 : 32)
            .background(shape.fill(configuration.isPressed ? Theme.quietFillPressed : Theme.quietFill))
            .contentShape(shape)
            .opacity(isEnabled ? 1.0 : 0.4)
    }
}
