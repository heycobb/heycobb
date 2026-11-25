import OwnholdKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance: AppearanceChoice = .system

    var body: some View {
        @Bindable var model = model
        ZStack {
            if model.activeServer == nil {
                WelcomeView()
            } else {
                BrowserView()
            }
        }
        .tint(Theme.accent)
        .appAppearance(appearance)
        .sheet(item: $model.signInRequest) { profile in
            SignInView(existing: profile)
        }
        .sheet(isPresented: $model.isAddingServer) {
            SignInView(existing: nil)
        }
        .sheet(item: model.signInRequest == nil ? $model.certificateReview : .constant(nil)) { review in
            CertificateReviewView(review: review) { trusted in
                if trusted {
                    Task { await model.trustCertificate(review) }
                } else {
                    model.certificateReview = nil
                }
            }
        }
        .overlay {
            if model.isLocked {
                LockView()
            } else if !Platform.isMac, model.hideInSwitcher, scenePhase != .active {
                PrivacyShield()
            }
        }
        .overlay(alignment: .bottom) {
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
            }
        }
        .animation(.snappy(duration: 0.25), value: model.banner)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.lockIfNeeded() }
            if phase == .active, model.isLocked { Task { await model.unlock() } }
        }
        .task {
            // Cold launch: the scene may already be active, so onChange won't fire.
            if model.isLocked, scenePhase == .active { await model.unlock() }
        }
    }
}

/// Covers content when the app is in the app switcher, so file names and
/// photos aren't visible in the snapshot.
struct PrivacyShield: View {
    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
            .ignoresSafeArea()
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Ownhold is locked")
                .font(.headline)
            Button("Unlock") { Task { await model.unlock() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        Text(text)
            .font(.subheadline)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            .glassEffect(.regular, in: .capsule)
            // Clears the floating search field / toolbar at the bottom on iOS.
            .padding(.bottom, Platform.isMac ? Theme.Spacing.xl : 72)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onTapGesture(perform: dismiss)
            .task {
                try? await Task.sleep(for: .seconds(3))
                dismiss()
            }
    }
}
