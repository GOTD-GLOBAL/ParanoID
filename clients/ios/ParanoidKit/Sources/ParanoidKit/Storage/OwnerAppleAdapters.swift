import CryptoKit
import Foundation
import Security

/// The owner key policy, as a value the backends are asked to enforce and the
/// tests read back: `WhenUnlockedThisDeviceOnly`, never synchronizable. It is
/// not a conformance badge; `OwnerKeychainKey.create()` refuses an item whose
/// stored attributes do not read back as this policy.
public struct OwnerKeyPolicy: Equatable, Sendable {
    public let accessible: String
    public let synchronizable: Bool

    /// The only policy the owner store accepts.
    public static let whenUnlockedThisDeviceOnly = OwnerKeyPolicy(
        accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String, synchronizable: false)
}

/// The owner wrapping key in the Keychain, under its own account and the owner
/// policy. Separate from the messaging `KeychainKey`, whose
/// `AfterFirstUnlockThisDeviceOnly` default stays untouched; changing that type's
/// account would not change its policy, so the owner store does not use it.
///
/// - `load()` never creates; a read refused because the device is locked
///   (`errSecInteractionNotAllowed`) is reported as `OwnerBackendLock.locked`,
///   every other status as `StorageError.keychain`. Errors are never absence.
/// - `create()` adds the item with the owner policy and reads its attributes
///   back; a duplicate (`errSecDuplicateItem`) is refused, never replaced.
/// - `deleteRetained()` refuses: the owner store never deletes a retained key.
///   Test teardown removes its own unique test account directly.
public struct OwnerKeychainKey: WrappingKeyStore, Sendable {
    public static let keyBytes = 32
    public let account: String
    public let policy: OwnerKeyPolicy

    /// No default account: the caller names the owner namespace explicitly.
    public init(account: String, policy: OwnerKeyPolicy = .whenUnlockedThisDeviceOnly) {
        self.account = account
        self.policy = policy
    }

    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func exists() throws -> Bool {
        var query = identity
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        case errSecInteractionNotAllowed: throw OwnerBackendLock.locked
        case let status: throw StorageError.keychain(status)
        }
    }

    public func load() throws -> SymmetricKey? {
        var query = identity
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard var material = item as? Data, material.count == Self.keyBytes else {
                throw StorageError.keychain(errSecDecode)
            }
            defer { material.resetBytes(in: material.startIndex..<material.endIndex) }
            return SymmetricKey(data: material)
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw OwnerBackendLock.locked
        case let status:
            throw StorageError.keychain(status)
        }
    }

    /// The stored policy attributes, or nil when there is no item.
    public func storedPolicy() throws -> OwnerKeyPolicy? {
        var query = identity
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let attributes = item as? [String: Any],
                  let accessible = attributes[kSecAttrAccessible as String] as? String else {
                throw StorageError.keychain(errSecDecode)
            }
            let synchronizable = (attributes[kSecAttrSynchronizable as String] as? Bool)
                ?? ((attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false)
            return OwnerKeyPolicy(accessible: accessible, synchronizable: synchronizable)
        case errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            throw OwnerBackendLock.locked
        case let status:
            throw StorageError.keychain(status)
        }
    }

    public func create() throws -> SymmetricKey {
        var material = Data(count: Self.keyBytes)
        let generated = material.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let address = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, Self.keyBytes, address)
        }
        guard generated == errSecSuccess else { throw StorageError.keychain(generated) }
        defer { material.resetBytes(in: material.startIndex..<material.endIndex) }
        var attributes = identity
        attributes[kSecAttrAccessible as String] = policy.accessible
        attributes[kSecAttrSynchronizable as String] = policy.synchronizable
        attributes[kSecValueData as String] = material
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
        // Insertion is not enforcement: read the policy back from the store
        // and refuse an item the Keychain filed under another class.
        guard try storedPolicy() == policy else { throw StorageError.keychain(errSecDecode) }
        return SymmetricKey(data: material)
    }

    /// The owner store never deletes a retained key; this backend has no such
    /// operation. Tests remove their own unique accounts themselves.
    public func deleteRetained() throws {
        throw StorageError.keychain(errSecNotAvailable)
    }
}

/// `OwnerFileIO` over the real Apple file system. Proposed, non-adopted
/// (RFC-0030 / draft ADR-0017). The seven catalogue operations are the already
/// tested `CatalogueAppleFileIO`; the owner additions are the create-only,
/// no-follow `owner/` directory and the owner protection class read back on
/// the inode. Nothing here deletes, repairs or recreates anything.
struct OwnerAppleFileIO: OwnerFileIO {
    private let fileSystem: any FileSystem
    private let inner: CatalogueAppleFileIO
    private let syscalls: CatalogueAppleSyscalls

    /// No default argument: the caller names the backend, as it names the root.
    init(fileSystem: any FileSystem) {
        self.init(fileSystem: fileSystem, syscalls: .darwin)
    }

    init(fileSystem: any FileSystem, syscalls: CatalogueAppleSyscalls) {
        self.fileSystem = fileSystem
        self.inner = CatalogueAppleFileIO(fileSystem: fileSystem, syscalls: syscalls)
        self.syscalls = syscalls
    }

