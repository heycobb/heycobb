import OwnholdKit
import SwiftUI

/// A quiet bar under the file list while uploads (or a move or delete) run.
struct ActivityBar: View {
    /// A move or delete in progress, e.g. "Deleting 3 items…".
    let working: String?
    /// Shown as a Cancel button while `working` is set.
    var onCancel: (() -> Void)? = nil

    @Environment(AppModel.self) private var model
    @State private var showingDetails = false

    var body: some View {
        let uploads = model.uploads
        if let working {
            bar {
                ProgressView().controlSize(.small)
                Text(working).font(.callout)
                Spacer()
                if let onCancel {
                    Button("Cancel", action: onCancel).font(.callout)
                }
            }
        } else if !uploads.isEmpty {
            bar {
                status(uploads)
                Spacer()
                Button(uploads.isRunning || uploads.preparing > 0 ? "Details" : "Show") { showingDetails = true }
                    .font(.callout)
                if !uploads.isRunning, uploads.preparing == 0 {
                    Button("Dismiss", systemImage: "xmark") { uploads.clearFinished() }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showingDetails) { UploadsView() }
        }
    }

    @ViewBuilder private func status(_ uploads: UploadQueue) -> some View {
        if uploads.preparing > 0, uploads.jobs.isEmpty {
            ProgressView().controlSize(.small)
            Text(uploads.preparing == 1 ? "Preparing 1 item…" : "Preparing \(uploads.preparing) items…").font(.callout)
        } else if uploads.isRunning {
            ProgressView(value: uploads.fraction)
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Uploading \(uploads.completed + 1) of \(uploads.jobs.count { $0.state != .cancelled })")
                    .font(.callout)
                if let current = uploads.current {
                    Text(current.name).font(.meta).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        } else if uploads.failed > 0 {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(uploads.failed == 1 ? "1 item couldn't be uploaded" : "\(uploads.failed) items couldn't be uploaded").font(.callout)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            Text(uploads.completed == 1 ? "1 item uploaded" : "\(uploads.completed) items uploaded").font(.callout)
        }
    }

    private func bar(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: Theme.Spacing.m) { content() }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s + 2)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }
}

/// Every upload in this session, with progress and errors.
struct UploadsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let uploads = model.uploads
        NavigationStack {
            List(uploads.jobs) { job in
                HStack(spacing: Theme.Spacing.m) {
                    Image(systemName: FileKind(extension: (job.name as NSString).pathExtension.lowercased()).symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.name).lineLimit(1).truncationMode(.middle)
                        detail(job)
                    }
                    Spacer(minLength: Theme.Spacing.s)
                    trailing(job)
                }
            }
            .overlay {
                if uploads.jobs.isEmpty {
                    ContentUnavailableView("No Uploads", systemImage: "arrow.up.circle")
                }
            }
            .navigationTitle("Uploads")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .secondaryAction) {
                    if uploads.isRunning {
                        Button("Cancel Uploads", systemImage: "xmark.circle", role: .destructive) { uploads.cancelAll() }
                    }
                    if uploads.failed > 0, !uploads.isRunning {
                        Button("Retry Failed", systemImage: "arrow.clockwise") { uploads.retryFailed() }
                    }
                    if !uploads.isRunning {
                        Button("Clear List", systemImage: "trash") { uploads.clearFinished() }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
    }

    @ViewBuilder private func detail(_ job: UploadQueue.Job) -> some View {
        switch job.state {
        case let .failed(message):
            Text(message).font(.caption).foregroundStyle(.orange)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        default:
            Text("\(job.folder)  ·  \(Format.bytes(job.size))")
                .font(.meta).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
    }

    @ViewBuilder private func trailing(_ job: UploadQueue.Job) -> some View {
        switch job.state {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.tertiary).accessibilityLabel("Waiting")
        case let .uploading(fraction):
            ProgressView(value: fraction).frame(width: 60).tint(Theme.accent)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).accessibilityLabel("Uploaded")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Failed")
        case .cancelled:
            EmptyView()
        }
    }
}
