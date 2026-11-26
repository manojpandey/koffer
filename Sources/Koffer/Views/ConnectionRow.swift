import SwiftUI
import KofferCore

/// Route and cloud connection for the selected job, just under the header.
struct JobContextView: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            RouteLine(job: job)
            if !job.remoteName.isEmpty && model.engine.rclonePath != nil {
                ConnectionRow(job: job)
            }
        }
    }
}

/// "~/Pictures → onedrive:Photos", middle-truncated, selectable, full paths on hover.
struct RouteLine: View {
    let job: SyncJob

    var body: some View {
        Text(line)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(fullText)
            .accessibilityLabel("Backs up \(DisplayNames.abbreviated(job.source)) to \(job.destination)")
    }

    private var line: String {
        "\(DisplayNames.abbreviated(job.source)) \u{2192} \(job.destination)"
    }

    private var fullText: String {
        "From \(job.source)\nTo \(job.destination)"
    }
}

/// One quiet line: is the cloud account reachable, and how much room is left.
struct ConnectionRow: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            ConnectionGlyph(kind: kind)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.xs)
            ConnectionActions(job: job, kind: kind)
        }
        .accessibilityElement(children: .contain)
    }

    private var remote: String { job.remoteName }
    private var name: String { DisplayNames.friendly(remote: remote) }

    private var kind: ConnectionKind {
        if case .running(let message) = model.engine.reconnectState {
            return .signingIn(message)
        }
        let state: RemoteState = model.engine.remoteStates[remote] ?? RemoteState.unknown
        switch state {
        case .unknown:
            return .unknown
        case .checking:
            return .checking
        case .connected(_, let total, let free):
            return .connected(total: total, free: free)
        case .failed(let message):
            if case .failed(let signInMessage) = model.engine.reconnectState {
                return .failed(signInMessage)
            }
            return .failed(message)
        }
    }

    private var text: String {
        switch kind {
        case .unknown:
            return "\(name) not checked yet"
        case .checking:
            return "Checking connection\u{2026}"
        case .connected(let total, let free):
            if let free = free, let total = total, total > 0 {
                return "\(name) connected \u{00B7} \(Format.bytes(free)) free of \(Format.bytes(total))"
            }
            if let free = free {
                return "\(name) connected \u{00B7} \(Format.bytes(free)) free"
            }
            return "\(name) connected"
        case .failed(let message):
            return message
        case .signingIn(let message):
            return message
        }
    }
}

enum ConnectionKind: Equatable {
    case unknown
    case checking
    case connected(total: Int64?, free: Int64?)
    case failed(String)
    case signingIn(String)
}

/// Small status glyph. Colour is always paired with a distinct symbol.
struct ConnectionGlyph: View {
    let kind: ConnectionKind

    var body: some View {
        switch kind {
        case .checking, .signingIn:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        case .unknown:
            glyph("circle.dashed", color: Color.secondary)
        case .connected:
            glyph("checkmark.circle.fill", color: Theme.success)
        case .failed:
            glyph("exclamationmark.circle.fill", color: Theme.warning)
        }
    }

    private func glyph(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

/// Refresh, "Sign in again" or "Cancel", depending on the state.
struct ConnectionActions: View {
    @EnvironmentObject var model: AppModel
    let job: SyncJob
    let kind: ConnectionKind

    var body: some View {
        switch kind {
        case .signingIn:
            Button("Cancel") { model.engine.cancelReconnect() }
                .buttonStyle(QuietButtonStyle(compact: true))
        case .failed:
            if model.engine.needsReconnect {
                // The sign-in card above already offers the button.
                RefreshConnectionButton()
            } else {
                Button("Sign in again") { model.engine.reconnect(remote: job.remoteName) }
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
        case .checking:
            EmptyView()
        case .unknown, .connected:
            RefreshConnectionButton()
        }
    }
}

struct RefreshConnectionButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button { model.refreshConnection() } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Check the connection again")
        .accessibilityLabel("Check the connection again")
        .disabled(model.engine.status.isBusy)
    }
}
