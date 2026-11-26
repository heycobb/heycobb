import Foundation

/// Works out what a photo backup still has to upload, without touching the
/// photo library or the network, so it can be tested on its own.
///
/// Each library item has one or more files ("resources"): a photo, a
/// video, or a Live Photo's photo plus its short video. Files go to
/// `destination/YYYY/MM` by the date they were taken, under their original
/// names. A file is skipped if this device already backed it up, or if a
/// file with the same name and size is already in its folder (backed up
/// before, or from another device). A same-named file of a different size
/// gets a numbered name instead of replacing anything.
public enum BackupPlanner {
    public struct Resource: Hashable, Sendable {
        public let name: String
        public let size: Int64?
        public init(name: String, size: Int64?) {
            self.name = name
            self.size = size
        }
    }

    public struct Asset: Hashable, Sendable {
        /// The library's identifier for the item, stable on this device.
        public let id: String
        public let created: Date?
        public let resources: [Resource]
        public init(id: String, created: Date?, resources: [Resource]) {
            self.id = id
            self.created = created
            self.resources = resources
        }
    }

    public struct Job: Hashable, Sendable {
        public let assetID: String
        public let resource: Resource
        public let folder: String
        public let name: String
        /// The file's size wasn't known when planning and a file with this
        /// name is already in the folder: compare sizes once the file is
        /// read, and skip it if they match (else use a numbered name).
        public var checkExisting = false
        /// What this device remembers once the file is uploaded.
        public var historyKey: String { BackupPlanner.historyKey(assetID: assetID, resource: resource.name) }
    }

    public struct Plan: Sendable {
        public var jobs: [Job] = []
        /// Files found already on the NAS: remember them without uploading.
        public var alreadyThere: [String] = []
        public var bytes: Int64 { jobs.reduce(0) { $0 + ($1.resource.size ?? 0) } }
    }

    public static func historyKey(assetID: String, resource: String) -> String { assetID + "|" + resource }

    /// `destination/2026/11` for an item taken in November 2026, in the
    /// device's calendar. Items with no date go to `destination/Undated`.
    public static func folder(for date: Date?, in destination: String, calendar: Calendar = .current) -> String {
        guard let date else { return RemoteItem.join(destination, "Undated") }
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        return RemoteItem.join(RemoteItem.join(destination, year), month)
    }

    /// - Parameters:
    ///   - history: keys of files this device has already backed up.
    ///   - existing: for each folder already listed, its file names
    ///     (lowercased) and sizes. Folders missing here count as empty.
    public static func plan(
        _ assets: [Asset],
        destination: String,
        history: Set<String>,
        existing: [String: [String: Int64?]],
        calendar: Calendar = .current
    ) -> Plan {
        var plan = Plan()
        // Names taken so far, including ones this plan hands out.
        var taken: [String: Set<String>] = existing.mapValues { Set($0.keys) }
        for asset in assets {
            let folder = folder(for: asset.created, in: destination, calendar: calendar)
            for resource in asset.resources {
                let key = historyKey(assetID: asset.id, resource: resource.name)
                guard !history.contains(key) else { continue }
                let lower = resource.name.lowercased()
                if let size = existing[folder]?[lower] {
                    if resource.size == nil {
                        plan.jobs.append(Job(assetID: asset.id, resource: resource, folder: folder, name: resource.name, checkExisting: true))
                        continue
                    }
                    if size != nil, size == resource.size {
                        plan.alreadyThere.append(key)
                        continue
                    }
                }
                let name = RemoteItem.uniqueName(for: resource.name, avoiding: taken[folder, default: []])
                taken[folder, default: []].insert(name.lowercased())
                plan.jobs.append(Job(assetID: asset.id, resource: resource, folder: folder, name: name))
            }
        }
        return plan
    }
}
