import Foundation
import Network
import Observation
import OwnholdKit

/// Finds Synology NAS on the local network, for the first-run setup.
///
/// DSM doesn't announce itself as Synology over Bonjour, but it does
/// announce file sharing (SMB) under its own name. Each SMB server found is
/// asked, over HTTPS on port 5001, which DSM APIs it has (an anonymous
/// request with no account details); those that answer like DSM are listed.
/// Runs only while the "Find your NAS" step is on screen.
@MainActor
@Observable
final class NASDiscovery {
    struct Found: Identifiable, Hashable {
        let name: String
        /// "FirelandsDS25.local"
        let host: String
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
                if await Self.isSynology(host: host) {
                    found.append(Found(name: name, host: host))
                    found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                }
            }
        }
    }

    /// Asks DSM's public API list whether this is a Synology NAS. No account
    /// details are sent. The certificate isn't checked for this question
    /// only: a home NAS uses its own, and it's checked properly (and shown
    /// to you) when you sign in.
    private nonisolated static func isSynology(host: String) async -> Bool {
        guard let url = URL(string: "https://\(host):5001/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpShouldHandleCookies = false
        let session = URLSession(configuration: .ephemeral, delegate: ProbeDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["success"] as? Bool == true && (json["data"] as? [String: Any])?["SYNO.API.Auth"] != nil
    }
}

/// Accepts the NAS's own certificate for the discovery question only.
private final class ProbeDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
