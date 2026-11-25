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
        .commands { FolderMenuCommands() }
        // Open the window at every launch, even if it was closed (to the
        // menu bar) when Ownhold last quit.
        .defaultLaunchBehavior(.presented)

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarMenu()
                .environment(model)
                .task { await model.start() }
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)
        #else
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        // iPad's menu bar and keyboard shortcuts.
        .commands { FolderMenuCommands() }
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
/// The menu bar icon. It also makes sure the main window is open at launch:
/// with a menu bar item, SwiftUI doesn't reopen a window that was closed
/// when Ownhold last quit, which would leave nothing on screen.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image("MenuBarIcon")
            .accessibilityLabel("Ownhold")
            .task {
                guard !Self.didLaunch else { return }
                Self.didLaunch = true
                try? await Task.sleep(for: .milliseconds(300))
                let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
                if !hasWindow { openWindow(id: OwnholdApp.mainWindowID) }
            }
    }

    @MainActor private static var didLaunch = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// With the menu bar item showing, closing the window leaves Ownhold
    /// running there (uploads keep going). Without it, Ownhold quits like
    /// other single-window apps.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "showMenuBarItem") as? Bool ?? true)
    }
}
#endif
