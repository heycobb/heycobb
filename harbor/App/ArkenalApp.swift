import AppIntents
import ArkenalKit
import SwiftUI

@main
struct ArkenalApp: App {
    static let mainWindowID = "main"
    @State private var model: AppModel
    #if os(macOS)
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #else
    @UIApplicationDelegateAdaptor private var appDelegate: IOSAppDelegate
    #endif

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Shortcuts and Siri actions reach the model through this, including
        // when they launch the app without a window.
        AppDependencyManager.shared.add(dependency: model)
        ProStore.shared.start()
        #if os(iOS)
        // Large uploads check certificates like everything else, and pick
        // up results of uploads that finished while Arkenal wasn't running.
        BackgroundUploads.shared.trust = model.trust
        BackgroundUploads.shared.reconnect()
        // Must be registered before launch finishes.
        PhotoBackup.registerBackgroundTask(model: model)
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        // Windows and tabs. The main window has a fixed value, so the menu
        // bar's "Open Arkenal" brings it back instead of opening another;
        // File › New Tab and Open in New Tab add tabs (see WindowTabs).
        WindowGroup("Arkenal", id: Self.mainWindowID, for: WindowTarget.self) { $target in
            RootView()
                .environment(model)
                .environment(\.initialFolder, target.folder)
                .background(WindowReader { WindowTabs.attach($0) })
                .task { await model.start() }
        } defaultValue: {
            .main
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            WindowCommands()
            FolderMenuCommands()
        }
        // Open the window at every launch, even if it was closed (to the
        // menu bar) when Arkenal last quit.
        .defaultLaunchBehavior(.presented)

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarMenu()
                .environment(model)
                .task { await model.start() }
        } label: {
            MenuBarLabel()
                .environment(model)
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
                .frame(width: 540, height: 520)
        }
        #endif
    }
}

#if os(macOS)
/// The menu bar icon. It also makes sure the main window is open at launch:
/// with a menu bar item, SwiftUI doesn't reopen a window that was closed
/// when Arkenal last quit, which would leave nothing on screen.
private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // While a backup or upload runs, the icon changes so it's visible
            // at a glance; the menu has the details.
            if let progress = model.syncProgress {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .accessibilityLabel("Arkenal, \(progress.title)")
            } else {
                Image("MenuBarIcon")
                    .accessibilityLabel("Arkenal")
            }
        }
            .task {
                guard !Self.didLaunch else { return }
                Self.didLaunch = true
                ThemeSettings.shared.appIcon.apply() // the Dock icon chosen in Settings
                try? await Task.sleep(for: .milliseconds(300))
                let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
                if !hasWindow, !DockIcon.isStartingInMenuBar { openWindow(id: ArkenalApp.mainWindowID) }
            }
    }

    @MainActor private static var didLaunch = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// With the menu bar item showing, closing the window leaves Arkenal
    /// running there (uploads keep going). Without it, Arkenal quits like
    /// other single-window apps.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !DockIcon.keepsRunning
    }

    /// Read before launch finishes, while the launch event is still current.
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        launchedAtLogin = LoginItem.launchedAtLogin()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened at login with the menu bar item on: start quietly in the menu
        // bar instead of putting a window in front of everything.
        if launchedAtLogin, DockIcon.keepsRunning {
            DockIcon.startInMenuBar()
        }
        let center = NotificationCenter.default
        // A window closing may leave none open; one opening needs the Dock icon back.
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After the close finishes, so the closing window no longer counts.
                DispatchQueue.main.async { MainActor.assumeIsolated { DockIcon.update() } }
            }
        }
    }
}

/// Settings › Menu Bar › Hide Dock Icon When Closed: while Arkenal has no
/// window open it lives only in the menu bar, like other menu bar apps.
@MainActor
enum DockIcon {
    nonisolated static var keepsRunning: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarItem") as? Bool ?? true
    }

    static var hidesWhenClosed: Bool {
        keepsRunning && (UserDefaults.standard.object(forKey: "hideDockWhenClosed") as? Bool ?? true)
    }

    /// Shows the Dock icon while any window (main or Settings) is open, and
    /// hides it once the last one closes, if the setting is on.
    static func update() {
        guard !isStartingInMenuBar else { return }
        // The menu bar item's own windows can't become main, so they don't count.
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        let policy: NSApplication.ActivationPolicy = hidesWhenClosed && !hasWindow ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            // Coming back from the menu bar: restore the chosen icon and bring the window forward.
            ThemeSettings.shared.appIcon.apply()
            NSApp.activate()
        }
    }

    /// Login launch: closes the window SwiftUI opens at launch (and the one
    /// the menu bar item opens if none is showing) and leaves the Dock.
    static var isStartingInMenuBar = false

    static func startInMenuBar() {
        isStartingInMenuBar = true
        Task { @MainActor in
            // SwiftUI opens the main window just after launch; wait for it.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                for window in NSApp.windows where window.isVisible && window.canBecomeMain { window.close() }
            }
            isStartingInMenuBar = false
            update()
        }
    }

    /// Call before opening a window from the menu bar, so it opens as a normal app window.
    static func show() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            ThemeSettings.shared.appIcon.apply()
        }
        NSApp.activate()
    }
}
#endif
