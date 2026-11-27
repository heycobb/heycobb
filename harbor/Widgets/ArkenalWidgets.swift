import ActivityKit
import ArkenalKit
import SwiftUI
import WidgetKit

@main
struct ArkenalWidgets: WidgetBundle {
    var body: some Widget {
        SyncLiveActivity()
    }
}

/// Progress of a backup or large upload, on the Lock Screen and in the
/// Dynamic Island. Arkenal starts it only for jobs that run a while and
/// ends it when the job finishes.
struct SyncLiveActivity: Widget {
    private static let accent = Color(red: 0.663, green: 0.722, blue: 0.757) // Granite, as in dark mode

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncActivityAttributes.self) { context in
            LockScreenView(state: context.state, server: context.attributes.serverName)
                .padding()
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: Self.symbol(context.state.kind))
                        .foregroundStyle(Self.accent)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.detail)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressBar(fraction: context.state.fraction)
                }
            } compactLeading: {
                Image(systemName: Self.symbol(context.state.kind))
                    .foregroundStyle(Self.accent)
            } compactTrailing: {
                if let fraction = context.state.fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                } else {
                    ProgressView().controlSize(.mini)
                }
            } minimal: {
                Image(systemName: Self.symbol(context.state.kind))
                    .foregroundStyle(Self.accent)
            }
        }
    }

    static func symbol(_ kind: SyncProgress.Kind) -> String {
        switch kind {
        case .photoBackup: "photo.stack"
        case .folderBackup: "folder"
        case .uploads: "arrow.up.circle"
        }
    }

    private struct LockScreenView: View {
        let state: SyncProgress
        let server: String

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: SyncLiveActivity.symbol(state.kind))
                        .foregroundStyle(SyncLiveActivity.accent)
                    Text(state.title).font(.headline)
                    Spacer()
                    Text(state.detail)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressBar(fraction: state.fraction)
                Text("To \(server)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct ProgressBar: View {
        let fraction: Double?

        var body: some View {
            if let fraction {
                ProgressView(value: fraction).tint(SyncLiveActivity.accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(SyncLiveActivity.accent)
            }
        }
    }
}
