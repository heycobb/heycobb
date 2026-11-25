import HarborKit
import SwiftUI

/// Rename a saved NAS or change its addresses, for example to add a
/// Tailscale address after setting up Tailscale.
struct ServerEditView: View {
    let server: ServerProfile

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var homeAddress = ""
    @State private var tailscaleAddress = ""
    @State private var internetAddress = ""
    @State private var showingGuide = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Home NAS"))
                    LabeledContent("Account", value: server.account)
                }
                Section {
                    AddressField(label: "Home network", text: $homeAddress, prompt: "192.168.1.20 or nas.local")
                    AddressField(label: "Tailscale", text: $tailscaleAddress, prompt: "nas.tailnet-name.ts.net")
                    AddressField(label: "Internet", text: $internetAddress, prompt: "Optional")
                } header: {
                    Text("Addresses")
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        if hasPlainHTTP {
                            Text("Harbor only connects over HTTPS. Remove “http://” and use port 5001.")
                                .foregroundStyle(.red)
                        }
                        Button("How do I find my Tailscale address?") { showingGuide = true }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit NAS")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = server
                        updated.name = name.isEmpty ? server.name : name
                        updated.endpoints = endpoints
                        Task { await model.update(updated) }
                        dismiss()
                    }
                    .disabled(endpoints.isEmpty || hasPlainHTTP)
                }
            }
            .sheet(isPresented: $showingGuide) { SetupGuideView() }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    private var endpoints: [Endpoint] {
        [
            Endpoint.parse(homeAddress, kind: .local),
            Endpoint.parse(tailscaleAddress, kind: .tailscale),
            Endpoint.parse(internetAddress, kind: .remote),
        ].compactMap { $0 }
    }

    private var hasPlainHTTP: Bool {
        [homeAddress, tailscaleAddress, internetAddress].contains { $0.lowercased().hasPrefix("http://") }
    }

    private func load() {
        name = server.name
        func address(_ kind: Endpoint.Kind) -> String {
            guard let url = server.endpoints.first(where: { $0.kind == kind })?.url, let host = url.host() else { return "" }
            return url.port == 5001 || url.port == nil ? host : "\(host):\(url.port!)"
        }
        homeAddress = address(.local)
        tailscaleAddress = address(.tailscale)
        internetAddress = address(.remote)
    }
}

/// Address text field shared by Add NAS and Edit NAS.
struct AddressField: View {
    let label: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        TextField(label, text: $text, prompt: Text(prompt))
            .font(.path)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
    }
}
