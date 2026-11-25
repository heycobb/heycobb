import OwnholdKit
import SwiftUI

@main
struct OwnholdApp: App {
    static let mainWindowID = "main"
    @State private var model = AppModel()
    #if os(macOS)
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        // One main window on the Mac, so the menu bar's "Open Ownhold"
        // brings it back instead of opening another.
        Window("Ownhold", id: Self.mainWindowID) {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .defaultSize(width: 1100, height: 720)

        MenuBarExtra("Ownhold", image: "MenuBarIcon", isInserted: $showMenuBarItem) {
            MenuBarMenu()
                .environment(model)
                .task { await model.start() }
        }
        .menuBarExtraStyle(.menu)
        #else
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
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

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// With the menu bar item showing, closing the window leaves Ownhold
    /// running there (uploads keep going). Without it, Ownhold quits like
    /// other single-window apps.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "showMenuBarItem") as? Bool ?? true)
    }
}
#endif
