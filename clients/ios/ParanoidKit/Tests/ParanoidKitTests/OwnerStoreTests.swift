import Foundation
import XCTest
@testable import ParanoidKit

// REQ-ID-002/003/004/006, REQ-MULTI-001, REQ-SEC-001; isolated public fixtures.
// File/key/AEAD doubles below are NON-CRYPTOGRAPHIC. Identity calls real Rust.
final class OwnerStoreTests: XCTestCase {
    @MainActor func testEveryCreationEffectFaultPreservesEvidenceAndNeverRecreatesPermit() async throws {
        let baseline = try OwnerFixture(); let b = baseline.coordinator()
        let op0 = try b.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try b.initializeNew(b.reserveNewOwner(op0), operation: op0)
        let effects = baseline.io.effects
        // Contract §5 ordering: allocation final sync -> owner dir/protect/sync/root sync -> intent -> key create once.
        let ix = { (name: String) in effects.firstIndex(of: name)! }
        XCTAssertLessThan(effects.lastIndex(of: "remove:" + baseline.path("catalogue.write.pending"))!, ix("mkdir:" + baseline.path("owner")))
        XCTAssertLessThan(ix("mkdir:" + baseline.path("owner")), ix("protectOwner:" + baseline.path("owner")))
        XCTAssertLessThan(ix("protectOwner:" + baseline.path("owner")), ix("sync:" + baseline.path("owner")))
        XCTAssertLessThan(ix("sync:" + baseline.path("owner")), ix("write:" + baseline.path("owner/write.pending")))
        XCTAssertLessThan(ix("write:" + baseline.path("owner/write.pending")), ix("keyCreate:2"))
        XCTAssertEqual(effects.filter { $0 == "keyCreate:2" }.count, 1)
        XCTAssertLessThan(ix("keyCreate:2"), ix("seal:2"))
        print("OWNER_CREATION_FAULT_MATRIX effects=\(effects.count) beforeAndAfterCases=\(effects.count * 2)")
        for after in [false, true] {
            for step in effects.indices {
                let label = "step \(step) \(effects[step]) after=\(after)"
                let f = try OwnerFixture(); let c = f.coordinator()
                let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
                f.io.faultAt = step; f.io.faultAfter = after
                var permit: OwnerCreationPermit?
                do { permit = try c.reserveNewOwner(op); _ = try c.initializeNew(permit!, operation: op); XCTFail(label) }
                catch { XCTAssertEqual(error as? OwnerStoreError, .backendFailure, label) }
                XCTAssertTrue(c.isBroken, label)
                XCTAssertEqual(f.io.effects, Array(effects.prefix(step + (after ? 1 : 0))), "no later effects or compensation, " + label)
                let reservationEnd = ix("mkdir:" + f.path("owner")) - 1
                // A reported failure of the final sync still yields no permit: entropy only after durable success.
                XCTAssertEqual(f.entropyCalls, step > reservationEnd ? 1 : 0, "entropy only after durable reservation, " + label)
                let evidence = f.io.data; let kinds = f.io.kinds; let keys = [f.catalogue.key, f.owner.key]
                XCTAssertThrowsError(try c.reserveNewOwner(op), label) { XCTAssertEqual($0 as? OwnerStoreError, .broken) }
                if let permit { XCTAssertThrowsError(try c.initializeNew(permit, operation: op), label) { XCTAssertEqual($0 as? OwnerStoreError, .broken) } }
                XCTAssertThrowsError(try c.begin(deadline: .now.advanced(by: .seconds(1))), label) { XCTAssertEqual($0 as? OwnerStoreError, .broken) }
                f.io.faultAt = nil
                let allocated = f.io.data[f.path("text-state.enc")].map { String(decoding: $0.dropFirst(29), as: UTF8.self).contains(#""allocation":"allocated""#) } ?? false
                let ownerIntact = f.io.data[f.path("owner/state.enc")] != nil && f.owner.key != nil
                let pending = ["catalogue.write.pending", "text-state.enc.tmp", "owner/write.pending", "owner/state.enc.tmp"].contains { f.io.data[f.path($0)] != nil }
                let reopened = f.coordinator()
                if pending {
                    XCTAssertThrowsError(try reopened.loadRetained(), label) { XCTAssertEqual($0 as? OwnerStoreError, .artifactsPresent, label) }
                } else if allocated && !ownerIntact {
                    // Allocated owner loss (directory alone, or missing key/file): never fresh, never cleaned.
                    XCTAssertThrowsError(try reopened.loadRetained(), label) { XCTAssertEqual($0 as? OwnerStoreError, .continuity, label) }
                    XCTAssertTrue(reopened.isBroken, label)
                } else if allocated {
                    XCTAssertEqual(try reopened.loadRetained().owner?.phase, "unregistered", label)
                } else {
                    XCTAssertFalse(try reopened.loadRetained().catalogue.allocated, label)
                    XCTAssertEqual(f.owner.key, nil, label)
                }
                XCTAssertEqual(f.io.data, evidence, label); XCTAssertEqual(f.io.kinds, kinds, label)
                XCTAssertEqual([f.catalogue.key, f.owner.key], keys, label)
            }
        }
    }

    @MainActor func testLeaseHandoffRetiresOldBootstrapHandlesBeforeNewWriter() async throws {
        let f = try OwnerFixture()
        let lease = OwnerNamespaceLease(root: f.root)
        let oldHolder = try lease.acquire()
        let old = CatalogueStore(directory: f.root, context: f.context,
                                 files: LeasedFileIO(f.io, lease: lease, holder: oldHolder),
                                 crypto: LeasedCryptography(f.catalogue, lease: lease, holder: oldHolder))
        XCTAssertEqual(try old.loadRetained(), f.context)
        XCTAssertThrowsError(try lease.acquire()) { XCTAssertEqual($0 as? OwnerStoreError, .busy) }
        lease.retire(oldHolder)
        f.io.events = []
        XCTAssertThrowsError(try old.commit(f.context)) { XCTAssertEqual($0 as? CatalogueStoreError, .backendFailure) }
        XCTAssertEqual(f.io.events, [], "stale handle fails before I/O")
        XCTAssertTrue(old.isBroken)
        let newHolder = try lease.acquire()
        let c = OwnerAllocationCoordinator(directory: f.root, context: f.context,
                                           files: LeasedFileIO(f.io, lease: lease, holder: newHolder),
                                           catalogueCrypto: LeasedCryptography(f.catalogue, lease: lease, holder: newHolder),
                                           ownerCrypto: LeasedCryptography(f.owner, lease: lease, holder: newHolder),
                                           entropy: { Data(repeating: 0, count: 16) })
        XCTAssertFalse(try c.loadRetained().catalogue.allocated)
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op)
        try c.finish(op)
        lease.retire(newHolder)
        f.io.events = []
        XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .backendFailure) }
        XCTAssertEqual(f.io.events, [])
        XCTAssertTrue(c.isBroken)
    }

    @MainActor func testRegistryConfirmationBindsUnresolvedOnlyAndPublicationFailurePreservesIntermediate() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        var op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.confirmWordsBackup(op)
        _ = try c.recordOwnerSigned(op, intent: f.intent(1, height: 100, name: "bob_fixture"), signer: PublicVectorSigner())
        var verifier = SyntheticBindingVerifier(); verifier.height = 101
        let permit = try await c.resolveExpired(op, proposedName: "alice_fixture", verifier: verifier)
        let second = try c.recordOwnerSigned(op, intent: f.intent(2, height: 150), signer: PublicVectorSigner(), append: permit)
        _ = try c.recordAssembled(op, attemptID: second.intent.attemptID, signer: SyntheticAssemblyInput())
        _ = try c.reserveSend(op, attemptID: second.intent.attemptID)
        f.io.failBefore = "write:" + f.path("catalogue.write.pending")
        await assertThrows(.backendFailure) { try await c.confirmRegistry(op, verifier: verifier) }
        XCTAssertTrue(c.isBroken)
        f.io.failBefore = nil
        let intermediate = try f.coordinator().loadRetained()
        XCTAssertEqual(intermediate.owner?.phase, "registryConfirmed")
        XCTAssertNil(intermediate.catalogue.binding)
        XCTAssertEqual(intermediate.owner?.attempts.map(\.resolution), ["expiredAbsent", "ownerBound"])
        XCTAssertEqual(intermediate.owner?.attempts.map(\.finalizedHeight), [101, 101])
        XCTAssertEqual(intermediate.owner?.attempts.last?.sends, 1)
        let c2 = f.coordinator(); _ = try c2.loadRetained()
        op = try c2.begin(deadline: .now.advanced(by: .seconds(30)))
        XCTAssertThrowsError(try c2.reserveSend(op, attemptID: second.intent.attemptID)) { XCTAssertEqual($0 as? OwnerStoreError, .invalidTransition) }
        op = try c2.begin(deadline: .now.advanced(by: .seconds(30)))
        let published = try c2.publishConfirmedBinding(op)
        XCTAssertEqual(published.catalogue.binding, intermediate.owner?.binding)
        XCTAssertEqual(try c2.publishConfirmedBinding(op), published)
        try c2.finish(op)
        XCTAssertEqual(try f.coordinator().loadRetained(), published)
        XCTAssertEqual(f.coreCalls.filter { !["identity", "lookup"].contains($0) }, [])
    }

    @MainActor func testExpiryResolutionIsTerminalAndPermitsExactlyOneSuccessorAppend() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        var op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.confirmWordsBackup(op)
        let first = try c.recordOwnerSigned(op, intent: f.intent(1, height: 100), signer: PublicVectorSigner())
        let before = f.io.data
        var verifier = SyntheticBindingVerifier(); verifier.height = 100 // not strictly above
        await assertThrows(.invalidTransition) { try await c.resolveExpired(op, proposedName: "bob_fixture", verifier: verifier) }
        XCTAssertEqual(f.io.data, before)
        // A semantic refusal ends the operation; a fresh one must be begun.
        XCTAssertThrowsError(try c.loadRetainedWhileActive(op)) { XCTAssertEqual($0 as? OwnerStoreError, .authorityRequired) }
        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        XCTAssertThrowsError(try c.recordOwnerSigned(op, intent: f.intent(2), signer: PublicVectorSigner())) { XCTAssertEqual($0 as? OwnerStoreError, .invalidTransition) }
        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        verifier.height = 101
        let permit = try await c.resolveExpired(op, proposedName: "bob_fixture", verifier: verifier)
        let resolved = try XCTUnwrap(try c.loadRetainedWhileActive(op).owner?.attempts.first)
        XCTAssertEqual(resolved.resolution, "expiredAbsent"); XCTAssertEqual(resolved.finalizedHeight, 101)
        XCTAssertEqual(resolved.message, first.message)
        let second = try c.recordOwnerSigned(op, intent: f.intent(2, height: 150, name: "bob_fixture"), signer: PublicVectorSigner(), append: permit)
        // The consumed permit cannot append while the new candidate is unresolved.
        XCTAssertThrowsError(try c.recordOwnerSigned(op, intent: f.intent(3, name: "bob_fixture"), signer: PublicVectorSigner(), append: permit)) { XCTAssertEqual($0 as? OwnerStoreError, .invalidTransition) }
        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        verifier.height = 200; verifier.disposition = .nameTaken
        let wrongName = try await c.resolveExpired(op, proposedName: "dave_fixture", verifier: verifier)
        XCTAssertThrowsError(try c.recordOwnerSigned(op, intent: f.intent(3, name: "carol_fixture"), signer: PublicVectorSigner(), append: wrongName)) { XCTAssertEqual($0 as? OwnerStoreError, .authorityRequired) }
        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        // Refusal invalidated the permit even for its own name; the taken name is never re-proposed.
        XCTAssertThrowsError(try c.recordOwnerSigned(op, intent: f.intent(3, name: "dave_fixture"), signer: PublicVectorSigner(), append: wrongName)) { XCTAssertEqual($0 as? OwnerStoreError, .authorityRequired) }
        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        verifier.height = 300
        await assertThrows(.invalidTransition) { try await c.resolveExpired(op, proposedName: "bob_fixture", verifier: verifier) }
        let reopened = try f.coordinator().loadRetained()
        XCTAssertEqual(reopened.owner?.attempts.map(\.intent.attemptID), [first.intent.attemptID, second.intent.attemptID])
        XCTAssertEqual(reopened.owner?.attempts.map(\.resolution), ["expiredAbsent", "nameTaken"])
        XCTAssertEqual(reopened.owner?.phase, "registrationPending")
    }

    @MainActor func testSendReservationIsDurableBeforeTicketAndFourthReleaseRefuses() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        var op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.confirmWordsBackup(op)
        let signed = try c.recordOwnerSigned(op, intent: f.intent(), signer: PublicVectorSigner())
        let assembled = try c.recordAssembled(op, attemptID: signed.intent.attemptID, signer: SyntheticAssemblyInput())
        for expected in 1...3 {
            let ticket = try c.reserveSend(op, attemptID: signed.intent.attemptID)
            XCTAssertNil(f.io.data[f.path("owner/write.pending")])
            XCTAssertEqual(try ticket.take(), try OwnerScalars.wire(XCTUnwrap(assembled.transaction)))
            XCTAssertThrowsError(try ticket.take()) { XCTAssertEqual($0 as? OwnerStoreError, .authorityRequired) }
            try c.finish(op)
            let reopened = try f.coordinator().loadRetained()
            XCTAssertEqual(reopened.owner?.attempts.first?.sends, UInt64(expected))
            XCTAssertEqual(reopened.owner?.attempts.first?.transaction, assembled.transaction)
            op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        }
        let before = f.io.data
        XCTAssertThrowsError(try c.reserveSend(op, attemptID: signed.intent.attemptID)) { XCTAssertEqual($0 as? OwnerStoreError, .limitExceeded) }
        XCTAssertEqual(f.io.data, before)
    }

    @MainActor func testAssemblyRetainsExactPreSponsorEvidenceOnReopen() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.confirmWordsBackup(op)
        let signed = try c.recordOwnerSigned(op, intent: f.intent(), signer: PublicVectorSigner())
        let assembled = try c.recordAssembled(op, attemptID: signed.intent.attemptID, signer: SyntheticAssemblyInput())
        XCTAssertEqual(assembled.intent, signed.intent); XCTAssertEqual(assembled.message, signed.message)
        XCTAssertEqual(assembled.ownerSignature, signed.ownerSignature); XCTAssertEqual(assembled.sends, 0)
        XCTAssertEqual(assembled.stage, "assembled"); XCTAssertNotNil(assembled.transaction)
        try c.finish(op)
        XCTAssertEqual(try f.coordinator().loadRetained().owner?.attempts, [assembled])
    }

    @MainActor func testOwnerSignedEvidenceIsDurableBeforeLeavingCoordinator() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.confirmWordsBackup(op)
        let saved = try c.recordOwnerSigned(op, intent: f.intent(), signer: PublicVectorSigner())
        XCTAssertEqual(saved.stage, "ownerSigned")
        XCTAssertEqual(saved.sends, 0)
        XCTAssertNil(saved.transaction)
        XCTAssertNil(f.io.data[f.path("owner/write.pending")])
        try c.finish(op)
        let reopened = try f.coordinator().loadRetained()
        XCTAssertEqual(reopened.owner?.phase, "registrationPending")
        XCTAssertEqual(reopened.owner?.attempts, [saved])
        XCTAssertEqual(f.coreCalls.filter { !["identity", "lookup"].contains($0) }, [])
    }

    @MainActor func testExplicitBackupConfirmationSurvivesReopen() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op)
        try c.confirmWordsBackup(op); try c.finish(op)
        XCTAssertEqual(try f.coordinator().loadRetained().owner?.wordsBackupConfirmed, true)
    }

    @MainActor func testVerifiedSyntheticRecoveryCommitsOwnerBeforeBindingAndReopensBoth() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let pair = try await c.recoverVerified(op, entropy: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", verifier: SyntheticBindingVerifier())
        XCTAssertEqual(pair.owner?.phase, "registryConfirmed")
        XCTAssertEqual(pair.owner?.binding, pair.catalogue.binding)
        XCTAssertEqual(pair.catalogue.binding?.name, "alice_fixture")
        XCTAssertFalse(try XCTUnwrap(pair.owner).wordsBackupConfirmed)
        XCTAssertEqual(f.entropyCalls, 0)
        let ownerRename = try XCTUnwrap(f.io.events.firstIndex(of: "rename:" + f.path("owner/state.enc.tmp")))
        let publishRename = try XCTUnwrap(f.io.events.lastIndex(of: "rename:" + f.path("text-state.enc.tmp")))
        XCTAssertLessThan(ownerRename, publishRename)
        try c.finish(op)
        XCTAssertEqual(try f.coordinator().loadRetained(), pair)
    }

    @MainActor func testReservationPrecedesPublicEntropyAndOwnerCommitReopens() async throws {
        let f = try OwnerFixture()
        let c = f.coordinator()
        let bootstrap = try c.loadRetained()
        XCTAssertFalse(bootstrap.catalogue.allocated)
        XCTAssertNil(bootstrap.owner)
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let permit = try c.reserveNewOwner(op)
        XCTAssertEqual(f.entropyCalls, 0)
        XCTAssertNil(f.owner.key)
        XCTAssertNil(f.io.kinds[f.path("owner")])
        f.onEntropy = {
            XCTAssertNil(f.io.data[f.path("catalogue.write.pending")])
            XCTAssertEqual(f.io.events.last, "sync:" + f.root.path)
        }
        let value = try c.initializeNew(permit, operation: op)
        XCTAssertEqual(value.entropy, "AAAAAAAAAAAAAAAAAAAAAA==")
        let actual = try DevnetBridge.command(request: #"{"op":"identity","entropy":"AAAAAAAAAAAAAAAAAAAAAA=="}"#)
        XCTAssertEqual(value.owner, actual.object["owner"] as? String)
        XCTAssertEqual(value.phase, "unregistered")
        XCTAssertEqual(f.entropyCalls, 1)
        try c.finish(op)
        let reopened = try f.coordinator().loadRetained()
        XCTAssertTrue(reopened.catalogue.allocated)
        XCTAssertEqual(reopened.owner, value)
        XCTAssertEqual(f.catalogue.key, 1)
        XCTAssertEqual(f.owner.key, 2)
        XCTAssertFalse(f.io.events.contains { $0.contains("realms") && !$0.hasPrefix("inspect:") })
    }
}

