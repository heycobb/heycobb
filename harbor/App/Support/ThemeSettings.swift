import Observation
import ArkenalKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Settings › Appearance: accent color, sidebar style and app icon.
/// Views read these through `Theme`, so a change redraws everything.
@Observable
final class ThemeSettings: @unchecked Sendable {
    // Read and written on the main thread only (from views and Settings).
    static let shared = ThemeSettings()

    var accent: AccentChoice {
        didSet {
            UserDefaults.standard.set(accent.rawValue, forKey: "accent")
            // The share extension uses the same accent.
            SharedContainer.defaults.set(accent.rawValue, forKey: "accent")
        }
    }
    var sidebarStyle: SidebarStyle {
        didSet { UserDefaults.standard.set(sidebarStyle.rawValue, forKey: "sidebarStyle") }
    }
    var appIcon: AppIconChoice {
        didSet { UserDefaults.standard.set(appIcon.rawValue, forKey: "appIcon") }
    }

    private init() {
        let defaults = UserDefaults.standard
        accent = defaults.string(forKey: "accent").flatMap(AccentChoice.init(storedValue:)) ?? .granite
        sidebarStyle = defaults.string(forKey: "sidebarStyle").flatMap(SidebarStyle.init) ?? .tinted
        appIcon = defaults.string(forKey: "appIcon").flatMap(AppIconChoice.init(storedValue:)) ?? .granite
        SharedContainer.defaults.set(accent.rawValue, forKey: "accent")
    }
}

enum SidebarStyle: String, CaseIterable, Identifiable {
    case tinted, plain
    var id: String { rawValue }
    var title: String { self == .tinted ? "Tinted" : "Plain" }
}

/// Each accent sets four colors, for light and dark: the accent itself, the
/// tinted sidebar, text on that sidebar, and text on a solid accent fill.
/// No purple or terracotta: both now read as generic, AI-made design.
/// System follows the Mac's own accent color (blue on iPhone and iPad) and
/// always uses the plain sidebar, so Arkenal looks like a standard Mac app.
enum AccentChoice: String, CaseIterable, Identifiable {
    case system, granite, spruce, fjord, rowan, amber
    var id: String { rawValue }

    /// Reads a saved choice, mapping accents that were renamed or removed
    /// (they looked too alike) to the closest one now.
    init?(storedValue: String) {
        switch storedValue {
        case "forest", "evergreen": self = .spruce
        case "midnight", "harbor": self = .fjord
        case "onyx", "graphite", "basalt": self = .granite
        case "rosewood": self = .rowan
        case "espresso": self = .amber
        default: self.init(rawValue: storedValue)
        }
    }

    var title: String {
        switch self {
        case .system: "System"
        case .spruce: "Spruce"
        case .fjord: "Fjord"
        case .granite: "Granite"
        case .rowan: "Rowan"
        case .amber: "Amber"
        }
    }

    var accent: Color {
        switch self {
        case .system: Self.systemAccent
        case .spruce: Color(light: 0x1D4B3C, dark: 0x6FBF9A)
        case .fjord: Color(light: 0x1F4A6E, dark: 0x7FB2DA)
        case .granite: Color(light: 0x2E3A41, dark: 0xA9B8C1)
        case .rowan: Color(light: 0x7A2F3B, dark: 0xE3949F)
        case .amber: Color(light: 0x9A6312, dark: 0xE3B261)
        }
    }

    /// Unused for System, which always has the plain sidebar.
    var sidebarTint: Color {
        switch self {
        case .spruce, .system: Color(light: 0xE3ECE6, dark: 0x18241E)
        case .fjord: Color(light: 0xE3EAF1, dark: 0x172230)
        case .granite: Color(light: 0xE5E9EB, dark: 0x1A2024)
        case .rowan: Color(light: 0xF2E6E8, dark: 0x2A1A1D)
        case .amber: Color(light: 0xF3ECDF, dark: 0x241D12)
        }
    }

    var sidebarText: Color {
        switch self {
        case .spruce, .system: Color(light: 0x1F2B25, dark: 0xDCE8E0)
        case .fjord: Color(light: 0x1C2733, dark: 0xDCE6F0)
        case .granite: Color(light: 0x222A2F, dark: 0xE1E6E9)
        case .rowan: Color(light: 0x33201F, dark: 0xF0DEE1)
        case .amber: Color(light: 0x2E2416, dark: 0xF0E6D4)
        }
    }

    var sidebarSecondary: Color {
        switch self {
        case .spruce, .system: Color(light: 0x5E7568, dark: 0x7E9A8B)
        case .fjord: Color(light: 0x5A6B7C, dark: 0x8296AA)
        case .granite: Color(light: 0x5E6A71, dark: 0x8B979E)
        case .rowan: Color(light: 0x7A5E62, dark: 0xA88990)
        case .amber: Color(light: 0x7C6A50, dark: 0xA89478)
        }
    }

