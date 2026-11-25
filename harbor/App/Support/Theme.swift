import HarborKit
import SwiftUI

/// Design tokens. One accent color, system typography, monospaced digits for
/// data. Everything else comes from the system so the app feels native on
/// each platform. See docs/DESIGN.md for the reasoning.
enum Theme {
    /// Defined in the asset catalog (light + dark variants).
    static let accent = Color.accentColor

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
    static let gridMinimum: CGFloat = 104
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
        case .tailscale: "point.3.connected.trianglepath.dotted"
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
