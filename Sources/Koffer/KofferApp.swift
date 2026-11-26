import SwiftUI
import KofferCore

@main
struct KofferApp: App {
    @StateObject private var model: AppModel = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
