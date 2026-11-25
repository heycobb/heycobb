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
        self.pins = keychain.codable([String: String].self, for: Self.pinsKey) ?? [:]
    }

    /// Trust a certificate the user has checked.
    public func trust(_ info: CertificateInfo) {
        lock.withLock {
            pins[info.host] = info.fingerprint
            keychain.setCodable(pins, for: Self.pinsKey)
        }
    }

    public func forget(host: String) {
        lock.withLock {
            pins = pins.filter { !$0.key.hasPrefix(host) }
            keychain.setCodable(pins, for: Self.pinsKey)
        }
    }

    /// If the most recent connection to `hostKey` was refused because of its
    /// certificate, returns why (and clears it).
    func takeRejection(for hostKey: String) -> NASError? {
        lock.withLock { rejections.removeValue(forKey: hostKey) }
    }

    static func hostKey(host: String, port: Int) -> String { "\(host):\(port)" }

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

    static func certificateInfo(trust: SecTrust, hostKey: String) -> CertificateInfo? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              let key = SecCertificateCopyKey(leaf),
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        let digest = SHA256.hash(data: keyData)
        let fingerprint = digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "Unknown"
        return CertificateInfo(host: hostKey, subject: subject, fingerprint: fingerprint)
    }
}
