import FileProvider
import Foundation
import OwnholdKit

/// Connects to one NAS for the Files app, reusing the app's sign-in and
/// trusted certificates. It never asks for a password: if the session has
/// expired, the Files app shows "Sign in in Ownhold".
actor ProviderContext {
    let domainID: String
    private var cached: (any FileService)?

    init(domainID: String) {
        self.domainID = domainID
    }

    func service() async throws -> any FileService {
        // Checked on every request (not just when connecting), so turning on
        // the app lock or turning off Files access takes effect at once.
        guard SharedContainer.isFilesAccessAllowed else {
            cached = nil
            throw NSFileProviderError(.notAuthenticated)
        }
        if let cached { return cached }
        if domainID == ProviderContext.demoDomain {
            let demo = DemoFileService()
            cached = demo
            return demo
        }
        guard let id = UUID(uuidString: domainID),
              let profile = SharedConnection.servers().first(where: { $0.id == id })
        else { throw NSFileProviderError(.notAuthenticated) }
        do {
            let client = try await SharedConnection.connect(to: profile)
            cached = client
            return client
        } catch {
            throw Self.fileProviderError(error)
        }
    }

    /// Forget the connection after an error, so the next request picks the
    /// best address again (for example after leaving home Wi-Fi).
    func reset() { cached = nil }

    /// Runs a request, translating Ownhold errors into ones the Files app understands.
    func run<T: Sendable>(_ work: @Sendable (any FileService) async throws -> T) async throws -> T {
        do {
            return try await work(service())
        } catch let error as NASError {
            if error == .unreachable || error == .sessionExpired { reset() }
            throw Self.fileProviderError(error)
        }
    }

    static let demoDomain = "demo"

    static func fileProviderError(_ error: Error) -> Error {
        guard let error = error as? NASError else { return error }
        switch error {
        case .sessionExpired, .invalidCredentials, .twoFactorRequired, .passwordExpired,
             .untrustedCertificate, .certificateChanged:
            return NSFileProviderError(.notAuthenticated)
        case .unreachable, .quickConnectUnavailable:
            return NSFileProviderError(.serverUnreachable)
        case .notFound:
            return NSFileProviderError(.noSuchItem)
        case .alreadyExists:
            return NSFileProviderError(.filenameCollision)
        case .noSpace:
            return NSFileProviderError(.insufficientQuota)
        case .permissionDenied:
            return CocoaError(.fileWriteNoPermission)
        default:
            return NSFileProviderError(.cannotSynchronize)
        }
    }
}
