// Native seams of the Apple catalogue adapters (RFC-0030 / draft ADR-0017;
// MR-02/06/14 prerequisites). Every case runs against the real file system in
// an owned temporary root and real CryptoKit. The few faults the real file
// system does not produce on demand (an interrupted, short or zero-length
// transfer, a file that grows under the reader) are injected at the POSIX
// seam and labelled FIXTURE-ONLY; the positive paths of the same calls stay
// native. Nothing here touches the application container or a Keychain.
import CryptoKit
import Foundation
import XCTest
@testable import ParanoidKit

final class CatalogueAppleFileIOTests: XCTestCase {
    // MARK: Inspection — errors are never absence

    func testInspectDistinguishesAbsentRegularDirectoryAndOther() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        XCTAssertEqual(try f.files.inspect(f.path("missing")), .absent)
        XCTAssertEqual(try f.files.inspect(f.root), .directory)
        try f.disk.write(Data([1]), to: f.path("regular"))
        XCTAssertEqual(try f.files.inspect(f.path("regular")), .regularFile)
        XCTAssertEqual(mkfifo(f.path("fifo").path, 0o600), 0)
        XCTAssertEqual(try f.files.inspect(f.path("fifo")), .other)
        try FileManager.default.createSymbolicLink(at: f.path("dangling"), withDestinationURL: f.path("missing"))
        XCTAssertEqual(try f.files.inspect(f.path("dangling")), .other, "a dangling link is present, not absent")
    }

    func testUnreadableParentIsAnErrorNotAbsence() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        try XCTSkipIf(geteuid() == 0, "permission faults are not observable as root")
        let locked = f.path("locked")
        try f.disk.createDirectory(at: locked)
        try f.disk.write(Data([7]), to: locked.appendingPathComponent("inside"))
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, 0o700) }
        XCTAssertThrowsError(try f.files.inspect(locked.appendingPathComponent("inside"))) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EACCES))
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.operation, .inspect)
        }
    }

    // MARK: Exclusive creation — never through a link, never truncating

    func testExclusiveWriteRefusesAnExistingLinkAndLeavesItsTargetAlone() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        let target = f.path("target")
        try f.disk.write(Data([0xAA, 0xBB]), to: target)
        let link = f.path("text-state.enc.tmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try f.files.writeExclusive(Data([1]), to: link)) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.operation, .create)
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EEXIST))
        }
        XCTAssertEqual(try f.disk.read(at: target, maximumBytes: 2), Data([0xAA, 0xBB]))
        XCTAssertEqual(try f.files.inspect(link), .other)
    }

    func testExclusiveWriteOfEmptyDataCreatesAnEmptyRegularFile() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        try f.files.writeExclusive(Data(), to: f.path("empty"))
        XCTAssertEqual(try f.files.inspect(f.path("empty")), .regularFile)
        XCTAssertEqual(try f.files.read(f.path("empty"), maximumBytes: 0), Data())
    }

    func testExclusiveWriteIsOwnerOnly() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        try f.files.writeExclusive(Data([1]), to: f.path("private"))
        var information = stat()
        XCTAssertEqual(lstat(f.path("private").path, &information), 0)
        XCTAssertEqual(information.st_mode & 0o777, 0o600)
    }

    // FIXTURE-ONLY syscall doubles: the real file system does not interrupt or
    // shorten a 3-byte write on demand. The bytes still reach the real inode.
    func testShortAndInterruptedWritesAreCompletedNotTruncated() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        let calls = CallCounter()
        var seams = CatalogueAppleSyscalls.darwin
        seams.write = { descriptor, bytes, count in
            switch calls.next() {
            case 1: return Darwin.write(descriptor, bytes, 1) // short write
            case 2: errno = EINTR; return -1                   // interrupted
            default: return Darwin.write(descriptor, bytes, count)
            }
        }
        let files = CatalogueAppleFileIO(fileSystem: f.disk, syscalls: seams)
        try files.writeExclusive(Data([1, 2, 3, 4]), to: f.path("resumed"))
        XCTAssertEqual(try f.disk.read(at: f.path("resumed"), maximumBytes: 4), Data([1, 2, 3, 4]))
        XCTAssertGreaterThanOrEqual(calls.value, 3)
    }

    // FIXTURE-ONLY: a zero-length write must fail, not spin, and must leave the
    // created inode as evidence rather than unlinking it.
    func testZeroLengthWriteFailsWithoutCompensatingDeletion() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        var seams = CatalogueAppleSyscalls.darwin
        seams.write = { _, _, _ in 0 }
        let files = CatalogueAppleFileIO(fileSystem: f.disk, syscalls: seams)
        XCTAssertThrowsError(try files.writeExclusive(Data([9]), to: f.path("stuck"))) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.operation, .write)
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EIO))
        }
        XCTAssertEqual(try f.files.inspect(f.path("stuck")), .regularFile, "partial evidence is kept")
        XCTAssertEqual(try f.files.read(f.path("stuck"), maximumBytes: 1), Data())
    }

    // FIXTURE-ONLY: a write error after bytes reached the inode keeps them.
    func testWriteErrorKeepsPartialBytes() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        let calls = CallCounter()
        var seams = CatalogueAppleSyscalls.darwin
        seams.write = { descriptor, bytes, _ in
            if calls.next() == 1 { return Darwin.write(descriptor, bytes, 2) }
            errno = ENOSPC
            return -1
        }
        let files = CatalogueAppleFileIO(fileSystem: f.disk, syscalls: seams)
        XCTAssertThrowsError(try files.writeExclusive(Data([1, 2, 3]), to: f.path("partial"))) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(ENOSPC))
        }
        XCTAssertEqual(try f.disk.read(at: f.path("partial"), maximumBytes: 3), Data([1, 2]))
    }

    // MARK: Bounded reads — regular inodes only, growth refused

    func testReadRefusesDirectoryFifoAndMissingWithoutBlocking() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        XCTAssertThrowsError(try f.files.read(f.root, maximumBytes: 10)) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.operation, .read)
        }
        XCTAssertEqual(mkfifo(f.path("fifo").path, 0o600), 0)
        // Opening a FIFO for reading would block until a writer appears; the
        // adapter refuses on the no-follow inspection before any open(2).
        XCTAssertThrowsError(try f.files.read(f.path("fifo"), maximumBytes: 10)) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EFTYPE))
        }
        XCTAssertThrowsError(try f.files.read(f.path("missing"), maximumBytes: 10)) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(ENOENT))
        }
    }

    func testReadAcceptsExactLimitAndRefusesOneByteMore() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        let exact = Data(repeating: 0x5A, count: 1_000)
        try f.disk.write(exact, to: f.path("exact"))
        XCTAssertEqual(try f.files.read(f.path("exact"), maximumBytes: 1_000), exact)
        XCTAssertThrowsError(try f.files.read(f.path("exact"), maximumBytes: 999)) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EFBIG))
        }
    }

    func testUnreadableFileIsAnErrorNotEmpty() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        try XCTSkipIf(geteuid() == 0, "permission faults are not observable as root")
        try f.disk.write(Data([1, 2, 3]), to: f.path("sealed-away"))
        XCTAssertEqual(chmod(f.path("sealed-away").path, 0), 0)
        defer { _ = chmod(f.path("sealed-away").path, 0o600) }
        XCTAssertThrowsError(try f.files.read(f.path("sealed-away"), maximumBytes: 3)) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EACCES))
        }
    }

    // FIXTURE-ONLY: the inode reports `maximumBytes` bytes, then one more byte
    // arrives while the descriptor is being read. The adapter must refuse
    // rather than return a prefix or an unbounded buffer.
    func testFileGrowingPastTheLimitDuringReadIsRefused() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        try f.disk.write(Data(repeating: 1, count: 64), to: f.path("growing"))
        let grown = CallCounter()
        var seams = CatalogueAppleSyscalls.darwin
        seams.read = { descriptor, buffer, capacity in
            let received = Darwin.read(descriptor, buffer, capacity)
            if received == 0, grown.next() == 1, capacity > 0 {
                buffer.storeBytes(of: UInt8(2), as: UInt8.self) // the byte that "arrived"
                return 1
            }
            return received
        }
        let files = CatalogueAppleFileIO(fileSystem: f.disk, syscalls: seams)
        XCTAssertThrowsError(try files.read(f.path("growing"), maximumBytes: 64)) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EFBIG))
        }
    }

    // FIXTURE-ONLY: an interrupted read is retried, and the bytes are exact.
    func testInterruptedReadIsRetried() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        try f.disk.write(Data([5, 6, 7]), to: f.path("interrupted"))
        let calls = CallCounter()
        var seams = CatalogueAppleSyscalls.darwin
        seams.read = { descriptor, buffer, capacity in
            if calls.next() == 1 { errno = EINTR; return -1 }
            return Darwin.read(descriptor, buffer, capacity)
        }
        let files = CatalogueAppleFileIO(fileSystem: f.disk, syscalls: seams)
        XCTAssertEqual(try files.read(f.path("interrupted"), maximumBytes: 3), Data([5, 6, 7]))
    }

    // MARK: Intent removal, protection, sync

    func testRemoveIntentOnlyRemovesARegularFile() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        XCTAssertThrowsError(try f.files.removeIntent(f.path("catalogue.write.pending"))) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(ENOENT))
        }
        let target = f.path("target")
        try f.disk.write(Data([1]), to: target)
        let link = f.path("catalogue.write.pending")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try f.files.removeIntent(link)) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EFTYPE))
        }
        XCTAssertEqual(try f.files.inspect(link), .other)
        XCTAssertEqual(try f.files.inspect(target), .regularFile)
        try FileManager.default.removeItem(at: link)
        try f.files.writeExclusive(Data("catalogue-write-v1\n".utf8), to: link)
        try f.files.removeIntent(link)
        XCTAssertEqual(try f.files.inspect(link), .absent)
    }

    func testProtectAndExcludeSetsTheBackupFlagAndFailsOnAMissingPath() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        try f.files.writeExclusive(Data([1]), to: f.path("candidate"))
        try f.files.protectAndExclude(f.path("candidate"))
        XCTAssertTrue(try f.disk.isExcludedFromBackup(at: f.path("candidate")))
        XCTAssertThrowsError(try f.files.protectAndExclude(f.path("missing"))) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.operation, .protect)
        }
    }

    func testFullSyncAndRenameReportMismatchedInodes() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        try f.disk.write(Data([1]), to: f.path("file"))
        try f.files.fullSync(f.path("file"), directory: false)
        try f.files.fullSync(f.root, directory: true)
        XCTAssertThrowsError(try f.files.fullSync(f.path("file"), directory: true)) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.operation, .sync)
        }
        XCTAssertThrowsError(try f.files.fullSync(f.path("missing"), directory: false))
        XCTAssertThrowsError(try f.files.rename(f.path("missing"), to: f.path("elsewhere"))) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.operation, .rename)
        }
        try f.files.rename(f.path("file"), to: f.path("renamed"))
        XCTAssertEqual(try f.files.inspect(f.path("renamed")), .regularFile)
    }

    // MARK: Cryptography — shipped framing, raw opening, opaque keys

    func testSealRoundTripsRawBytesThroughTheShippedFraming() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        let key = try f.keys.create()
        let plaintext = Data("{\"v\":5,\"ü\":\"\u{fffd}\"}".utf8)
        let sealed = try f.crypto.seal(plaintext, with: key)
        XCTAssertEqual(f.crypto.framingOverhead, 29)
        XCTAssertEqual(sealed.count, plaintext.count + f.crypto.framingOverhead)
        XCTAssertEqual(sealed.first, SnapshotCodec.version)
        XCTAssertEqual(try f.crypto.open(sealed, with: key), plaintext)
        XCTAssertEqual(Data(try SnapshotCodec.open(key: key, value: sealed).utf8), plaintext,
                       "the old reader parses the same box")
    }

    func testSealRefusesPlaintextThatIsNotExactUTF8() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        let key = try f.keys.create()
        XCTAssertThrowsError(try f.crypto.seal(Data([0x7B, 0xFF, 0x7D]), with: key)) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.operation, .seal)
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EILSEQ))
        }
    }

    func testOpenRefusesWrongKeyTamperingShortAndWrongVersionBoxes() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        let key = try f.keys.create()
        let other = SymmetricKey(data: Data(repeating: 0x77, count: 32))
        let sealed = try f.crypto.seal(Data("abc".utf8), with: key)
        XCTAssertThrowsError(try f.crypto.open(sealed, with: other))
        var tampered = sealed
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(try f.crypto.open(tampered, with: key))
        XCTAssertThrowsError(try f.crypto.open(sealed.prefix(28), with: key)) {
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EBADMSG))
        }
        var versioned = sealed
        versioned[versioned.startIndex] = 2
        XCTAssertThrowsError(try f.crypto.open(versioned, with: key))
        XCTAssertEqual(try f.crypto.open(sealed, with: key), Data("abc".utf8), "the untouched box still opens")
    }

    func testForeignKeyExistenceMapsEachSlotToItsOwnBackend() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        XCTAssertFalse(try f.crypto.foreignKeyExists(.owner))
        XCTAssertFalse(try f.crypto.foreignKeyExists(.fi))
        XCTAssertFalse(try f.crypto.foreignKeyExists(.ru))
        _ = try f.fi.create()
        XCTAssertFalse(try f.crypto.foreignKeyExists(.owner))
        XCTAssertTrue(try f.crypto.foreignKeyExists(.fi))
        XCTAssertFalse(try f.crypto.foreignKeyExists(.ru))
        XCTAssertNil(try f.crypto.loadKey(), "the catalogue key is a separate namespace")
    }

    func testCreateKeyIsCreateOnly() throws {
        let f = try AdapterFixture()
        defer { f.cleanup() }
        let created = try f.crypto.createKey()
        XCTAssertEqual(try f.crypto.loadKey(), created)
        XCTAssertThrowsError(try f.crypto.createKey())
        XCTAssertEqual(f.keys.creations, 1)
        XCTAssertEqual(f.keys.deletions, 0)
    }
}