    func inspect(_ url: URL) throws -> CataloguePathKind { try inner.inspect(url) }
    func writeExclusive(_ bytes: Data, to url: URL) throws { try inner.writeExclusive(bytes, to: url) }
    func protectAndExclude(_ url: URL) throws { try inner.protectAndExclude(url) }
    func fullSync(_ url: URL, directory: Bool) throws { try inner.fullSync(url, directory: directory) }
    func rename(_ source: URL, to destination: URL) throws { try inner.rename(source, to: destination) }
    func removeIntent(_ url: URL) throws { try inner.removeIntent(url) }

    /// The bounded catalogue read. On iOS a `.complete`-protected file that the
    /// kernel refuses while the device is locked fails `open(2)` with `EPERM`;
    /// that precise condition is reported as `OwnerBackendLock.locked` so the
    /// coordinator may retry a read-only open later. `EACCES` and every other
    /// error stay failures. The host has no Data Protection, so no mapping.
    func read(_ url: URL, maximumBytes: Int) throws -> Data {
        do { return try inner.read(url, maximumBytes: maximumBytes) }
        catch let error as CatalogueAppleAdapterError {
            #if os(iOS)
            if error.operation == .read, error.code == Int(EPERM) { throw OwnerBackendLock.locked }
            #endif
            throw error
        }
    }

    /// `mkdir(2)` with mode 0700: the final component is never followed, so an
    /// existing link, file or directory of any kind is refused (`EEXIST`) and
    /// left untouched. The new directory is then opened `O_DIRECTORY|O_NOFOLLOW`
    /// and its mode pinned with `fchmod` in case the umask widened it.
    func createOwnerDirectory(_ url: URL) throws {
        let (made, code) = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, EINVAL) }
            return (syscalls.mkdir(path, 0o700), errno)
        }
        guard made == 0 else { throw CatalogueAppleAdapterError(.create, url, errno: code) }
        let (descriptor, openCode) = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else { return (-1, EINVAL) }
            return (syscalls.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0), errno)
        }
        guard descriptor >= 0 else { throw CatalogueAppleAdapterError(.create, url, errno: openCode) }
        defer { _ = syscalls.close(descriptor) }
        var information = stat()
        guard syscalls.fstat(descriptor, &information) == 0 else {
            throw CatalogueAppleAdapterError(.create, url, errno: errno)
        }
        guard (information.st_mode & S_IFMT) == S_IFDIR else {
            throw CatalogueAppleAdapterError(.create, url, code: Int(ENOTDIR), reason: "owner path is not a directory")
        }
        if information.st_mode & 0o777 != 0o700 {
            guard syscalls.fchmod(descriptor, 0o700) == 0 else {
                throw CatalogueAppleAdapterError(.create, url, errno: errno)
            }
        }
    }

    /// Owner protection on this inode, read back: Data Protection `.complete`
    /// (iOS only; the macOS host has no such attribute) and backup exclusion.
    /// The path is inspected without following first: a link or foreign inode
    /// is refused, never protected through.
    func protectOwnerAndExclude(_ url: URL, policy: OwnerProtection) throws {
        switch try inner.inspect(url) {
        case .regularFile, .directory: break
        case .absent: throw CatalogueAppleAdapterError(.protect, url, errno: ENOENT)
        case .other: throw CatalogueAppleAdapterError(.protect, url, code: Int(EFTYPE), reason: "not a regular file or directory")
        }
        switch policy {
        case .ownerComplete:
            #if os(iOS)
            do {
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
                let stored = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
                guard stored == .complete else {
                    throw CatalogueAppleAdapterError(.protect, url, code: Int(EIO), reason: "protection class did not stick")
                }
            } catch let error as CatalogueAppleAdapterError {
                throw error
            } catch {
                throw CatalogueAppleAdapterError(.protect, url, underlying: error)
            }
            #endif
        }
        do {
            try fileSystem.excludeFromBackup(at: url)
            guard try fileSystem.isExcludedFromBackup(at: url) else {
                throw CatalogueAppleAdapterError(.protect, url, code: Int(EIO), reason: "backup exclusion did not stick")
            }
        } catch let error as CatalogueAppleAdapterError {
            throw error
        } catch {
            throw CatalogueAppleAdapterError(.protect, url, underlying: error)
        }
    }
}

/// `OwnerCryptography` over the shipped version-1 AES-GCM framing and one
/// explicit opaque owner key namespace. Proposed, non-adopted. The owner store
/// has no foreign namespaces of its own; those belong to the catalogue adapter.
struct OwnerAppleCryptography: OwnerCryptography {
    typealias Key = SymmetricKey
    private let owner: any WrappingKeyStore

    /// Explicit owner backend only — `OwnerKeychainKey` in production, an
    /// in-memory key in host tests. No default account and no key export.
    init(owner: any WrappingKeyStore) {
        self.owner = owner
    }

    var framingOverhead: Int { SnapshotCodec.headerBytes + SnapshotCodec.tagBytes }
    /// `load()` never creates; a locked backend surfaces as `OwnerBackendLock`.
    func loadKey() throws -> SymmetricKey? { try owner.load() }
    /// Create-only by the backend's contract; never replaces a retained key.
    func createKey() throws -> SymmetricKey { try owner.create() }
    func foreignKeyExists(_ slot: CatalogueForeignStore) throws -> Bool {
        throw CatalogueAppleAdapterError(.open, nil, code: Int(EINVAL), reason: "the owner store has no foreign key namespaces")
    }
    func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data { try AppleFramedBox.seal(plaintext, with: key) }
    func open(_ sealed: Data, with key: SymmetricKey) throws -> Data { try AppleFramedBox.open(sealed, with: key) }
}