    var onAccent: Color {
        switch self {
        case .system: .white
        case .spruce: Color(light: 0xF3F0E8, dark: 0x0E1F18)
        case .fjord: Color(light: 0xF2F5F8, dark: 0x0D1B28)
        case .granite: Color(light: 0xF3F5F6, dark: 0x12171A)
        case .rowan: Color(light: 0xFAF2F2, dark: 0x22100F)
        case .amber: Color(light: 0xFCF7EE, dark: 0x22180A)
        }
    }

    /// The Mac's accent from System Settings › Appearance (the Mac target has
    /// no global accent of its own); iOS has no user accent, so system blue.
    private static var systemAccent: Color {
        #if os(macOS)
        Color(nsColor: .controlAccentColor)
        #else
        Color(uiColor: .systemBlue)
        #endif
    }
}

/// The app icon: the Arkenal peak in four colorways.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case granite, snow, spruce, fjord
    var id: String { rawValue }

    /// Reads a saved choice, mapping icons that were renamed.
    init?(storedValue: String) {
        switch storedValue {
        case "graphite", "basalt": self = .granite
        case "paper": self = .snow
        case "evergreen": self = .spruce
        case "harbor": self = .fjord
        default: self.init(rawValue: storedValue)
        }
    }

    var title: String {
        switch self {
        case .granite: "Granite"
        case .snow: "Snow"
        case .spruce: "Spruce"
        case .fjord: "Fjord"
        }
    }

    /// The alternate icon's name in the asset catalog; nil is the main icon.
    var assetName: String? {
        switch self {
        case .granite: nil
        case .snow: "AppIcon-Snow"
        case .spruce: "AppIcon-Spruce"
        case .fjord: "AppIcon-Fjord"
        }
    }

    /// Background, peak and core colors, for the preview in Settings
    /// (match Design/AppIcon/make_icons.py).
    var colors: (background: Color, glyph: Color, dot: Color) {
        switch self {
        case .granite: (Color(hex: 0x232B30), Color(hex: 0xEEF1F2), Color(hex: 0xA9B8C1))
        case .snow: (Color(hex: 0xEEF1F2), Color(hex: 0x2E3A41), Color(hex: 0x6F7E86))
        case .spruce: (Color(hex: 0x1D4B3C), Color(hex: 0xF3F0E8), Color(hex: 0x8FD3B0))
        case .fjord: (Color(hex: 0x1F4A6E), Color(hex: 0xF2F5F8), Color(hex: 0x7FB2DA))
        }
    }

    /// Switches the Home Screen icon (iPhone, iPad) or the Dock icon (Mac,
    /// while Arkenal runs; Finder keeps the standard icon).
    @MainActor func apply() {
        #if os(iOS)
        guard UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != assetName else { return }
        UIApplication.shared.setAlternateIconName(assetName) { _ in }
        #else
        NSApp.applicationIconImage = assetName.flatMap { NSImage(named: $0) }
        #endif
    }
}

/// The app icon drawn in SwiftUI, for previews (matches App/AppIcon.icon,
/// generated by Design/AppIcon/make_icons.py).
struct MonogramIcon: View {
    let choice: AppIconChoice

    /// The peak's outline in a 100-point square, already lowered by 3 like the icon.
    private static let peak: [CGPoint] = [
        (19.56, 78), (50, 14.78), (80.44, 78), (71.56, 78), (54.47, 42.5), (45.53, 42.5), (28.44, 78),
    ].map { CGPoint(x: $0.0, y: $0.1 + 3) }

    var body: some View {
        let colors = choice.colors
        Canvas { context, size in
            let s = size.width / 100
            let rect = CGRect(origin: .zero, size: size)
            let tile = Path(roundedRect: rect, cornerRadius: 22.4 * s, style: .continuous)
            context.fill(tile, with: .color(colors.background))
            // The light icon needs an edge to stand out on white.
            if choice == .snow {
                context.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 22.4 * s - 0.5, style: .continuous),
                               with: .color(.black.opacity(0.12)), lineWidth: 1)
            }
            var peak = Path()
            peak.addLines(Self.peak.map { CGPoint(x: $0.x * s, y: $0.y * s) })
            peak.closeSubpath()
            context.fill(peak, with: .color(colors.glyph))
            context.fill(Path(ellipseIn: CGRect(x: 42 * s, y: 58 * s, width: 16 * s, height: 16 * s)), with: .color(colors.dot))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// A color with separate light- and dark-mode values.
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        })
        #else
        self.init(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
        #endif
    }
}
