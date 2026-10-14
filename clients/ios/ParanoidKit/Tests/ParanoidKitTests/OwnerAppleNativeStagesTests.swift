// Native stages of the owner store over the real Apple adapters (RFC-0030 /
// draft ADR-0017; REQ-ID-002/003/004/006 prerequisites). Real temporary roots,
// real CryptoKit, in-memory SymmetricKey backends; the trusted verifier, signer
// and assembler fixtures of OwnerStoreTests supply synthetic verified input,
// never live registry/signature verification. Faults the real file system does
// not produce on demand are injected at labelled FIXTURE-ONLY seams.
import CryptoKit
import Foundation
import XCTest
@testable import ParanoidKit

@MainActor final class OwnerAppleNativeStagesTests: XCTestCase {
    private static let publicEntropy = Data(repeating: 0, count: 16)
    private static let publicOwner = "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk" // bridge/tests/devnet.rs vector

    // 1. Synthetic verified recovery → confirmed owner commit → binding publication → reopen pair.
    func testVerifiedRecoveryCommitsOwnerThenPublishesBindingAndReopensThePair() async throws {
        let f = try OwnerStageFixture()
        defer { f.cleanup() }
        try f.bootstrap()
        let c = f.coordinator(entropy: { XCTFail("recovery never draws entropy"); return Data() })
        XCTAssertFalse(try c.loadRetained().catalogue.allocated)
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let pair = try await c.recoverVerified(op, entropy: Self.publicEntropy.base64EncodedString(), verifier: SyntheticBindingVerifier())
        try c.finish(op)
        XCTAssertTrue(pair.catalogue.allocated)
        XCTAssertEqual(pair.owner?.phase, "registryConfirmed")
        XCTAssertEqual(pair.owner?.owner, Self.publicOwner)
        XCTAssertEqual(pair.owner?.binding?.name, "alice_fixture")
        XCTAssertEqual(pair.catalogue.binding, pair.owner?.binding, "publication follows the owner commit")
        XCTAssertFalse(pair.owner?.wordsBackupConfirmed ?? true, "recovery is not a backup assertion")
        XCTAssertEqual(f.ownerKey.creations, 1)
        XCTAssertTrue(try f.disk.isExcludedFromBackup(at: f.ownerFile))
        let ownerBytes = try f.disk.read(at: f.ownerFile, maximumBytes: f.cap)
        let catalogueBytes = try f.disk.read(at: f.catalogueFile, maximumBytes: f.cap)
        c.close()
        let reopened = f.coordinator(entropy: { XCTFail("no entropy on reopen"); return Data() })
        XCTAssertEqual(try reopened.loadRetained(), pair)
        XCTAssertEqual(try f.disk.read(at: f.ownerFile, maximumBytes: f.cap), ownerBytes, "open never rewrites")
        XCTAssertEqual(try f.disk.read(at: f.catalogueFile, maximumBytes: f.cap), catalogueBytes)
        XCTAssertEqual(f.ownerKey.deletions, 0)
    }

