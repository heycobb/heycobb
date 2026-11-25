import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum Platform {
    /// Name sent to DSM when remembering this device for 2-factor sign-in.
    /// Shown in DSM under Personal > Security > Trusted devices.
    @MainActor static var deviceName: String {
        #if canImport(UIKit)
        "Ownhold on \(UIDevice.current.model)"
        #else
        "Ownhold on Mac"
        #endif
    }

    #if os(macOS)
    static let isMac = true
    #else
    static let isMac = false
    #endif
}

/// Light haptic confirmation on devices that have them.
@MainActor
enum Haptics {
    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

/// The system share sheet for one or more local files.
@MainActor
enum SharePresenter {
    static func present(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            // iPad: show near the top right, where the toolbar is.
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.maxX - 60, y: top.view.safeAreaInsets.top + 8, width: 1, height: 1)
            popover.permittedArrowDirections = [.up]
        }
        top.present(controller, animated: true)
        #else
        guard let content = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        let anchor = NSRect(x: content.bounds.maxX - 80, y: content.bounds.maxY - 8, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: content, preferredEdge: .minY)
        #endif
    }
}
