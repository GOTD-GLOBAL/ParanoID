// Lock classification of the Apple owner file adapter (PR #85 review P2).
// An `EPERM` is a retryable owner lock ONLY with positive evidence that
// protected data is unavailable, at the `open(2)` stage, for the owner state
// file. Everything else is a failure the store freezes on. All platform state
// here is FIXTURE-ONLY injected (syscall seam + availability closure) and
// labelled as such: it exercises the classifier, not a locked device.
import CryptoKit
import Foundation
import XCTest
@testable import ParanoidKit

@MainActor final class OwnerAppleLockClassificationTests: XCTestCase {
    // Positive: EPERM at open of owner/state.enc while protected data is unavailable → locked, retryable.
    func testConfirmedUnavailabilityAtOpenOfTheOwnerFileIsARetryableLock() throws {
        let f = try LockFixture()
        defer { f.cleanup() }
        try f.commitOwner()
        f.fault.failOpen(ofSuffix: "/owner/state.enc", create: false, errno: EPERM)
        f.availability.set(false)
        XCTAssertThrowsError(try f.files.read(f.ownerFile, maximumBytes: f.cap)) {
            XCTAssertTrue($0 is OwnerBackendLock, "confirmed unavailability at open is the lock: \($0)")
        }
        let c = f.coordinator()
        XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .locked) }
        XCTAssertFalse(c.isBroken, "a read-only lock before any effect does not latch")
        f.fault.clear(); f.availability.set(true)
        XCTAssertEqual(try c.loadRetained().owner?.phase, "unregistered", "retry after unlock")
        XCTAssertEqual(f.ownerKey.deletions, 0)
        c.close()
    }

    // Negative: the same EPERM while protected data IS available is an ordinary failure.
    func testEPERMWithProtectedDataAvailableIsAFailureNotALock() throws {
        let f = try LockFixture()
        defer { f.cleanup() }
        try f.commitOwner()
        f.fault.failOpen(ofSuffix: "/owner/state.enc", create: false, errno: EPERM)
        f.availability.set(true)
        XCTAssertThrowsError(try f.files.read(f.ownerFile, maximumBytes: f.cap)) {
            XCTAssertFalse($0 is OwnerBackendLock)
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EPERM))
        }
        let c = f.coordinator()
        XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .backendFailure) }
        XCTAssertTrue(c.isBroken, "an unconfirmed permission error freezes the store")
        c.close()
    }

    // Negative: EACCES is never a lock, whatever the availability signal says.
    func testEACCESIsNeverALockEvenWhenProtectedDataIsReportedUnavailable() throws {
        let f = try LockFixture()
        defer { f.cleanup() }
        try f.commitOwner()
        f.fault.failOpen(ofSuffix: "/owner/state.enc", create: false, errno: EACCES)
        f.availability.set(false)
        XCTAssertThrowsError(try f.files.read(f.ownerFile, maximumBytes: f.cap)) {
            XCTAssertFalse($0 is OwnerBackendLock)
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EACCES))
        }
    }

    // Negative: EPERM at the descriptor-read stage (after a successful open) is a failure.
    func testEPERMAtTheReadStageIsAFailureNotALock() throws {
        let f = try LockFixture()
        defer { f.cleanup() }
        try f.commitOwner()
        f.fault.failRead(errno: EPERM)
        f.availability.set(false)
        XCTAssertThrowsError(try f.files.read(f.ownerFile, maximumBytes: f.cap)) {
            XCTAssertFalse($0 is OwnerBackendLock)
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EPERM))
        }
    }

    // Negative: EPERM at the inspection (lstat) stage is a failure.
    func testEPERMAtTheInspectionStageIsAFailureNotALock() throws {
        let f = try LockFixture()
        defer { f.cleanup() }
        try f.commitOwner()
        f.fault.failLstat(ofSuffix: "/owner/state.enc", errno: EPERM)
        f.availability.set(false)
        XCTAssertThrowsError(try f.files.read(f.ownerFile, maximumBytes: f.cap)) {
            XCTAssertFalse($0 is OwnerBackendLock)
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EPERM))
        }
    }

    // Negative: the catalogue file is not the owner store; EPERM there freezes, it does not lock.
    func testEPERMOpeningTheCatalogueIsAFailureNotAnOwnerLock() throws {
        let f = try LockFixture()
        defer { f.cleanup() }
        try f.commitOwner()
        f.fault.failOpen(ofSuffix: "/text-state.enc", create: false, errno: EPERM)
        f.availability.set(false)
        XCTAssertThrowsError(try f.files.read(f.catalogueFile, maximumBytes: f.cap)) {
            XCTAssertFalse($0 is OwnerBackendLock)
        }
        let c = f.coordinator()
        XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .backendFailure) }
        XCTAssertTrue(c.isBroken)
        c.close()
    }

    // Positive lock after the write began is terminal: the readback of the
    // renamed owner candidate hits a confirmed lock; the writer latches and
    // keeps every artifact, nothing is retried or cleaned.
    func testConfirmedLockDuringTheReadbackOfAWriteIsTerminal() throws {
        let f = try LockFixture()
        defer { f.cleanup() }
        let c = f.coordinator()
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let permit = try c.reserveNewOwner(op)
        // Arm only the O_RDONLY open of the owner file: the create of the
        // candidate and the rename still happen, the byte-exact readback does not.
        f.fault.failOpen(ofSuffix: "/owner/state.enc", create: false, errno: EPERM)
        f.availability.set(false)
        XCTAssertThrowsError(try c.initializeNew(permit, operation: op)) { XCTAssertEqual($0 as? OwnerStoreError, .backendFailure) }
        XCTAssertTrue(c.isBroken, "uncertainty after the write began is terminal")
        f.fault.clear(); f.availability.set(true)
        XCTAssertTrue(f.disk.fileExists(at: f.ownerFile), "the renamed candidate stays as evidence")
        XCTAssertTrue(f.disk.fileExists(at: f.root.appendingPathComponent("owner/write.pending")), "intent kept")
        XCTAssertEqual(f.ownerKey.creations, 1); XCTAssertEqual(f.ownerKey.deletions, 0)
        c.close()
        let reopened = f.coordinator()
        XCTAssertThrowsError(try reopened.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .artifactsPresent) }
        reopened.close()
    }

    // Without a protected-data signal (the plain initializer) nothing is ever a lock.
    func testWithoutAProtectedDataSignalEPERMIsAlwaysAFailure() throws {
        let f = try LockFixture()
        defer { f.cleanup() }
        try f.commitOwner()
        f.fault.failOpen(ofSuffix: "/owner/state.enc", create: false, errno: EPERM)
        var seams = CatalogueAppleSyscalls.darwin
        seams.open = f.fault.openHook
        let plain = OwnerAppleFileIO(fileSystem: f.disk, syscalls: seams) // default signal: available
        XCTAssertThrowsError(try plain.read(f.ownerFile, maximumBytes: f.cap)) {
            XCTAssertFalse($0 is OwnerBackendLock)
        }
    }
}

