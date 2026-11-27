import ArkenalKit
import StoreKit
import SwiftUI

/// What Arkenal Pro adds, and the one-time purchase. Shown from Settings,
/// and when a Pro feature is tapped; never on its own.
struct ProView: View {
    @Environment(\.dismiss) private var dismiss
    private var store: ProStore { ProStore.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Arkenal Pro")
                            .font(.largeTitle.weight(.semibold))
                        Text("One purchase for iPhone, iPad and Mac, shared with your family.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        feature(Platform.isMac ? "Folder Backup" : "Automatic Photo Backup", "clock.arrow.circlepath")
                        feature("Photos, by month", "photo.on.rectangle.angled")
                        if Platform.isMac { feature("Keep Downloaded in Finder", "arrow.down.circle") }
                        feature("Shortcuts and Siri", "square.stack.3d.up")
                        if !Platform.isMac {
                            feature("Scan to NAS", "doc.viewfinder")
                            feature("Large uploads that finish in the background", "arrow.up.circle")
                        }
                        feature("More than one NAS", "externaldrive.badge.plus")
                        feature("Encrypted folders", "lock.rectangle.stack")
                        feature("Wake NAS and Recently Deleted", "power")
                    }
                    if store.isUnlocked {
                        Label("You have Arkenal Pro.", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.accent)
                    } else {
                        VStack(spacing: Theme.Spacing.s) {
                            Button {
                                Task { await store.purchase() }
                            } label: {
                                Text(store.product.map { "Unlock for \($0.displayPrice)" } ?? "Unlock Arkenal Pro")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(store.product == nil || store.isPurchasing)
                            Button("Restore Purchases") { Task { await store.restore() } }
                                .buttonStyle(.borderless)
                        }
                    }
                    if let message = store.message {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
                .padding(Theme.Spacing.l)
                .frame(maxWidth: 480, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .tint(Theme.accent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
        .onDisappear { store.message = nil }
    }

    private func feature(_ title: String, _ symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        }
        .font(.body)
    }
}

/// Stands in for a Pro screen until Pro is unlocked.
struct ProLockedView: View {
    let title: String
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "lock")
        } description: {
            Text("Part of Arkenal Pro.")
        } actions: {
            Button("Learn More") { model.showingPro = true }
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle(title)
    }
}
