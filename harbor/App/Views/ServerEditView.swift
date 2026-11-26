import OwnholdKit
import SwiftUI

/// Rename a saved NAS or change its addresses, for example to add a
/// private-network (VPN) address after setting up Tailscale or similar.
struct ServerEditView: View {
    let server: ServerProfile

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var homeAddress = ""
    @State private var vpnAddress = ""
    @State private var quickConnectID = ""
    @State private var internetAddress = ""
    @State private var macAddress = ""
    @State private var showingGuide = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Home NAS"))
                    LabeledContent("Account", value: server.account)
                }
                Section {
                    if server.kind != .synology {
                        LabeledContent("Connects With", value: server.kind.label)
                    }
                    AddressField(label: "Home network", text: $homeAddress, prompt: "192.168.1.20 or nas.local")
                    AddressField(label: "Private network (VPN)", text: $vpnAddress, prompt: "Tailscale, ZeroTier or WireGuard address")
                    AddressField(label: "Internet", text: $internetAddress, prompt: "Optional")
                } header: {
                    Text("Addresses")
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        if server.kind == .synology { AddressHints(endpoints: endpoints) }
                        if hasPlainHTTP {
                            Text(server.kind == .synology ? "Ownhold only connects over HTTPS. Remove “http://” and use port 5001." : "Ownhold only connects over HTTPS. Remove “http://”.")
                                .foregroundStyle(.red)
                        }
                        Button("How do I find my VPN address?") { showingGuide = true }
                            .buttonStyle(.borderless)
                    }
                }
                if server.kind.hasQuickConnect {
                    QuickConnectSection(id: $quickConnectID) { showingGuide = true }
                }
                Section {
                    TextField("MAC Address", text: $macAddress, prompt: Text("00:11:32:AA:BB:CC"))
                        .font(.path)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                } header: {
                    Text("Wake NAS")
                } footer: {
                    if !macAddressIsValid {
                        Text("Use the format 00:11:32:AA:BB:CC.").foregroundStyle(.red)
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
                        updated.quickConnectID = trimmedQuickConnectID.isEmpty ? nil : trimmedQuickConnectID
                        updated.macAddress = WakeOnLAN.parseMAC(macAddress).map(WakeOnLAN.format)
                        Task { await model.update(updated) }
                        dismiss()
                    }
                    .disabled(!canSave)
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
            Endpoint.parse(homeAddress, kind: .local, server: server.kind),
            Endpoint.parse(vpnAddress, kind: .vpn, server: server.kind),
            Endpoint.parse(internetAddress, kind: .remote, server: server.kind),
        ].compactMap { $0 }
    }

    private var trimmedQuickConnectID: String { quickConnectID.trimmingCharacters(in: .whitespaces) }

    private var canSave: Bool {
        let qcValid = trimmedQuickConnectID.isEmpty || QuickConnectLookup.isValidID(trimmedQuickConnectID)
        let hasAddress = !endpoints.isEmpty || !trimmedQuickConnectID.isEmpty
        return hasAddress && qcValid && !hasPlainHTTP && macAddressIsValid
    }

    private var macAddressIsValid: Bool {
        macAddress.trimmingCharacters(in: .whitespaces).isEmpty || WakeOnLAN.parseMAC(macAddress) != nil
    }

    private var hasPlainHTTP: Bool {
        [homeAddress, vpnAddress, internetAddress].contains { $0.lowercased().hasPrefix("http://") }
    }

    private func load() {
        name = server.name
        func address(_ kind: Endpoint.Kind) -> String {
            server.endpoints.first(where: { $0.kind == kind })?.editableText(server: server.kind) ?? ""
        }
        homeAddress = address(.local)
        vpnAddress = address(.vpn)
        quickConnectID = server.quickConnectID ?? ""
        internetAddress = address(.remote)
        macAddress = server.macAddress ?? ""
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

/// Live advice under the address fields: Synology DDNS set-up and port typos.
struct AddressHints: View {
    let endpoints: [Endpoint]

    var body: some View {
        if endpoints.contains(where: \.usesDSMHTTPPort) {
            Label("Port 5000 is DSM's plain-HTTP port. Ownhold uses HTTPS, which is usually port 5001.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        if endpoints.contains(where: \.isSynologyDDNS) {
            Label {
                Text("That's a Synology DDNS address. To reach it away from home, forward port 5001 on your router to the NAS and use a Let's Encrypt certificate (DSM: Control Panel › Security › Certificate). This makes DSM reachable from the internet, so turn on 2-factor sign-in and auto-block.")
            } icon: {
                Image(systemName: "globe")
            }
        }
    }
}

/// Optional QuickConnect ID, with a plain explanation of what it sends where.
struct QuickConnectSection: View {
    @Binding var id: String
    let showGuide: () -> Void

    private var trimmed: String { id.trimmingCharacters(in: .whitespaces) }
    private var isValid: Bool { trimmed.isEmpty || QuickConnectLookup.isValidID(trimmed) }

    var body: some View {
        Section {
            TextField("QuickConnect ID", text: $id, prompt: Text("Optional"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        } header: {
            Text("QuickConnect")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if !isValid {
                    Text("QuickConnect IDs use only letters, numbers and hyphens.")
                        .foregroundStyle(.red)
                }
                Text("Ownhold asks Synology's QuickConnect service for your NAS's current addresses, then connects to it directly. Only the ID is sent to Synology. Your files and password never go through Synology's servers.")
                Button("Where do I find it?", action: showGuide)
                    .buttonStyle(.borderless)
            }
        }
    }
}
