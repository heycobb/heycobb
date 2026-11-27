import ArkenalKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Design tokens. One accent color, system typography, monospaced digits for
/// data. Everything else comes from the system so the app feels native on
/// each platform. See docs/DESIGN.md for the reasoning.
enum Theme {
    /// The accent chosen in Settings › Appearance (Granite by default).
    /// Named explicitly: on the Mac it isn't the app's global accent.
    static var accent: Color { ThemeSettings.shared.accent.accent }
    /// Text and icons on a solid accent fill.
    static var onAccent: Color { ThemeSettings.shared.accent.onAccent }

    /// The sidebar: tinted with the accent, or the system's plain sidebar.
    enum Sidebar {
        /// Blackout turns the tint off: the sidebar is black like the rest.
        static var isTinted: Bool { ThemeSettings.shared.sidebarStyle == .tinted && ThemeSettings.shared.accent != .system && !Blackout.isOn }
        /// Glass (Mac): the window is frosted and the content sits on a card.
        /// Blackout stays solid black.
        static var isGlass: Bool {
            #if os(macOS)
            ThemeSettings.shared.sidebarStyle == .glass && !Blackout.isOn
            #else
            false
            #endif
        }
        static var background: Color { ThemeSettings.shared.accent.sidebarTint }
        static var text: Color { isTinted ? ThemeSettings.shared.accent.sidebarText : .primary }
        static var secondary: Color { isTinted ? ThemeSettings.shared.accent.sidebarSecondary : .secondary }
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 32
    }

    /// Thumbnails use small, consistent corners. Big pill-shaped cards are
    /// one of the clearest "generated UI" tells.
    static let thumbnailRadius: CGFloat = 6
    #if os(macOS)
    static let gridMinimum: CGFloat = 150
    #else
    static let gridMinimum: CGFloat = 104
    #endif
    /// iPad (regular width) and Mac.
    static let gridMinimumRegular: CGFloat = 150

    /// Photos-style grid: square thumbnails separated by hairline gaps.
    static let photoMinimum: CGFloat = 90
    static let photoMinimumRegular: CGFloat = 140
    static let photoSpacing: CGFloat = 2
}

/// The user's choice in Settings › Appearance.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark, blackout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        case .blackout: "Blackout"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark, .blackout: .dark
        }
    }

    #if os(macOS)
    /// Applied app-wide on the Mac, so Settings and menus follow too.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark, .blackout: NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

extension View {
    /// Applies Settings › Appearance.
    func appAppearance(_ choice: AppearanceChoice) -> some View {
        #if os(macOS)
        onChange(of: choice, initial: true) { NSApp.appearance = choice.nsAppearance }
        #else
        // Set on the windows rather than with preferredColorScheme: an open
        // sheet (Settings) then changes right away, not after it closes.
        onChange(of: choice, initial: true) {
            let style: UIUserInterfaceStyle = switch choice {
            case .system: .unspecified
            case .light: .light
            case .dark, .blackout: .dark
            }
            for scene in UIApplication.shared.connectedScenes {
                for window in (scene as? UIWindowScene)?.windows ?? [] {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
        #endif
    }
}

/// Blackout: dark mode taken further for dark rooms and OLED screens. True
/// black behind everything (sheets too, which dark mode lifts to grey) and
/// rows only just lifted off it. Text keeps the system's light label colors,
/// so tinted buttons and links keep the accent.
enum Blackout {
    static let background = Color.black
    static let row = Color(red: 0.07, green: 0.07, blue: 0.075)

    static var isOn: Bool { UserDefaults.standard.string(forKey: "appearance") == AppearanceChoice.blackout.rawValue }
}

/// Puts a list or form on Blackout's colors when it's chosen.
struct BlackoutSurface: ViewModifier {
    @AppStorage("appearance") private var appearance: AppearanceChoice = .system

    // No if/else here: swapping views would close open sheets and reset
    // scroll positions whenever the appearance changes.
    func body(content: Content) -> some View {
        let on = appearance == .blackout
        content
            .scrollContentBackground(on ? .hidden : .automatic)
            .background(on ? Blackout.background : .clear)
    }
}

/// Row backgrounds for Blackout. Applied to each section (a Group hands a
/// modifier to every child), since a row color set on the whole form
/// doesn't reach its rows.
struct BlackoutRows: ViewModifier {
    @AppStorage("appearance") private var appearance: AppearanceChoice = .system

    func body(content: Content) -> some View {
        content.listRowBackground(appearance == .blackout ? Blackout.row : nil)
    }
}

extension View {
    func blackoutSurface() -> some View { modifier(BlackoutSurface()) }
}

#if os(macOS)
/// The desktop behind the window, frosted (like Finder's sidebar). Goes
/// solid while the window is in the background, as macOS does, and with
/// Reduce Transparency.
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        #if DEBUG
        // For checking the look with the window in the background.
        if CommandLine.arguments.contains("-glassActive") { view.state = .active }
        #endif
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Glass: the content area as a rounded card, inset from the frosted window
/// on every side. No if/else (it would reset scroll positions on a switch).
struct GlassCard: ViewModifier {
    let on: Bool
    static let radius: CGFloat = 10
    static let inset: CGFloat = 8

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: on ? Self.radius : 0, style: .continuous)
        content
            .background { shape.fill(Color(nsColor: .controlBackgroundColor)) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(on ? 0.08 : 0), lineWidth: 0.5) }
            .padding([.horizontal, .bottom], on ? Self.inset : 0)
            .toolbarBackgroundVisibility(on ? .hidden : .automatic, for: .windowToolbar)
    }
}
#endif

