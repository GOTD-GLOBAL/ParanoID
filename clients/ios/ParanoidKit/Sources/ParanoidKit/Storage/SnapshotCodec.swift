import CryptoKit
import Foundation

/// Why one snapshot codec operation failed.
///
/// Android collapses all three into `GeneralSecurityException`
/// (`SnapshotCodec.java:18,29,33`); on iOS they stay apart so a caller can
/// tell a refused input from a refused box, while still catching one type.
public enum SnapshotCodecError: Error, Equatable, Sendable {
    /// `seal` was handed more than 8 MiB of UTF-8 (`SnapshotCodec.java:18`).
    case snapshotLimit
    /// `open` was handed something that is not a version-1 snapshot: fewer
    /// than 29 bytes, more than 8 MiB + 29 bytes, or a leading byte other
    /// than `0x01` (`SnapshotCodec.java:29`). Nothing was decrypted.
    case invalidSnapshot
    /// AES-GCM refused the box: a wrong key, or a tampered nonce, ciphertext
    /// or tag. This is Android's `AEADBadTagException` out of
    /// `Cipher.doFinal` (`SnapshotCodec.java:33`).
    case authenticationFailure
}

/// Standard AES-GCM storage encryption, byte for byte the format of
/// `clients/android/src/org/paranoid/text/SnapshotCodec.java:13-37`.
///
/// A sealed snapshot is
///
/// ```text
/// byte 0        0x01          format version, also the AES-GCM associated data
/// bytes 1..12   nonce         12 random bytes, one per seal
/// bytes 13..    ciphertext    AES-256-GCM of the UTF-8 plaintext
/// last 16 bytes tag           128-bit GCM tag
/// ```
///
/// so the smallest snapshot is 29 bytes (empty plaintext) and the largest is
/// 8 MiB + 29. The version byte is fed to the cipher as associated data
/// (`updateAAD(VERSION)`, `SnapshotCodec.java:21,32`), which is what binds the
/// header to the box: flipping it to `0x02` is refused by the length/version
/// check, and a snapshot sealed under any other associated data fails
/// authentication.
///
/// This type is only the codec. The key belongs to the storage adapter — on
/// Android the Keystore alias `paranoid-text-state-v0`
/// (`TextEngine.java:208-218`, 256-bit, GCM), on iOS the Keychain item of the
/// same name — and the at-rest file rules (temp file, `F_FULLFSYNC`,
/// `rename`, byte-exact read-back) belong to the file layer. Raw snapshots
/// hold private keys and plaintext: never log a snapshot, sealed or open.
public enum SnapshotCodec {
    /// Largest plaintext `seal` accepts, in UTF-8 bytes: 8 MiB, the `MAX` of
    /// `SnapshotCodec.java:13` and the core's own state limit.
    public static let maximumPlaintextBytes = 8 * 1024 * 1024
    /// The one format version this codec writes and reads.
    public static let version: UInt8 = 1
    /// AES-GCM nonce length. Android refuses any other length outright
    /// (`SnapshotCodec.java:23`); CryptoKit only ever produces 12.
    public static let nonceBytes = 12
    /// AES-GCM tag length: 128 bits, the `GCMParameterSpec(128, ...)` of
    /// `SnapshotCodec.java:31`.
    public static let tagBytes = 16
    /// Version byte plus nonce, the fixed prefix before the ciphertext.
    public static let headerBytes = 1 + nonceBytes
    /// Smallest well-formed snapshot: header plus tag, an empty plaintext.
    public static let minimumSnapshotBytes = headerBytes + tagBytes
    /// Largest well-formed snapshot: `maximumPlaintextBytes` plus the
    /// header and the tag, the `MAX + 29` bound of `SnapshotCodec.java:29`.
    public static let maximumSnapshotBytes = maximumPlaintextBytes + minimumSnapshotBytes

    /// The associated data of every box: the single version byte.
    private static let associatedData = Data([version])

    /// Seals `value` under `key` into `[0x01][nonce][ciphertext‖tag]`.
    ///
    /// The nonce is fresh per call (`AES.GCM.Nonce()`), so two seals of the
    /// same text under the same key never match — the property
    /// `StorageSmoke.java:12` asserts.
    ///
    /// - Throws: `SnapshotCodecError.snapshotLimit` when the UTF-8 of `value`
    ///   is longer than 8 MiB. A CryptoKit failure, which a 12-byte nonce and
    ///   an AES key size make unreachable, propagates unchanged.
    public static func seal(key: SymmetricKey, value: String) throws -> Data {
        var plaintext = Data(value.utf8)
        // Android wipes its plaintext copy (`SnapshotCodec.java:25`); so do
        // we, with the same caveat that intermediate String storage cannot be
        // promised zeroized.
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        guard plaintext.count <= maximumPlaintextBytes else {
            throw SnapshotCodecError.snapshotLimit
        }
        let box = try AES.GCM.seal(plaintext,
                                   using: key,
                                   nonce: AES.GCM.Nonce(),
                                   authenticating: associatedData)
        var snapshot = Data(capacity: headerBytes + box.ciphertext.count + tagBytes)
        snapshot.append(version)
        snapshot.append(contentsOf: box.nonce)
        snapshot.append(box.ciphertext)
        snapshot.append(box.tag)
        return snapshot
    }

    /// Opens a snapshot written by `seal` (or by the Android codec) under
    /// `key`.
    ///
    /// The length and version checks run before any crypto, exactly as
    /// `SnapshotCodec.java:29` does. The plaintext is decoded like Java's
    /// `new String(bytes, UTF_8)`: malformed sequences become U+FFFD rather
    /// than an error, which authentication has already made unreachable for
    /// anything this codec sealed.
    ///
    /// - Throws: `SnapshotCodecError.invalidSnapshot` for a length or version
    ///   the format does not allow, `SnapshotCodecError.authenticationFailure`
    ///   when AES-GCM refuses the box.
    public static func open(key: SymmetricKey, value: Data) throws -> String {
        guard value.count >= minimumSnapshotBytes,
              value.count <= maximumSnapshotBytes,
              value.first == version else {
            throw SnapshotCodecError.invalidSnapshot
        }
        // `value` may be a slice, so every bound is taken from its own indices.
        let nonce = value[value.startIndex + 1..<value.startIndex + headerBytes]
        let tagStart = value.endIndex - tagBytes
        let ciphertext = value[value.startIndex + headerBytes..<tagStart]
        let tag = value[tagStart..<value.endIndex]
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: ciphertext,
                                            tag: tag)
            var plaintext = try AES.GCM.open(box, using: key, authenticating: associatedData)
            defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
            return String(decoding: plaintext, as: UTF8.self)
        } catch {
            // The nonce and tag lengths are guaranteed by the checks above, so
            // the only reachable failure is a refused box.
            throw SnapshotCodecError.authenticationFailure
        }
    }
}
