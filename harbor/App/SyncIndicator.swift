import Foundation
import OwnholdKit
import os
#if os(iOS)
import ActivityKit
import UIKit
#else
import AppKit
import SwiftUI
#endif

extension AppModel {
    /// The backup or upload running now, if any. Backups come first.
    var syncProgress: SyncProgress? {
        #if os(iOS)
        if let progress = Self.progress(backup.phase, kind: .photoBackup) { return progress }
        #else
        if let progress = Self.progress(folderBackup.phase, kind: .folderBackup) { return progress }
        #endif
        let queue = uploads
        let active = queue.jobs.count { $0.state != .cancelled }
        guard queue.remaining > 0, active > 0 else { return nil }
        return SyncProgress(kind: .uploads, done: queue.completed, total: active, fraction: queue.fraction)
    }

    private static func progress(_ phase: PhotoBackupPhase, kind: SyncProgress.Kind) -> SyncProgress? {
        switch phase {
        case .scanning: SyncProgress(kind: kind)
        case let .uploading(done, total, _): SyncProgress(kind: kind, done: done, total: total, fraction: total > 0 ? Double(done) / Double(total) : nil)
        default: nil
        }
    }

    /// Watches `syncProgress` for as long as the app runs and passes each
    /// change to the indicator.
    func trackSyncProgress() {
        let progress = withObservationTracking { syncProgress } onChange: { [weak self] in
            Task { @MainActor in self?.trackSyncProgress() }
        }
        SyncIndicator.shared.update(progress, serverName: activeServer?.name ?? "NAS")
    }
}

#if os(iOS)
typealias PhotoBackupPhase = PhotoBackup.Phase
#else
typealias PhotoBackupPhase = FolderBackup.Phase
#endif

/// iPhone and iPad: a Live Activity for long jobs (Settings › Show Progress
/// on Lock Screen). Mac: a progress bar on the Dock icon.
@MainActor
final class SyncIndicator {
    static let shared = SyncIndicator()
    static let liveActivityKey = "showLiveActivity"

    private static let log = Logger(subsystem: "app.ownhold.Ownhold", category: "sync-indicator")
    /// Jobs shorter than this never show the indicator, so it doesn't flash.
    private static let startDelay: Duration = .seconds(5)
    /// The system limits how often a Live Activity may change.
    private static let minimumInterval: TimeInterval = 2

    private var latest: SyncProgress?
    private var pendingStart: Task<Void, Never>?
    private var lastPush = Date.distantPast
    private var pendingPush: Task<Void, Never>?
    #if os(iOS)
    private var activity: Activity<SyncActivityAttributes>?
    #else
    private var dockShowing = false
    #endif

    func update(_ progress: SyncProgress?, serverName: String) {
        latest = progress
        guard let progress else {
            pendingStart?.cancel()
            pendingStart = nil
            pendingPush?.cancel()
            pendingPush = nil
            finish()
            return
        }
        if isShowing {
            push(progress)
        } else if pendingStart == nil {
            pendingStart = Task { [weak self] in
                try? await Task.sleep(for: Self.startDelay)
                guard !Task.isCancelled, let self else { return }
                pendingStart = nil
                if let latest { begin(latest, serverName: serverName) }
            }
        }
    }

    /// Throttled: at most one change every couple of seconds.
    private func push(_ progress: SyncProgress) {
        let wait = Self.minimumInterval - Date().timeIntervalSince(lastPush)
        guard wait > 0 else {
            lastPush = Date()
            show(progress)
            return
        }
        guard pendingPush == nil else { return }
        pendingPush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            pendingPush = nil
            if let latest { push(latest) }
        }
    }

    #if os(iOS)
    private var isShowing: Bool { activity != nil }

    private func begin(_ progress: SyncProgress, serverName: String) {
        let enabled = UserDefaults.standard.object(forKey: Self.liveActivityKey) as? Bool ?? true
        // A Live Activity can only be started while Ownhold is open.
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active else { return }
        do {
            activity = try Activity.request(
                attributes: SyncActivityAttributes(serverName: serverName),
                content: ActivityContent(state: progress, staleDate: nil)
            )
            lastPush = Date()
        } catch {
            Self.log.error("Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func show(_ progress: SyncProgress) {
        guard let id = activity?.id else { return }
        Task.detached { await Self.running(id)?.update(ActivityContent(state: progress, staleDate: nil)) }
    }

    private func finish() {
        guard let id = activity?.id else { return }
        activity = nil
        Task.detached { await Self.running(id)?.end(nil, dismissalPolicy: .immediate) }
    }

    /// Looked up by ID: `Activity` can't be passed between tasks.
    private nonisolated static func running(_ id: String) -> Activity<SyncActivityAttributes>? {
        Activity<SyncActivityAttributes>.activities.first { $0.id == id }
    }

    /// Turning the setting off ends one that's showing.
    func settingChanged(_ on: Bool) {
        if !on { finish() }
    }
    #else
    private var isShowing: Bool { dockShowing }

    private func begin(_ progress: SyncProgress, serverName: String) {
        dockShowing = true
        lastPush = Date()
        show(progress)
    }

    private func show(_ progress: SyncProgress) {
        let tile = NSApp.dockTile
        let view = NSHostingView(rootView: DockProgressView(icon: NSApp.applicationIconImage, fraction: progress.fraction))
        view.frame = NSRect(origin: .zero, size: tile.size)
        tile.contentView = view
        tile.display()
    }

    private func finish() {
        guard dockShowing else { return }
        dockShowing = false
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
    #endif
}

#if os(macOS)
/// The app icon with a progress bar along the bottom, like Finder's copies.
private struct DockProgressView: View {
    let icon: NSImage?
    let fraction: Double?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit()
            }
            GeometryReader { geo in
                // Inside the icon's own margin, like Finder's copy progress.
                let width = geo.size.width * 0.62
                let height = geo.size.height * 0.085
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.75))
                    Capsule().strokeBorder(.white.opacity(0.9), lineWidth: max(height * 0.12, 1))
                    Capsule().fill(.white)
                        .frame(width: max((width - height * 0.5) * (fraction ?? 0.04), height * 0.5))
                        .padding(height * 0.25)
                }
                .frame(width: width, height: height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, geo.size.height * 0.2)
            }
        }
    }
}
#endif
