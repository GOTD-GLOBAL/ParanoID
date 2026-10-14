import Foundation

/// Exclusive caller-owned lease over one isolated root and its four key
/// namespaces. Exactly one holder at a time; handles of a retired holder fail
/// before any backend call. Not a multiprocess or filesystem lock.
final class OwnerNamespaceLease {
    final class Holder { fileprivate init() {} }
    let root: URL
    private(set) var holder: Holder?
    init(root: URL) { self.root = root }
    /// Fails while another holder is live: quiesce and retire it first.
    func acquire() throws -> Holder {
        guard holder == nil else { throw OwnerStoreError.busy }
        let h = Holder(); holder = h; return h
    }
    /// Revokes every handle bound to this holder; idempotent for a stale one.
    func retire(_ holder: Holder) { if self.holder === holder { self.holder = nil } }
    fileprivate func check(_ holder: Holder, _ url: URL? = nil) throws {
        guard self.holder === holder else { throw OwnerStoreError.backendFailure }
        if let url, url.standardizedFileURL.path != root.standardizedFileURL.path,
           !url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") { throw OwnerStoreError.backendFailure }
    }
}
/// Lease-enforcing wrapper: the inner backend is reached only while this
/// holder owns the lease and only for paths under the leased root.
final class LeasedFileIO: OwnerFileIO {
    private let inner: any OwnerFileIO
    private let lease: OwnerNamespaceLease
    private let holder: OwnerNamespaceLease.Holder
    init(_ inner: any OwnerFileIO, lease: OwnerNamespaceLease, holder: OwnerNamespaceLease.Holder) {
        self.inner = inner; self.lease = lease; self.holder = holder
    }
    func inspect(_ url: URL) throws -> CataloguePathKind { try lease.check(holder, url); return try inner.inspect(url) }
    func writeExclusive(_ bytes: Data, to url: URL) throws { try lease.check(holder, url); try inner.writeExclusive(bytes, to: url) }
    func protectAndExclude(_ url: URL) throws { try lease.check(holder, url); try inner.protectAndExclude(url) }
    func fullSync(_ url: URL, directory: Bool) throws { try lease.check(holder, url); try inner.fullSync(url, directory: directory) }
    func rename(_ source: URL, to destination: URL) throws { try lease.check(holder, source); try lease.check(holder, destination); try inner.rename(source, to: destination) }
    func read(_ url: URL, maximumBytes: Int) throws -> Data { try lease.check(holder, url); return try inner.read(url, maximumBytes: maximumBytes) }
    func removeIntent(_ url: URL) throws { try lease.check(holder, url); try inner.removeIntent(url) }
    func createOwnerDirectory(_ url: URL) throws { try lease.check(holder, url); try inner.createOwnerDirectory(url) }
    func protectOwnerAndExclude(_ url: URL, policy: OwnerProtection) throws { try lease.check(holder, url); try inner.protectOwnerAndExclude(url, policy: policy) }
}
/// Same enforcement over an opaque-key backend. Conformance to
/// `OwnerCryptography` is inherited from the wrapped backend's own policy:
/// wrapping a messaging-policy key store does not make it an owner store.
final class LeasedCryptography<Inner: CatalogueCryptography>: OwnerCryptography {
    typealias Key = Inner.Key
    private let inner: Inner
    private let lease: OwnerNamespaceLease
    private let holder: OwnerNamespaceLease.Holder
    init(_ inner: Inner, lease: OwnerNamespaceLease, holder: OwnerNamespaceLease.Holder) {
        self.inner = inner; self.lease = lease; self.holder = holder
    }
    var framingOverhead: Int { inner.framingOverhead }
    func loadKey() throws -> Key? { try lease.check(holder); return try inner.loadKey() }
    func createKey() throws -> Key { try lease.check(holder); return try inner.createKey() }
    func foreignKeyExists(_ slot: CatalogueForeignStore) throws -> Bool { try lease.check(holder); return try inner.foreignKeyExists(slot) }
    func seal(_ plaintext: Data, with key: Key) throws -> Data { try lease.check(holder); return try inner.seal(plaintext, with: key) }
    func open(_ sealed: Data, with key: Key) throws -> Data { try lease.check(holder); return try inner.open(sealed, with: key) }
}
