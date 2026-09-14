import CryptoKit
import Foundation
import Security

/// The two questions `StorageGuard.start(...)` asks about the retained
/// wrapping key.
///
/// It is the seam `FileSystem` is for the commit: the Keychain answers only
/// inside an application that owns a keychain group, so the startup rule can
/// be driven over a real Keychain on the simulator
/// (`App/ParanoIDTests/KeychainStoreTests.swift`) and over a stand-in on the
/// host, where `SecItemCopyMatching` refuses an unsigned test binary with
/// `errSecMissingEntitlement` before any rule is reached.
public protocol RetainedKey {
    /// Whether the item is there, without copying the key material out.
    func exists() throws -> Bool
    /// Removes the item of a previous installation.
    func deleteRetained() throws
}

/// The AES-256 wrapping key of `text-state.enc`, held in the Keychain.
///
/// It is the iOS counterpart of the Android Keystore alias
/// (`StorageGuard.java:5`, `TextEngine.java:208-218`) and keeps the same
/// identity, `paranoid-text-state-v0`, so that the two clients describe the
/// same thing. What differs is the platform: a Keystore alias dies with the
/// application, a Keychain item does not, which is what `InstallMarker`
/// exists for.
///
/// The item is a generic password holding 32 raw bytes:
///
/// - `kSecAttrAccount` = `paranoid-text-state-v0`, and no service attribute,
///   so that the account alone addresses it — the same query that deletes a
///   stale key;
/// - `kSecAttrAccessible` = `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
///   because the state file uses the matching data protection class and the
///   application must reopen its state after a reboot without the user
///   unlocking first, while `ThisDeviceOnly` keeps the key out of every
///   backup and off every other device;
/// - `kSecAttrSynchronizable` = `false`: never iCloud Keychain.
///
/// The key is created once and never regenerated over an existing state file.
public struct KeychainKey: RetainedKey, Sendable {
    /// The one account this client uses, unchanged from Android.
    public static let account = "paranoid-text-state-v0"
    /// AES-256.
    public static let keyBytes = 32
    /// The key of the running application.
    public static let standard = KeychainKey()

    /// The `kSecAttrAccount` of the item.
    public let account: String

    /// - Parameter account: the account to address. The default is the only
    ///   one the application uses; a test may name another to stay out of its
    ///   way.
    public init(account: String = KeychainKey.account) {
        self.account = account
    }

    /// Class and account: what identifies the item in every call below.
    ///
    /// `kSecUseDataProtectionKeychain` asks for the iOS-style keychain
    /// explicitly, so that the same code means the same thing when these types
    /// are compiled for the macOS host test runner.
    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Whether the item is present, without copying the key material out.
    ///
    /// - Throws: `StorageError.keychain` for any status other than found or
    ///   not found. An unreadable Keychain is never reported as "absent",
    ///   because absent means "delete the file and start over".
    public func exists() throws -> Bool {
        var query = identity
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw StorageError.keychain(status)
        }
    }

    /// Copies the key out, or returns `nil` when there is no item.
    ///
    /// - Throws: `StorageError.keychain`, including for an item whose length
    ///   is not 32 bytes — something this client never wrote.
    public func load() throws -> SymmetricKey? {
        var query = identity
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard var material = item as? Data, material.count == Self.keyBytes else {
                throw StorageError.keychain(errSecDecode)
            }
            defer { material.resetBytes(in: material.startIndex..<material.endIndex) }
            return SymmetricKey(data: material)
        case errSecItemNotFound:
            return nil
        default:
            throw StorageError.keychain(status)
        }
    }

    /// Generates and stores a new key.
    ///
    /// Adding an item that already exists is refused by the Keychain
    /// (`errSecDuplicateItem`) and reported, rather than overwritten: a second
    /// key would make every committed snapshot unreadable.
    ///
    /// - Throws: `StorageError.keychain`.
    public func create() throws -> SymmetricKey {
        var material = Data(count: Self.keyBytes)
        let generated = material.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let address = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, Self.keyBytes, address)
        }
        guard generated == errSecSuccess else { throw StorageError.keychain(generated) }
        // Best effort, with the same caveat as `SnapshotCodec.seal`: the copy
        // `Security` takes out of the query dictionary is not ours to wipe,
        // and `Data` is copy-on-write, so this clears the local buffer only.
        defer { material.resetBytes(in: material.startIndex..<material.endIndex) }

        var attributes = identity
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        attributes[kSecValueData as String] = material
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
        return SymmetricKey(data: material)
    }

    /// Returns the stored key, creating one only when there is no state file
    /// to make unreadable.
    ///
    /// This is `TextEngine.java:206-218` line for line: a missing key with a
    /// snapshot present is "key missing; do not regenerate", which here is
    /// `StorageError.frozen`. `StorageGuard.start(...)` has already decided
    /// the same thing; the check is repeated at the point of creation so that
    /// no later caller can reach a regeneration by skipping the guard.
    ///
    /// - Throws: `StorageError.frozen`, `StorageError.keychain`.
    public func loadOrCreate(snapshotExists: Bool) throws -> SymmetricKey {
        if let existing = try load() { return existing }
        guard !snapshotExists else { throw StorageError.frozen }
        return try create()
    }

    /// Deletes the item, if any.
    ///
    /// Called on a first launch of a container whose Keychain may still hold
    /// the key of a previous installation. `errSecItemNotFound` is the normal
    /// outcome and is success. The query adds
    /// `kSecAttrSynchronizable = kSecAttrSynchronizableAny` so that the wipe
    /// covers a synchronizable leftover this client would never create but
    /// could inherit; everything else it would find under this account is its
    /// own.
    ///
    /// - Throws: `StorageError.keychain` — a wipe that failed must not be
    ///   followed by recording the install marker.
    public func deleteRetained() throws {
        var query = identity
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StorageError.keychain(status)
        }
    }
}
