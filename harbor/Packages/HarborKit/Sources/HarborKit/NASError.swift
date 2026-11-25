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

    public var errorDescription: String? {
        switch self {
        case .unreachable:
            "Can't reach the NAS. Check that you're on your home network or that Tailscale is connected."
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
            "You don't have permission to open this."
        case .notFound:
            "This item no longer exists on the NAS."
        case let .server(code, api):
            "The NAS returned an error (\(api) \(code))."
        case .malformedResponse:
            "The NAS sent a response Harbor didn't understand."
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
            case 407: return .permissionDenied
            case 408: return .notFound
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
    public let fingerprint: String

    public init(host: String, subject: String, fingerprint: String) {
        self.host = host
        self.subject = subject
        self.fingerprint = fingerprint
    }
}