// MARK: - Fixtures

private final class AdapterFixture {
    let disk = DataProtectionFileSystem()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("catalogue-adapter-synthetic-" + UUID().uuidString, isDirectory: true)
    let keys = AdapterMemoryKey(byte: 0x31)
    let owner = AdapterMemoryKey(byte: 0x42)
    let fi = AdapterMemoryKey(byte: 0x53)
    let ru = AdapterMemoryKey(byte: 0x64)
    var files: CatalogueAppleFileIO { CatalogueAppleFileIO(fileSystem: disk) }
    var crypto: CatalogueAppleCryptography {
        CatalogueAppleCryptography(catalogue: keys, owner: owner, fi: fi, ru: ru)
    }
    init() throws {
        try disk.createDirectory(at: root)
        try disk.excludeFromBackup(at: root)
    }
    func path(_ name: String) -> URL { root.appendingPathComponent(name) }
    /// Teardown of this test's own root only; permissions are restored first
    /// so a locked directory does not survive the run.
    func cleanup() {
        _ = chmod(path("locked").path, 0o700)
        _ = chmod(path("sealed-away").path, 0o600)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class AdapterMemoryKey: WrappingKeyStore {
    private let byte: UInt8
    private var value: SymmetricKey?
    private(set) var creations = 0
    private(set) var deletions = 0
    init(byte: UInt8) { self.byte = byte }
    func exists() throws -> Bool { value != nil }
    func load() throws -> SymmetricKey? { value }
    func create() throws -> SymmetricKey {
        guard value == nil else { throw CatalogueStoreError.continuity }
        let key = SymmetricKey(data: Data(repeating: byte, count: 32))
        value = key
        creations += 1
        return key
    }
    func deleteRetained() throws {
        deletions += 1
        XCTFail("Catalogue adapters must never delete retained keys")
        throw CatalogueStoreError.backendFailure
    }
}

/// A counter the `@Sendable` syscall doubles can share.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
