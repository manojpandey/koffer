import SwiftUI

/// Shows `model.confirmation` as a card over the panel. Replaces system confirmation dialogs, which take
/// focus away from the menu bar panel and make it close when they're dismissed.
struct ConfirmOverlayHost: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let confirmation = model.confirmation {
            ConfirmOverlay(confirmation: confirmation)
                .transition(.opacity)
        }
    }
}

private struct ConfirmOverlay: View {
    @EnvironmentObject var model: AppModel
    let confirmation: PanelConfirmation

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .contentShape(Rectangle())
                .onTapGesture { cancel() }
            card
                .padding(Theme.Space.l)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(confirmation.title)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(confirmation.message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                Button("Cancel") { cancel() }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button(confirmation.confirmTitle) { confirm() }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .foregroundStyle(confirmation.isDestructive ? Theme.failure : Color.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: 300, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func confirm() {
        let action: () -> Void = confirmation.action
        model.confirmation = nil
        action()
    }

    private func cancel() {
        let cancelAction: () -> Void = confirmation.cancel
        model.confirmation = nil
        cancelAction()
    }
}
