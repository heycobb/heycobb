import HarborKit
import SwiftUI

/// First screen. On iPhone the actions sit at the bottom, within thumb
/// reach; on iPad and Mac everything is one centered block, so the buttons
/// aren't stranded at the bottom of a tall window.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingGuide = false

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            if isCompact { Spacer(minLength: Theme.Spacing.xl) }
            intro
            points
            if isCompact { Spacer(minLength: Theme.Spacing.xl) }
            actions
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.bottom, isCompact ? Theme.Spacing.l : 0)
        .frame(maxWidth: isCompact ? .infinity : 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Harbor")
                .font(.system(.largeTitle, weight: .semibold))
            Text("Your NAS on your iPhone, iPad and Mac. At home or away.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var points: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Point(symbol: "lock", text: "Connects straight to your NAS. No accounts, no tracking.")
            Point(symbol: "point.3.connected.trianglepath.dotted", text: "Your home network when you're home, Tailscale when you're away.")
            Point(symbol: "arrow.down.circle", text: "Keep files on this device for when you're offline.")
        }
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            ForEach(model.servers) { server in
                Button {
                    Task { await model.activate(server) }
                } label: {
                    Label(server.name, systemImage: "externaldrive")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Button {
                model.isAddingServer = true
            } label: {
                Text("Add a NAS").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                Task { await model.startDemo() }
            } label: {
                Text("Try the Demo Library").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button("New to NAS or Tailscale? Read the setup guide") { showingGuide = true }
                .font(.footnote)
                .buttonStyle(.borderless)
                .padding(.top, Theme.Spacing.s)
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showingGuide) { SetupGuideView() }
    }

    private struct Point: View {
        let symbol: String
        let text: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