// MARK: - Fixtures (all injected platform state is FIXTURE-ONLY)

/// Thread-safe fault switches for the POSIX seam.
private final class SyscallFault: @unchecked Sendable {
    private let lock = NSLock()
    private var openSuffix: String?; private var openCreate = false; private var openErrno: Int32 = 0
    private var readErrno: Int32?
    private var lstatSuffix: String?; private var lstatErrno: Int32 = 0
    func failOpen(ofSuffix suffix: String, create: Bool, errno code: Int32) { lock.lock(); openSuffix = suffix; openCreate = create; openErrno = code; lock.unlock() }
    func failRead(errno code: Int32) { lock.lock(); readErrno = code; lock.unlock() }
    func failLstat(ofSuffix suffix: String, errno code: Int32) { lock.lock(); lstatSuffix = suffix; lstatErrno = code; lock.unlock() }
    func clear() { lock.lock(); openSuffix = nil; readErrno = nil; lstatSuffix = nil; lock.unlock() }
    var openHook: @Sendable (UnsafePointer<CChar>, Int32, mode_t) -> Int32 {
        { path, flags, mode in
            self.lock.lock(); let suffix = self.openSuffix; let create = self.openCreate; let code = self.openErrno; self.lock.unlock()
            if let suffix, String(cString: path).hasSuffix(suffix), (flags & O_CREAT != 0) == create { errno = code; return -1 }
            return Darwin.open(path, flags, mode)
        }
    }
    var readHook: @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int {
        { descriptor, buffer, capacity in
            self.lock.lock(); let code = self.readErrno; self.lock.unlock()
            if let code { errno = code; return -1 }
            return Darwin.read(descriptor, buffer, capacity)
        }
    }
    var lstatHook: @Sendable (UnsafePointer<CChar>, UnsafeMutablePointer<stat>) -> Int32 {
        { path, information in
            self.lock.lock(); let suffix = self.lstatSuffix; let code = self.lstatErrno; self.lock.unlock()
            if let suffix, String(cString: path).hasSuffix(suffix) { errno = code; return -1 }
            return Darwin.lstat(path, information)
        }
    }
}

