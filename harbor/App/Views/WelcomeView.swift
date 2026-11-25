import HarborKit
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var addingServer = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Spacer()
            Text("Harbor")
                .font(.system(.largeTitle, design: .default, weight: .semibold))
            Text("Your NAS, on your terms. Browse, preview and keep files offline over your home network or Tailscale. No accounts, no tracking.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Point(symbol: "lock", text: "Signs in directly to your NAS. Nothing passes through our servers. We don't have any.")
                Point(symbol: "point.3.connected.trianglepath.dotted", text: "Uses your home address when you're home, Tailscale when you're not.")
                Point(symbol: "arrow.down.circle", text: "Keep files and folders on this device for when you're offline.")
            }
            .padding(.vertical, Theme.Spacing.m)

            Spacer()

            if !model.servers.isEmpty {
                ForEach(model.servers) { server in
                    Button {
                        Task { await model.activate(server) }
                    } label: {
                        Label(server.name, systemImage: "externaldrive")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }

            Button {
                addingServer = true
            } label: {
                Text("Add a NAS").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Try the demo library") {
                Task { await model.startDemo() }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, Theme.Spacing.l)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $addingServer) {
            SignInView(existing: nil)
        }
    }

    private struct Point: View {
        let symbol: String
        let text: String

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                Text(text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
