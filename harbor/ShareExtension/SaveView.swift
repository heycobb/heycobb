import LocalAuthentication
import OwnholdKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Save to Ownhold: choose a NAS and folder, then upload what was shared.
/// Uploads go straight to the NAS over the app's pinned connection; nothing
/// is sent anywhere else, and the copies made for uploading are deleted.
struct SaveView: View {
    let providers: [NSItemProvider]
    let finish: (_ cancelled: Bool) -> Void

    @State private var servers: [ServerProfile] = []
    @State private var server: ServerProfile?
    @State private var service: (any FileService)?
    /// The folder being browsed, as a trail from the shared folder down.
    @State private var path: [RemoteItem] = []
    @State private var phase: Phase = .starting
    @State private var progress: Double = 0
    @State private var current = ""
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var reload = 0
    @State private var makingFolder = false

    private enum Phase: Equatable {
        case starting, locked, choosing, uploading, done, failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Save to Ownhold")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { finish(true) }
                            .disabled(phase == .uploading)
                    }
                }
        }
        .tint(SharedAccent.color)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 500)
        .safeAreaInset(edge: .bottom) {
            // While loading, locked or after an error there's no action bar:
            // keep a way out (the choosing screen has Cancel in its own bar).
            if phase != .choosing, phase != .done {
                HStack {
                    Spacer()
                    Button(phase == .uploading ? "Stop" : "Cancel") { finish(true) }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                }
                .padding(16)
            }
        }
        #endif
        .task { await start() }
        .alert("New Folder", isPresented: $creatingFolder) {
            // Return triggers Create (the alert's default button) once.
            TextField("Name", text: $newFolderName)
            Button("Create") { Task { await makeFolder() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .starting:
            ProgressView()
        case .locked:
            ContentUnavailableView {
                Label("Ownhold Is Locked", systemImage: "lock")
            } actions: {
                Button("Unlock") { Task { await unlock() } }
                    .buttonStyle(.borderedProminent)
            }
        case .choosing:
            chooser
        case .uploading:
            VStack(spacing: 12) {
                ProgressView(value: progress).frame(maxWidth: 240)
                Text(current).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding()
        case .done:
            Label("Saved to \(path.last?.name ?? "your NAS")", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(SharedAccent.color)
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't Save", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Close") { finish(true) }
            }
        }
    }

    // MARK: Choosing

    private var chooser: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pathBar
            Divider()
            if let service {
                FolderList(service: service, folder: path.last, reload: reload) { path.append($0) }
                    .id("\(server?.id.uuidString ?? "")\(path.last?.path ?? "/")\(reload)")
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
            Divider()
            actions
        }
    }

    /// What's being saved, and to which NAS.
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: itemSymbol)
                .font(.title2)
                .foregroundStyle(SharedAccent.color)
                .frame(width: 44, height: 44)
                .background(SharedAccent.color.opacity(0.12), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(itemCount).font(.headline)
                if let name = providers.first?.suggestedName {
                    Text(providers.count == 1 ? name : "\(name) and \(providers.count - 1) more")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if servers.count > 1 {
                Menu {
                    ForEach(servers) { profile in
                        Button(profile.name) { Task { await select(profile) } }
                    }
                } label: {
                    Label(server?.name ?? "NAS", systemImage: "externaldrive")
                        .font(.callout)
                }
                .fixedSize()
            } else if let server {
                Label(server.name, systemImage: "externaldrive")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Back button plus the path, each part tappable (works on the Mac too,
    /// where share sheets have no navigation bar back button).
    private var pathBar: some View {
        HStack(spacing: 6) {
            Button {
                path.removeLast()
            } label: {
                Image(systemName: "chevron.backward")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(path.isEmpty)
            .accessibilityLabel("Back")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        crumb("Shared Folders", depth: 0)
                        ForEach(Array(path.enumerated()), id: \.element.path) { index, folder in
                            Image(systemName: "chevron.forward")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            crumb(folder.name, depth: index + 1)
                        }
                    }
                    .id("end")
                }
                .onChange(of: path) { proxy.scrollTo("end", anchor: .trailing) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func crumb(_ title: String, depth: Int) -> some View {
        let isCurrent = depth == path.count
        return Button(title) { path = Array(path.prefix(depth)) }
            .buttonStyle(.borderless)
            .font(.callout.weight(isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? Color.primary : SharedAccent.color)
            .disabled(isCurrent)
            .lineLimit(1)
    }

    /// New Folder and the save button, always at the bottom.
    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                newFolderName = ""
                creatingFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(path.isEmpty || service == nil)
            Spacer(minLength: 0)
            #if os(macOS)
            // Mac share sheets have no toolbar, so Cancel lives here (and Esc).
            Button("Cancel") { finish(true) }
                .keyboardShortcut(.cancelAction)
            #endif
            Button {
                Task { await save() }
            } label: {
                Text(path.isEmpty ? "Choose a Folder" : "Save Here")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(path.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var itemCount: String {
        let types = providers.map(\.registeredContentTypes)
        let photos = types.allSatisfy { $0.contains { $0.conforms(to: .image) } }
        let videos = types.allSatisfy { $0.contains { $0.conforms(to: .movie) } }
        let noun = photos ? "photo" : videos ? "video" : "item"
        return providers.count == 1 ? "1 \(noun)" : "\(providers.count) \(noun)s"
    }

    private var itemSymbol: String {
        let types = providers.flatMap(\.registeredContentTypes)
        if types.contains(where: { $0.conforms(to: .image) }) { return providers.count > 1 ? "photo.stack" : "photo" }
        if types.contains(where: { $0.conforms(to: .movie) }) { return "film" }
        return providers.count > 1 ? "doc.on.doc" : "doc"
    }

    private func makeFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !makingFolder, let service, let parent = path.last, RemoteItem.isValidName(name) else { return }
        makingFolder = true
        defer { makingFolder = false }
        do {
            let folder = try await service.createFolder(named: name, in: parent.path)
            if let server { SharedChanges.announce(domain: server.id.uuidString, name: server.name, folders: [parent.path]) }
            path.append(folder)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    // MARK: Flow

    private func start() async {
        servers = SharedConnection.servers()
        if servers.isEmpty { servers = [.demo] }
        if SharedConnection.requiresUnlock {
            phase = .locked
            await unlock()
        } else {
            await begin()
        }
    }

    private func unlock() async {
        let context = LAContext()
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Save to Ownhold")) == true {
            await begin()
        }
    }

    private func begin() async {
        phase = .choosing
        await select(servers.first { SharedConnection.hasSession(for: $0) } ?? servers[0])
    }

    private func select(_ profile: ServerProfile) async {
        server = profile
        service = nil
        path = []
        do {
            let connected = try await SharedConnection.connect(to: profile)
            service = connected
            if let last = SharedConnection.lastFolder(for: profile) {
                path = Self.trail(to: last)
            }
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private func save() async {
        guard let service, let server, let folder = path.last else { return }
        phase = .uploading
        let total = Double(providers.count)
        var staged: [URL] = []
        defer { staged.forEach { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        do {
            var taken = Set((try? await service.list(folder: folder.path, offset: 0, limit: 5000, sort: .name, ascending: true).items.map(\.name)) ?? [])
            for (index, provider) in providers.enumerated() {
                let file = try await Self.stage(provider)
                staged.append(file)
                // Never overwrite: a clash gets "Name 2", like Keep Both in the app.
                let name = RemoteItem.uniqueName(for: file.lastPathComponent, avoiding: taken)
                taken.insert(name)
                current = name
                let base = Double(index)
                try await service.upload(file, as: name, to: folder.path, replacing: false) { fraction in
                    Task { @MainActor in progress = (base + fraction) / total }
                }
            }
            SharedConnection.setLastFolder(folder.path, for: server)
            SharedChanges.announce(domain: server.id.uuidString, name: server.name, folders: [folder.path])
            phase = .done
            try? await Task.sleep(for: .milliseconds(700))
            finish(false)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    // MARK: Helpers

    /// Copies a shared item to a private temporary folder, keeping its name.
    private static func stage(_ provider: NSItemProvider) async throws -> URL {
        let type = provider.registeredContentTypes.first { $0.conforms(to: .data) || $0.conforms(to: .item) } ?? .data
        // Read before the callback, which may run on another thread.
        let suggested = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let name = suggested.map { name in
                        (name as NSString).pathExtension.isEmpty ? name + "." + url.pathExtension : name
                    } ?? url.lastPathComponent
                    let copy = folder.appending(path: name.replacingOccurrences(of: "/", with: "-"))
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// "/Photos/Trips" → [Photos, Trips] as folders, for the navigation path.
    private static func trail(to path: String) -> [RemoteItem] {
        var result: [RemoteItem] = []
        var current = ""
        for part in path.split(separator: "/").map(String.init) {
            current += "/" + part
            result.append(RemoteItem(path: current, name: part, isDirectory: true))
        }
        return result
    }

    private static func message(for error: Error) -> String {
        if let error = error as? NASError {
            switch error {
            case .sessionExpired, .invalidCredentials, .twoFactorRequired, .passwordExpired:
                return "Open Ownhold and sign in to your NAS, then try again."
            case .untrustedCertificate, .certificateChanged:
                return "Open Ownhold to check your NAS's certificate, then try again."
            default:
                return error.errorDescription ?? "Something went wrong."
            }
        }
        return error.localizedDescription
    }
}

/// The subfolders of one NAS folder (the shared folders at the top).
private struct FolderList: View {
    let service: any FileService
    let folder: RemoteItem?
    let reload: Int
    let open: (RemoteItem) -> Void
    @State private var folders: [RemoteItem] = []
    @State private var loaded = false

    var body: some View {
        List(folders) { child in
            Button { open(child) } label: {
                HStack {
                    Label(child.name, systemImage: child.isShare ? "externaldrive" : "folder")
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if !loaded {
                ProgressView()
            } else if folders.isEmpty {
                ContentUnavailableView("No Folders Inside", systemImage: "folder",
                                       description: Text("Save here, or make a new folder."))
            }
        }
        .task {
            if let folder {
                folders = (try? await service.list(folder: folder.path, offset: 0, limit: 2000, sort: .name, ascending: true).items.filter(\.isDirectory)) ?? []
            } else {
                folders = (try? await service.listShares()) ?? []
            }
            loaded = true
        }
    }
}

/// The accent chosen in the app (Settings › Appearance), shared through the
/// app group so the extension matches.
enum SharedAccent {
    static var color: Color {
        let palette: [String: (UInt32, UInt32)] = [
            "evergreen": (0x1D4B3C, 0x6FBF9A),
            "harbor": (0x1F4A6E, 0x7FB2DA),
            "graphite": (0x3B3F45, 0xB9C0C8),
            "rosewood": (0x7A2F3B, 0xE3949F),
            "forest": (0x0F2E24, 0x4E9C78),
            "midnight": (0x14213A, 0x6F8FC4),
            "onyx": (0x16171A, 0xE6E7E9),
            "espresso": (0x3F2A1E, 0xC9A27E),
        ]
        if SharedContainer.defaults.string(forKey: "accent") == "system" {
            #if os(iOS)
            return Color(uiColor: .systemBlue)
            #else
            return Color(nsColor: .controlAccentColor)
            #endif
        }
        let pair = palette[SharedContainer.defaults.string(forKey: "accent") ?? ""] ?? palette["evergreen"]!
        return dynamic(light: pair.0, dark: pair.1)
    }

    private static func rgb(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            let c = rgb(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
        #endif
    }
}
