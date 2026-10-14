import Foundation

/// Exclusive caller-owned lease over one isolated root and its four key
/// namespaces. Exactly one holder at a time; handles of a retired holder fail
/// before any backend call. Not a multiprocess or filesystem lock.
final class OwnerNamespaceLease {
    final class Holder { fileprivate init() {} }
    let root: URL
    private(set) var holder: Holder?
    private var coordinator: UUID?
    init(root: URL) { self.root = root }
    /// Fails while another holder is live: quiesce and retire it first.
    func acquire() throws -> Holder {
        guard holder == nil else { throw OwnerStoreError.busy }
        let h = Holder(); holder = h; return h
    }
    /// Revokes every handle bound to this holder; idempotent for a stale one.
    func retire(_ holder: Holder) { if self.holder === holder { self.holder = nil; coordinator = nil } }
    func close(_ holder: Holder, coordinator id: UUID) {
        if self.holder === holder, coordinator == nil || coordinator == id { retire(holder) }
    }
    func claim(_ holder: Holder, coordinator id: UUID) throws {
        guard self.holder === holder else { throw OwnerStoreError.backendFailure }
        guard coordinator == nil || coordinator == id else { throw OwnerStoreError.authorityRequired }
        coordinator = id
    }
    func validate(_ holder: Holder, coordinator id: UUID) throws {
        guard self.holder === holder, coordinator == id else { throw OwnerStoreError.backendFailure }
    }
    fileprivate func check(_ holder: Holder, _ url: URL? = nil, coordinator id: UUID?) throws {
        guard coordinator == id else { throw OwnerStoreError.backendFailure }
        guard self.holder === holder else { throw OwnerStoreError.backendFailure }
        if let url, url.standardizedFileURL.path != root.standardizedFileURL.path,
           !url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") { throw OwnerStoreError.backendFailure }
    }
}
/// Lease-enforcing wrapper: the inner backend is reached only while this
/// holder owns the lease and only for paths under the leased root.
final class LeasedFileIO: OwnerFileIO {
    private let inner: any OwnerFileIO
    let lease: OwnerNamespaceLease
    let holder: OwnerNamespaceLease.Holder
    private(set) var coordinator: UUID?
    func bind(_ id: UUID) throws {
        guard coordinator == nil || coordinator == id else { throw OwnerStoreError.authorityRequired }
        coordinator = id
    }
    init(_ inner: any OwnerFileIO, lease: OwnerNamespaceLease, holder: OwnerNamespaceLease.Holder) {
        self.inner = inner; self.lease = lease; self.holder = holder
    }
    func inspect(_ url: URL) throws -> CataloguePathKind { try lease.check(holder, url, coordinator: coordinator); return try inner.inspect(url) }
    func writeExclusive(_ bytes: Data, to url: URL) throws { try lease.check(holder, url, coordinator: coordinator); try inner.writeExclusive(bytes, to: url) }
    func protectAndExclude(_ url: URL) throws { try lease.check(holder, url, coordinator: coordinator); try inner.protectAndExclude(url) }
    func fullSync(_ url: URL, directory: Bool) throws { try lease.check(holder, url, coordinator: coordinator); try inner.fullSync(url, directory: directory) }
    func rename(_ source: URL, to destination: URL) throws { try lease.check(holder, source, coordinator: coordinator); try lease.check(holder, destination, coordinator: coordinator); try inner.rename(source, to: destination) }
    func read(_ url: URL, maximumBytes: Int) throws -> Data { try lease.check(holder, url, coordinator: coordinator); return try inner.read(url, maximumBytes: maximumBytes) }
    func removeIntent(_ url: URL) throws { try lease.check(holder, url, coordinator: coordinator); try inner.removeIntent(url) }
    func createOwnerDirectory(_ url: URL) throws { try lease.check(holder, url, coordinator: coordinator); try inner.createOwnerDirectory(url) }
    func protectOwnerAndExclude(_ url: URL, policy: OwnerProtection) throws { try lease.check(holder, url, coordinator: coordinator); try inner.protectOwnerAndExclude(url, policy: policy) }
}
/// Same enforcement over an opaque-key backend. Conformance to
/// `OwnerCryptography` is inherited from the wrapped backend's own policy:
/// wrapping a messaging-policy key store does not make it an owner store.
final class LeasedCryptography<Inner: CatalogueCryptography>: CatalogueCryptography {
    typealias Key = Inner.Key
    private let inner: Inner
    let lease: OwnerNamespaceLease
    let holder: OwnerNamespaceLease.Holder
    private(set) var coordinator: UUID?
    func bind(_ id: UUID) throws {
        guard coordinator == nil || coordinator == id else { throw OwnerStoreError.authorityRequired }
        coordinator = id
    }
    init(_ inner: Inner, lease: OwnerNamespaceLease, holder: OwnerNamespaceLease.Holder) {
        self.inner = inner; self.lease = lease; self.holder = holder
    }
    var framingOverhead: Int { inner.framingOverhead }
    func loadKey() throws -> Key? { try lease.check(holder, coordinator: coordinator); return try inner.loadKey() }
    func createKey() throws -> Key { try lease.check(holder, coordinator: coordinator); return try inner.createKey() }
    func foreignKeyExists(_ slot: CatalogueForeignStore) throws -> Bool { try lease.check(holder, coordinator: coordinator); return try inner.foreignKeyExists(slot) }
    func seal(_ plaintext: Data, with key: Key) throws -> Data { try lease.check(holder, coordinator: coordinator); return try inner.seal(plaintext, with: key) }
    func open(_ sealed: Data, with key: Key) throws -> Data { try lease.check(holder, coordinator: coordinator); return try inner.open(sealed, with: key) }
}
extension LeasedCryptography: OwnerCryptography where Inner: OwnerCryptography {}
