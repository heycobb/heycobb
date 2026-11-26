import Foundation

/// Picks the best reachable address for a NAS.
///
/// All endpoints are probed at once; the highest-priority one that answers
/// wins. So at home you get the fast LAN address, and away from home the
/// Tailscale address, with no setting to flip.
public struct ConnectionResolver: Sendable {
    let trust: CertificateTrust
    let timeout: TimeInterval

    public init(trust: CertificateTrust, timeout: TimeInterval = 4) {
        self.trust = trust
        self.timeout = timeout
    }

    public func resolve(_ endpoints: [Endpoint], server: ServerKind = .synology) async throws -> Endpoint {
        guard !endpoints.isEmpty else { throw NASError.unreachable }

        let results = await withTaskGroup(of: (Int, Result<Void, Error>).self) { group in
            for (index, endpoint) in endpoints.enumerated() {
                group.addTask { (index, await probe(endpoint, server: server)) }
            }
            var collected: [Int: Result<Void, Error>] = [:]
            for await (index, result) in group {
                collected[index] = result
                // Stop early once every higher-priority endpoint has answered
                // and this one succeeded.
                if case .success = result, (0 ..< index).allSatisfy({ collected[$0] != nil }) {
                    group.cancelAll()
                    break
                }
            }
            return collected
        }

        for index in endpoints.indices {
            if case .success = results[index] { return endpoints[index] }
        }
        // Prefer telling the user about certificate problems over "unreachable".
        let errors = results.values.compactMap { result -> NASError? in
            if case let .failure(error) = result { return error as? NASError }
            return nil
        }
        if let certError = errors.first(where: { if case .untrustedCertificate = $0 { true } else if case .certificateChanged = $0 { true } else { false } }) {
            throw certError
        }
        throw NASError.unreachable
    }

    private func probe(_ endpoint: Endpoint, server: ServerKind) async -> Result<Void, Error> {
        switch server {
        case .synology: return await probeDSM(endpoint)
        case .webdav: return await probeWebDAV(endpoint)
        case .smb:
            let port = endpoint.url.port ?? 445
            return await ServerDetector.isListening(host: endpoint.url.host() ?? "", port: port, timeout: timeout)
                ? .success(()) : .failure(NASError.unreachable)
        }
    }

    /// Any HTTP answer means the server is there (it may ask for the
    /// password: no account details are sent here). The certificate is
    /// checked against the pinned one.
    private func probeWebDAV(_ endpoint: Endpoint) async -> Result<Void, Error> {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "OPTIONS"
        do {
            _ = try await session.data(for: request)
            return .success(())
        } catch {
            let key = CertificateTrust.hostKey(host: endpoint.url.host() ?? "", port: endpoint.url.port ?? 443)
            if let rejection = trust.takeRejection(for: key) { return .failure(rejection) }
            return .failure(NASError.unreachable)
        }
    }

    private func probeDSM(_ endpoint: Endpoint) async -> Result<Void, Error> {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var components = URLComponents(url: endpoint.url.appending(path: "webapi/query.cgi"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Info"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "query"),
            URLQueryItem(name: "query", value: "SYNO.API.Auth"),
        ]
        do {
            let (data, _) = try await session.data(from: components.url!)
            let envelope = try JSONDecoder().decode(Envelope<[String: APIInfo]>.self, from: data)
            return envelope.success ? .success(()) : .failure(NASError.malformedResponse)
        } catch {
            let key = CertificateTrust.hostKey(host: endpoint.url.host() ?? "", port: endpoint.url.port ?? 443)
            if let rejection = trust.takeRejection(for: key) { return .failure(rejection) }
            return .failure(NASError.unreachable)
        }
    }
}
