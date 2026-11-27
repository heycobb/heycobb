# Encrypted folders: file format

Ownhold encrypts files on the device before they reach the NAS and decrypts
them after they're downloaded. This document describes what's stored, so the
format isn't a black box and could be read by other software. The code is in
`Packages/OwnholdKit/Sources/OwnholdKit/Vault.swift` (format) and
`VaultFileService.swift` (how it's used).

Only Apple's built-in cryptography is used: CryptoKit (AES-256-GCM, HKDF,
HMAC-SHA256) and CommonCrypto (PBKDF2). No crypto code is bundled. This
keeps Ownhold in the "encryption within Apple's operating system" case
for export compliance (see the end of this document).

## Layout on the NAS

An encrypted folder is a normal folder holding `ownhold-vault.json` plus
the encrypted items, in the same tree as the plain folders and files
(so renaming or moving a folder is one change on the NAS):

```
Private/                      ← the encrypted folder (its own name isn't encrypted)
  ownhold-vault.json          ← settings: how to unlock
  m5k2…q7a/                   ← an encrypted folder name
    t3p9…x2c                  ← an encrypted file
  _4fz…k1b                    ← a name too long to store: kept under a hash
  _4fz…k1b.n                  ← …and its full encrypted name
```

What the NAS can still see: how many files and folders there are, how
they're nested, their approximate sizes and their dates. Names and contents
are hidden. The same name in two different folders is stored the same way,
so the NAS can tell that two names match (not what they are).

## Keys

- **Master key:** 32 random bytes per encrypted folder.
- **Sub-keys:** HKDF-SHA256 from the master key, with no salt and info
  `ownhold-vault-v1 content`, `ownhold-vault-v1 names` and
  `ownhold-vault-v1 name-nonces`. Each is 32 bytes.
- **Password key:** PBKDF2-HMAC-SHA256 of the password, run on the UTF-8
  of its Unicode NFC form, with a 16-byte random salt. Iterations are
  stored in the file (600,000 for new folders).
- **Recovery key:** 32 random bytes, shown once as 52 characters of
  Crockford base32 (alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`) in groups
  of four. On input, case is ignored, spaces and dashes are skipped, O
  reads as 0, and I or L read as 1.

The master key is sealed twice with AES-256-GCM, each copy stored as
`nonce ‖ ciphertext ‖ tag` (12 + 32 + 16 bytes):

- with the password key, AAD `ownhold-vault-v1 password <id>`;
- with the recovery key, AAD `ownhold-vault-v1 recovery <id>`.

`<id>` is the folder's UUID in uppercase, as stored.

Changing the password re-seals the master key with a new salt and
re-writes `ownhold-vault.json`. Files don't change.

## ownhold-vault.json

```json
{
  "format": "ownhold-vault",
  "version": 1,
  "id": "UUID",
  "kdf": { "name": "PBKDF2-HMAC-SHA256", "iterations": 600000, "salt": "base64" },
  "passwordKey": "base64",
  "recoveryKey": "base64"
}
```

## Names

1. `n` = UTF-8 of the name in NFC.
2. `nonce` = the first 12 bytes of HMAC-SHA256(name-nonces key, n).
3. `sealed` = AES-256-GCM(names key, nonce, n, AAD `OHV1`), stored as
   `nonce ‖ ciphertext ‖ tag`.
4. The stored name is lowercase RFC 4648 base32 of `sealed`, with no padding.

Taking the nonce from the name (a synthetic IV) makes the stored name the
same every time, so a path can be found without listing every folder.
Different names get different nonces.

If the stored name would be longer than 200 characters, the item is stored
as `_` followed by base32(SHA-256(sealed)). The full base32 name is kept in
a file next to it with `.n` added to the name. `_` and `.` never appear in
base32, so these can't be confused with ordinary stored names.

## Files

```
header (64 bytes)  = "OHV1" ‖ AES-GCM(content key, random nonce, file key, AAD "OHV1")
chunk i            = AES-GCM(file key, nonce = 0x00000000 ‖ i as UInt64 big-endian,
                             plaintext[i·65536 ..< (i+1)·65536],
                             AAD = 0x01 for the last chunk, 0x00 otherwise)
                     stored as ciphertext ‖ tag (no nonce)
```

- Every file has a new random 32-byte file key. A nonce made from the
  chunk index is therefore never reused.
- An empty file still has one (empty) last chunk.
- Changing, reordering or cutting off chunks makes decryption fail.

Sizes follow from the stored size alone:

```
body   = stored − 64
chunks = ceil(body / 65552)
plain  = body − 16 · chunks
```

Reading a range from a stored file needs only the header and the chunks
that cover the range. That's how video seeks without downloading the whole
file.

## On the device

Unlocked keys stay in memory. "Keep Unlocked on This Device" puts the master
key in the Keychain (this device only, never synced). Folders not kept
unlocked lock when Ownhold quits, and also when the app lock engages.
Thumbnails of encrypted files are kept in memory only, never in the
thumbnail cache on disk.

Offline copies, previews and Recents work as they do for other files. They
are decrypted copies, protected by the device's own encryption.

## Export compliance (checklist for release)

- Only OS-provided cryptography (CryptoKit, CommonCrypto). Don't add a
  crypto library.
- US: mass-market encryption software, self-classified 5D992.c. Under BIS's
  current rules no annual self-classification report is needed for a
  finished product like this one. Check again before release.
- App Store Connect: answer the encryption questions for the first build
  with encrypted folders, then set `ITSAppUsesNonExemptEncryption` (and
  `ITSEncryptionExportComplianceCode` if one is given) in `Config/Info.plist`
  as App Store Connect says. **It's `false` today, which was right before
  this feature: revisit before shipping it.**
- France: per Apple's documentation, apps using only the OS's encryption
  need no documents. Confirm in App Store Connect.
