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

/// The only place the word "rclone" appears.
struct RcloneMissingCard: View {
    @EnvironmentObject var model: AppModel
    @State private var copied: Bool = false
    private static let command: String = "brew install rclone"
    private var copyTitle: String { copied ? "Copied" : "Copy" }

    var body: some View {
        AttentionCard(symbol: "wrench.and.screwdriver.fill", tint: Theme.warning, title: "One setup step",
                      message: "Koffer uses rclone, a free tool, to talk to OneDrive. Install it once in Terminal:") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Text(RcloneMissingCard.command)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: Theme.Space.xs)
                    Button {
                        model.copyToClipboard(RcloneMissingCard.command)
                        copied = true
                    } label: {
                        Label(copyTitle, systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                }
                .padding(Theme.Space.s)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.quietFill))
                Button("Check again") { model.engine.recheckRclone() }
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
        }
    }
}

struct ReconnectCard: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        AttentionCard(symbol: "person.crop.circle.badge.exclamationmark", tint: Theme.warning,
                      title: "Sign in to OneDrive again",
                      message: "OneDrive wants you to confirm it's you. This opens Terminal, which sends you to your browser to sign in.") {
            Button("Reconnect OneDrive") {
                TerminalLauncher.run(model.engine.reconnectCommand(for: job.id))
            }
            .buttonStyle(QuietButtonStyle(compact: true))
        }
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
