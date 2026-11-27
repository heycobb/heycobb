import CommonCrypto
import CryptoKit
import Foundation

/// Encrypted folders: files are encrypted on the device before they're
/// uploaded and decrypted after they're downloaded, so the NAS, and anyone
/// who can read its drives or the network, only ever sees scrambled data.
///
/// Only Apple's built-in cryptography is used (CryptoKit and CommonCrypto),
/// no bundled crypto code. The format is documented in docs/ENCRYPTION.md.
///
/// A folder on the NAS becomes an encrypted folder when it holds
/// `ownhold-vault.json`. Everything else in it, at any depth, is encrypted:
/// - Names: AES-GCM with a nonce derived from the name (HMAC-SHA256), so the
///   same name always gives the same stored name and paths can be found
///   without listing. Stored as lowercase base32 (safe on case-insensitive
///   shares). Names too long for the NAS are stored under a hash, with the
///   full encrypted name in a small file next to it.
/// - Contents: a random key per file, sealed with the folder's content key in
///   a 64-byte header, then the data in 64 KB chunks, each AES-GCM sealed with
///   its index as the nonce and a flag on the last one, so chunks can't be
///   reordered, swapped between files or cut off without it being noticed.
///   Chunks also let a video seek without downloading the whole file.
/// - Keys: a random 256-bit folder key, sealed once with a key made from the
///   password (PBKDF2-HMAC-SHA256) and once with a recovery key.
public enum Vault {
    public static let configName = "ownhold-vault.json"
    public static let chunkSize = 64 * 1024
    static let magic = Data("OHV1".utf8)
    static let tagSize = 16
    static let headerSize = 64
    static var storedChunk: Int { chunkSize + tagSize }
    /// The longest stored name; longer ones are kept under a hash. NAS file
    /// systems allow 255 bytes; this leaves room.
    static let maxStoredName = 200
    static let longNamePrefix = "_"
    static let longNameSuffix = ".n"
    /// PBKDF2 rounds for new folders (OWASP's figure for HMAC-SHA256).
    public static let defaultIterations = 600_000

    /// Whether a name in a NAS listing is the encrypted folder's settings.
    public static func isConfig(_ name: String) -> Bool { name.lowercased() == configName }

    // MARK: Sizes

    /// The decrypted size of a stored file, from its stored size alone.
    public static func plainSize(stored: Int64) -> Int64? {
        let body = stored - Int64(headerSize)
        guard body >= Int64(tagSize) else { return nil }
        let chunks = (body + Int64(storedChunk) - 1) / Int64(storedChunk)
        let plain = body - chunks * Int64(tagSize)
        return plain >= 0 ? plain : nil
    }

    /// The stored size of a file of `plain` bytes.
    public static func storedSize(plain: Int64) -> Int64 {
        let chunks = max(1, (plain + Int64(chunkSize) - 1) / Int64(chunkSize))
        return Int64(headerSize) + plain + chunks * Int64(tagSize)
    }
}

// MARK: - Keys

/// An unlocked encrypted folder's keys. Kept in memory while it's unlocked
/// (and in the Keychain if the user chooses to stay unlocked on the device).
public struct VaultKeys: Sendable, Equatable {
    let master: SymmetricKey
    let content: SymmetricKey
    let names: SymmetricKey
    let nameNonces: SymmetricKey

    public init(master: SymmetricKey) {
        self.master = master
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("ownhold-vault-v1 \(label)".utf8), outputByteCount: 32)
        }
        content = derive("content")
        names = derive("names")
        nameNonces = derive("name-nonces")
    }

    /// The master key's bytes, for keeping in the Keychain.
    public var masterData: Data { master.withUnsafeBytes { Data($0) } }

    public init?(masterData: Data) {
        guard masterData.count == 32 else { return nil }
        self.init(master: SymmetricKey(data: masterData))
    }

    public static func == (a: VaultKeys, b: VaultKeys) -> Bool { a.masterData == b.masterData }
}

public enum VaultError: Error, Equatable, Sendable {
    case wrongPassword
    case wrongRecoveryKey
    case notAVault
    case unsupportedVersion
    case damaged
    case nameTooLong
    /// The encrypted folder at this path needs unlocking first.
    case locked(String)
    /// Share links, extracting on the NAS and similar can't work on files the
    /// NAS can't read.
    case unavailable
    /// Encrypted folders can't be inside one another.
    case nested
    /// Face ID's saved key is gone or no longer valid (for example, a face
    /// or finger was added in Settings): the password is needed.
    case biometryUnavailable
    case biometryCanceled
}

