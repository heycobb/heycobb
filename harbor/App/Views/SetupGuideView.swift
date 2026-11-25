import SwiftUI

/// Step-by-step setup for people who haven't connected to a NAS from a
/// phone before, or haven't used Tailscale. Plain language, exact DSM menu
/// paths, and what to do when something doesn't work.
struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    Text("Setup takes about 10 minutes. For the first part, you'll need a computer on the same network as your NAS.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        StepView(number: index + 1, step: step)
                    }

                    Divider()

                    GuideSection(title: "Optional: check the certificate fingerprint", symbol: "checkmark.shield") {
                        Paragraph("Ownhold shows a fingerprint the first time it connects. To confirm it really is your NAS:")
                        Bullet("On a Mac at home, open Safari and go to **https://** followed by your NAS's address and **:5001**, for example https://192.168.1.20:5001.")
                        Bullet("Safari warns that the connection isn't private. Click **Show Details**, then **view the certificate**.")
                        Bullet("Open **Details** and find **SHA-256** under Fingerprints. It should match the fingerprint in Ownhold.")
                        Paragraph("If you set up your NAS yourself and you're at home, it's fine to skip this. Ownhold remembers the certificate and warns you if it ever changes.")
                    }

                    GuideSection(title: "If something doesn't work", symbol: "wrench.and.screwdriver") {
                        Problem("“Can't reach the NAS”", "At home, check that this device is on your home Wi-Fi and the address is right. Away from home, check that Tailscale is switched on in the Tailscale app.")
                        Problem("“Only connects over HTTPS”", "Turn on HTTPS in DSM (step 2), and use port 5001.")
                        Problem("“Incorrect account name or password”", "Use the same account and password you use to sign in to DSM in a browser.")
                        Problem("“Temporarily blocked”", "DSM blocks a device after several failed sign-ins. Wait for the block to expire, or remove it in DSM under **Control Panel › Security › Protection**.")
                        Problem("“You don't have permission”", "Your account needs File Station access (step 3).")
                    }
                }
                .padding(Theme.Spacing.l)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Setup Guide")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 600)
        #endif
    }

    // MARK: Content

    struct Step {
        let title: String
        let symbol: String
        let lines: [Line]
    }

    enum Line {
        case text(String)
        case bullet(String)
        case link(String, URL)
    }

    static let steps: [Step] = [
        Step(title: "Find your NAS's address", symbol: "magnifyingglass", lines: [
            .text("Your NAS has an address on your home network, usually something like 192.168.1.20."),
            .bullet("On a computer at home, open **find.synology.com** in a web browser. It lists the NAS and its address."),
            .bullet("Or, if you already open DSM in a browser, use the address you type there, without “http://” and without the port number."),
            .text("Tip: so the address never changes, set a fixed address in DSM under **Control Panel › Network › Network Interface**, or reserve it in your router's settings."),
        ]),
        Step(title: "Make sure HTTPS is on", symbol: "lock", lines: [
            .text("Ownhold only uses encrypted connections, so your password and files are never sent in the clear."),
            .bullet("In DSM, open **Control Panel › Login Portal**, then the **DSM** tab."),
            .bullet("Check that the HTTPS port is **5001** (the standard setting)."),
        ]),
        Step(title: "Check your account", symbol: "person.crop.circle", lines: [
            .bullet("Use the account and password you use to sign in to DSM."),
            .bullet("If the account isn't an administrator, allow File Station: **Control Panel › User & Group**, select the account, **Edit › Applications**, and allow **File Station**."),
            .bullet("If you use 2-factor sign-in, Ownhold asks for the code. Turn on **Remember this device** so you only enter it once."),
        ]),
        Step(title: "Add your NAS in Ownhold", symbol: "plus.circle", lines: [
            .bullet("Tap **Add a NAS**. Give it a name, enter the home address from step 1, your account and your password."),
            .bullet("The first time, Ownhold shows **Check Certificate**. That's normal: most home NAS boxes use their own certificate instead of one from a public authority. Tap **Trust**."),
            .text("At home, you're done. To reach your NAS from anywhere else, set up Tailscale (step 5)."),
        ]),
        Step(title: "Use it away from home with Tailscale", symbol: "point.3.connected.trianglepath.dotted", lines: [
            .text("Tailscale connects your devices to your NAS over a private, encrypted network, without opening anything on your router. It's free for personal use."),
            .bullet("**On the NAS:** in DSM, open **Package Center**, search for **Tailscale**, install it, open it, and sign in. You can create a Tailscale account there."),
            .bullet("**On this device:** install the Tailscale app, sign in with the same account, and switch it on."),
            .bullet("In the Tailscale app, find your NAS in the list of devices. Its name looks like **nas.tailnet-name.ts.net**. An address starting with **100.** also works."),
            .bullet("In Ownhold, open **Settings**, select your NAS, and enter that name as the **Tailscale** address. (Or enter it when you first add the NAS.)"),
            .text("Keep Tailscale switched on when you're away. Ownhold picks your home address at home and Tailscale everywhere else, automatically."),
            .link("Get Tailscale", URL(string: "https://tailscale.com/download")!),
        ]),
    ]
}

// MARK: - Building blocks

private struct StepView: View {
    let number: Int
    let step: SetupGuideView.Step

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text("\(number)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Theme.accent, in: .circle)
                    .accessibilityHidden(true)
                Text(step.title)
                    .font(.headline)
                    .accessibilityLabel("Step \(number): \(step.title)")
            }
            .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(Array(step.lines.enumerated()), id: \.offset) { _, line in
                    switch line {
                    case let .text(text): Paragraph(text)
                    case let .bullet(text): Bullet(text)
                    case let .link(title, url):
                        Link(destination: url) {
                            Label(title, systemImage: "arrow.up.forward.square")
                        }
                        .padding(.top, Theme.Spacing.xs)
                    }
                }
            }
            .padding(.leading, 24 + Theme.Spacing.s)
        }
    }
}

private struct GuideSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct Paragraph: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(LocalizedStringKey(text))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
            Text(LocalizedStringKey(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Problem: View {
    let title: String
    let fix: String
    init(_ title: String, _ fix: String) {
        self.title = title
        self.fix = fix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(LocalizedStringKey(fix))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
