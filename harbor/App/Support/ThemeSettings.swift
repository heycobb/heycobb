import Observation
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
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: "accent") }
    }
    var sidebarStyle: SidebarStyle {
        didSet { UserDefaults.standard.set(sidebarStyle.rawValue, forKey: "sidebarStyle") }
    }
    var appIcon: AppIconChoice {
        didSet { UserDefaults.standard.set(appIcon.rawValue, forKey: "appIcon") }
    }

    private init() {
        let defaults = UserDefaults.standard
        accent = defaults.string(forKey: "accent").flatMap(AccentChoice.init) ?? .evergreen
        sidebarStyle = defaults.string(forKey: "sidebarStyle").flatMap(SidebarStyle.init) ?? .tinted
        appIcon = defaults.string(forKey: "appIcon").flatMap(AppIconChoice.init) ?? .evergreen
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
enum AccentChoice: String, CaseIterable, Identifiable {
    case evergreen, harbor, graphite, rosewood
    var id: String { rawValue }

    var title: String {
        switch self {
        case .evergreen: "Evergreen"
        case .harbor: "Harbor Blue"
        case .graphite: "Graphite"
        case .rosewood: "Rosewood"
        }
    }

    var accent: Color {
        switch self {
        case .evergreen: Color(light: 0x1D4B3C, dark: 0x6FBF9A)
        case .harbor: Color(light: 0x1F4A6E, dark: 0x7FB2DA)
        case .graphite: Color(light: 0x3B3F45, dark: 0xB9C0C8)
        case .rosewood: Color(light: 0x7A2F3B, dark: 0xE3949F)
        }
    }

    var sidebarTint: Color {
        switch self {
        case .evergreen: Color(light: 0xE3ECE6, dark: 0x18241E)
        case .harbor: Color(light: 0xE3EAF1, dark: 0x172230)
        case .graphite: Color(light: 0xECEDEF, dark: 0x1E2023)
        case .rosewood: Color(light: 0xF2E6E8, dark: 0x2A1A1D)
        }
    }

    var sidebarText: Color {
        switch self {
        case .evergreen: Color(light: 0x1F2B25, dark: 0xDCE8E0)
        case .harbor: Color(light: 0x1C2733, dark: 0xDCE6F0)
        case .graphite: Color(light: 0x25282C, dark: 0xE4E6E9)
        case .rosewood: Color(light: 0x33201F, dark: 0xF0DEE1)
        }
    }

    var sidebarSecondary: Color {
        switch self {
        case .evergreen: Color(light: 0x5E7568, dark: 0x7E9A8B)
        case .harbor: Color(light: 0x5A6B7C, dark: 0x8296AA)
        case .graphite: Color(light: 0x6A6E74, dark: 0x8C9198)
        case .rosewood: Color(light: 0x7A5E62, dark: 0xA88990)
        }
    }

    var onAccent: Color {
        switch self {
        case .evergreen: Color(light: 0xF3F0E8, dark: 0x0E1F18)
        case .harbor: Color(light: 0xF2F5F8, dark: 0x0D1B28)
        case .graphite: Color(light: 0xF4F4F5, dark: 0x16181B)
        case .rosewood: Color(light: 0xFAF2F2, dark: 0x22100F)
        }
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
        case .graphite: (Color(hex: 0x2C2F33), Color(hex: 0xE6E8EA), Color(hex: 0x8FD3B0))
        case .harbor: (Color(hex: 0x1F4A6E), Color(hex: 0xF2F5F8), Color(hex: 0x7FB2DA))
        }
    }

    /// Switches the Home Screen icon (iPhone, iPad) or the Dock icon (Mac,
    /// while Ownhold runs; Finder keeps the standard icon).
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
