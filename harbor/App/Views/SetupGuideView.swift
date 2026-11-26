import SwiftUI

/// Setup for people who haven't connected to a NAS from a phone before.
/// Three short steps up front; everything else (troubleshooting, other ways
/// to connect, certificate checks) is folded away under "Need help?".
struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Connect Your NAS")
                            .font(.largeTitle.weight(.semibold))
                        Text("Three steps, about 10 minutes.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        StepView(number: 1, title: "Find its address") {
                            Text("On a computer at home, open **find.synology.com**. It shows your NAS and an address like **192.168.1.20**.")
                            Link("Open find.synology.com", destination: URL(string: "https://find.synology.com")!)
                        }
                        StepView(number: 2, title: "Add it to Ownhold") {
                            Text("Choose **Add a NAS** and enter that address with the account you use for DSM.")
                            Text("When Ownhold asks about the certificate, choose **Trust**. That's normal for a home NAS.")
                        }
                        StepView(number: 3, title: "Reach it from anywhere", optional: true) {
                            Text("Install **Tailscale** on your NAS (from Package Center) and on this device. Then add the NAS's Tailscale name in Settings as its **Private network (VPN)** address.")
                            Link("Get Tailscale", destination: URL(string: "https://tailscale.com/download")!)
                        }
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text("Need help?")
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Self.help) { topic in
                            HelpTopic(topic: topic)
                            if topic.id != Self.help.last?.id { Divider() }
                        }
                    }
                }
                .padding(Theme.Spacing.l)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .tint(Theme.accent)
            .navigationTitle("Setup Guide")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
    }

    // MARK: Help

    struct Topic: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }

    static let help: [Topic] = [
        Topic(title: "Can't reach the NAS", text: "At home, check that you're on your home Wi-Fi and the address is right. Away from home, check that Tailscale is switched on."),
        Topic(title: "Wrong account name or password", text: "Use the same account and password you use to sign in to DSM in a browser. If DSM blocked this device after failed attempts, remove the block in **Control Panel › Security › Protection**."),
        Topic(title: "No permission to see files", text: "In DSM, open **Control Panel › User & Group**, edit the account, and allow **File Station** under **Applications**."),
        Topic(title: "Only connects over HTTPS", text: "Ownhold only uses encrypted connections. In DSM, check **Control Panel › Login Portal**: the HTTPS port should be **5001**."),
        Topic(title: "Using a different VPN", text: "WireGuard, ZeroTier, NetBird and similar all work while their app is on. Enter the NAS's address on that network as the **Private network (VPN)** address."),
        Topic(title: "QuickConnect or DDNS", text: "Enter your QuickConnect ID or yourname.synology.me address when you add the NAS. Ownhold connects directly, without Synology's relay, so this works away from home only if your NAS is reachable from the internet."),
        Topic(title: "Checking the certificate", text: "To confirm the fingerprint Ownhold shows, open **https://** your NAS's address **:5001** in Safari at home, view the certificate, and compare its SHA-256 fingerprint. Ownhold warns you if the certificate ever changes."),
    ]
}

// MARK: - Building blocks

private struct StepView<Content: View>: View {
    let number: Int
    let title: String
    var optional = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Text("\(number)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 36, height: 36)
                .background(Theme.accent, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    if optional {
                        Text("Optional")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 5)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(number): \(title)\(optional ? ", optional" : "")")
                .accessibilityAddTraits(.isHeader)
                content
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HelpTopic: View {
    let topic: SetupGuideView.Topic
    @State private var isOpen = false

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            Text(LocalizedStringKey(topic.text))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Spacing.xs)
        } label: {
            Text(topic.title)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture { withAnimation { isOpen.toggle() } }
        }
        // iOS tints a disclosure label like a button; keep it plain text.
        .tint(.primary)
        .padding(.vertical, Theme.Spacing.xs)
    }
}
