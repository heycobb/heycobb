import ArkenalKit
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
            Text("Arkenal")
                .font(.system(.largeTitle, weight: .semibold))
            Text("The files and photos on your NAS, at home and away.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
}
