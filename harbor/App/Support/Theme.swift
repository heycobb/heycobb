import OwnholdKit
import SwiftUI

/// Design tokens. One accent color, system typography, monospaced digits for
/// data. Everything else comes from the system so the app feels native on
/// each platform. See docs/DESIGN.md for the reasoning.
enum Theme {
    /// Deep evergreen, defined in the asset catalog (light + dark variants).
    /// Named explicitly: on the Mac it isn't the app's global accent.
    static let accent = Color("AccentColor")

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

extension Font {
    /// Sizes, dates and paths: monospaced so columns line up and the app reads as a precise tool.
    static let meta = Font.caption.monospacedDigit()
    static let path = Font.footnote.monospaced()
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
