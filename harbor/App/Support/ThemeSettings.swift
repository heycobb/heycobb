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
        accent = defaults.string(forKey: "accent").flatMap(AccentChoice.init(storedValue:)) ?? .basalt
        sidebarStyle = defaults.string(forKey: "sidebarStyle").flatMap(SidebarStyle.init) ?? .tinted
        appIcon = defaults.string(forKey: "appIcon").flatMap(AppIconChoice.init) ?? .evergreen
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
    case system, basalt, evergreen, harbor, rosewood, amber
    var id: String { rawValue }

    /// Reads a saved choice, mapping accents that were removed (they looked
    /// too alike) to the closest one left.
    init?(storedValue: String) {
        switch storedValue {
        case "forest": self = .evergreen
        case "midnight": self = .harbor
        case "onyx", "graphite": self = .basalt
        case "espresso": self = .amber
        default: self.init(rawValue: storedValue)
        }
    }

    var title: String {
        switch self {
        case .system: "System"
        case .evergreen: "Evergreen"
        case .harbor: "Harbor Blue"
        case .basalt: "Basalt"
        case .rosewood: "Rosewood"
        case .amber: "Amber"
        }
    }

    var accent: Color {
        switch self {
        case .system: Self.systemAccent
        case .evergreen: Color(light: 0x1D4B3C, dark: 0x6FBF9A)
        case .harbor: Color(light: 0x1F4A6E, dark: 0x7FB2DA)
        case .basalt: Color(light: 0x2E3A41, dark: 0xA9B8C1)
        case .rosewood: Color(light: 0x7A2F3B, dark: 0xE3949F)
        case .amber: Color(light: 0x9A6312, dark: 0xE3B261)
        }
    }

    /// Unused for System, which always has the plain sidebar.
    var sidebarTint: Color {
        switch self {
        case .evergreen, .system: Color(light: 0xE3ECE6, dark: 0x18241E)
        case .harbor: Color(light: 0xE3EAF1, dark: 0x172230)
        case .basalt: Color(light: 0xE5E9EB, dark: 0x1A2024)
        case .rosewood: Color(light: 0xF2E6E8, dark: 0x2A1A1D)
        case .amber: Color(light: 0xF3ECDF, dark: 0x241D12)
        }
    }

    var sidebarText: Color {
        switch self {
        case .evergreen, .system: Color(light: 0x1F2B25, dark: 0xDCE8E0)
        case .harbor: Color(light: 0x1C2733, dark: 0xDCE6F0)
        case .basalt: Color(light: 0x222A2F, dark: 0xE1E6E9)
        case .rosewood: Color(light: 0x33201F, dark: 0xF0DEE1)
        case .amber: Color(light: 0x2E2416, dark: 0xF0E6D4)
        }
    }

    var sidebarSecondary: Color {
        switch self {
        case .evergreen, .system: Color(light: 0x5E7568, dark: 0x7E9A8B)
        case .harbor: Color(light: 0x5A6B7C, dark: 0x8296AA)
        case .basalt: Color(light: 0x5E6A71, dark: 0x8B979E)
        case .rosewood: Color(light: 0x7A5E62, dark: 0xA88990)
        case .amber: Color(light: 0x7C6A50, dark: 0xA89478)
        }
    }

    var onAccent: Color {
        switch self {
        case .system: .white
        case .evergreen: Color(light: 0xF3F0E8, dark: 0x0E1F18)
        case .harbor: Color(light: 0xF2F5F8, dark: 0x0D1B28)
        case .basalt: Color(light: 0xF3F5F6, dark: 0x12171A)
        case .rosewood: Color(light: 0xFAF2F2, dark: 0x22100F)
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

/// The app icon: the same "oh" monogram in four colorways.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case evergreen, paper, graphite, harbor
    var id: String { rawValue }

    var title: String {
        switch self {
        case .evergreen: "Evergreen"
        case .paper: "Paper"
        case .graphite: "Graphite"
        case .harbor: "Harbor Blue"
        }
    }

    /// The alternate icon's name in the asset catalog; nil is the main icon.
    var assetName: String? {
        switch self {
        case .evergreen: nil
        case .paper: "AppIcon-Paper"
        case .graphite: "AppIcon-Graphite"
        case .harbor: "AppIcon-Harbor"
        }
    }

    /// Background, letter and dot colors, for the preview in Settings.
    var colors: (background: Color, glyph: Color, dot: Color) {
        switch self {
        case .evergreen: (Color(hex: 0x1D4B3C), Color(hex: 0xF3F0E8), Color(hex: 0x8FD3B0))
        case .paper: (Color(hex: 0xF3F0E8), Color(hex: 0x1D4B3C), Color(hex: 0x4FA57E))
        case .graphite: (Color(hex: 0x2C2F33), Color(hex: 0xE6E8EA), Color(hex: 0xE6E8EA))
        case .harbor: (Color(hex: 0x1F4A6E), Color(hex: 0xF2F5F8), Color(hex: 0x7FB2DA))
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

/// The monogram drawn in SwiftUI, for previews (matches App/AppIcon.icon).
struct MonogramIcon: View {
    let choice: AppIconChoice

    var body: some View {
        let colors = choice.colors
        Canvas { context, size in
            let s = size.width / 100
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 22.4 * s, style: .continuous), with: .color(colors.background))
            var h = Path()
            h.move(to: CGPoint(x: 31 * s, y: 80 * s))
            h.addLine(to: CGPoint(x: 31 * s, y: 25 * s))
            h.move(to: CGPoint(x: 31 * s, y: 51 * s))
            h.addArc(center: CGPoint(x: 50 * s, y: 51 * s), radius: 19 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            h.addLine(to: CGPoint(x: 69 * s, y: 80 * s))
            context.stroke(h, with: .color(colors.glyph), style: StrokeStyle(lineWidth: 9.5 * s, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: 41.5 * s, y: 57.5 * s, width: 17 * s, height: 17 * s)), with: .color(colors.dot))
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