    // 2. Real encrypted reopen of ownerSigned, assembled, sent and confirmed states, exact bytes.
    func testOwnerSignedAssembledSendAndConfirmedStatesSurviveEncryptedReopen() async throws {
        let f = try OwnerStageFixture()
        defer { f.cleanup() }
        try f.bootstrap()
        var c = f.coordinator()
        var op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op)
        try c.confirmWordsBackup(op)
        let attempt = try c.recordOwnerSigned(op, intent: f.intent(), signer: PublicVectorSigner())
        try c.finish(op)
        XCTAssertEqual(attempt.stage, "ownerSigned"); XCTAssertEqual(attempt.sends, 0); XCTAssertNil(attempt.transaction)
        var saved = try f.disk.read(at: f.ownerFile, maximumBytes: f.cap)
        c.close(); c = f.coordinator()
        var retained = try c.loadRetained()
        XCTAssertEqual(retained.owner?.phase, "registrationPending")
        XCTAssertEqual(retained.owner?.attempts, [attempt], "pre-sponsor evidence is exact after reopen")
        XCTAssertEqual(try f.disk.read(at: f.ownerFile, maximumBytes: f.cap), saved)

        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let assembled = try c.recordAssembled(op, attemptID: attempt.intent.attemptID, signer: SyntheticAssemblyInput())
        try c.finish(op)
        XCTAssertEqual(assembled.stage, "assembled"); XCTAssertNotNil(assembled.transaction)
        XCTAssertEqual(assembled.message, attempt.message); XCTAssertEqual(assembled.ownerSignature, attempt.ownerSignature)
        saved = try f.disk.read(at: f.ownerFile, maximumBytes: f.cap)
        c.close(); c = f.coordinator()
        retained = try c.loadRetained()
        XCTAssertEqual(retained.owner?.attempts, [assembled])
        XCTAssertEqual(try f.disk.read(at: f.ownerFile, maximumBytes: f.cap), saved)

        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let ticket = try c.reserveSend(op, attemptID: attempt.intent.attemptID)
        let bytes = try ticket.take()
        XCTAssertEqual(bytes.first, 2, "the saved two-signature framing is what is released")
        try c.finish(op)
        saved = try f.disk.read(at: f.ownerFile, maximumBytes: f.cap)
        c.close(); c = f.coordinator()
        retained = try c.loadRetained()
        XCTAssertEqual(retained.owner?.attempts.first?.sends, 1, "the send reservation is durable")
        XCTAssertEqual(try f.disk.read(at: f.ownerFile, maximumBytes: f.cap), saved)

        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let confirmed = try await c.confirmRegistry(op, verifier: SyntheticBindingVerifier())
        try c.finish(op)
        XCTAssertEqual(confirmed.owner?.phase, "registryConfirmed")
        XCTAssertEqual(confirmed.owner?.attempts.first?.resolution, "ownerBound")
        XCTAssertEqual(confirmed.owner?.attempts.first?.finalizedHeight, 101)
        XCTAssertEqual(confirmed.catalogue.binding, confirmed.owner?.binding)
        saved = try f.disk.read(at: f.ownerFile, maximumBytes: f.cap)
        let catalogueSaved = try f.disk.read(at: f.catalogueFile, maximumBytes: f.cap)
        c.close(); c = f.coordinator()
        XCTAssertEqual(try c.loadRetained(), confirmed)
        XCTAssertEqual(try f.disk.read(at: f.ownerFile, maximumBytes: f.cap), saved)
        XCTAssertEqual(try f.disk.read(at: f.catalogueFile, maximumBytes: f.cap), catalogueSaved)
        XCTAssertEqual(f.ownerKey.creations, 1); XCTAssertEqual(f.catalogueKey.creations, 1); XCTAssertEqual(f.ownerKey.deletions, 0)
        XCTAssertFalse(f.disk.fileExists(at: f.root.appendingPathComponent("owner/write.pending")))
        XCTAssertFalse(f.disk.fileExists(at: f.root.appendingPathComponent("catalogue.write.pending")))
        c.close()
    }

    // 3. FIXTURE-ONLY: publication interrupted before any catalogue effect (the
    // catalogue intent cannot be created). The confirmed owner is preserved, the
    // catalogue stays allocated with a null binding, nothing publishes itself.
    func testInterruptedPublicationBeforeTheCatalogueIntentLeavesAnIntermediateOnlyExplicitPublicationCompletes() async throws {
        let f = try OwnerStageFixture()
        defer { f.cleanup() }
        try f.bootstrap()
        let fault = PathFault()
        var c = f.coordinator(files: f.files(fault: fault))
        var op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op)
        try c.finish(op)
        let catalogueBefore = try f.disk.read(at: f.catalogueFile, maximumBytes: f.cap)
        fault.refuseCreate(of: "catalogue.write.pending", errno: ENOSPC)
        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        await assertThrows(.backendFailure) { try await c.confirmRegistry(op, verifier: SyntheticBindingVerifier()) }
        XCTAssertTrue(c.isBroken, "a failed write latches the writer")
        fault.clear()
        let ownerAfter = try f.disk.read(at: f.ownerFile, maximumBytes: f.cap)
        XCTAssertEqual(try f.disk.read(at: f.catalogueFile, maximumBytes: f.cap), catalogueBefore, "no catalogue effect")
        XCTAssertFalse(f.disk.fileExists(at: f.root.appendingPathComponent("catalogue.write.pending")))
        c.close(); c = f.coordinator(files: f.files(fault: fault))
        let intermediate = try c.loadRetained()
        XCTAssertEqual(intermediate.owner?.phase, "registryConfirmed")
        XCTAssertNotNil(intermediate.owner?.binding)
        XCTAssertTrue(intermediate.catalogue.allocated)
        XCTAssertNil(intermediate.catalogue.binding, "reopening never publishes by itself")
        XCTAssertEqual(try f.disk.read(at: f.ownerFile, maximumBytes: f.cap), ownerAfter)
        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let published = try c.publishConfirmedBinding(op)
        try c.finish(op)
        XCTAssertEqual(published.catalogue.binding, intermediate.owner?.binding)
        c.close(); c = f.coordinator()
        XCTAssertEqual(try c.loadRetained(), published)
        XCTAssertEqual(f.ownerKey.creations, 1); XCTAssertEqual(f.ownerKey.deletions, 0)
        c.close()
    }

    // 4. FIXTURE-ONLY: publication interrupted after the catalogue intent exists
    // (the candidate cannot be created). The leftover intent freezes the
    // catalogue on reopen; every byte of evidence stays where it was.
    func testInterruptedPublicationAfterTheIntentFreezesTheCatalogueAndKeepsEvidence() async throws {
        let f = try OwnerStageFixture()
        defer { f.cleanup() }
        try f.bootstrap()
        let fault = PathFault()
        var c = f.coordinator(files: f.files(fault: fault))
        var op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op)
        try c.finish(op)
        let catalogueBefore = try f.disk.read(at: f.catalogueFile, maximumBytes: f.cap)
        fault.refuseCreate(of: "text-state.enc.tmp", errno: ENOSPC)
        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        await assertThrows(.backendFailure) { try await c.confirmRegistry(op, verifier: SyntheticBindingVerifier()) }
        XCTAssertTrue(c.isBroken)
        fault.clear()
        let ownerAfter = try f.disk.read(at: f.ownerFile, maximumBytes: f.cap)
        let intent = f.root.appendingPathComponent("catalogue.write.pending")
        XCTAssertEqual(try f.disk.read(at: intent, maximumBytes: 64), Data("catalogue-write-v1\n".utf8), "intent evidence kept")
        XCTAssertEqual(try f.disk.read(at: f.catalogueFile, maximumBytes: f.cap), catalogueBefore)
        c.close(); c = f.coordinator()
        XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .artifactsPresent) }
        XCTAssertEqual(try f.disk.read(at: intent, maximumBytes: 64), Data("catalogue-write-v1\n".utf8), "no cleanup")
        XCTAssertEqual(try f.disk.read(at: f.ownerFile, maximumBytes: f.cap), ownerAfter)
        XCTAssertEqual(try f.disk.read(at: f.catalogueFile, maximumBytes: f.cap), catalogueBefore)
        XCTAssertEqual(f.ownerKey.deletions, 0)
        c.close()
    }

    // 5. Foreign key, foreign context, leftover intent/temp and missing halves refuse without modification.
    func testForeignKeyContextLeftoverArtifactsAndMissingHalvesRefuseWithoutModification() throws {
        let f = try OwnerStageFixture()
        defer { f.cleanup() }
        try f.bootstrap()
        var c = f.coordinator()
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op)
        try c.finish(op); c.close()
        let ownerBytes = try f.disk.read(at: f.ownerFile, maximumBytes: f.cap)
        let catalogueBytes = try f.disk.read(at: f.catalogueFile, maximumBytes: f.cap)
        func unchanged(_ file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try f.disk.read(at: f.ownerFile, maximumBytes: f.cap), ownerBytes, file: file, line: line)
            XCTAssertEqual(try f.disk.read(at: f.catalogueFile, maximumBytes: f.cap), catalogueBytes, file: file, line: line)
            XCTAssertEqual(f.ownerKey.deletions, 0, file: file, line: line)
        }
        // leftover intent
        let intent = f.root.appendingPathComponent("owner/write.pending")
        try f.disk.write(Data("owner-write-v1\n".utf8), to: intent) // synthetic fixture only
        c = f.coordinator()
        XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .artifactsPresent) }
        XCTAssertTrue(f.disk.fileExists(at: intent), "no cleanup"); try unchanged()
        try FileManager.default.removeItem(at: intent); c.close()
        // leftover temp
        let temp = f.root.appendingPathComponent("owner/state.enc.tmp")
        try f.disk.write(Data([1]), to: temp)
        c = f.coordinator()
        XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .artifactsPresent) }
        XCTAssertTrue(f.disk.fileExists(at: temp)); try unchanged()
        try FileManager.default.removeItem(at: temp); c.close()
        // foreign owner key: the box authenticates only under the retained key
        let foreign = StageMemoryKey(byte: 0x99); _ = try foreign.create()
        c = f.coordinator(ownerKey: foreign)
        XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .authenticationFailed) }
        try unchanged(); c.close()
        // foreign context: another installation's catalogue never opens here
        let other = try IdentityCatalogue(installID: "33333333-3333-4333-8333-333333333333", ownerRef: f.context.ownerRef, realms: f.context.realms)
        c = f.coordinator(context: other)
        XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .contextMismatch) }
        try unchanged(); c.close()
        // allocated catalogue, owner file missing: loss, never a fresh owner
        let moved = f.root.appendingPathComponent("owner-state-moved-aside")
        try FileManager.default.moveItem(at: f.ownerFile, to: moved) // synthetic fixture only
        c = f.coordinator()
        XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .continuity) }
        XCTAssertFalse(f.disk.fileExists(at: f.ownerFile), "nothing recreated")
        XCTAssertEqual(f.ownerKey.creations, 1)
        c.close()
        try FileManager.default.moveItem(at: moved, to: f.ownerFile)
        // allocated catalogue, whole owner directory missing: loss as well
        let dir = f.root.appendingPathComponent("owner")
        let dirMoved = f.root.appendingPathComponent("owner-moved-aside")
        try FileManager.default.moveItem(at: dir, to: dirMoved)
        c = f.coordinator()
        XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .continuity) }
        XCTAssertEqual(try f.files().inspect(dir), .absent, "no directory recreated")
        c.close()
        try FileManager.default.moveItem(at: dirMoved, to: dir)
        c = f.coordinator()
        XCTAssertEqual(try c.loadRetained().owner?.owner, Self.publicOwner, "the untouched pair still opens")
        try unchanged(); c.close()
    }

    // 6. A read-only owner lock before any effect is retryable; a lock after the write began is terminal.
    func testReadOnlyOwnerLockIsRetryableButALockAfterTheWriteBeganIsTerminal() throws {
        let f = try OwnerStageFixture()
        defer { f.cleanup() }
        try f.bootstrap()
        var c = f.coordinator()
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op)
        try c.finish(op); c.close()
        f.ownerKey.locked = true
        c = f.coordinator()
        XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .locked) }
        XCTAssertFalse(c.isBroken, "a precisely classified read-only lock does not latch")
        f.ownerKey.locked = false
        XCTAssertEqual(try c.loadRetained().owner?.owner, Self.publicOwner, "retry after unlock")
        c.close()

        // Second root: the key locks right after its creation, i.e. after the
        // owner write began (intent already durable). Uncertainty is terminal.
        let g = try OwnerStageFixture()
        defer { g.cleanup() }
        try g.bootstrap()
        g.ownerKey.lockAfterCreate = true
        let d = g.coordinator()
        let op2 = try d.begin(deadline: .now.advanced(by: .seconds(30)))
        let permit = try d.reserveNewOwner(op2)
        XCTAssertThrowsError(try d.initializeNew(permit, operation: op2)) { XCTAssertEqual($0 as? OwnerStoreError, .backendFailure) }
        XCTAssertTrue(d.isBroken)
        XCTAssertEqual(g.ownerKey.creations, 1, "the key was created once and is kept")
        XCTAssertTrue(g.disk.fileExists(at: g.root.appendingPathComponent("owner/write.pending")), "intent evidence kept")
        XCTAssertFalse(g.disk.fileExists(at: g.ownerFile))
        d.close()
        g.ownerKey.locked = false
        let e = g.coordinator()
        XCTAssertThrowsError(try e.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .artifactsPresent) }
        XCTAssertEqual(g.ownerKey.deletions, 0)
        e.close()
    }

    // 7. FIXTURE-ONLY: the owner candidate's full sync fails. The writer latches,
    // temp and intent stay as evidence, the key is created once and kept.
    func testOwnerCandidateSyncFailureFreezesAndKeepsTempIntentAndKey() throws {
        let f = try OwnerStageFixture()
        defer { f.cleanup() }
        try f.bootstrap()
        let failing = FailingSyncFileSystem(inner: f.disk, failingName: "state.enc.tmp")
        let c = f.coordinator(files: OwnerAppleFileIO(fileSystem: failing))
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let permit = try c.reserveNewOwner(op)
        XCTAssertThrowsError(try c.initializeNew(permit, operation: op)) { XCTAssertEqual($0 as? OwnerStoreError, .backendFailure) }
        XCTAssertTrue(c.isBroken)
        XCTAssertEqual(failing.failures, 1)
        XCTAssertTrue(f.disk.fileExists(at: f.root.appendingPathComponent("owner/state.enc.tmp")), "candidate kept")
        XCTAssertTrue(f.disk.fileExists(at: f.root.appendingPathComponent("owner/write.pending")), "intent kept")
        XCTAssertFalse(f.disk.fileExists(at: f.ownerFile))
        XCTAssertEqual(f.ownerKey.creations, 1); XCTAssertEqual(f.ownerKey.deletions, 0)
        c.close()
        let reopened = f.coordinator()
        XCTAssertThrowsError(try reopened.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .artifactsPresent) }
        reopened.close()
    }

    // 8. The owner cryptography has no foreign namespaces; on the host a permission error is not a lock.
    func testOwnerCryptographyHasNoForeignNamespacesAndHostPermissionErrorsAreNotLocks() throws {
        let f = try OwnerStageFixture()
        defer { f.cleanup() }
        let crypto = OwnerAppleCryptography(owner: f.ownerKey)
        XCTAssertThrowsError(try crypto.foreignKeyExists(.owner))
        XCTAssertEqual(crypto.framingOverhead, 29)
        #if !os(iOS)
        try XCTSkipIf(geteuid() == 0, "permission faults are not observable as root")
        let locked = f.root.appendingPathComponent("unreadable")
        try f.disk.write(Data([1]), to: locked)
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, 0o600) }
        XCTAssertThrowsError(try f.files().read(locked, maximumBytes: 1)) {
            XCTAssertFalse($0 is OwnerBackendLock)
            XCTAssertEqual(($0 as? CatalogueAppleAdapterError)?.code, Int(EACCES))
        }
        #endif
    }
}

