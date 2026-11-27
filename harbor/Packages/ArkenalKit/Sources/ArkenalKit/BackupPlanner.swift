import Foundation

/// Works out what a photo backup still has to upload, without touching the
/// photo library or the network, so it can be tested on its own.
///
/// Each library item has one or more files ("resources"): a photo, a
/// video, or a Live Photo's photo plus its short video. Files go to
/// `destination/YYYY/MM` by the date they were taken, under their original
/// names. A file is skipped when:
/// - this device already backed it up;
/// - another device backed up the same iCloud Photos item (iPhone and Mac
///   with iCloud Photos see the same library: its cloud identifier is the
///   same on both, and the NAS keeps a list of them, see BackupManifest);
/// - a file with the same name is already in its folder with the same size,
///   or with the same date to the second (backups set a file's date to when
///   it was taken), so nothing has to be downloaded to compare.
/// A same-named file that differs gets a numbered name instead of replacing
/// anything.
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
        /// The iCloud Photos identifier, the same on every device signed in
        /// to the same library. Nil without iCloud Photos.
        public let cloudID: String?
        public let created: Date?
        public let resources: [Resource]
        public init(id: String, cloudID: String? = nil, created: Date?, resources: [Resource]) {
            self.id = id
            self.cloudID = cloudID
            self.created = created
            self.resources = resources
        }
    }

    /// A file already in a backup folder on the NAS.
    public struct ExistingFile: Hashable, Sendable {
        public let size: Int64?
        public let modified: Date?
        public init(size: Int64?, modified: Date? = nil) {
            self.size = size
            self.modified = modified
        }
    }

    public struct Job: Hashable, Sendable {
        public let assetID: String
        /// For the NAS's list of backed-up iCloud items, once uploaded.
        public var cloudKey: String?
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
        /// iCloud items found already on the NAS that its list doesn't have yet.
        public var sharedFound: [String] = []
        public var bytes: Int64 { jobs.reduce(0) { $0 + ($1.resource.size ?? 0) } }
    }

    public static func historyKey(assetID: String, resource: String) -> String { assetID + "|" + resource }

    /// The key in the NAS's list for one file of an iCloud Photos item.
    public static func cloudKey(cloudID: String?, resource: String) -> String? { cloudID.map { $0 + "|" + resource } }

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
    ///   - shared: cloud keys other devices backed up (the NAS's list).
    ///   - existing: for each folder already listed, its files by name
    ///     (lowercased). Folders missing here count as empty.
    public static func plan(
        _ assets: [Asset],
        destination: String,
        history: Set<String>,
        shared: Set<String> = [],
        files existing: [String: [String: ExistingFile]],
        calendar: Calendar = .current
    ) -> Plan {
        var plan = Plan()
        // Names taken so far, including ones this plan hands out.
        var taken: [String: Set<String>] = existing.mapValues { Set($0.keys) }
        for asset in assets {
            let folder = folder(for: asset.created, in: destination, calendar: calendar)
            for resource in asset.resources {
                let key = historyKey(assetID: asset.id, resource: resource.name)
                let cloudKey = cloudKey(cloudID: asset.cloudID, resource: resource.name)
                guard !history.contains(key) else { continue }
                if let cloudKey, shared.contains(cloudKey) {
                    plan.alreadyThere.append(key)
                    continue
                }
                let lower = resource.name.lowercased()
                if let file = existing[folder]?[lower] {
                    let sameSize = file.size != nil && file.size == resource.size
                    let sameDate = file.modified != nil && asset.created != nil
                        && abs(file.modified!.timeIntervalSince(asset.created!)) < 1.5
                    if sameSize || sameDate {
                        plan.alreadyThere.append(key)
                        if let cloudKey { plan.sharedFound.append(cloudKey) }
                        continue
                    }
                    if resource.size == nil {
                        var job = Job(assetID: asset.id, resource: resource, folder: folder, name: resource.name, checkExisting: true)
                        job.cloudKey = cloudKey
                        plan.jobs.append(job)
                        continue
                    }
                }
                let name = RemoteItem.uniqueName(for: resource.name, avoiding: taken[folder, default: []])
                taken[folder, default: []].insert(name.lowercased())
                var job = Job(assetID: asset.id, resource: resource, folder: folder, name: name)
                job.cloudKey = cloudKey
                plan.jobs.append(job)
            }
        }
        return plan
    }

    /// Sizes only (no dates or iCloud list).
    public static func plan(
        _ assets: [Asset],
        destination: String,
        history: Set<String>,
        existing: [String: [String: Int64?]],
        calendar: Calendar = .current
    ) -> Plan {
        plan(assets, destination: destination, history: history,
             files: existing.mapValues { $0.mapValues { ExistingFile(size: $0) } }, calendar: calendar)
    }
}

/// The NAS's list of iCloud Photos items already backed up, kept in the
/// backup folder (".arkenal-backup.json") so an iPhone and a Mac using the
/// same iCloud library don't both upload the same photos. It holds opaque
/// iCloud identifiers and file names only.
public struct BackupManifest: Codable, Sendable, Equatable {
    public static let fileName = ".arkenal-backup.json"
    /// The name before the app was renamed: still read, then replaced.
    public static let legacyFileName = ".ownhold-backup.json"

    public static func isManifest(_ name: String) -> Bool { name == fileName || name == legacyFileName }
    public var version = 1
    public var items: Set<String> = []

    public init(items: Set<String> = []) { self.items = items }

    public static func decode(_ data: Data) -> BackupManifest {
        (try? JSONDecoder().decode(BackupManifest.self, from: data)) ?? BackupManifest()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }
}
