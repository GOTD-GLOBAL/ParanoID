import Foundation
import XCTest
@testable import ParanoidKit

final class OwnerStoreRegressionTests: XCTestCase {
    @MainActor func testContradictoryTakenProposedNameDoesNotRewriteLedgerOrMintPermit() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.confirmWordsBackup(op)
        _ = try c.recordOwnerSigned(op, intent: f.intent(), signer: PublicVectorSigner())
        let before = f.io.data
        var verifier = SyntheticBindingVerifier(); verifier.disposition = .nameTaken
        await assertThrows(.invalidTransition) {
            try await c.resolveExpired(op, proposedName: "alice_fixture", verifier: verifier)
        }
        XCTAssertEqual(f.io.data, before, "inconsistent evidence must not rewrite the retained ledger")
        XCTAssertFalse(c.isBroken)
    }

    @MainActor func testBusyBackendFailureAfterAnEffectStillBreaksWriter() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        f.io.faultAt = 0; f.io.faultAfter = true; f.io.faultError = .busy
        XCTAssertThrowsError(try c.reserveNewOwner(op))
        XCTAssertTrue(c.isBroken, "busy is only non-destructive for an incoming request, not a failed write")
        let events = f.io.events
        XCTAssertThrowsError(try c.reserveNewOwner(op)) { XCTAssertEqual($0 as? OwnerStoreError, .broken) }
        XCTAssertEqual(f.io.events, events)
        XCTAssertNotNil(f.io.data[f.path("catalogue.write.pending")])
    }

    @MainActor func testOwnerWriterBoundsEveryInterpolatedFieldBeforeRustValidation() async throws {
        let f = try OwnerFixture(); var calls: [String] = []
        let core = OwnerMaterialCore(observed: { calls.append($0) })
        let base = try core.identity(entropy: "AAAAAAAAAAAAAAAAAAAAAA==", context: f.context)
        var v = base
        v.phase = String(repeating: "a", count: 1_000_000)
        calls = []
        XCTAssertThrowsError(try OwnerEnvelopeCodec.encode(v, core: core)) { XCTAssertEqual($0 as? OwnerStoreError, .limitExceeded) }
        XCTAssertTrue(calls.isEmpty)
        v = base; v.phase = "registrationPending"; v.wordsBackupConfirmed = true
        v.attempts = [.init(intent: f.intent(name: #"\u0061lice_fixture"#), message: "AQ==", ownerSignature: String(repeating: "1", count: 64))]
        calls = []
        XCTAssertThrowsError(try OwnerEnvelopeCodec.encode(v, core: core))
        XCTAssertTrue(calls.isEmpty, "invalid new model must be rejected before Rust derivation")
        XCTAssertTrue(f.io.effects.isEmpty)
    }

    @MainActor func testLateCancelledVerifierCannotClearSuccessorAuthority() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        let old = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let gate = GateVerifier()
        let task = Task { @MainActor in try await c.recoverVerified(old, entropy: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", verifier: gate) }
        await gate.entered()
        try c.cancel(old)
        let successor = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        gate.release(.evidence)
        do { _ = try await task.value; XCTFail("cancelled callback succeeded") } catch { }
        XCTAssertTrue(f.io.effects.isEmpty)
        XCTAssertFalse(try c.loadRetainedWhileActive(successor).catalogue.allocated)
        try c.finish(successor)
    }

    @MainActor func testCancellationAndCloseAtEveryCreationEffectStopsWithoutCompensation() async throws {
        let baseline = try OwnerFixture(); let bc = baseline.coordinator()
        let bop = try bc.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try bc.initializeNew(bc.reserveNewOwner(bop), operation: bop)
        let effects = baseline.io.effects
        for close in [false, true] {
            for index in effects.indices {
                let f = try OwnerFixture(); let c = f.coordinator()
                let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
                f.io.onEffect = { _ in
                    if f.io.effects.count == index + 1 {
                        if close { c.close() } else { do { try c.cancel(op) } catch { XCTFail("cancel refused: \(error)") } }
                    }
                }
                XCTAssertThrowsError(try c.initializeNew(c.reserveNewOwner(op), operation: op))
                XCTAssertTrue(c.isBroken, "effect \(index), close=\(close)")
                XCTAssertEqual(f.io.effects, Array(effects.prefix(index + 1)), "no post-revocation effects")
                let events = f.io.events
                XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .broken) }
                XCTAssertEqual(f.io.events, events)
            }
        }
    }

    @MainActor func testReadOnlyExpiryChecksImmediatelyBeforeSignerAndAssembler() async throws {
        // Parent/reviewer observed runtime RED against frozen 697bd685 for the
        // real-public-vector signer case; extend the same boundary to assembly.
        for assembling in [false, true] {
            let f = try OwnerFixture(); let c = f.coordinator()
            let setup = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            _ = try c.initializeNew(c.reserveNewOwner(setup), operation: setup); try c.confirmWordsBackup(setup)
            if assembling { _ = try c.recordOwnerSigned(setup, intent: f.intent(), signer: PublicVectorSigner()) }
            try c.finish(setup)
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
            let op = try c.begin(deadline: deadline)
            var delayed = false
            f.io.onEvent = { event in
                if event == "keyLoad:2", !delayed {
                    delayed = true
                    while ContinuousClock.now <= deadline { Thread.sleep(forTimeInterval: 0.002) }
                }
            }
            let signer = CountingOwnerSigner(); let assembler = CountingOwnerAssembler()
            let effects = f.io.effects
            if assembling { XCTAssertThrowsError(try c.recordAssembled(op, attemptID: f.intent().attemptID, signer: assembler)) }
            else { XCTAssertThrowsError(try c.recordOwnerSigned(op, intent: f.intent(), signer: signer)) }
            XCTAssertTrue(delayed); XCTAssertEqual(signer.calls, 0); XCTAssertEqual(assembler.calls, 0)
            XCTAssertEqual(f.io.effects, effects); XCTAssertFalse(c.isBroken, "read-only expiry is not write uncertainty")
        }
    }

    @MainActor func testTicketRevokedOnCloseConfirmationAndCoordinatorDestruction() async throws {
        for reason in ["close", "confirmed", "deallocated"] {
            let f = try OwnerFixture(); let lease = OwnerNamespaceLease(root: f.root); let h = try lease.acquire()
            var c: OwnerAllocationCoordinator<OwnerFixtureCrypto, OwnerFixtureCrypto>? = OwnerAllocationCoordinator(
                directory: f.root, context: f.context, files: LeasedFileIO(f.io, lease: lease, holder: h),
                catalogueCrypto: LeasedCryptography(f.catalogue, lease: lease, holder: h),
                ownerCrypto: LeasedCryptography(f.owner, lease: lease, holder: h), entropy: { Data(repeating: 0, count: 16) })
            let op = try c!.begin(deadline: .now.advanced(by: .seconds(30)))
            _ = try c!.initializeNew(c!.reserveNewOwner(op), operation: op); try c!.confirmWordsBackup(op)
            let s = try c!.recordOwnerSigned(op, intent: f.intent(), signer: PublicVectorSigner())
            _ = try c!.recordAssembled(op, attemptID: s.intent.attemptID, signer: SyntheticAssemblyInput())
            let ticket = try c!.reserveSend(op, attemptID: s.intent.attemptID)
            switch reason {
            case "close": c!.close()
            case "confirmed": _ = try await c!.confirmRegistry(op, verifier: SyntheticBindingVerifier())
            default:
                weak let weakCoordinator = c
                c = nil
                XCTAssertNil(weakCoordinator, "ticket must not retain its issuing coordinator")
            }
            let events = f.io.events
            XCTAssertThrowsError(try ticket.take(), reason)
            XCTAssertEqual(f.io.events, events)
        }
    }

    @MainActor func testInvalidNewCandidateRefusesWithoutFreezingRetainedStore() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        var op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.confirmWordsBackup(op)
        let signer = CountingOwnerSigner(); let bytes = f.io.data
        XCTAssertThrowsError(try c.recordOwnerSigned(op, intent: f.intent(name: "NotCanonical"), signer: signer)) {
            XCTAssertEqual($0 as? OwnerStoreError, .invalidFormat)
        }
        XCTAssertEqual(signer.calls, 0); XCTAssertEqual(f.io.data, bytes); XCTAssertFalse(c.isBroken)
        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        XCTAssertNotNil(try c.loadRetainedWhileActive(op).owner)
    }

    @MainActor func testRejectedOldTicketCannotCancelSuccessorOperation() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        let old = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(old), operation: old); try c.confirmWordsBackup(old)
        let signed = try c.recordOwnerSigned(old, intent: f.intent(), signer: PublicVectorSigner())
        _ = try c.recordAssembled(old, attemptID: signed.intent.attemptID, signer: SyntheticAssemblyInput())
        let ticket = try c.reserveSend(old, attemptID: signed.intent.attemptID)
        try c.finish(old)
        let next = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let events = f.io.events
        XCTAssertThrowsError(try ticket.take())
        XCTAssertEqual(f.io.events, events)
        XCTAssertNoThrow(try c.loadRetainedWhileActive(next), "old capability must not revoke the successor")
    }

    @MainActor func testFullLedgerReconcilesWithoutIssuingAppendAuthority() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        var op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.confirmWordsBackup(op)
        var permit: OwnerAppendPermit?
        for i in 1...8 {
            _ = try c.recordOwnerSigned(op, intent: f.intent(i), signer: PublicVectorSigner(), append: permit)
            if i != 8 {
                permit = try await c.resolveExpired(op, proposedName: "alice_fixture", verifier: SyntheticBindingVerifier())
                XCTAssertNotNil(permit)
            }
        }
        let before = try XCTUnwrap(c.loadRetainedWhileActive(op).owner)
        do {
            let append: OwnerAppendPermit? = try await c.resolveExpired(op, proposedName: "alice_fixture", verifier: SyntheticBindingVerifier())
            XCTAssertNil(append, "full ledger reconciles but must not mint an inoperable permit")
        } catch { XCTFail("eighth reconciliation refused: \(error)"); return }
        let after = try XCTUnwrap(c.loadRetainedWhileActive(op).owner)
        XCTAssertEqual(after.attempts.count, 8)
        XCTAssertEqual(Array(after.attempts.dropLast()), Array(before.attempts.dropLast()))
        XCTAssertEqual(after.attempts.map(\.intent), before.attempts.map(\.intent))
        XCTAssertEqual(after.attempts.last?.resolution, "expiredAbsent")
        let signer = CountingOwnerSigner()
        XCTAssertThrowsError(try c.recordOwnerSigned(op, intent: f.intent(9), signer: signer)) {
            XCTAssertEqual($0 as? OwnerStoreError, .limitExceeded)
        }
        XCTAssertEqual(signer.calls, 0)
        op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let pair = try await c.confirmRegistry(op, verifier: SyntheticBindingVerifier())
        XCTAssertEqual(pair.owner?.attempts, after.attempts)
        XCTAssertEqual(pair.owner?.phase, "registryConfirmed")
        XCTAssertEqual(pair.catalogue.binding, pair.owner?.binding)
    }

    @MainActor func testInvalidRetainedDocumentsMustFreezeWriter() async throws {
        for target in ["catalogue", "owner"] {
            for mode in ["schema", "version", "bound", "material"] {
                let f = try OwnerFixture(); let c0 = f.coordinator()
                let op = try c0.begin(deadline: .now.advanced(by: .seconds(30)))
                _ = try c0.initializeNew(c0.reserveNewOwner(op), operation: op); try c0.finish(op)
                let path = f.path(target == "catalogue" ? "text-state.enc" : "owner/state.enc")
                let saved = f.io.data[path]!
                var text = String(decoding: saved.dropFirst(29), as: UTF8.self)
                var expected = OwnerStoreError.invalidFormat
                switch mode {
                case "schema": text = text.replacingOccurrences(of: target == "catalogue" ? #""kind":"catalogue""# : #""kind":"owner""#, with: #""kind":"invalid""#)
                case "version": text = text.replacingOccurrences(of: target == "catalogue" ? #""version":5"# : #""version":1"#, with: #""version":99"#); expected = .unsupportedVersion
                case "bound": text = String(repeating: " ", count: 65_566); expected = .limitExceeded
                default:
                    if target == "catalogue" { continue }
                    let m = try OwnerMaterialCore().identity(entropy: "AAAAAAAAAAAAAAAAAAAAAA==", context: f.context)
                    text = text.replacingOccurrences(of: #""owner":"\#(m.owner)""#, with: #""owner":"\#(m.identity)""#); expected = .bindingMismatch
                }
                f.io.data[path] = try (target == "catalogue" ? f.catalogue : f.owner).seal(Data(text.utf8), with: target == "catalogue" ? 1 : 2)
                let c = f.coordinator()
                XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, expected) }
                print("REVIEW retained \(target)/\(mode): first=\(expected) broken=\(c.isBroken)")
                XCTAssertTrue(c.isBroken, "integrity failure must freeze retained \(target)/\(mode)")
                f.io.events = []
                XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .broken) }
                XCTAssertTrue(f.io.events.isEmpty, "broken writer must not touch backend")
                // Test-only restoration is not authority to revive this writer.
                f.io.data[path] = saved
                f.io.events = []
                XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .broken) }
                XCTAssertTrue(f.io.events.isEmpty)
            }
        }
    }
    @MainActor func testExpiryAtWriteBoundariesNeverAdoptsOrReleasesSuccess() async throws {
        // Each injected delay occurs AFTER the named real fixture effect. Final
        // sync is distinguished by the already removed intent, not a guessed sleep.
        for kind in ["allocation", "creation", "send"] {
            for boundary in ["intent", "key", "finalSync"] {
                let f = try OwnerFixture(); let c = f.coordinator()
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                let op = try c.begin(deadline: deadline)
                var permit: OwnerCreationPermit?
                var attemptID = ""
                if kind != "allocation" { permit = try c.reserveNewOwner(op) }
                if kind == "send" {
                    _ = try c.initializeNew(XCTUnwrap(permit), operation: op); try c.confirmWordsBackup(op)
                    let signed = try c.recordOwnerSigned(op, intent: f.intent(), signer: PublicVectorSigner())
                    attemptID = signed.intent.attemptID
                    _ = try c.recordAssembled(op, attemptID: attemptID, signer: SyntheticAssemblyInput())
                }
                f.io.effects = []
                let intent = f.path(kind == "allocation" ? "catalogue.write.pending" : "owner/write.pending")
                let parent = kind == "allocation" ? f.root.path : f.path("owner")
                var triggered = false
                f.io.onEffect = { event in
                    let target: Bool
                    switch boundary {
                    case "intent": target = event == "write:" + intent
                    case "key": target = event == (kind == "creation" ? "keyCreate:2" : (kind == "send" ? "seal:2" : "seal:1"))
                    default: target = event == "sync:" + parent && f.io.effects.contains("remove:" + intent)
                    }
                    if target && !triggered {
                        triggered = true
                        while ContinuousClock.now <= deadline { Thread.sleep(forTimeInterval: 0.002) }
                    }
                }
                switch kind {
                case "allocation": XCTAssertThrowsError(try c.reserveNewOwner(op))
                case "creation": XCTAssertThrowsError(try c.initializeNew(XCTUnwrap(permit), operation: op))
                default: XCTAssertThrowsError(try c.reserveSend(op, attemptID: attemptID))
                }
                XCTAssertTrue(triggered, kind + boundary)
                XCTAssertTrue(c.isBroken, "expired after effect: " + kind + boundary)
                let events = f.io.events; let bytes = f.io.data
                XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .broken) }
                XCTAssertEqual(f.io.events, events); XCTAssertEqual(f.io.data, bytes)
                if boundary != "finalSync" { XCTAssertNotNil(f.io.data[intent], "no cleanup after expiry") }
            }
        }
    }

    @MainActor func testExternalWaitIsBoundedAndCancellationDoesNotDependOnVerifierCooperation() async throws {
        for reason in ["cancel", "task", "deadline", "close"] {
            let f = try OwnerFixture(); let c = f.coordinator()
            let deadline = ContinuousClock.now.advanced(by: reason == "deadline" ? .seconds(1) : .seconds(30))
            let op = try c.begin(deadline: deadline)
            let gate = GateVerifier()
            defer { gate.release(.evidence) }
            let finished = XCTestExpectation(description: "caller finished: " + reason)
            let task = Task { @MainActor in
                defer { finished.fulfill() }
                return try await c.recoverVerified(op, entropy: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", verifier: gate)
            }
            await gate.entered()
            switch reason {
            case "cancel": do { try c.cancel(op) } catch { XCTFail("cancel refused: \(error)") }
            case "task": task.cancel()
            case "close": c.close()
            default: break
            }
            // Test-only watchdog, not a production deadline or scheduler-latency
            // assertion. Keep the verifier held until the caller completes or fails
            // this finite wait; even on RED, release it before awaiting task.value.
            let completion = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(completion, .completed, "caller must finish without waiting for verifier: " + reason)
            let before = f.io.events
            gate.release(.evidence)
            do { _ = try await task.value; XCTFail("late success: " + reason) } catch { }
            XCTAssertEqual(f.io.events, before, "late callback cannot revive authority")
            XCTAssertTrue(f.io.effects.isEmpty)
            if reason != "close" {
                do {
                    let fresh = try c.begin(deadline: .now.advanced(by: .seconds(30)))
                    XCTAssertFalse(try c.loadRetainedWhileActive(fresh).catalogue.allocated)
                    try c.finish(fresh)
                } catch { XCTFail("fresh operation refused: \(reason): \(error)") }
            }
        }
    }

    @MainActor func testTicketRevocationOnRevisionErrorDeadlineAndLeaseLoss() async throws {
        for reason in ["revision", "error", "deadline", "lease"] {
            let f = try OwnerFixture(); let lease = OwnerNamespaceLease(root: f.root); let holder = try lease.acquire()
            let c = OwnerAllocationCoordinator(directory: f.root, context: f.context,
                files: LeasedFileIO(f.io, lease: lease, holder: holder),
                catalogueCrypto: LeasedCryptography(f.catalogue, lease: lease, holder: holder),
                ownerCrypto: LeasedCryptography(f.owner, lease: lease, holder: holder),
                entropy: { Data(repeating: 0, count: 16) })
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            let op = try c.begin(deadline: deadline)
            _ = try c.initializeNew(c.reserveNewOwner(op), operation: op)
            try c.confirmWordsBackup(op)
            let signed = try c.recordOwnerSigned(op, intent: f.intent(), signer: PublicVectorSigner())
            _ = try c.recordAssembled(op, attemptID: signed.intent.attemptID, signer: SyntheticAssemblyInput())
            let ticket = try c.reserveSend(op, attemptID: signed.intent.attemptID)
            switch reason {
            case "revision": _ = try c.reserveSend(op, attemptID: signed.intent.attemptID)
            case "error": XCTAssertThrowsError(try c.reserveSend(op, attemptID: "foreign"))
            case "deadline": try await Task.sleep(until: deadline, clock: .continuous)
            default: lease.retire(holder)
            }
            let events = f.io.events
            XCTAssertThrowsError(try ticket.take(), reason)
            XCTAssertEqual(f.io.events, events, "release checks volatile authority before backend: " + reason)
            let bytes = try XCTUnwrap(f.io.data[f.path("owner/state.enc")])
            XCTAssertEqual(try OwnerEnvelopeCodec.decode(bytes.dropFirst(29), context: f.context, core: .init()).attempts.first?.sends,
                           reason == "revision" ? 2 : 1, "lost release never refunds a send")
        }
    }

    @MainActor func testExclusiveLeaseRejectsSecondCoordinatorAndMixedNamespaceWithoutIO() async throws {
        let f = try OwnerFixture(); let lease = OwnerNamespaceLease(root: f.root); let holder = try lease.acquire()
        func make(_ other: OwnerNamespaceLease, _ h: OwnerNamespaceLease.Holder) -> OwnerAllocationCoordinator<OwnerFixtureCrypto, OwnerFixtureCrypto> {
            OwnerAllocationCoordinator(directory: f.root, context: f.context,
                files: LeasedFileIO(f.io, lease: lease, holder: holder),
                catalogueCrypto: LeasedCryptography(f.catalogue, lease: lease, holder: holder),
                ownerCrypto: LeasedCryptography(f.owner, lease: other, holder: h), entropy: { Data(repeating: 0, count: 16) })
        }
        let first = make(lease, holder); _ = try first.loadRetained()
        let second = make(lease, holder); let events = f.io.events
        XCTAssertThrowsError(try second.loadRetained(), "one holder must not authorize two coordinators")
        XCTAssertEqual(f.io.events, events)
        let foreign = OwnerNamespaceLease(root: f.root); let foreignHolder = try foreign.acquire()
        let mixed = make(foreign, foreignHolder)
        XCTAssertThrowsError(try mixed.loadRetained(), "all three handles must share the exact lease/holder")
        XCTAssertEqual(f.io.events, events)
    }

    @MainActor func testAllocatedCatalogueWriterRejectsInvalidBindingWithoutMutation() async throws {
        let f = try OwnerFixture()
        let before = f.io.data
        let material = try OwnerMaterialCore().identity(entropy: "AAAAAAAAAAAAAAAAAAAAAA==", context: f.context)
        for name in ["Alice", "alice\"", #"\u0061lice_fixture"#, String(repeating: "a", count: 25)] {
            let b = OwnerBinding(genesis: material.genesis, program: material.program,
                identity: material.identity, owner: material.owner, name: name)
            // Nested call compiles on both old and strict throwing writers; rejection must happen in encode.
            XCTAssertThrowsError(try writerOnly(.init(context: f.context, allocated: true, binding: b)))
        }
        let b = OwnerBinding(genesis: "not_base58", program: material.program,
            identity: material.identity, owner: material.owner, name: "alice_fixture")
        XCTAssertThrowsError(try writerOnly(.init(context: f.context, allocated: true, binding: b)))
        XCTAssertEqual(f.io.data, before)
    }

    private func writerOnly(_ value: AllocatedCatalogueState) throws -> Data {
        // A throwing closure keeps the RED source valid before encode becomes throwing.
        let encode: (AllocatedCatalogueState) throws -> Data = AllocatedCatalogueCodec.encode
        return try encode(value)
    }

    @MainActor func testDispatchTicketIsInvalidAfterFinishOrCancel() async throws {
        for cancel in [false, true] {
            let f = try OwnerFixture(); let c = f.coordinator()
            let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            _ = try c.initializeNew(c.reserveNewOwner(op), operation: op)
            try c.confirmWordsBackup(op)
            let signed = try c.recordOwnerSigned(op, intent: f.intent(), signer: PublicVectorSigner())
            _ = try c.recordAssembled(op, attemptID: signed.intent.attemptID, signer: SyntheticAssemblyInput())
            let ticket = try c.reserveSend(op, attemptID: signed.intent.attemptID)
            if cancel { try c.cancel(op) } else { try c.finish(op) }
            XCTAssertThrowsError(try ticket.take(), "dispatch must not survive operation cancellation/completion")
        }
    }

    @MainActor func testExplicitCancellationDuringVerifierWaitPreventsWrites() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let gate = GateVerifier()
        let task = Task { @MainActor in
            try await c.recoverVerified(op, entropy: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", verifier: gate)
        }
        await gate.entered()
        do { try c.cancel(op) }
        catch { XCTFail("explicit cancellation was refused: \(error)") }
        gate.release(.evidence)
        do { _ = try await task.value; XCTFail("cancelled recovery adopted late verification") }
        catch { XCTAssertTrue([OwnerStoreError.cancelled, .authorityRequired].contains(error as? OwnerStoreError ?? .backendFailure)) }
        XCTAssertTrue(f.io.effects.isEmpty, "cancel before allocation must perform zero writes")
        XCTAssertNil(f.owner.key)
    }

    @MainActor func testRetiredLeaseRefusesBeforeEntropyGeneration() async throws {
        let f = try OwnerFixture()
        let lease = OwnerNamespaceLease(root: f.root)
        let h = try lease.acquire()
        let c = OwnerAllocationCoordinator(directory: f.root, context: f.context,
            files: LeasedFileIO(f.io, lease: lease, holder: h),
            catalogueCrypto: LeasedCryptography(f.catalogue, lease: lease, holder: h),
            ownerCrypto: LeasedCryptography(f.owner, lease: lease, holder: h),
            entropy: { f.entropyCalls += 1; return Data(repeating: 0, count: 16) })
        let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
        let permit = try c.reserveNewOwner(op)
        lease.retire(h)
        let events = f.io.events
        XCTAssertThrowsError(try c.initializeNew(permit, operation: op))
        XCTAssertEqual(f.entropyCalls, 0, "lost lease invalidates authority before entropy")
        XCTAssertEqual(f.io.events, events, "stale wrapped handles must not reach backend")
    }

    @MainActor func testMessagingWrapperDoesNotAcquireOwnerPolicyConformance() async throws {
        let f = try OwnerFixture()
        let lease = OwnerNamespaceLease(root: f.root)
        let h = try lease.acquire()
        let inner = CatalogueOnlyProbe(inner: f.catalogue)
        XCTAssertFalse((inner as Any) is any OwnerCryptography)
        let wrapped: Any = LeasedCryptography(inner, lease: lease, holder: h)
        XCTAssertFalse(wrapped is any OwnerCryptography, "wrapping cannot upgrade messaging policy to owner policy")
        XCTAssertTrue((LeasedCryptography(f.owner, lease: lease, holder: h) as Any) is any OwnerCryptography)
    }

    @MainActor func testExpiryDuringAllocationWriteCannotMintCreationPermit() async throws {
        let f = try OwnerFixture(); let c = f.coordinator()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        let op = try c.begin(deadline: deadline)
        f.io.onEffect = { event in
            if event == "write:" + f.path("catalogue.write.pending") {
                while ContinuousClock.now <= deadline { Thread.sleep(forTimeInterval: 0.02) }
            }
        }
        XCTAssertThrowsError(try c.reserveNewOwner(op), "expired operation must not get a fresh permit")
        XCTAssertTrue(c.isBroken, "expiry after write began is terminal uncertainty")
        XCTAssertEqual(f.entropyCalls, 0)
        XCTAssertNil(f.owner.key)
    }

    @MainActor func testInvalidCatalogueInputIsNotSilentlyNormalized() async throws {
        let f = try OwnerFixture()
        let material = try OwnerMaterialCore().identity(entropy: "AAAAAAAAAAAAAAAAAAAAAA==", context: f.context)
        let binding = OwnerBinding(genesis: material.genesis, program: material.program,
            identity: material.identity, owner: material.owner, name: "alice_fixture")
        let impossible = AllocatedCatalogueState(context: f.context, allocated: false, binding: binding)
        XCTAssertThrowsError(try AllocatedCatalogueCodec.decode(AllocatedCatalogueCodec.encode(impossible), context: f.context),
                            "invalid binding must not be silently discarded by encode")
    }
}