// MARK: - Fixtures

@MainActor private final class OwnerStageFixture {
    let disk = DataProtectionFileSystem()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("owner-stage-synthetic-" + UUID().uuidString, isDirectory: true)
    let catalogueKey = StageMemoryKey(byte: 0x31)
    let ownerKey = StageMemoryKey(byte: 0x42)
    let fi = StageMemoryKey(byte: 0x53)
    let ru = StageMemoryKey(byte: 0x64)
    let context: IdentityCatalogue
    var cap: Int { 65_536 + SnapshotCodec.headerBytes + SnapshotCodec.tagBytes }
    var ownerFile: URL { root.appendingPathComponent("owner/state.enc") }
    var catalogueFile: URL { root.appendingPathComponent("text-state.enc") }
    private lazy var lease = OwnerNamespaceLease(root: root)
    private var previous: (any OwnerStageClosable)?

    init() throws {
        context = try IdentityCatalogue(installID: "11111111-1111-4111-8111-111111111111",
            ownerRef: "22222222-2222-4222-8222-222222222222",
            realms: .init(fi: .init(origin: "https://fi.example.invalid:38444", pin: String(repeating: "a", count: 64), protocolKind: "identity-v3"),
                          ru: .init(origin: "https://ru.example.invalid:38444", pin: String(repeating: "b", count: 64), protocolKind: "identity-v3")))
        try disk.createDirectory(at: root)
        try disk.excludeFromBackup(at: root)
    }
    func cleanup() {
        previous?.close()
        _ = chmod(root.appendingPathComponent("unreadable").path, 0o600)
        try? FileManager.default.removeItem(at: root)
    }
    func files(fault: PathFault? = nil) -> OwnerAppleFileIO {
        guard let fault else { return OwnerAppleFileIO(fileSystem: disk) }
        var seams = CatalogueAppleSyscalls.darwin
        seams.open = { path, flags, mode in
            if flags & O_CREAT != 0, let code = fault.code(forCreating: path) { errno = code; return -1 }
            return Darwin.open(path, flags, mode)
        }
        return OwnerAppleFileIO(fileSystem: disk, syscalls: seams)
    }
    var catalogueCrypto: CatalogueAppleCryptography {
        CatalogueAppleCryptography(catalogue: catalogueKey, owner: ownerKey, fi: fi, ru: ru)
    }
    /// The retained bootstrap, written by the unchanged old store, then retired.
    func bootstrap() throws {
        let holder = try lease.acquire()
        let io = files()
        let old = CatalogueStore(directory: root, context: context,
            files: LeasedFileIO(io, lease: lease, holder: holder),
            crypto: LeasedCryptography(catalogueCrypto, lease: lease, holder: holder))
        try old.inspectFresh(); try old.commit(context)
        lease.retire(holder)
    }
    func intent(_ number: Int = 1, name: String = "alice_fixture") -> OwnerAttemptIntent {
        .init(attemptID: String(format: "00000000-0000-4000-8000-%012d", number), name: name, sponsorRealmKey: context.realms.fi,
              payer: String(repeating: "1", count: 32), blockhash: String(repeating: "1", count: 32), lastValidHeight: 100)
    }
    /// Controlled handoff: the previous coordinator is closed before a new holder is acquired.
    func coordinator(files io: OwnerAppleFileIO? = nil, ownerKey key: StageMemoryKey? = nil, context ctx: IdentityCatalogue? = nil,
                     entropy: @escaping () throws -> Data = { Data(repeating: 0, count: 16) })
        -> OwnerAllocationCoordinator<CatalogueAppleCryptography, OwnerAppleCryptography> {
        previous?.close()
        let holder = try! lease.acquire()
        let io = io ?? files()
        let next = OwnerAllocationCoordinator(directory: root, context: ctx ?? context,
            files: LeasedFileIO(io, lease: lease, holder: holder),
            catalogueCrypto: LeasedCryptography(catalogueCrypto, lease: lease, holder: holder),
            ownerCrypto: LeasedCryptography(OwnerAppleCryptography(owner: key ?? ownerKey), lease: lease, holder: holder),
            entropy: entropy)
        previous = next
        return next
    }
}

