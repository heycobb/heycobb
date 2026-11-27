import Foundation

/// Makes the right client for a NAS's kind, for the app and its extensions.
public enum Connector {
    /// Signs in with a password and returns what to keep in the Keychain:
    /// a DSM session for Synology, the password itself for SMB and WebDAV
    /// (which have no sessions).
    public static func signIn(
        _ profile: ServerProfile,
        at endpoint: Endpoint,
        credentials: Credentials,
        trust: CertificateTrust,
        deviceName: String,
        previous: Session?,
        rememberDevice: Bool
    ) async throws -> Session {
        switch profile.kind {
        case .synology:
            let client = FileStationClient(baseURL: endpoint.url, trust: trust)
            return try await client.signIn(
                credentials,
                deviceName: deviceName,
                deviceToken: previous?.deviceToken,
                rememberDevice: rememberDevice
            )
        case .webdav, .smb:
            let session = Session.password(credentials.password)
            let client = service(for: profile, at: endpoint, session: session, trust: trust)
            do {
                try await client.validateSession()
            } catch NASError.sessionExpired {
                // WebDAV's "who are you?" means the password is wrong here.
                throw NASError.invalidCredentials
            }
            return session
        }
    }

    /// A client for a NAS already signed in to.
    public static func service(for profile: ServerProfile, at endpoint: Endpoint, session: Session, trust: CertificateTrust) -> any FileService {
        switch profile.kind {
        case .synology:
            FileStationClient(baseURL: endpoint.url, trust: trust, sid: session.sid)
        case .webdav:
            WebDAVClient(baseURL: endpoint.url, account: profile.account, password: session.sid, trust: trust)
        case .smb:
            SMBFileService(endpoint: endpoint.url, account: profile.account, password: session.sid)
        }
    }

    /// Like `service`, then checks the sign-in still works. A refused
    /// password comes back as `.sessionExpired`, so the app asks again.
    public static func connect(_ profile: ServerProfile, at endpoint: Endpoint, session: Session, trust: CertificateTrust) async throws -> any FileService {
        guard !session.sid.isEmpty else { throw NASError.sessionExpired }
        let client = service(for: profile, at: endpoint, session: session, trust: trust)
        do {
            try await client.validateSession()
        } catch NASError.invalidCredentials {
            throw NASError.sessionExpired
        }
        return client
    }
}
