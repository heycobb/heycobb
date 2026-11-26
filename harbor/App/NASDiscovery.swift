import Foundation
import Network
import Observation
import OwnholdKit

/// Finds NAS on the local network, for the first-run setup.
///
/// Every NAS announces file sharing (SMB) over Bonjour under its own name.
/// Each one found is asked, over HTTPS on port 5001, whether it's running
/// Synology DSM (an anonymous request with no account details). Synology
/// NAS are listed first and use DSM's API; the rest connect over SMB.
/// Runs only while the "Find your NAS" step is on screen.
@MainActor
@Observable
final class NASDiscovery {
    struct Found: Identifiable, Hashable {
        let name: String
        /// "FirelandsDS25.local"
        let host: String
        /// Its IP addresses, so a typed address can be matched to its name.
        let addresses: Set<String>
        let kind: ServerKind
        var id: String { host }
    }

    private(set) var found: [Found] = []
    private(set) var isSearching = false

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var checked: Set<String> = []

    func start() {
        guard browser == nil else { return }
        isSearching = true
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case let .service(name, _, _, _) = result.endpoint { return name }
                return nil
            }
            Task { @MainActor in self?.consider(names) }
        }
        browser.start(queue: .main)
        self.browser = browser
        // Searching stops showing as busy after a while; results can still arrive.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.isSearching = false
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }

    private func consider(_ names: [String]) {
        for name in names {
            let host = name + ".local"
            guard checked.insert(host).inserted else { continue }
            Task {
                let kind: ServerKind = await ServerDetector.isSynology(host: host) ? .synology : .smb
                found.append(Found(name: name, host: host, addresses: await Self.addresses(of: host), kind: kind))
                found.sort {
                    ($0.kind == .synology ? 0 : 1, $0.name.localizedLowercase) < ($1.kind == .synology ? 0 : 1, $1.name.localizedLowercase)
                }
            }
        }
    }

    /// The name a typed address belongs to, if it's one of the NAS found.
    func name(forAddress address: String) -> String? { match(address)?.name }

    /// The kind of a NAS found here, for a typed address of it.
    func kind(forAddress address: String) -> ServerKind? { match(address)?.kind }

    private func match(_ address: String) -> Found? {
        let host = address.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        return found.first { $0.host.lowercased() == host || $0.addresses.contains(host) }
    }

    private nonisolated static func addresses(of host: String) async -> Set<String> {
        await Task.detached {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
            defer { freeaddrinfo(first) }
            var found = Set<String>()
            var pointer: UnsafeMutablePointer<addrinfo>? = first
            while let info = pointer?.pointee {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.ai_addr, info.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                }
                pointer = info.ai_next
            }
            return found
        }.value
    }
}