@MainActor private protocol OwnerStageClosable: AnyObject { func close() }
extension OwnerAllocationCoordinator: OwnerStageClosable {}

/// In-memory opaque key double: real `SymmetricKey` values for real CryptoKit
/// boxes, NOT a Keychain and NOT the owner accessibility policy. `locked`
/// reports the precise read-only lock; `lockAfterCreate` locks the key the
/// moment it is created, i.e. after the owner write began.
private final class StageMemoryKey: OwnerKeyBackend {
    /// FIXTURE-ONLY descriptor: a memory key cannot enforce a Keychain policy;
    /// it only reports the canonical one so the adapter admits it on the host.
    func storedPolicy() throws -> OwnerKeyPolicy? { try load() == nil ? nil : .whenUnlockedThisDeviceOnly }
    private let byte: UInt8
    private var value: SymmetricKey?
    var locked = false
    var lockAfterCreate = false
    private(set) var creations = 0
    private(set) var deletions = 0
    init(byte: UInt8) { self.byte = byte }
    func exists() throws -> Bool { if locked { throw OwnerBackendLock.locked }; return value != nil }
    func load() throws -> SymmetricKey? { if locked { throw OwnerBackendLock.locked }; return value }
    func create() throws -> SymmetricKey {
        guard value == nil else { throw OwnerStoreError.continuity }
        let key = SymmetricKey(data: Data(repeating: byte, count: 32)); value = key; creations += 1
        if lockAfterCreate { locked = true }
        return key
    }
    func deleteRetained() throws { deletions += 1; XCTFail("owner store must never delete retained keys"); throw OwnerStoreError.backendFailure }
}