// NON-CRYPTOGRAPHIC trusted assembly-input fixture: structurally consistent
// bytes, NOT a signature-valid transaction or executed sponsored_assemble.
@MainActor struct SyntheticAssemblyInput: IsolatedTrustedOwnerAssembler {
    func assembled(for r: OwnerAssemblyRequest) throws -> OwnerAssemblyEvidence {
        let sig = Data(repeating: 0, count: 64)
        let bytes = try Data([2]) + sig + OwnerScalars.base58(r.attempt.ownerSignature, count: 64) + OwnerScalars.wire(r.attempt.message)
        return .init(request: r, transaction: bytes.base64EncodedString(), signature: OwnerScalars.base58Encode(sig))
    }
}
// Real Rust sponsored_sign on public all-zero 16-byte entropy. This fixture
// vouches only for the isolated boundary; no foreground UI/RPC trust is tested.
@MainActor struct PublicVectorSigner: IsolatedTrustedOwnerSigner {
    func ownerSigned(for r: OwnerSigningRequest) throws -> OwnerSignedEvidence {
        let v = r.material; let t = r.intent
        let result = try DevnetBridge.command(request: #"{"op":"sponsored_sign","entropy":"\#(v.entropy)","name":"\#(t.name)","blockhash":"\#(t.blockhash)","genesis":"\#(v.genesis)","payer":"\#(t.payer)"}"#).object
        XCTAssertEqual(result["owner"] as? String, v.owner); XCTAssertEqual(result["name"] as? String, t.name)
        return try .init(request: r, message: XCTUnwrap(result["message"] as? String), ownerSignature: XCTUnwrap(result["owner_signature"] as? String))
    }
}

@MainActor func assertThrows<T>(_ expected: OwnerStoreError, _ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await body(); XCTFail("expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? OwnerStoreError, expected, file: file, line: line) }
}

@MainActor struct SyntheticBindingVerifier: IsolatedTrustedOwnerVerifier {
    func binding(for request: OwnerBindingRequest) async throws -> OwnerBindingEvidence? {
        let v = request.material
        return .init(request: request, binding: .init(genesis: v.genesis, program: v.program, identity: v.identity, owner: v.owner, name: "alice_fixture"), finalizedHeight: 101)
    }
    var height: UInt64 = 101
    var disposition = OwnerTerminalDisposition.expiredAbsent
    func expiry(for request: OwnerExpiryRequest) async throws -> OwnerExpiryEvidence? {
        .init(request: request, finalizedHeight: height, dispositions: request.material.attempts.filter { $0.resolution == "unresolved" }.map { ($0.intent.attemptID, disposition) })
    }
}

final class OwnerFixtureIO: OwnerFileIO {
    var data: [String: Data] = [:]
    var kinds: [String: CataloguePathKind] = [:]
    var events: [String] = []
    var failBefore: String?
    var faultAt: Int?
    var faultAfter = false
    var effects: [String] = []
    /// Fault seam: throw before or after exactly the N-th effect; never undo it.
    func effect(_ e: String, _ apply: () throws -> Void) throws {
        events.append(e)
        if e == failBefore { throw OwnerStoreError.backendFailure }
        let index = effects.count
        if faultAt == index, !faultAfter { throw OwnerStoreError.backendFailure }
        try apply(); effects.append(e)
        if faultAt == index, faultAfter { throw OwnerStoreError.backendFailure }
    }
    private func record(_ e: String) throws { events.append(e); if e == failBefore { throw OwnerStoreError.backendFailure } }
    func inspect(_ u: URL) throws -> CataloguePathKind { events.append("inspect:" + u.path); return kinds[u.path] ?? (data[u.path] == nil ? .absent : .regularFile) }
    func writeExclusive(_ bytes: Data, to u: URL) throws { try effect("write:" + u.path) { guard data[u.path] == nil, kinds[u.path] == nil else { throw OwnerStoreError.artifactsPresent }; data[u.path] = bytes } }
    func protectAndExclude(_ u: URL) throws { try effect("protectCatalogue:" + u.path) {} }
    func protectOwnerAndExclude(_ u: URL, policy: OwnerProtection) throws { try effect("protectOwner:" + u.path) {} }
    func createOwnerDirectory(_ u: URL) throws { try effect("mkdir:" + u.path) { guard kinds[u.path] == nil, data[u.path] == nil else { throw OwnerStoreError.artifactsPresent }; kinds[u.path] = .directory } }
    func fullSync(_ u: URL, directory: Bool) throws { try effect("sync:" + u.path) {} }
    func rename(_ u: URL, to d: URL) throws { try effect("rename:" + u.path) { data[d.path] = data.removeValue(forKey: u.path) } }
    func read(_ u: URL, maximumBytes: Int) throws -> Data { events.append("read:" + u.path); guard let bytes = data[u.path] else { throw OwnerStoreError.continuity }; guard bytes.count <= maximumBytes else { throw OwnerStoreError.limitExceeded }; return bytes }
    func removeIntent(_ u: URL) throws { try effect("remove:" + u.path) { data.removeValue(forKey: u.path) } }
}
final class OwnerFixtureCrypto: OwnerCryptography {
    let id: Int
    var key: Int?
    let io: OwnerFixtureIO
    var foreign: (CatalogueForeignStore) -> Bool = { _ in false }
    init(_ id: Int, _ io: OwnerFixtureIO) { self.id = id; self.io = io }
    var framingOverhead: Int { 29 }
    func loadKey() throws -> Int? { io.events.append("keyLoad:\(id)"); return key }
    func createKey() throws -> Int { try io.effect("keyCreate:\(id)") { guard key == nil else { throw OwnerStoreError.keyMismatch }; key = id }; return id }
    func foreignKeyExists(_ slot: CatalogueForeignStore) throws -> Bool { io.events.append("foreign:\(slot.rawValue)"); return foreign(slot) }
    func seal(_ plaintext: Data, with key: Int) throws -> Data { try io.effect("seal:\(id)") {}; return Data(repeating: UInt8(key), count: 29) + plaintext }
    func open(_ sealed: Data, with key: Int) throws -> Data { io.events.append("open:\(id)"); guard sealed.count >= 29, sealed.prefix(29).allSatisfy({ $0 == UInt8(key) }) else { throw OwnerStoreError.authenticationFailed }; return sealed.dropFirst(29) }
}
@MainActor final class OwnerFixture {
    let root = URL(fileURLWithPath: "/isolated-public-owner-fixture")
    let io = OwnerFixtureIO()
    let context: IdentityCatalogue
    let catalogue: OwnerFixtureCrypto
    let owner: OwnerFixtureCrypto
    var coreCalls: [String] = []
    var entropyCalls = 0
    var onEntropy: (() -> Void)?
    init() throws {
        let fi = try IdentityCatalogue.Realm(origin: "https://fi.example", pin: String(repeating: "a", count: 64), protocolKind: "identity-v3")
        let ru = try IdentityCatalogue.Realm(origin: "https://ru.example", pin: String(repeating: "b", count: 64), protocolKind: "identity-v3")
        context = try IdentityCatalogue(installID: "00000000-0000-0000-0000-000000000001", ownerRef: "00000000-0000-0000-0000-000000000002", realms: .init(fi: fi, ru: ru))
        catalogue = OwnerFixtureCrypto(1, io); owner = OwnerFixtureCrypto(2, io)
        catalogue.foreign = { [owner] in $0 == .owner && owner.key != nil }
        io.kinds[root.path] = .directory
        catalogue.key = 1
        io.data[root.appendingPathComponent("text-state.enc").path] = try catalogue.seal(IdentityCatalogueCodec.encode(context), with: 1)
        io.events = []; io.effects = []
    }
    func path(_ s: String) -> String { root.appendingPathComponent(s).path }
    func intent(_ number: Int = 1, height: UInt64 = 100, name: String = "alice_fixture") -> OwnerAttemptIntent {
        .init(attemptID: String(format: "00000000-0000-0000-0000-%012d", number), name: name, sponsorRealmKey: context.realms.fi, payer: String(repeating: "1", count: 32), blockhash: String(repeating: "1", count: 32), lastValidHeight: height)
    }
    func coordinator() -> OwnerAllocationCoordinator<OwnerFixtureCrypto, OwnerFixtureCrypto> {
        OwnerAllocationCoordinator(directory: root, context: context, files: io, catalogueCrypto: catalogue, ownerCrypto: owner, entropy: { [self] in entropyCalls += 1; onEntropy?(); return Data(repeating: 0, count: 16) }, core: .init(observed: { [self] in coreCalls.append($0) }))
    }
}