extension VaultError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .wrongPassword: "The password is incorrect."
        case .wrongRecoveryKey: "The recovery key is incorrect."
        case .notAVault: "This folder isn't an encrypted folder."
        case .unsupportedVersion: "This encrypted folder was made by a newer version of Ownhold. Update Ownhold to open it."
        case .damaged: "This file is damaged or was changed outside Ownhold, so it can't be decrypted."
        case .nameTooLong: "The name is too long for an encrypted folder."
        case .locked: "This encrypted folder is locked."
        case .unavailable: "This isn't available in an encrypted folder, because the NAS can't read the files."
        case .nested: "An encrypted folder can't be inside another encrypted folder."
        case .biometryUnavailable: "Enter the password. Face ID needs to be turned on again for this folder, for example after a face or fingerprint was added on this device."
        case .biometryCanceled: "Unlocking was cancelled."
        }
    }
}

// MARK: - Settings file

/// `ownhold-vault.json`: what's needed to unlock the folder, and nothing
/// that helps anyone who doesn't have the password or recovery key.
public struct VaultConfig: Codable, Sendable, Equatable {
    public struct KDF: Codable, Sendable, Equatable {
        public var name = "PBKDF2-HMAC-SHA256"
        public var iterations: Int
        public var salt: Data
    }

    public var format = "ownhold-vault"
    public var version = 1
    public var id: UUID
    public var kdf: KDF
    /// The master key sealed with the key made from the password.
    public var passwordKey: Data
    /// The master key sealed with the recovery key.
    public var recoveryKey: Data

    /// A new folder: returns its settings, its keys and the recovery key to
    /// show the user once.
    public static func create(password: String, iterations: Int = Vault.defaultIterations) throws -> (config: VaultConfig, keys: VaultKeys, recoveryKey: String) {
        let master = SymmetricKey(size: .bits256)
        let recovery = SymmetricKey(size: .bits256)
        let id = UUID()
        let salt = Self.random(16)
        let kek = try Self.passwordKey(password, salt: salt, iterations: iterations)
        let config = VaultConfig(
            id: id,
            kdf: KDF(iterations: iterations, salt: salt),
            passwordKey: try Self.wrap(master, with: kek, label: "password", id: id),
            recoveryKey: try Self.wrap(master, with: recovery, label: "recovery", id: id)
        )
        return (config, VaultKeys(master: master), RecoveryKey.encode(recovery.withUnsafeBytes { Data($0) }))
    }

