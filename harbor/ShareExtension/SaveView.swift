import LocalAuthentication
import OwnholdKit
import SwiftUI
import UniformTypeIdentifiers

/// Save to Ownhold: choose a NAS and folder, then upload what was shared.
/// Uploads go straight to the NAS over the app's pinned connection; nothing
/// is sent anywhere else, and the copies made for uploading are deleted.
struct SaveView: View {
    let providers: [NSItemProvider]
    let finish: (_ cancelled: Bool) -> Void

    @State private var servers: [ServerProfile] = []
    @State private var server: ServerProfile?
    @State private var service: (any FileService)?
    @State private var path: [RemoteItem] = []
    @State private var phase: Phase = .starting
    @State private var progress: Double = 0
    @State private var current = ""

    private enum Phase: Equatable {
        case starting, locked, choosing, uploading, done, failed(String)
    }

    private static let accent = Color(red: 0.114, green: 0.294, blue: 0.235)

    var body: some View {
        // One stack for every folder level, so Cancel, Save Here and the
        // destination line stay visible while browsing.
        NavigationStack(path: $path) {
            chrome(content, title: "Save to Ownhold")
                .navigationDestination(for: RemoteItem.self) { folder in
                    if let service {
                        chrome(level(folder, service: service), title: folder.name)
                    }
                }
        }
        .tint(Self.accent)
        .task { await start() }
    }

    /// A folder while choosing; the progress or result once saving starts.
    @ViewBuilder private func level(_ folder: RemoteItem, service: any FileService) -> some View {
        if phase == .choosing {
            FolderLevel(service: service, folder: folder)
        } else {
            content
        }
    }

    private func chrome(_ view: some View, title: String) -> some View {
        view
            .navigationTitle(title)
            .navigationBarBackButtonHidden(phase != .choosing)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish(true) }
                        .disabled(phase == .uploading)
                }
                if phase == .choosing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save Here") { Task { await save() } }
                            .disabled(path.isEmpty)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if phase == .choosing {
                    Text(destinationLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(.bar)
                }
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
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(Self.accent)
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
            if servers.count > 1 {
                Picker("NAS", selection: Binding(get: { server?.id }, set: { id in
                    if let picked = servers.first(where: { $0.id == id }) { Task { await select(picked) } }
                })) {
                    ForEach(servers) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)
            }
            if let service {
                FolderLevel(service: service, folder: nil)
                    .id(server?.id)
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
    }

    private var destinationLine: String {
        let count = providers.count == 1 ? "1 item" : "\(providers.count) items"
        guard let folder = path.last else { return "Choose a folder for \(count)" }
        return "\(count) to \(folder.path)"
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

/// One level of NAS folders (the shared folders when `folder` is nil).
private struct FolderLevel: View {
    let service: any FileService
    let folder: RemoteItem?
    @State private var folders: [RemoteItem] = []
    @State private var loaded = false

    var body: some View {
        List(folders) { child in
            NavigationLink(value: child) {
                Label(child.name, systemImage: child.isShare ? "externaldrive" : "folder")
            }
        }
        .overlay {
            if !loaded { ProgressView() }
            else if folders.isEmpty { Text("No folders").foregroundStyle(.secondary) }
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