/// FIXTURE-ONLY: refuses `open(O_CREAT)` of one named path with a chosen errno.
private final class PathFault: @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?
    private var errnoValue: Int32 = 0
    func refuseCreate(of lastPathComponent: String, errno code: Int32) { lock.lock(); name = lastPathComponent; errnoValue = code; lock.unlock() }
    func clear() { lock.lock(); name = nil; lock.unlock() }
    func code(forCreating path: UnsafePointer<CChar>) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        guard let name else { return nil }
        return String(cString: path).hasSuffix("/" + name) ? errnoValue : nil
    }
}

/// FIXTURE-ONLY: the real file system, except that the first full sync of one
/// named path fails. Every other operation is the shipped implementation.
private final class FailingSyncFileSystem: FileSystem, @unchecked Sendable {
    private let inner: DataProtectionFileSystem
    private let failingName: String
    private(set) var failures = 0
    init(inner: DataProtectionFileSystem, failingName: String) { self.inner = inner; self.failingName = failingName }
    func fileExists(at url: URL) -> Bool { inner.fileExists(at: url) }
    func createDirectory(at url: URL) throws { try inner.createDirectory(at: url) }
    func excludeFromBackup(at url: URL) throws { try inner.excludeFromBackup(at: url) }
    func isExcludedFromBackup(at url: URL) throws -> Bool { try inner.isExcludedFromBackup(at: url) }
    func write(_ data: Data, to url: URL) throws { try inner.write(data, to: url) }
    func fullSync(at url: URL, directory: Bool) throws {
        if url.lastPathComponent == failingName, failures == 0 {
            failures += 1
            throw FileSystemError(.fullSync, url, code: Int(EIO), reason: "injected sync failure")
        }
        try inner.fullSync(at: url, directory: directory)
    }
    func rename(from source: URL, to destination: URL) throws { try inner.rename(from: source, to: destination) }
    func read(at url: URL, maximumBytes: Int) throws -> Data { try inner.read(at: url, maximumBytes: maximumBytes) }
    func removeItem(at url: URL) throws { try inner.removeItem(at: url) }
}
