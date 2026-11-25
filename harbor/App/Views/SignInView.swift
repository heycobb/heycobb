import OwnholdKit
import SwiftUI

/// Add a NAS, or sign back in to a saved one.
struct SignInView: View {
    let existing: ServerProfile?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var homeAddress = ""
    @State private var vpnAddress = ""
    @State private var quickConnectID = ""
    @State private var internetAddress = ""
    @State private var account = ""
    @State private var password = ""
    @State private var otpCode = ""
    @State private var needsCode = false
    @State private var rememberDevice = true
    @State private var working = false
    @State private var errorText: String?
    @State private var review: CertificateReview?
    @State private var showingGuide = false
    @FocusState private var focus: Field?

    private enum Field { case name, home, vpn, internet, account, password, code }

    var body: some View {
        NavigationStack {
            Form {
                if existing == nil {
                    Section {
                        Button {
                            showingGuide = true
                        } label: {
                            Label("New to this? Read the setup guide", systemImage: "questionmark.circle")
                        }
                    }
                    Section {
                        TextField("Name", text: $name, prompt: Text("Home NAS"))
                            .focused($focus, equals: .name)
                    }
                    Section {
                        addressField("Home network", text: $homeAddress, prompt: "192.168.1.20 or nas.local", field: .home)
                        addressField("Private network (VPN)", text: $vpnAddress, prompt: "Tailscale, ZeroTier or WireGuard address", field: .vpn)
                        addressField("Internet", text: $internetAddress, prompt: "Optional", field: .internet)
                    } header: {
                        Text("Addresses")
                    } footer: {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                            AddressHints(endpoints: endpoints)
                            Text("Ownhold tries them all at once and uses the highest one on this list that answers, so your home network wins when you're home. HTTPS only; port 5001 is assumed if you don't give one.")
                        }
                    }
                    QuickConnectSection(id: $quickConnectID) { showingGuide = true }
                } else if let existing {
                    Section {
                        LabeledContent("NAS", value: existing.name)
                        LabeledContent("Account", value: existing.account)
                    }
                }

                Section {
                    if existing == nil {
                        TextField("Account", text: $account)
                            .textContentType(.username)
                            .focused($focus, equals: .account)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .onSubmit(submit)
                    if needsCode {
                        TextField("6-digit code", text: $otpCode)
                            .textContentType(.oneTimeCode)
                            .font(.body.monospacedDigit())
                            .focused($focus, equals: .code)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            .onSubmit(submit)
                        Toggle("Remember this device", isOn: $rememberDevice)
                    }
                } footer: {
                    if needsCode {
                        Text("Your NAS uses 2-factor sign-in. If you remember this device, you won't be asked for a code here again.")
                    } else {
                        Text("Your password goes only to your NAS and isn't stored by Ownhold.")
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "Add NAS" : "Sign In")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Sign In", action: submit).disabled(!canSubmit)
                    }
                }
            }
            .sheet(isPresented: $showingGuide) { SetupGuideView() }
            .sheet(item: $review) { review in
                CertificateReviewView(review: review) { trusted in
                    self.review = nil
                    if trusted {
                        model.trust.trust(review.info, alsoFor: endpoints.map { CertificateTrustKey.make($0.url) })
                        submit()
                    }
                }
            }
            .onAppear { focus = existing == nil ? .name : .password }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .interactiveDismissDisabled(working)
    }

    private func addressField(_ label: String, text: Binding<String>, prompt: String, field: Field) -> some View {
        TextField(label, text: text, prompt: Text(prompt))
            .font(.path)
            .focused($focus, equals: field)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
    }

    private var endpoints: [Endpoint] {
        [
            Endpoint.parse(homeAddress, kind: .local),
            Endpoint.parse(vpnAddress, kind: .vpn),
            Endpoint.parse(internetAddress, kind: .remote),
        ].compactMap { $0 }
    }

    private var canSubmit: Bool {
        guard !password.isEmpty, !needsCode || otpCode.count >= 6 else { return false }
        guard existing == nil else { return true }
        let qc = quickConnectID.trimmingCharacters(in: .whitespaces)
        let hasAddress = !endpoints.isEmpty || QuickConnectLookup.isValidID(qc)
        return !account.isEmpty && hasAddress && (qc.isEmpty || QuickConnectLookup.isValidID(qc))
    }

    private func submit() {
        guard canSubmit, !working else { return }
        if existing == nil, [homeAddress, vpnAddress, internetAddress].contains(where: { $0.lowercased().hasPrefix("http://") }) {
            errorText = "Ownhold only connects over HTTPS. Turn on HTTPS in DSM (Control Panel > Login Portal) and use port 5001."
            return
        }
        let profile = existing ?? ServerProfile(
            name: name.isEmpty ? "NAS" : name,
            account: account,
            endpoints: endpoints,
            quickConnectID: quickConnectID.trimmingCharacters(in: .whitespaces).isEmpty ? nil : quickConnectID.trimmingCharacters(in: .whitespaces)
        )
        let credentials = Credentials(
            account: profile.account,
            password: password,
            otpCode: needsCode ? otpCode : nil
        )
        working = true
        errorText = nil
        Task {
            defer { working = false }
            do {
                try await model.signIn(to: profile, credentials: credentials, rememberDevice: rememberDevice)
                password = ""
                dismiss()
            } catch NASError.twoFactorRequired {
                needsCode = true
                focus = .code
            } catch let error as NASError {
                switch error {
                case let .untrustedCertificate(info):
                    review = CertificateReview(info: info, changed: false)
                case let .certificateChanged(info):
                    review = CertificateReview(info: info, changed: true)
                default:
                    errorText = error.errorDescription
                }
                if error == .twoFactorFailed { otpCode = "" }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

struct CertificateReviewView: View {
    let review: CertificateReview
    /// Called with `true` if the user trusts the certificate.
    let decide: (Bool) -> Void
    @State private var confirmChange = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(review.changed
                             ? "This NAS presented a different certificate than last time."
                             : "Your device doesn't recognize this NAS's certificate.")
                    } icon: {
                        Image(systemName: review.changed ? "exclamationmark.shield.fill" : "shield.lefthalf.filled")
                            .foregroundStyle(review.changed ? .red : Theme.accent)
                    }
                } footer: {
                    Text(review.changed
                         ? "If you didn't renew or replace the certificate in DSM, don't continue. Someone may be intercepting the connection."
                         : "This is normal for a NAS using DSM's built-in self-signed certificate. Ownhold will remember this certificate and refuse to connect if it ever changes unexpectedly.")
                }
                Section {
                    LabeledContent("Server", value: review.info.host)
                    LabeledContent("Issued to", value: review.info.subject)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("SHA-256 fingerprint").font(.caption).foregroundStyle(.secondary)
                        Text(review.info.certificateFingerprint.isEmpty ? review.info.fingerprint : review.info.certificateFingerprint)
                            .font(.path)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Certificate")
                } footer: {
                    Text("To double-check, open your NAS's address in Safari on a computer at home and view its certificate: the SHA-256 fingerprint there should match. The setup guide explains how.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Check Certificate")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Don't Trust") { decide(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(review.changed ? "Trust New…" : "Trust") {
                        if review.changed { confirmChange = true } else { decide(true) }
                    }
                }
            }
            .confirmationDialog("Trust the new certificate?", isPresented: $confirmChange, titleVisibility: .visible) {
                Button("Trust New Certificate", role: .destructive) { decide(true) }
            } message: {
                Text("Only do this if you replaced the certificate on your NAS yourself.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }

}