@MainActor private final class CountingOwnerAssembler: IsolatedTrustedOwnerAssembler {
    var calls = 0
    func assembled(for request: OwnerAssemblyRequest) throws -> OwnerAssemblyEvidence {
        calls += 1
        return try SyntheticAssemblyInput().assembled(for: request)
    }
}

@MainActor private final class CountingOwnerSigner: IsolatedTrustedOwnerSigner {
    var calls = 0
    func ownerSigned(for request: OwnerSigningRequest) throws -> OwnerSignedEvidence {
        calls += 1
        return try PublicVectorSigner().ownerSigned(for: request)
    }
}

private struct CatalogueOnlyProbe: CatalogueCryptography {
    typealias Key = Int
    let inner: OwnerFixtureCrypto
    var framingOverhead: Int { inner.framingOverhead }
    func loadKey() throws -> Int? { try inner.loadKey() }
    func createKey() throws -> Int { try inner.createKey() }
    func foreignKeyExists(_ slot: CatalogueForeignStore) throws -> Bool { try inner.foreignKeyExists(slot) }
    func seal(_ plaintext: Data, with key: Int) throws -> Data { try inner.seal(plaintext, with: key) }
    func open(_ sealed: Data, with key: Int) throws -> Data { try inner.open(sealed, with: key) }
}