    public static func decode(_ data: Data) throws -> VaultConfig {
        guard let config = try? JSONDecoder().decode(VaultConfig.self, from: data), config.format == "ownhold-vault" else {
            throw VaultError.notAVault
        }
        guard config.version == 1 else { throw VaultError.unsupportedVersion }
        return config
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public func unlock(password: String) throws -> VaultKeys {
        let kek = try Self.passwordKey(password, salt: kdf.salt, iterations: kdf.iterations)
        guard let master = try? Self.unwrap(passwordKey, with: kek, label: "password", id: id) else { throw VaultError.wrongPassword }
        return VaultKeys(master: master)
    }

    public func unlock(recoveryKey text: String) throws -> VaultKeys {
        guard let bytes = RecoveryKey.decode(text),
              let master = try? Self.unwrap(recoveryKey, with: SymmetricKey(data: bytes), label: "recovery", id: id)
        else { throw VaultError.wrongRecoveryKey }
        return VaultKeys(master: master)
    }

    /// The same folder with a new password. Files don't change: only the
    /// sealed master key does. The recovery key keeps working.
    public func changingPassword(to password: String, keys: VaultKeys, iterations: Int = Vault.defaultIterations) throws -> VaultConfig {
        var copy = self
        let salt = Self.random(16)
        copy.kdf = KDF(iterations: iterations, salt: salt)
        copy.passwordKey = try Self.wrap(keys.master, with: Self.passwordKey(password, salt: salt, iterations: iterations), label: "password", id: id)
        return copy
    }

    // MARK: Helpers

    static func random(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    private static func aad(_ label: String, _ id: UUID) -> Data { Data("ownhold-vault-v1 \(label) \(id.uuidString)".utf8) }

    static func wrap(_ key: SymmetricKey, with kek: SymmetricKey, label: String, id: UUID) throws -> Data {
        let bytes = key.withUnsafeBytes { Data($0) }
        guard let combined = try AES.GCM.seal(bytes, using: kek, authenticating: aad(label, id)).combined else { throw VaultError.damaged }
        return combined
    }

    static func unwrap(_ data: Data, with kek: SymmetricKey, label: String, id: UUID) throws -> SymmetricKey {
        let box = try AES.GCM.SealedBox(combined: data)
        let bytes = try AES.GCM.open(box, using: kek, authenticating: aad(label, id))
        guard bytes.count == 32 else { throw VaultError.damaged }
        return SymmetricKey(data: bytes)
    }

    /// PBKDF2-HMAC-SHA256 from CommonCrypto. The password is normalised so
    /// the same characters typed on different keyboards give the same key.
    static func passwordKey(_ password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let normalised = password.precomposedStringWithCanonicalMapping
        let passwordBytes = Array(normalised.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer in
            passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                passwordBuffer.withMemoryRebound(to: Int8.self) { passwordChars in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordChars.baseAddress, passwordBytes.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(clamping: iterations),
                        &derived, derived.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw VaultError.damaged }
        defer { derived.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        return SymmetricKey(data: derived)
    }
}

// MARK: - Recovery key

/// A recovery key as people write it down: 52 characters in groups of four,
/// in Crockford's base32 (digits and capitals, no I, L, O or U). Reading it
/// back ignores case, spaces and dashes, and reads O as 0 and I or L as 1.
public enum RecoveryKey {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    public static func encode(_ bytes: Data) -> String {
        let text = Array(Base32.encode(bytes, alphabet: alphabet))
        return stride(from: 0, to: text.count, by: 4)
            .map { String(text[$0..<min($0 + 4, text.count)]) }
            .joined(separator: "-")
    }

    public static func decode(_ text: String) -> Data? {
        let cleaned = text.uppercased().compactMap { character -> Character? in
            switch character {
            case " ", "-", "\n", "\t": nil
            case "O": "0"
            case "I", "L": "1"
            default: character
            }
        }
        guard let bytes = Base32.decode(String(cleaned), alphabet: alphabet), bytes.count == 32 else { return nil }
        return bytes
    }
}

/// RFC 4648 base32, lowercase, no padding. Case-insensitive file systems
/// can't confuse two names written this way.
enum Base32 {
    static let standard = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)

    static func encode(_ data: Data, alphabet: [UInt8] = standard) -> String {
        var output = [UInt8]()
        output.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { output.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return String(decoding: output, as: UTF8.self)
    }

    static func decode(_ text: String, alphabet: [UInt8] = standard) -> Data? {
        var values = [UInt8](repeating: 255, count: 256)
        for (index, character) in alphabet.enumerated() { values[Int(character)] = UInt8(index) }
        var output = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for character in text.utf8 {
            let value = values[Int(character)]
            guard value != 255 else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                output.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        // Leftover bits must be the zero padding encode adds.
        guard bits < 5, buffer & ((1 << UInt32(bits)) - 1) == 0 else { return nil }
        return output
    }
}

// MARK: - Names

public extension VaultKeys {
    /// The stored form of a name. Long names come back as a hash, with
    /// `longName` holding what goes in its ".n" file.
    func encryptName(_ name: String) throws -> (stored: String, longName: String?) {
        let plain = Data(name.precomposedStringWithCanonicalMapping.utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: plain, using: nameNonces)
        let nonce = try AES.GCM.Nonce(data: Data(mac).prefix(12))
        guard let combined = try AES.GCM.seal(plain, using: names, nonce: nonce, authenticating: Vault.magic).combined else {
            throw VaultError.damaged
        }
        let encoded = Base32.encode(combined)
        if encoded.count <= Vault.maxStoredName { return (encoded, nil) }
        let hash = Base32.encode(Data(SHA256.hash(data: combined)))
        return (Vault.longNamePrefix + hash, encoded)
    }

    /// A name from its stored form (or, for a long name, its ".n" file's text).
    func decryptName(_ stored: String) throws -> String {
        guard let combined = Base32.decode(stored),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: names, authenticating: Vault.magic),
              let name = String(data: plain, encoding: .utf8)
        else { throw VaultError.damaged }
        return name
    }
}

// MARK: - Contents

public extension VaultKeys {
    /// A new file's header and its file key.
    func newFileHeader() throws -> (header: Data, key: SymmetricKey) {
        let fileKey = SymmetricKey(size: .bits256)
        let bytes = fileKey.withUnsafeBytes { Data($0) }
        guard let sealed = try AES.GCM.seal(bytes, using: content, authenticating: Vault.magic).combined else { throw VaultError.damaged }
        let header = Vault.magic + sealed
        assert(header.count == Vault.headerSize)
        return (header, fileKey)
    }

    /// The file key from a stored file's first 64 bytes.
    func fileKey(fromHeader header: Data) throws -> SymmetricKey {
        let header = Data(header)
        guard header.count >= Vault.headerSize, header.prefix(4) == Vault.magic,
              let box = try? AES.GCM.SealedBox(combined: header.subdata(in: 4..<Vault.headerSize)),
              let bytes = try? AES.GCM.open(box, using: content, authenticating: Vault.magic),
              bytes.count == 32
        else { throw VaultError.damaged }
        return SymmetricKey(data: bytes)
    }

    /// Encrypts a local file into a new local file.
    func encryptFile(at source: URL, to destination: URL) throws {
        let size = Int64((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let chunks = max(1, (size + Int64(Vault.chunkSize) - 1) / Int64(Vault.chunkSize))
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        let (header, key) = try newFileHeader()
        try output.write(contentsOf: header)
        for index in 0..<chunks {
            try autoreleasepool {
                let plain = try input.read(upToCount: Vault.chunkSize) ?? Data()
                try output.write(contentsOf: Vault.sealChunk(plain, index: UInt64(index), last: index == chunks - 1, key: key))
            }
        }
        // Keep the original's date, so uploads keep it (Photo Backup relies on it).
        if let date = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: destination.path)
        }
    }

    /// Decrypts a stored file into a new local file.
    func decryptFile(at source: URL, to destination: URL) throws {
        let size = Int64((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard Vault.plainSize(stored: size) != nil else { throw VaultError.damaged }
        let chunks = (size - Int64(Vault.headerSize) + Int64(Vault.storedChunk) - 1) / Int64(Vault.storedChunk)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        var finished = false
        defer {
            try? input.close()
            try? output.close()
            if !finished { try? FileManager.default.removeItem(at: destination) }
        }
        let key = try fileKey(fromHeader: try input.read(upToCount: Vault.headerSize) ?? Data())
        for index in 0..<chunks {
            try autoreleasepool {
                let stored = try input.read(upToCount: Vault.storedChunk) ?? Data()
                try output.write(contentsOf: Vault.openChunk(stored, index: UInt64(index), last: index == chunks - 1, key: key))
            }
        }
        finished = true
    }

    /// Encrypts data in memory (small files such as ".n" names in tests).
    func encrypt(_ data: Data) throws -> Data {
        let (header, key) = try newFileHeader()
        var output = header
        let chunks = max(1, (data.count + Vault.chunkSize - 1) / Vault.chunkSize)
        for index in 0..<chunks {
            let start = index * Vault.chunkSize
            let piece = data.subdata(in: (data.startIndex + start)..<(data.startIndex + min(start + Vault.chunkSize, data.count)))
            output += try Vault.sealChunk(piece, index: UInt64(index), last: index == chunks - 1, key: key)
        }
        return output
    }

    func decrypt(_ data: Data) throws -> Data {
        let data = Data(data)
        guard let plain = Vault.plainSize(stored: Int64(data.count)) else { throw VaultError.damaged }
        let key = try fileKey(fromHeader: data.prefix(Vault.headerSize))
        return try Vault.openChunks(data.subdata(in: Vault.headerSize..<data.count), first: 0, plainSize: plain, key: key)
    }
}

extension Vault {
    static func nonce(_ index: UInt64) -> AES.GCM.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: index.bigEndian) { bytes.append(contentsOf: $0) }
        return try! AES.GCM.Nonce(data: bytes)
    }

    static func sealChunk(_ plain: Data, index: UInt64, last: Bool, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce(index), authenticating: Data([last ? 1 : 0]))
        return box.ciphertext + box.tag
    }

    static func openChunk(_ stored: Data, index: UInt64, last: Bool, key: SymmetricKey) throws -> Data {
        let stored = Data(stored)
        guard stored.count >= tagSize else { throw VaultError.damaged }
        guard let box = try? AES.GCM.SealedBox(nonce: nonce(index), ciphertext: stored.prefix(stored.count - tagSize), tag: stored.suffix(tagSize)),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Data([last ? 1 : 0]))
        else { throw VaultError.damaged }
        return plain
    }

    /// Decrypts consecutive stored chunks starting at chunk `first`.
    static func openChunks(_ stored: Data, first: Int64, plainSize: Int64, key: SymmetricKey) throws -> Data {
        let stored = Data(stored)
        let lastIndex = max(0, (plainSize + Int64(chunkSize) - 1) / Int64(chunkSize) - 1)
        var output = Data()
        var position = 0
        var index = first
        while position < stored.count {
            let end = min(position + storedChunk, stored.count)
            output += try openChunk(stored.subdata(in: position..<end), index: UInt64(index), last: index == lastIndex, key: key)
            position = end
            index += 1
        }
        return output
    }

    /// Which stored bytes hold plaintext bytes `offset..<offset+length`, and
    /// where they start in the decrypted chunks.
    static func storedRange(offset: Int64, length: Int, plainSize: Int64) -> (firstChunk: Int64, storedOffset: Int64, storedLength: Int, skip: Int, take: Int)? {
        guard offset >= 0, offset < plainSize, length > 0 else { return nil }
        let end = min(offset + Int64(length), plainSize)
        let first = offset / Int64(chunkSize)
        let last = (end - 1) / Int64(chunkSize)
        let storedOffset = Int64(headerSize) + first * Int64(storedChunk)
        let storedEnd = min(Int64(headerSize) + (last + 1) * Int64(storedChunk), storedSize(plain: plainSize))
        return (first, storedOffset, Int(storedEnd - storedOffset), Int(offset - first * Int64(chunkSize)), Int(end - offset))
    }
}
