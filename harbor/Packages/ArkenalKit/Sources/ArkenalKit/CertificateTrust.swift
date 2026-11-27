import CryptoKit
import Foundation
import Security

/// Decides which TLS certificates to accept.
///
/// - Certificates the system already trusts (for example a Let's Encrypt
///   certificate on a Synology DDNS name) are accepted normally.
/// - A self-signed certificate is accepted only if the user has explicitly
///   trusted its public-key fingerprint for that host and port.
/// - Certificate checks are never turned off.
public final class CertificateTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let keychain: Keychain
    private let lock = NSLock()
    private var pins: [String: String]
    private var rejections: [String: NASError] = [:]
    private static let pinsKey = "certificate-pins"

    public init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
        let saved = keychain.codable([String: String].self, for: Self.pinsKey) ?? [:]
        // Older versions kept the host's case; keys are lowercase now.
        self.pins = Dictionary(saved.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// Trust a certificate the user has checked, for the address it came
    /// from and for the NAS's other addresses (`alsoFor`, as "host:port").
    /// Pinning the other addresses too means the prompt appears once per
    /// NAS, not once per address, and it only ever narrows what those
    /// addresses may present: exactly this key.
    public func trust(_ info: CertificateInfo, alsoFor hostKeys: [String] = []) {
        lock.withLock {
            for key in Set(([info.host] + hostKeys).map { $0.lowercased() }) {
                pins[key] = info.fingerprint
            }
            keychain.setCodable(pins, for: Self.pinsKey)
        }
    }

    /// Extends a NAS's existing pin to addresses that don't have one yet,
    /// for example a Tailscale address added after setup. Does nothing if
    /// none of `existingKeys` is pinned (a publicly trusted certificate).
    public func extendPin(from existingKeys: [String], to newKeys: [String]) {
        lock.withLock {
            guard let fingerprint = existingKeys.lazy.compactMap({ self.pins[$0.lowercased()] }).first else { return }
            for key in newKeys.map({ $0.lowercased() }) where pins[key] == nil {
                pins[key] = fingerprint
            }
            keychain.setCodable(pins, for: Self.pinsKey)
        }
    }

    public func forget(host: String) {
        lock.withLock {
            pins.removeValue(forKey: host.lowercased())
            keychain.setCodable(pins, for: Self.pinsKey)
        }
    }

    /// If the most recent connection to `hostKey` was refused because of its
    /// certificate, returns why (and clears it).
    func takeRejection(for hostKey: String) -> NASError? {
        lock.withLock { rejections.removeValue(forKey: hostKey) }
    }

    /// Host names are compared without case: URLSession reports
    /// "FirelandsDS25.local" as "firelandsds25.local".
    public static func hostKey(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust
        else { return (.performDefaultHandling, nil) }

        let key = Self.hostKey(host: space.host, port: space.port)
        let systemTrusted = SecTrustEvaluateWithError(trust, nil)
        guard let info = Self.certificateInfo(trust: trust, hostKey: key) else {
            return (.cancelAuthenticationChallenge, nil)
        }

        return lock.withLock {
            if let pinned = pins[key] {
                if pinned == info.fingerprint {
                    return (.useCredential, URLCredential(trust: trust))
                }
                if systemTrusted {
                    // The NAS moved to a publicly trusted certificate; the old pin is obsolete.
                    pins.removeValue(forKey: key)
                    keychain.setCodable(pins, for: Self.pinsKey)
                    return (.useCredential, URLCredential(trust: trust))
                }
                rejections[key] = .certificateChanged(info)
                return (.cancelAuthenticationChallenge, nil)
            }
            if systemTrusted {
                return (.useCredential, URLCredential(trust: trust))
            }
            rejections[key] = .untrustedCertificate(info)
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func certificateInfo(trust: SecTrust, hostKey: String) -> CertificateInfo? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "Unknown"
        return CertificateInfo(
            host: hostKey,
            subject: subject,
            fingerprint: hex(SHA256.hash(data: keyData)),
            certificateFingerprint: hex(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        )
    }
}
