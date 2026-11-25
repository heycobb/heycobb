import HarborKit
import SwiftUI

@main
struct HarborApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 520, height: 560)
        }
        #endif
    }
}
