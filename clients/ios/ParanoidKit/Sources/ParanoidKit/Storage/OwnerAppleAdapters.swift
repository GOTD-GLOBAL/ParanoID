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

    /// Only this file builds policy values: the canonical constant below and
    /// the readback of an existing item. No caller can construct a weaker one.
    fileprivate init(accessible: String, synchronizable: Bool) {
        self.accessible = accessible
        self.synchronizable = synchronizable
    }

    /// The only policy the owner store accepts.
    public static let whenUnlockedThisDeviceOnly = OwnerKeyPolicy(
        accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String, synchronizable: false)

    /// FIXTURE-ONLY: the messaging policy a legacy `KeychainKey` item carries,
    /// for host tests that prove a weaker retained item is refused. Not a
    /// policy the owner store ever writes.
    static let fixtureWeakMessagingPolicy = OwnerKeyPolicy(
        accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, synchronizable: false)
}

/// A key backend that enforces the canonical owner policy on the items it
/// creates and reads back their stored policy. `OwnerKeychainKey` conforms; the
/// messaging `KeychainKey` does not and must not: adopting `WrappingKeyStore`
/// alone never qualifies a backend for the owner store. Host memory fixtures
/// may conform behind a deliberately labelled FIXTURE-ONLY seam; they report a
/// descriptor, not enforcement.
public protocol OwnerKeyBackend: WrappingKeyStore {
    /// The policy attributes of the retained item, or nil when there is none.
    func storedPolicy() throws -> OwnerKeyPolicy?
}

/// The owner wrapping key in the Keychain, under its own account and the owner
/// policy. Separate from the messaging `KeychainKey`, whose
/// `AfterFirstUnlockThisDeviceOnly` default stays untouched; changing that type's
/// account would not change its policy, so the owner store does not use it.
///
/// - `load()` never creates; a read refused because the device is locked
///   (`errSecInteractionNotAllowed`) is reported as `OwnerBackendLock.locked`,
///   every other status as `StorageError.keychain`. Errors are never absence.
///   A retained item whose stored attributes are not the canonical owner
///   policy (for example a legacy messaging item under this account) is
///   refused — not used, not deleted, not migrated.
/// - `create()` adds the item with the canonical policy and reads its
///   attributes back; a duplicate (`errSecDuplicateItem`) is refused, never
///   replaced. There is no way to ask this type for another policy.
/// - `deleteRetained()` refuses: the owner store never deletes a retained key.
///   Test teardown removes its own unique test account directly.
public struct OwnerKeychainKey: OwnerKeyBackend, Sendable {
    public static let keyBytes = 32
    /// The one policy this backend writes and accepts.
    public static let policy = OwnerKeyPolicy.whenUnlockedThisDeviceOnly
    public let account: String