extension EnvironmentValues {
    /// Settings › Appearance › Blackout, for views that draw their own
    /// backgrounds (the Mac sidebar).
    @Entry var isBlackout = false
}

/// The window itself: black behind everything in Blackout. On the Mac the
/// window background shows through the sidebar, folders and empty screens.
struct BlackoutWindow: ViewModifier {
    let on: Bool
    /// The main window follows the Glass sidebar style; Settings stays solid.
    var followsGlass = false

    func body(content: Content) -> some View {
        #if os(macOS)
        // Glass: the desktop shows through, frosted. Reduce Transparency in
        // System Settings makes the material solid on its own.
        let glass = followsGlass && !on && ThemeSettings.shared.sidebarStyle == .glass
        content.containerBackground(for: .window) {
            ZStack {
                Color(nsColor: .windowBackgroundColor).opacity(on || glass ? 0 : 1)
                Blackout.background.opacity(on ? 1 : 0)
                if glass { WindowGlass() }
            }
        }
        #else
        content.background(on ? Blackout.background : .clear)
        #endif
    }
}

/// A Form that follows Blackout: black behind, near-black rows.
struct OwnForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            Group { content }.modifier(BlackoutRows())
        }
        .blackoutSurface()
    }
}

extension Font {
    /// Sizes, dates and paths: monospaced so columns line up and the app reads as a precise tool.
    static let meta = Font.caption.monospacedDigit()
    static let path = Font.footnote.monospaced()

    /// Names under grid tiles. The Mac's caption size (10 pt) is too small
    /// to read at a glance in a window full of folders.
    #if os(macOS)
    static let tileName = Font.body
    static let tileMeta = Font.subheadline.monospacedDigit()
    #else
    static let tileName = Font.caption
    static let tileMeta = Font.meta
    #endif
}

extension FileKind {
    var symbol: String {
        switch self {
        case .folder: "folder.fill"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .archive: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .text: "text.alignleft"
        case .other: "doc"
        }
    }

    /// Folders get the accent; files stay neutral so thumbnails carry the color.
    var tint: Color {
        self == .folder ? Theme.accent : .secondary
    }
}

extension Endpoint.Kind {
    var symbol: String {
        switch self {
        case .local: "house"
        case .vpn: "point.3.connected.trianglepath.dotted"
        case .remote: "globe"
        }
    }
}

enum Format {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return value.formatted(.dateTime.year().month(.abbreviated).day())
    }
}

/// A List that follows Blackout, like OwnForm.
struct OwnList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List {
            Group { content }.modifier(BlackoutRows())
        }
        .blackoutSurface()
    }
}
