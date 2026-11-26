import Foundation

/// Photos and videos grouped by month, newest first, for the Photos view.
/// Dates are the files' modification dates (Photo Backup sets them to when
/// each photo was taken).
public enum PhotoTimeline {
    public struct Month: Identifiable, Sendable {
        /// "2026-11", or "undated".
        public let id: String
        /// The first day of the month; nil for items without a date.
        public let start: Date?
        public let items: [RemoteItem]
    }

    public static func isPhotoOrVideo(_ item: RemoteItem) -> Bool {
        item.kind == .image || item.kind == .video
    }

    /// Folders not worth walking: Recycle Bins and DSM's thumbnail folders.
    public static func shouldSkipFolder(_ item: RemoteItem) -> Bool {
        RecycleBin.contains(item.path) || item.name.hasPrefix("@") || item.name.hasPrefix(".")
    }

    public static func months(_ items: [RemoteItem], calendar: Calendar = .current) -> [Month] {
        let media = items.filter(isPhotoOrVideo)
        let dated = media.filter { $0.modified != nil }.sorted { $0.modified! > $1.modified! }
        var months: [Month] = []
        var current: (id: String, start: Date, items: [RemoteItem])?
        for item in dated {
            let parts = calendar.dateComponents([.year, .month], from: item.modified!)
            let id = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
            if current?.id != id {
                if let current { months.append(Month(id: current.id, start: current.start, items: current.items)) }
                current = (id, calendar.date(from: parts) ?? item.modified!, [])
            }
            current?.items.append(item)
        }
        if let current { months.append(Month(id: current.id, start: current.start, items: current.items)) }
        let undated = media.filter { $0.modified == nil }
        if !undated.isEmpty { months.append(Month(id: "undated", start: nil, items: undated)) }
        return months
    }
}