    /// No default account: the caller names the owner namespace explicitly.
    /// No policy parameter: the canonical policy is not configurable.
    public init(account: String) {
        self.account = account
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
            // The bytes alone are not the owner key: the item must carry the
            // canonical policy. A weaker retained item is refused and left alone.
            guard try storedPolicy() == Self.policy else { throw StorageError.keychain(errSecDecode) }
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
        attributes[kSecAttrAccessible as String] = Self.policy.accessible
        attributes[kSecAttrSynchronizable as String] = Self.policy.synchronizable
        attributes[kSecValueData as String] = material
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
        // Insertion is not enforcement: read the policy back from the store
        // and refuse an item the Keychain filed under another class.
        guard try storedPolicy() == Self.policy else { throw StorageError.keychain(errSecDecode) }
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
    private let protectedDataAvailable: @Sendable () -> Bool

    /// No default argument for the backend: the caller names it, as it names
    /// the root. Without a protected-data signal nothing is ever classified as
    /// a lock: every permission error is a failure the store freezes on.
    init(fileSystem: any FileSystem) {
        self.init(fileSystem: fileSystem, syscalls: .darwin, protectedDataAvailable: { true })
    }

    /// `protectedDataAvailable` is the platform's own statement whether
    /// protected files can be opened right now (the application passes
    /// `UIApplication.shared.isProtectedDataAvailable`, read on the main thread
    /// at the moment of the failure). It is the only evidence that turns an
    /// `EPERM` into a retryable lock; a test may inject it and must label that.
    init(fileSystem: any FileSystem, protectedDataAvailable: @escaping @Sendable () -> Bool) {
        self.init(fileSystem: fileSystem, syscalls: .darwin, protectedDataAvailable: protectedDataAvailable)
    }

    init(fileSystem: any FileSystem, syscalls: CatalogueAppleSyscalls,
         protectedDataAvailable: @escaping @Sendable () -> Bool = { true }) {
        self.fileSystem = fileSystem
        self.inner = CatalogueAppleFileIO(fileSystem: fileSystem, syscalls: syscalls)
        self.syscalls = syscalls
        self.protectedDataAvailable = protectedDataAvailable
    }

    func inspect(_ url: URL) throws -> CataloguePathKind { try inner.inspect(url) }
    func writeExclusive(_ bytes: Data, to url: URL) throws { try inner.writeExclusive(bytes, to: url) }
    func protectAndExclude(_ url: URL) throws { try inner.protectAndExclude(url) }
    func fullSync(_ url: URL, directory: Bool) throws { try inner.fullSync(url, directory: directory) }
    func rename(_ source: URL, to destination: URL) throws { try inner.rename(source, to: destination) }
    func removeIntent(_ url: URL) throws { try inner.removeIntent(url) }

    /// The bounded catalogue read, with exactly one classified exception. A
    /// `.complete`-protected owner file that the kernel refuses while protected
    /// data is unavailable fails `open(2)` with `EPERM`; that is reported as
    /// `OwnerBackendLock.locked`, so the coordinator may retry a read-only open
    /// after unlock, only when all of the following hold:
    ///
    /// 1. the failure came from the `open(2)` syscall itself — not from the
    ///    inspection before it, not from the `fstat`/inode confirmation that
    ///    follows it, not from the descriptor read;
    /// 2. the path is the owner state file `owner/state.enc` of the leased
    ///    root — the catalogue (messaging class) and every other path freeze;
    /// 3. `errno` is `EPERM` — `EACCES` and anything else are failures;
    /// 4. the platform reports protected data unavailable at that moment
    ///    (`protectedDataAvailable()` is `false`) — positive evidence, sampled
    ///    after the failure; the error code alone is never that evidence.
    ///
    /// Everything else propagates as the ordinary adapter failure and the store
    /// freezes on it. Without a protected-data signal nothing is ever a lock.
    func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let inspected = try inner.inspectRegular(url, maximumBytes: maximumBytes)
        let descriptor: Int32
        do {
            // The catch spans the open syscall alone: `fstat`, inode
            // confirmation and the descriptor read run outside it below.
            descriptor = try inner.openOnly(url)
        } catch let error as CatalogueAppleAdapterError
            where error.operation == .read && error.code == Int(EPERM) && Self.isOwnerStateFile(url) {
            if !protectedDataAvailable() { throw OwnerBackendLock.locked }
            throw error
        }
        defer { _ = syscalls.close(descriptor) }
        try inner.confirmOpened(descriptor, url: url, inspected: inspected)
        return try inner.readBounded(descriptor, url: url, inspected: inspected, maximumBytes: maximumBytes)
    }

    /// The owner store's one readable file, by the fixed layout of the format
    /// contract (§5): `<root>/owner/state.enc`. Candidates, intents and the
    /// catalogue are never classified.
    static func isOwnerStateFile(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return standardized.lastPathComponent == "state.enc"
            && standardized.deletingLastPathComponent().lastPathComponent == "owner"
    }

    /// `mkdir(2)` with mode 0700: the final component is never followed, so an
    /// existing link, file or directory of any kind is refused (`EEXIST`) and
    /// left untouched. The new directory is then opened `O_DIRECTORY|O_NOFOLLOW`
    /// and its mode confirmed, pinning it with `fchmod` if it differs from 0700
    /// (a umask only ever removes bits; the check is defensive, not a widening).
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
    private let owner: any OwnerKeyBackend

    /// Only an owner-policy backend is admitted: `OwnerKeychainKey` in
    /// production, a labelled FIXTURE-ONLY memory key in host tests. The
    /// messaging `KeychainKey` is not an `OwnerKeyBackend` and does not type
    /// check here, whatever account it carries. No default and no key export.
    init(owner: any OwnerKeyBackend) {
        self.owner = owner
    }

    var framingOverhead: Int { SnapshotCodec.headerBytes + SnapshotCodec.tagBytes }

    /// `load()` never creates; a locked backend surfaces as `OwnerBackendLock`.
    /// A retained item whose stored policy is not the canonical owner policy is
    /// refused before any use — never deleted, migrated or replaced.
    func loadKey() throws -> SymmetricKey? {
        guard let key = try owner.load() else { return nil }
        try requireCanonicalPolicy()
        return key
    }

    /// Create-only by the backend's contract; never replaces a retained key.
    /// The created item is read back and must carry the canonical policy.
    func createKey() throws -> SymmetricKey {
        let key = try owner.create()
        try requireCanonicalPolicy()
        return key
    }

    private func requireCanonicalPolicy() throws {
        guard try owner.storedPolicy() == .whenUnlockedThisDeviceOnly else {
            throw CatalogueAppleAdapterError(.key, nil, code: Int(EACCES), reason: "retained owner key is not under the owner policy")
        }
    }
    func foreignKeyExists(_ slot: CatalogueForeignStore) throws -> Bool {
        throw CatalogueAppleAdapterError(.open, nil, code: Int(EINVAL), reason: "the owner store has no foreign key namespaces")
    }
    func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data { try AppleFramedBox.seal(plaintext, with: key) }
    func open(_ sealed: Data, with key: SymmetricKey) throws -> Data { try AppleFramedBox.open(sealed, with: key) }
}
