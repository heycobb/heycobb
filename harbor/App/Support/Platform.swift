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
        "Harbor on \(UIDevice.current.model)"
        #else
        "Harbor on Mac"
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
