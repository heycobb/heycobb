import OwnholdKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// First run: one question per screen. Find the NAS (found on the network,
/// or typed in), sign in, optionally add a Tailscale address, then choose a
/// few options. Everything here can be changed later in Settings.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step: Step = .welcome
    @State private var discovery = NASDiscovery()
    @State private var showingGuide = false

    // Find
    @State private var name = ""
    @State private var address = ""
    @State private var quickConnectID = ""
    @State private var usesQuickConnect = false

    // Sign in
    @State private var account = ""
    @State private var password = ""
    @State private var otpCode = ""
    @State private var needsCode = false
    @State private var rememberDevice = true
    @State private var working = false
    @State private var errorText: String?
    @State private var review: CertificateReview?
    @FocusState private var focus: Field?

    // Away from home
    @State private var vpnAddress = ""

    // Options
    @State private var setUpBackup = false

    private enum Step: Int, CaseIterable { case welcome, find, signIn, away, options }
    private enum Field { case address, quickConnect, account, password, code, vpn }

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome { header }
            ScrollView {
                content
                    .frame(maxWidth: 480, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.top, step == .welcome ? 0 : Theme.Spacing.l)
                    .frame(maxWidth: .infinity, minHeight: step == .welcome ? 420 : nil)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
                .frame(maxWidth: 480)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.l)
        }
        .tint(Theme.accent)
        .animation(.snappy(duration: 0.3), value: step)
        .sheet(isPresented: $showingGuide) { SetupGuideView() }
        .sheet(item: $review) { review in
            CertificateReviewView(review: review) { trusted in
                self.review = nil
                if trusted {
                    model.trust.trust(review.info, alsoFor: endpoints.map { CertificateTrustKey.make($0.url) })
                    signIn()
                }
            }
        }
        .onChange(of: step) { _, step in
            if step == .find { discovery.start() } else { discovery.stop() }
            switch step {
            case .find: focus = nil
            case .signIn: focus = account.isEmpty ? .account : .password
            default: focus = nil
            }
        }
        .onDisappear { discovery.stop() }
    }

    // MARK: Frame

    private var header: some View {
        HStack {
            if step != .options {
                Button {
                    if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(working || step == .away)
                .opacity(step == .away ? 0 : 1)
            }
            Spacer()
            // Where you are: four dots for the four steps after the welcome.
            HStack(spacing: 6) {
                ForEach(1..<Step.allCases.count, id: \.self) { index in
                    Capsule()
                        .fill(index <= step.rawValue ? Theme.accent : Color.secondary.opacity(0.3))
                        .frame(width: index == step.rawValue ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step.rawValue) of \(Step.allCases.count - 1)")
            Spacer()
            Color.clear.frame(width: 24, height: 24)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.m)
        .frame(maxWidth: 560)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .find: find
        case .signIn: signInStep
        case .away: away
        case .options: options
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: Theme.Spacing.s) {
            switch step {
            case .welcome:
                primary("Get Started") { step = .find }
                secondary("Try the Demo") { Task { await model.startDemo() } }
            case .find:
                primary("Continue", enabled: canContinueFromFind) {
                    if name.isEmpty { name = usesQuickConnect ? quickConnectID : address }
                    step = .signIn
                }
                link("Where do I find this?") { showingGuide = true }
            case .signIn:
                primary(working ? "Signing In…" : "Sign In", enabled: canSignIn && !working, action: signIn)
                Text("Your password goes only to your NAS.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .away:
                primary("Continue", enabled: vpnAddress.isEmpty || vpnEndpoint != nil) {
                    Task {
                        await saveVPNAddress()
                        step = .options
                    }
                }
                secondary("Skip") { step = .options }
            case .options:
                primary("Start Browsing", action: finish)
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: Theme.Spacing.l) {
            Spacer(minLength: Theme.Spacing.xl)
            MonogramIcon(choice: ThemeSettings.shared.appIcon)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Spacing.s) {
                Text("Ownhold")
                    .font(.system(.largeTitle, weight: .semibold))
                Text("Your Synology files and photos, at home and away. Nothing in between: no account, no cloud.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    private var find: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            title("Find your NAS", detail: "Make sure this \(Self.deviceName) is on the same Wi-Fi as your NAS.")

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(discovery.found) { nas in
                    let selected = !usesQuickConnect && address == nas.host
                    Button {
                        usesQuickConnect = false
                        address = nas.host
                        name = nas.name
                    } label: {
                        HStack(spacing: Theme.Spacing.m) {
                            Image(systemName: "externaldrive.fill")
                                .font(.title2)
                                .foregroundStyle(Theme.accent)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(nas.name).font(.headline)
                                Text(nas.host).font(.path).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected ? Theme.accent : .secondary)
                        }
                        .padding(Theme.Spacing.m)
                        .background(.quaternary.opacity(selected ? 1 : 0.5), in: .rect(cornerRadius: 12))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                if discovery.found.isEmpty {
                    HStack(spacing: Theme.Spacing.s) {
                        if discovery.isSearching {
                            ProgressView().controlSize(.small)
                            Text("Looking on this network…")
                        } else {
                            Image(systemName: "magnifyingglass")
                            Text("No NAS found here. Enter its address below.")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Theme.Spacing.s)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if usesQuickConnect {
                    field("QuickConnect ID", text: $quickConnectID, prompt: "your-quickconnect-id", focus: .quickConnect)
                    link("Enter an address instead") { usesQuickConnect = false }
                } else {
                    field("Or enter its address", text: $address, prompt: "192.168.1.20 or nas.local", focus: .address, monospaced: true)
                        .onChange(of: address) { _, new in
                            // Typing over a found NAS: its name no longer applies.
                            if !discovery.found.contains(where: { $0.host == new }) { name = "" }
                        }
                    if address.lowercased().hasPrefix("http://") {
                        Text("Ownhold only connects over HTTPS. Remove “http://”.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    link("Use a QuickConnect ID instead") { usesQuickConnect = true }
                }
            }
        }
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            title("Sign in to \(displayName)", detail: "Use the account you use for DSM.")
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                field("Account", text: $account, prompt: "Account name", focus: .account, contentType: .username)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Password").font(.subheadline.weight(.medium))
                    SecureField("Password", text: $password, prompt: Text("Password"))
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .onSubmit(signIn)
                        .inputStyle()
                }
                if needsCode {
                    field("6-digit code", text: $otpCode, prompt: "123456", focus: .code, contentType: .oneTimeCode)
                        .onSubmit(signIn)
                    Toggle("Remember this device", isOn: $rememberDevice)
                }
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var away: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            title("Use it away from home", detail: "Optional. With Tailscale on your NAS and this \(Self.deviceName), Ownhold reaches your NAS from anywhere, without opening your router.")
            field("Tailscale or VPN address", text: $vpnAddress, prompt: "nas.tailnet.ts.net or 100.x.y.z", focus: .vpn, monospaced: true)
            Link(destination: URL(string: "https://tailscale.com/download")!) {
                Label("Get Tailscale", systemImage: "arrow.up.forward.square")
            }
            Text("You can add this later in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var options: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            title("You're connected", detail: "A few options to start with. All of them are in Settings.")
            VStack(spacing: 0) {
                optionRow(Platform.isMac ? "Show NAS in Finder" : "Show NAS in Files App",
                          symbol: Platform.isMac ? "finder" : "folder",
                          isOn: $model.showInFilesApp)
                    .disabled(model.requireUnlock)
                Divider().padding(.leading, 52)
                optionRow(Platform.isMac ? "Lock with Touch ID" : "Lock with Face ID",
                          symbol: "lock",
                          isOn: $model.requireUnlock)
                Divider().padding(.leading, 52)
                optionRow(Platform.isMac ? "Back Up Mac Folders" : "Back Up Photos",
                          symbol: Platform.isMac ? "clock.arrow.circlepath" : "photo.on.rectangle",
                          isOn: $setUpBackup)
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
            if model.requireUnlock {
                Text(Platform.isMac ? "Finder can't ask for Touch ID, so it stays off while the lock is on." : "The Files app can't ask for Face ID, so it stays off while the lock is on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Pieces

    private func title(_ text: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(text)
                .font(.system(.largeTitle, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, focus field: Field, monospaced: Bool = false, contentType: TextContentTypeChoice? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(label).font(.subheadline.weight(.medium))
            TextField(label, text: text, prompt: Text(prompt))
                .font(monospaced ? .body.monospaced() : .body)
                .focused($focus, equals: field)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(monospaced ? .URL : (contentType == .oneTimeCode ? .numberPad : .default))
                #endif
                .modifier(ContentTypeModifier(choice: contentType))
                .inputStyle()
        }
    }

    private func optionRow(_ title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.m)
    }

    private func primary(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .font(.callout)
    }

    // MARK: Logic

    private static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    private var displayName: String { name.isEmpty ? "your NAS" : name }

    private var trimmedQuickConnectID: String { quickConnectID.trimmingCharacters(in: .whitespaces) }

    private var endpoints: [Endpoint] {
        usesQuickConnect ? [] : [Endpoint.parse(address, kind: .local)].compactMap { $0 }
    }

    private var vpnEndpoint: Endpoint? { Endpoint.parse(vpnAddress, kind: .vpn) }

    private var canContinueFromFind: Bool {
        if usesQuickConnect { return QuickConnectLookup.isValidID(trimmedQuickConnectID) }
        return !endpoints.isEmpty && !address.lowercased().hasPrefix("http://")
    }

    private var canSignIn: Bool {
        !account.isEmpty && !password.isEmpty && (!needsCode || otpCode.count >= 6)
    }

    private func signIn() {
        guard canSignIn, !working else { return }
        let profile = ServerProfile(
            name: name.isEmpty ? "NAS" : name,
            account: account,
            endpoints: endpoints,
            quickConnectID: usesQuickConnect ? trimmedQuickConnectID : nil
        )
        let credentials = Credentials(account: account, password: password, otpCode: needsCode ? otpCode : nil)
        working = true
        errorText = nil
        // Keeps these screens up after signing in, for the last two steps.
        model.isOnboarding = true
        Task {
            defer { working = false }
            do {
                try await model.signIn(to: profile, credentials: credentials, rememberDevice: rememberDevice)
                password = ""
                step = .away
            } catch NASError.twoFactorRequired {
                model.isOnboarding = false
                needsCode = true
                focus = .code
            } catch let error as NASError {
                model.isOnboarding = false
                switch error {
                case let .untrustedCertificate(info): review = CertificateReview(info: info, changed: false)
                case let .certificateChanged(info): review = CertificateReview(info: info, changed: true)
                default: errorText = error.errorDescription
                }
                if error == .twoFactorFailed { otpCode = "" }
            } catch {
                model.isOnboarding = false
                errorText = error.localizedDescription
            }
        }
    }

    private func saveVPNAddress() async {
        guard let vpn = vpnEndpoint, var profile = model.activeServer else { return }
        profile.endpoints.removeAll { $0.kind == .vpn }
        profile.endpoints.append(vpn)
        await model.update(profile)
    }

    private func finish() {
        if setUpBackup { model.navigationRequest = .backup }
        model.isOnboarding = false
    }
}

// MARK: - Text fields

/// Large, rounded fields: the onboarding screens aren't a Settings form.
private extension View {
    func inputStyle() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
    }
}

private enum TextContentTypeChoice { case username, oneTimeCode }

private struct ContentTypeModifier: ViewModifier {
    let choice: TextContentTypeChoice?

    func body(content: Content) -> some View {
        switch choice {
        case .username: content.textContentType(.username)
        case .oneTimeCode: content.textContentType(.oneTimeCode)
        case nil: content
        }
    }
}
