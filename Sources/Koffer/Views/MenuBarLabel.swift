import SwiftUI
import KofferCore

/// The status item. Menu bar labels render as template images, so this stays Image + Text.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let state: MenuBarState = model.menuBarState
        HStack(spacing: 3) {
            Image(systemName: state.symbol)
            if let text = state.text {
                Text(text)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.accessibility)
    }
}