/// The injected platform statement about protected data (FIXTURE-ONLY).
private final class Availability: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    func set(_ available: Bool) { lock.lock(); value = available; lock.unlock() }
    var read: @Sendable () -> Bool { { self.lock.lock(); defer { self.lock.unlock() }; return self.value } }
}

@MainActor private final class LockFixture {
    let disk = DataProtectionFileSystem()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("owner-lock-synthetic-" + UUID().uuidString, isDirectory: true)
    let catalogueKey = LockMemoryKey(byte: 0x31)
    let ownerKey = LockMemoryKey(byte: 0x42)
    let fi = LockMemoryKey(byte: 0x53)
    let ru = LockMemoryKey(byte: 0x64)
    let fault = SyscallFault()
    let availability = Availability()
    let context: IdentityCatalogue
    var cap: Int { 65_536 + SnapshotCodec.headerBytes + SnapshotCodec.tagBytes }
    var ownerFile: URL { root.appendingPathComponent("owner/state.enc") }
    var catalogueFile: URL { root.appendingPathComponent("text-state.enc") }
    private lazy var lease = OwnerNamespaceLease(root: root)
    private var previous: OwnerAllocationCoordinator<CatalogueAppleCryptography, OwnerAppleCryptography>?

    init() throws {
        context = try IdentityCatalogue(installID: "11111111-1111-4111-8111-111111111111",
            ownerRef: "22222222-2222-4222-8222-222222222222",
            realms: .init(fi: .init(origin: "https://fi.example.invalid:38444", pin: String(repeating: "a", count: 64), protocolKind: "identity-v3"),
                          ru: .init(origin: "https://ru.example.invalid:38444", pin: String(repeating: "b", count: 64), protocolKind: "identity-v3")))
        try disk.createDirectory(at: root)
        try disk.excludeFromBackup(at: root)
        // The retained bootstrap, written by the unchanged old store, then retired.
        let holder = try lease.acquire()
        let old = CatalogueStore(directory: root, context: context,
            files: LeasedFileIO(files, lease: lease, holder: holder),
            crypto: LeasedCryptography(catalogueCrypto, lease: lease, holder: holder))
        try old.inspectFresh(); try old.commit(context)
        lease.retire(holder)
    }
    func cleanup() { previous?.close(); try? FileManager.default.removeItem(at: root) }
    /// The adapter under test: real file system, FIXTURE-ONLY seam and signal.
    var files: OwnerAppleFileIO {
        var seams = CatalogueAppleSyscalls.darwin
        seams.open = fault.openHook; seams.read = fault.readHook; seams.lstat = fault.lstatHook
        return OwnerAppleFileIO(fileSystem: disk, syscalls: seams, protectedDataAvailable: availability.read)
    }
    var catalogueCrypto: CatalogueAppleCryptography {
        CatalogueAppleCryptography(catalogue: catalogueKey, owner: ownerKey, fi: fi, ru: ru)
    }
    func coordinator() -> OwnerAllocationCoordinator<CatalogueAppleCryptography, OwnerAppleCryptography> {
        previous?.close()
        let holder = try! lease.acquire()
        let next = OwnerAllocationCoordinator(directory: root, context: context,
            files: LeasedFileIO(files, lease: lease, holder: holder),
            catalogueCrypto: LeasedCryptography(catalogueCrypto, lease: lease, holder: holder),
            ownerCrypto: LeasedCryptography(OwnerAppleCryptography(owner: ownerKey), lease: lease, holder: holder),
            entropy: { Data(repeating: 0, count: 16) })
        previous = next
        return next
    }
    /// A committed unregistered owner, with every fault and signal reset.
    func commitOwner() throws {
        let c = coordinator()
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op)
        try c.finish(op); c.close(); previous = nil
        fault.clear(); availability.set(true)
    }
}

private final class LockMemoryKey: WrappingKeyStore {
    private let byte: UInt8
    private var value: SymmetricKey?
    private(set) var creations = 0
    private(set) var deletions = 0
    init(byte: UInt8) { self.byte = byte }
    func exists() throws -> Bool { value != nil }
    func load() throws -> SymmetricKey? { value }
    func create() throws -> SymmetricKey {
        guard value == nil else { throw OwnerStoreError.continuity }
        let key = SymmetricKey(data: Data(repeating: byte, count: 32)); value = key; creations += 1; return key
    }
    func deleteRetained() throws { deletions += 1; XCTFail("owner store must never delete retained keys"); throw OwnerStoreError.backendFailure }
}
