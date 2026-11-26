#if os(macOS)
import AppKit
import ServiceManagement

/// Settings › Open at Login. macOS keeps the setting (System Settings ›
/// General › Login Items), so it's read from there each time, never stored.
@MainActor
@Observable
final class LoginItem {
    static let shared = LoginItem()

    private(set) var status: SMAppService.Status = SMAppService.mainApp.status

    /// On, or waiting for approval in System Settings.
    var isOn: Bool {
        get { status == .enabled || status == .requiresApproval }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                // Refused (for example, turned off by a management profile): show the real state.
            }
            refresh()
        }
    }

    var needsApproval: Bool { status == .requiresApproval }

    func refresh() { status = SMAppService.mainApp.status }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// True when macOS opened Ownhold as a login item, rather than the user.
    static func launchedAtLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
#endif
