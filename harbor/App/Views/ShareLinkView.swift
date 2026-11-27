import OwnholdKit
import SwiftUI

/// Creates a link the NAS serves to anyone who has it (DSM's Sharing
/// Links), with an optional expiry and password, then offers to copy or
/// send it, or to stop sharing.
struct ShareLinkView: View {
    let item: RemoteItem
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var expiry: Expiry = .week
    @State private var usePassword = false
    @State private var password = ""
    @State private var link: SharingLink?
    @State private var working = false
    @State private var copied = false

    enum Expiry: String, CaseIterable, Identifiable {
        case day, week, month, never
        var id: Self { self }
        var title: String {
            switch self {
            case .day: "1 Day"
            case .week: "1 Week"
            case .month: "1 Month"
            case .never: "Never"
            }
        }

        /// The last day the link works.
        var date: Date? {
            let days = switch self {
            case .day: 1
            case .week: 7
            case .month: 30
            case .never: 0
            }
            return days == 0 ? nil : Calendar.current.date(byAdding: .day, value: days, to: .now)
        }
    }

    var body: some View {
        NavigationStack {
            OwnForm {
                Section {
                    HStack(spacing: Theme.Spacing.m) {
                        ThumbnailView(item: item, size: .small, side: 40)
                        Text(item.name).lineLimit(2).truncationMode(.middle)
                    }
                }
                if let link {
                    created(link)
                } else {
                    options
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share Link")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: link == nil ? .cancellationAction : .confirmationAction) {
                    Button(link == nil ? "Cancel" : "Done") { dismiss() }
                }
                if link == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { Task { await create() } }
                            .disabled(working || (usePassword && password.isEmpty))
                    }
                }
            }
            .disabled(working)
        }
        .tint(Theme.accent)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        #if os(macOS)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    @ViewBuilder private var options: some View {
        Section {
            Picker("Expires", selection: $expiry) {
                ForEach(Expiry.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Require Password", isOn: $usePassword)
            if usePassword {
                SecureField("Password", text: $password)
                    .textContentType(.newPassword)
            }
        } footer: {
            Text("Anyone with the link can open this\(item.isDirectory ? " folder" : " file") from your NAS.")
        }
    }

    @ViewBuilder private func created(_ link: SharingLink) -> some View {
        Section {
            Text(link.url.absoluteString)
                .font(.path)
                .textSelection(.enabled)
            Button(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc") {
                Pasteboard.copy(link.url.absoluteString)
                copied = true
            }
            ShareLink(item: link.url) {
                Label("Send Link…", systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text(expiryNote(link))
        }
        Section {
            Button("Stop Sharing", role: .destructive) {
                Task {
                    working = true
                    defer { working = false }
                    if await model.deleteShareLink(link) { dismiss() }
                }
            }
        }
    }

    private func expiryNote(_ link: SharingLink) -> String {
        let until = link.expires.map { "until \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "until you stop sharing"
        return "Works \(until)\(link.hasPassword ? ", with the password" : ""). You can also manage links in DSM's File Station."
    }

    private func create() async {
        working = true
        defer { working = false }
        link = await model.createShareLink(for: item, password: usePassword ? password : nil, expires: expiry.date)
        password = ""
    }
}

enum Pasteboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
