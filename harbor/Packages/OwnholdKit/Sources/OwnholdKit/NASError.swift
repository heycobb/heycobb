import Foundation

/// Errors surfaced to the UI. Messages are written for people, not developers.
public enum NASError: Error, Equatable, Sendable, LocalizedError {
    case unreachable
    case untrustedCertificate(CertificateInfo)
    case certificateChanged(CertificateInfo)
    case invalidCredentials
    case accountDisabled
    case twoFactorRequired
    case twoFactorFailed
    case ipBlocked
    case passwordExpired
    case sessionExpired
    case permissionDenied
    case notFound
    case server(code: Int, api: String)
    case malformedResponse
    case quickConnectNotFound
    case quickConnectUnavailable
    case alreadyExists
    case noSpace
    case invalidName
    case streamingUnsupported

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            "Can't reach the NAS. Check that you're on your home network, or that your VPN (such as Tailscale) is connected."
        case .untrustedCertificate:
            "This NAS uses a certificate your device doesn't recognize. Check the fingerprint before trusting it."
        case .certificateChanged:
            "The NAS certificate changed since you last connected. If you didn't replace it, someone may be intercepting the connection."
        case .invalidCredentials:
            "Incorrect account name or password."
        case .accountDisabled:
            "This account is disabled on the NAS."
        case .twoFactorRequired:
            "Enter the code from your authenticator app."
        case .twoFactorFailed:
            "That verification code didn't work. Try the next one."
        case .ipBlocked:
            "The NAS has temporarily blocked this device after too many failed sign-ins."
        case .passwordExpired:
            "Your password has expired. Change it in DSM, then sign in again."
        case .sessionExpired:
            "Your session expired. Sign in again."
        case .permissionDenied:
            "Your account doesn't have permission for this. An administrator can change it in DSM."
        case .notFound:
            "This item no longer exists on the NAS."
        case let .server(code, api):
            "The NAS returned an error (\(api) \(code))."
        case .malformedResponse:
            "The NAS sent a response Ownhold didn't understand."
        case .quickConnectNotFound:
            "That QuickConnect ID wasn't found. Check it in DSM under Control Panel › External Access › QuickConnect."
        case .quickConnectUnavailable:
            "Couldn't look up your NAS through QuickConnect right now. Ownhold will use your saved addresses."
        case .alreadyExists:
            "An item with that name already exists there."
        case .noSpace:
            "The NAS is out of space, or your account has reached its storage limit."
        case .invalidName:
            "That name isn't allowed. Names can't be empty, contain “/”, or be too long."
        case .streamingUnsupported:
            "This NAS can't stream that file, so Ownhold will download it instead."
        }
    }

    // Synology reuses numbers across APIs, so codes are mapped per API family.
    // Codes 100–199 are shared by every API.
    static func from(code: Int, api: String) -> NASError {
        switch code {
        case 105: return .permissionDenied
        case 106, 107, 119: return .sessionExpired
        default: break
        }
        if api == "SYNO.API.Auth" {
            switch code {
            case 400: return .invalidCredentials
            case 401: return .accountDisabled
            case 402: return .permissionDenied
            case 403, 406: return .twoFactorRequired
            case 404: return .twoFactorFailed
            case 407: return .ipBlocked
            case 408, 409, 410: return .passwordExpired
            default: return .server(code: code, api: api)
            }
        }
        if api.hasPrefix("SYNO.FileStation") {
            switch code {
            case 407, 411, 1803: return .permissionDenied
            case 408: return .notFound
            case 412, 413, 418, 419, 420: return .invalidName
            case 414, 1003, 1004, 1805: return .alreadyExists
            case 415, 416, 1804: return .noSpace
            default: return .server(code: code, api: api)
            }
        }
        return .server(code: code, api: api)
    }
}

/// Details of a server certificate, shown to the user before trusting it.
public struct CertificateInfo: Equatable, Sendable, Codable {
    public let host: String
    public let subject: String
    /// SHA-256 of the certificate's public key, as colon-separated hex.
    /// This is what Ownhold pins: it survives a certificate renewal that
    /// keeps the same key.
    public let fingerprint: String
    /// SHA-256 of the whole certificate, as colon-separated hex. This is the
    /// value Safari, Chrome and Firefox show, so it's the one people can
    /// compare against.
    public let certificateFingerprint: String

    public init(host: String, subject: String, fingerprint: String, certificateFingerprint: String = "") {
        self.host = host
        self.subject = subject
        self.fingerprint = fingerprint
        self.certificateFingerprint = certificateFingerprint
    }
}
