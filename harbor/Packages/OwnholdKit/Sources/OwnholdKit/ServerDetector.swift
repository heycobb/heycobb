import Foundation
import Network

/// Works out what kind of NAS a typed address is, so adding one only asks
/// for its address, account and password.
///
/// No account details are sent while detecting. Certificates aren't checked
/// for these questions only (a home NAS uses its own); the real one is
/// checked, and shown to you, when you sign in.
public enum ServerDetector {
    /// What the text alone says, without asking the network: "smb://…" is
    /// SMB; an HTTPS address with a path is WebDAV (DSM never has one).
    public static func kind(fromText text: String) -> ServerKind? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.hasPrefix("smb://") { return .smb }
        if raw.hasPrefix("https://"), let url = URLComponents(string: raw), url.path.count > 1 { return .webdav }
        return nil
    }

    /// Asks the network: DSM first (Synology), then WebDAV when a port other
    /// than DSM's was typed, then SMB. Nil if nothing answered.
    public static func detect(_ text: String, timeout: TimeInterval = 4) async -> ServerKind? {
        if let kind = kind(fromText: text) { return kind }
        guard let endpoint = Endpoint.parse(text), let host = endpoint.url.host() else { return nil }
        let typedPort = URLComponents(string: text.lowercased().hasPrefix("https://") ? text : "https://" + text)?.port
        if await isSynology(host: host, port: typedPort ?? 5001, timeout: timeout) { return .synology }
        if let typedPort, typedPort != 5001, await isWebDAV(host: host, port: typedPort, timeout: timeout) { return .webdav }
        if await isListening(host: host, port: 445, timeout: timeout) { return .smb }
        return nil
    }

    /// For several typed addresses of one NAS (home, VPN, internet): asks
    /// about all of them at once and goes by the first in order that
    /// answered. Synology if none did, so the usual sign-in errors apply.
    public static func detect(addresses: [String]) async -> ServerKind {
        let texts = addresses.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for text in texts {
            if let kind = kind(fromText: text) { return kind }
        }
        let answers = await withTaskGroup(of: (Int, ServerKind?).self) { group in
            for (index, text) in texts.enumerated() {
                group.addTask { (index, await detect(text)) }
            }
            var answers: [Int: ServerKind] = [:]
            for await (index, kind) in group { answers[index] = kind }
            return answers
        }
        return texts.indices.lazy.compactMap { answers[$0] }.first ?? .synology
    }

    /// Whether DSM's public API list answers at this address.
    public static func isSynology(host: String, port: Int = 5001, timeout: TimeInterval = 4) async -> Bool {
        guard let url = URL(string: "https://\(host):\(port)/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth") else { return false }
        let session = probeSession(timeout)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, _) = try? await session.data(for: URLRequest(url: url, timeoutInterval: timeout)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["success"] as? Bool == true && (json["data"] as? [String: Any])?["SYNO.API.Auth"] != nil
    }

    /// Whether an HTTPS server here speaks WebDAV (says "DAV" to OPTIONS).
    public static func isWebDAV(host: String, port: Int, timeout: TimeInterval = 4) async -> Bool {
        guard let url = URL(string: "https://\(host):\(port)/") else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "OPTIONS"
        let session = probeSession(timeout)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.value(forHTTPHeaderField: "DAV") != nil || http.statusCode == 401
    }

    /// Whether something accepts connections on the port (SMB uses 445).
    public static func isListening(host: String, port: Int, timeout: TimeInterval = 4) async -> Bool {
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let once = Once()
        let open = await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: true) }
                case .failed, .cancelled: once.run { continuation.resume(returning: false) }
                case .waiting: once.run { continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { continuation.resume(returning: false) }
            }
        }
        connection.cancel()
        return open
    }

    private static func probeSession(_ timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: AnyCertificate(), delegateQueue: nil)
    }

    /// Accepts the NAS's own certificate for the detection questions only.
    private final class AnyCertificate: NSObject, URLSessionDelegate, Sendable {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            return (.useCredential, URLCredential(trust: trust))
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }
}
