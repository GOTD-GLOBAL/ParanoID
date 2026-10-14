import Foundation
import XCTest
@testable import ParanoidKit

// REQ-ID-002/003/004/006, REQ-MULTI-001, REQ-SEC-001; isolated public fixtures.
// File/key/AEAD doubles below are NON-CRYPTOGRAPHIC. Identity calls real Rust.
final class OwnerStoreTests: XCTestCase {
    @MainActor func testEveryRetainedOpenPathCallsOnlyIdentityAndLookupAndLegacyBytesStayIntact() async throws {
        // Build every retained stage, reopen each on a fresh coordinator, and assert the Rust operation allowlist.
        var stages: [(String, OwnerFixture)] = []
        do { let f = try OwnerFixture(); stages.append(("bootstrap", f)) }
        do {
            let f = try OwnerFixture(); let c = f.coordinator(); let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.finish(op); stages.append(("unregistered", f))
        }
        do {
            let f = try OwnerFixture(); let c = f.coordinator(); let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.confirmWordsBackup(op)
            _ = try c.recordOwnerSigned(op, intent: f.intent(), signer: PublicVectorSigner()); try c.finish(op); stages.append(("ownerSigned", f))
        }
        do {
            let f = try OwnerFixture(); let c = f.coordinator(); let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.confirmWordsBackup(op)
            let s = try c.recordOwnerSigned(op, intent: f.intent(), signer: PublicVectorSigner())
            _ = try c.recordAssembled(op, attemptID: s.intent.attemptID, signer: SyntheticAssemblyInput())
            _ = try c.reserveSend(op, attemptID: s.intent.attemptID); try c.finish(op); stages.append(("assembled+1send", f))
        }
        do {
            let f = try OwnerFixture(); let c = f.coordinator(); let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            _ = try await c.recoverVerified(op, entropy: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", verifier: SyntheticBindingVerifier()); try c.finish(op); stages.append(("confirmed+published", f))
        }
        for (label, f) in stages {
            let catalogueBytes = f.io.data[f.path("text-state.enc")]; let ownerBytes = f.io.data[f.path("owner/state.enc")]
            f.coreCalls = []
            let c = f.coordinator()
            let reopened = try c.loadRetained()
            XCTAssertEqual(try c.loadRetained(), reopened, label)
            XCTAssertEqual(Set(f.coreCalls).subtracting(["identity", "lookup"]), [], "signing/register/proof never run on open, " + label)
            XCTAssertEqual(f.io.data[f.path("text-state.enc")], catalogueBytes, "open never rewrites, " + label)
            XCTAssertEqual(f.io.data[f.path("owner/state.enc")], ownerBytes, label)
            c.close() // controlled handoff before the separate legacy read-only probe
            // Old bootstrap store still refuses anything beyond the exact bootstrap pair.
            let legacy = CatalogueStore(directory: f.root, context: f.context, files: f.io, crypto: f.catalogue)
            if label == "bootstrap" { XCTAssertEqual(try legacy.loadRetained(), f.context) }
            else { XCTAssertThrowsError(try legacy.loadRetained(), label) { XCTAssertEqual($0 as? CatalogueStoreError, .artifactsPresent, label) } }
            XCTAssertEqual(f.io.data[f.path("text-state.enc")], catalogueBytes, label)
        }
        // The documented Rust operations that must never appear on any open path.
        let forbidden: Set<String> = ["sponsored_sign", "sponsored_assemble", "register", "identity_owner_proof_v3", "recover", "export_mnemonic"]
        XCTAssertTrue(forbidden.isDisjoint(with: ["identity", "lookup"]))
    }

    @MainActor func testEveryOwnerReplacementAndPublicationEffectFaultFreezesWithoutCleanup() async throws {
        // Baseline: committed unregistered owner; replacement = backup confirmation; publication = catalogue binding.
        func committed() throws -> OwnerFixture {
            let f = try OwnerFixture(); let c = f.coordinator()
            let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.finish(op)
            f.io.events = []; f.io.effects = []; return f
        }
        let b = try committed(); let bc = b.coordinator()
        let bop = try bc.begin(deadline: .now.advanced(by: .seconds(30)))
        try bc.confirmWordsBackup(bop)
        let effects = b.io.effects
        XCTAssertEqual(effects.first, "write:" + b.path("owner/write.pending"), "intent precedes every owner replacement effect")
        XCTAssertFalse(effects.contains { $0.hasPrefix("keyCreate") || $0.hasPrefix("mkdir") }, "retained key is loaded, never created")
        XCTAssertLessThan(effects.firstIndex(of: "sync:" + b.path("owner"))!, effects.firstIndex(of: "seal:2")!, "intent parent sync precedes key compare/seal")
        print("OWNER_REPLACEMENT_FAULT_MATRIX effects=\(effects.count) beforeAndAfterCases=\(effects.count * 2)")
        for after in [false, true] {
            for step in effects.indices {
                let label = "step \(step) \(effects[step]) after=\(after)"
                let f = try committed(); let c = f.coordinator(); _ = try c.loadRetained()
                let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
                f.io.faultAt = step; f.io.faultAfter = after
                XCTAssertThrowsError(try c.confirmWordsBackup(op), label) { XCTAssertEqual($0 as? OwnerStoreError, .backendFailure, label) }
                XCTAssertTrue(c.isBroken, label)
                XCTAssertEqual(f.io.effects, Array(effects.prefix(step + (after ? 1 : 0))), label)
                let data = f.io.data; let keys = [f.catalogue.key, f.owner.key]
                XCTAssertThrowsError(try c.confirmWordsBackup(op), label) { XCTAssertEqual($0 as? OwnerStoreError, .broken) }
                XCTAssertThrowsError(try c.loadRetained(), label) { XCTAssertEqual($0 as? OwnerStoreError, .broken) }
                XCTAssertEqual(f.io.data, data, label); XCTAssertEqual([f.catalogue.key, f.owner.key], keys, label)
                f.io.faultAt = nil
                let pending = ["owner/write.pending", "owner/state.enc.tmp"].contains { f.io.data[f.path($0)] != nil }
                if pending { XCTAssertThrowsError(try f.coordinator().loadRetained(), label) { XCTAssertEqual($0 as? OwnerStoreError, .artifactsPresent, label) } }
                else { XCTAssertNotNil(try f.coordinator().loadRetained().owner, label) }
                XCTAssertEqual(f.io.data, data, label)
            }
        }
        // Readback must be byte-exact: a torn destination after rename breaks the writer and adopts nothing.
        do {
            let f = try committed(); let c = f.coordinator(); _ = try c.loadRetained()
            let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            f.io.onEffect = { if $0 == "rename:" + f.path("owner/state.enc.tmp") { f.io.data[f.path("owner/state.enc")]?.append(0) } }
            XCTAssertThrowsError(try c.confirmWordsBackup(op)) { XCTAssertEqual($0 as? OwnerStoreError, .readbackMismatch) }
            XCTAssertTrue(c.isBroken); XCTAssertNotNil(f.io.data[f.path("owner/write.pending")])
            XCTAssertFalse(f.io.effects.contains("remove:" + f.path("owner/write.pending")))
        }
        // A semantic refusal after the write began (oversized seal) is terminal, not a clean refusal.
        do {
            let f = try committed(); let c = f.coordinator(); _ = try c.loadRetained()
            let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            f.owner.oversizedSeal = true
            XCTAssertThrowsError(try c.confirmWordsBackup(op)) { XCTAssertEqual($0 as? OwnerStoreError, .limitExceeded) }
            XCTAssertTrue(c.isBroken); XCTAssertNil(f.io.data[f.path("owner/state.enc.tmp")]); XCTAssertNotNil(f.io.data[f.path("owner/write.pending")])
            XCTAssertThrowsError(try c.confirmWordsBackup(op)) { XCTAssertEqual($0 as? OwnerStoreError, .broken) }
        }
        // Key continuity: a swapped owner key after the intent refuses before sealing; catalogue key likewise during publication.
        do {
            let f = try committed(); let c = f.coordinator(); _ = try c.loadRetained()
            let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            f.io.onEvent = { if $0 == "keyLoad:2", f.io.data[f.path("owner/write.pending")] != nil { f.owner.key = 7 } }
            XCTAssertThrowsError(try c.confirmWordsBackup(op)) { XCTAssertEqual($0 as? OwnerStoreError, .keyMismatch) }
            XCTAssertFalse(f.io.events.contains("seal:2")); XCTAssertNotNil(f.io.data[f.path("owner/write.pending")]); XCTAssertTrue(c.isBroken)
        }
        // Publication faults: owner stays confirmed, catalogue binding stays null, coordinator broken, new instance reopens the intermediate.
        let p = try OwnerFixture(); let pc = p.coordinator()
        var pop = try pc.begin(deadline: .now.advanced(by: .seconds(30)))
        _ = try await pc.recoverVerified(pop, entropy: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", verifier: SyntheticBindingVerifier())
        try pc.finish(pop)
        let publishEffects = p.io.effects.suffix(from: p.io.effects.lastIndex(of: "write:" + p.path("catalogue.write.pending"))!)
        for after in [false, true] {
            for (offset, effect) in publishEffects.enumerated() {
                let label = "publish step \(offset) \(effect) after=\(after)"
                let g = try OwnerFixture(); let gc = g.coordinator()
                pop = try gc.begin(deadline: .now.advanced(by: .seconds(30)))
                let gateIndex = publishEffects.startIndex + offset
                g.io.faultAt = gateIndex; g.io.faultAfter = after
                await assertThrows(.backendFailure) { try await gc.recoverVerified(pop, entropy: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", verifier: SyntheticBindingVerifier()) }
                XCTAssertTrue(gc.isBroken, label)
                XCTAssertEqual(g.io.effects, Array(p.io.effects.prefix(gateIndex + (after ? 1 : 0))), label)
                g.io.faultAt = nil
                let data = g.io.data
                let pendingCatalogue = ["catalogue.write.pending", "text-state.enc.tmp"].contains { g.io.data[g.path($0)] != nil }
                if pendingCatalogue {
                    XCTAssertThrowsError(try g.coordinator().loadRetained(), label) { XCTAssertEqual($0 as? OwnerStoreError, .artifactsPresent, label) }
                } else {
                    let reopened = try g.coordinator().loadRetained()
                    XCTAssertEqual(reopened.owner?.phase, "registryConfirmed", label)
                    XCTAssertEqual(reopened.catalogue.binding == nil || reopened.catalogue.binding == reopened.owner?.binding, true, label)
                }
                XCTAssertEqual(g.io.data, data, "reopen performs no repair, " + label)
            }
        }
    }

    @MainActor func testOwnerAndAllocatedCatalogueByteBoundariesRefuseWithoutSigning() async throws {
        let f = try OwnerFixture()
        var calls: [String] = []
        let core = OwnerMaterialCore(observed: { calls.append($0) })
        let base = try core.identity(entropy: "AAAAAAAAAAAAAAAAAAAAAA==", context: f.context)
        let canonical = try OwnerEnvelopeCodec.encode(base, core: core)
        let text = String(decoding: canonical, as: UTF8.self)
        func decode(_ s: String) throws -> OwnerEnvelopeV1 { try OwnerEnvelopeCodec.decode(Data(s.utf8), context: f.context, core: core) }
        func refuse(_ s: String, _ e: OwnerStoreError, _ label: String = "", line: UInt = #line) {
            XCTAssertThrowsError(try decode(s), label, line: line) { XCTAssertEqual($0 as? OwnerStoreError, e, label + ": " + s.prefix(80), line: line) }
        }
        XCTAssertEqual(try decode(text), base)
        XCTAssertEqual(Array(text.utf8).prefix(1), [123]); XCTAssertFalse(text.contains("\n"))
        // Raw cap precedes UTF-8 and parsing; framed cap precedes opening.
        XCTAssertThrowsError(try OwnerEnvelopeCodec.decode(Data(repeating: 0xff, count: 65_537), context: f.context, core: core)) { XCTAssertEqual($0 as? OwnerStoreError, .limitExceeded) }
        XCTAssertThrowsError(try OwnerEnvelopeCodec.decode(Data(repeating: 0xff, count: 65_536), context: f.context, core: core)) { XCTAssertEqual($0 as? OwnerStoreError, .invalidFormat) }
        XCTAssertThrowsError(try OwnerEnvelopeCodec.decode(Data(), context: f.context, core: core)) { XCTAssertEqual($0 as? OwnerStoreError, .invalidFormat) }
        refuse("\u{FEFF}" + text, .invalidFormat, "BOM")
        XCTAssertEqual(try decode(" \t\r\n" + text + " \n"), base, "the four JSON whitespace bytes")
        refuse(text + "\u{0B}", .invalidFormat, "vertical tab is not JSON whitespace")
        // Version tokens: integer literal only; other versions unsupported, coercions malformed.
        refuse(text.replacingOccurrences(of: #""version":1,"#, with: #""version":2,"#), .unsupportedVersion)
        refuse(text.replacingOccurrences(of: #""version":1,"#, with: #""version":0,"#), .unsupportedVersion)
        for token in ["1.0", "01", "\"1\"", "true", "1e0", "+1", "-1", " 1 ", "18446744073709551616", "1 "] {
            let variant = text.replacingOccurrences(of: #""version":1,"#, with: #""version":\#(token),"#)
            if token == " 1 " || token == "1 " { XCTAssertEqual(try decode(variant), base, token) }
            else { refuse(variant, .invalidFormat, "version token \(token)") }
        }
        // Duplicate decoded keys at every depth, unknown/missing fields, wrong types, null where forbidden.
        refuse(text.replacingOccurrences(of: #""kind":"owner","#, with: #""kind":"owner","kind":"owner","#), .invalidFormat, "dup")
        refuse(text.replacingOccurrences(of: #""kind":"owner","#, with: #""k\u0069nd":"owner","kind":"owner","#), .invalidFormat, "escaped dup")
        refuse(text.replacingOccurrences(of: #""kind":"owner","#, with: #""kind":"owner","extra":1,"#), .invalidFormat, "unknown")
        refuse(text.replacingOccurrences(of: #""kind":"owner","#, with: ""), .invalidFormat, "missing")
        refuse(text.replacingOccurrences(of: #""wordsBackupConfirmed":false"#, with: #""wordsBackupConfirmed":null"#), .invalidFormat)
        refuse(text.replacingOccurrences(of: #""wordsBackupConfirmed":false"#, with: #""wordsBackupConfirmed":0"#), .invalidFormat)
        refuse(text.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":{}"#), .invalidFormat)
        refuse(text.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[[]]"#), .invalidFormat, "unexpected container not traversed")
        refuse(text.replacingOccurrences(of: #""binding":null"#, with: #""binding":{}"#), .invalidFormat)
        refuse(text.replacingOccurrences(of: #""binding":null"#, with: #""binding":"null""#), .invalidFormat)
        refuse(text.replacingOccurrences(of: #""attempts":[]}"#, with: #""attempts":[],}"#), .invalidFormat, "trailing comma")
        refuse(text + "x", .invalidFormat, "trailing data")
        refuse(text.replacingOccurrences(of: #""phase":"unregistered""#, with: #""phase":"Unregistered""#), .invalidFormat)
        refuse(text.replacingOccurrences(of: #""phase":"unregistered""#, with: #""phase":"registrationPending""#), .invalidFormat, "pending requires attempts")
        refuse(text.replacingOccurrences(of: #""phase":"unregistered""#, with: #""phase":"registryConfirmed""#), .invalidFormat, "confirmed requires binding")
        // Entropy/Base64 vs Base58 confusion and material consistency.
        refuse(text.replacingOccurrences(of: "AAAAAAAAAAAAAAAAAAAAAA==", with: "AAAAAAAAAAAAAAAAAAAAAA"), .invalidFormat, "unpadded")
        refuse(text.replacingOccurrences(of: "AAAAAAAAAAAAAAAAAAAAAA==", with: "AAAAAAAAAAAAAAAAAAAAAB=="), .invalidFormat, "noncanonical")
        refuse(text.replacingOccurrences(of: "AAAAAAAAAAAAAAAAAAAAAA==", with: String(repeating: "A", count: 32) + "===="), .invalidFormat, "24 bytes")
        refuse(text.replacingOccurrences(of: "AAAAAAAAAAAAAAAAAAAAAA==", with: base.owner), .invalidFormat, "base58 in entropy")
        refuse(text.replacingOccurrences(of: #""owner":"\#(base.owner)""#, with: #""owner":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=""#), .invalidFormat, "base64 in owner")
        refuse(text.replacingOccurrences(of: #""owner":"\#(base.owner)""#, with: #""owner":"\#(base.identity)""#), .bindingMismatch, "owner/identity swapped")
        refuse(text.replacingOccurrences(of: #""program":"\#(base.program)""#, with: #""program":"\#(base.genesis)""#), .bindingMismatch)
        refuse(text.replacingOccurrences(of: #""owner":"\#(base.owner)""#, with: #""owner":"0\#(base.owner.dropFirst())""#), .invalidFormat, "non-alphabet 0")
        refuse(text.replacingOccurrences(of: #""owner":"\#(base.owner)""#, with: #""owner":"1\#(base.owner)""#), .limitExceeded, "45 characters exceed the B58-32 bound")
        refuse(text.replacingOccurrences(of: #""owner":"\#(base.owner)""#, with: #""owner":"\#(String(repeating: "z", count: 44))""#), .invalidFormat, "44 characters decoding to 33 bytes")
        // Control characters, malformed UTF-8 and escapes.
        refuse(text.replacingOccurrences(of: #""kind":"owner""#, with: "\"kind\":\"own\u{01}er\""), .invalidFormat)
        XCTAssertThrowsError(try OwnerEnvelopeCodec.decode(Data(text.utf8).dropLast() + Data([0xff, 125]), context: f.context, core: core)) { XCTAssertEqual($0 as? OwnerStoreError, .invalidFormat) }
        refuse(text.replacingOccurrences(of: #""kind":"owner""#, with: #""kind":"\udc00owner""#), .invalidFormat, "lone surrogate")
        refuse(text.replacingOccurrences(of: #""kind":"owner""#, with: #""kind":"\u00f6wner""#), .invalidFormat, "non-ASCII escape")
        XCTAssertEqual(try decode(text.replacingOccurrences(of: #""kind":"owner""#, with: #""kind":"\u006fwner""#)), base, "ASCII escape")
        // Context equality.
        refuse(text.replacingOccurrences(of: f.context.ownerRef, with: "00000000-0000-0000-0000-0000000000ff"), .contextMismatch)
        refuse(text.replacingOccurrences(of: #""installID":"\#(f.context.installID)""#, with: #""installID":"\#(f.context.installID.dropLast() + "a")""#), .contextMismatch)
        refuse(text.replacingOccurrences(of: #""installID":"\#(f.context.installID)""#, with: #""installID":"\#(f.context.installID.dropLast() + "A")""#), .invalidFormat, "uppercase hex is not UUID grammar")
        // Maximum ledger: eight entries decode, nine refuse at the limit without reading further.
        func attempt(_ n: Int, resolution: String = "expiredAbsent", height: String = "200") -> String {
            #"{"attemptID":"00000000-0000-0000-0000-\#(String(format: "%012d", n))","stage":"ownerSigned","name":"alice_fixture","sponsorRealmKey":{"origin":"\#(f.context.realms.fi.origin)","pin":"\#(f.context.realms.fi.pin)","protocol":"identity-v3"},"payer":"\#(String(repeating: "1", count: 32))","blockhash":"\#(String(repeating: "1", count: 32))","last_valid_height":100,"message":"AQ==","owner_signature":"\#(String(repeating: "1", count: 64))","transaction":null,"signature":null,"sends":0,"resolution":"\#(resolution)","finalized_height":\#(height)}"#
        }
        let pending = text.replacingOccurrences(of: #""phase":"unregistered""#, with: #""phase":"registrationPending""#).replacingOccurrences(of: #""wordsBackupConfirmed":false"#, with: #""wordsBackupConfirmed":true"#)
        let eight = pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#((1...7).map { attempt($0) }.joined(separator: ",")),\#(attempt(8, resolution: "unresolved", height: "null"))]"#)
        XCTAssertEqual(try decode(eight).attempts.count, 8)
        XCTAssertEqual(try OwnerEnvelopeCodec.encode(decode(eight), core: core), Data(eight.utf8), "deterministic re-encoding of the maximal ledger")
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#((1...8).map { attempt($0) }.joined(separator: ",")),\#(attempt(9, resolution: "unresolved", height: "null"))]"#), .limitExceeded, "nine")
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1)),\#(attempt(1, resolution: "unresolved", height: "null"))]"#), .invalidFormat, "duplicate attempt id")
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, resolution: "unresolved", height: "null")),\#(attempt(2, resolution: "unresolved", height: "null"))]"#), .invalidFormat, "two unresolved")
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, height: "100"))]"#), .invalidFormat, "finalized not strictly above expiry")
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, resolution: "ownerBound"))]"#), .invalidFormat, "ownerBound outside confirmed")
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, resolution: "unresolved", height: "null").replacingOccurrences(of: #""sends":0"#, with: #""sends":4"#))]"#), .invalidFormat, "fourth send")
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, resolution: "unresolved", height: "null").replacingOccurrences(of: #""sends":0"#, with: #""sends":-1"#))]"#), .invalidFormat, "negative")
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, resolution: "unresolved", height: "null").replacingOccurrences(of: #""last_valid_height":100"#, with: #""last_valid_height":18446744073709551616"#))]"#), .invalidFormat, "u64 overflow")
        XCTAssertEqual(try decode(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, resolution: "unresolved", height: "null").replacingOccurrences(of: #""last_valid_height":100"#, with: #""last_valid_height":18446744073709551615"#))]"#)).attempts.first?.intent.lastValidHeight, UInt64.max)
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, resolution: "unresolved", height: "null").replacingOccurrences(of: #""message":"AQ==""#, with: #""message":"""#))]"#), .invalidFormat, "empty wire")
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, resolution: "unresolved", height: "null").replacingOccurrences(of: #""message":"AQ==""#, with: #""message":"\#(Data(repeating: 1, count: 1_233).base64EncodedString())""#))]"#), .invalidFormat, "1233 bytes")
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, resolution: "unresolved", height: "null").replacingOccurrences(of: #""name":"alice_fixture""#, with: #""name":"Alice""#))]"#), .invalidFormat, "name grammar")
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, resolution: "unresolved", height: "null").replacingOccurrences(of: #""payer":"\#(String(repeating: "1", count: 32))""#, with: #""payer":"\#(base.owner)""#))]"#), .invalidFormat, "payer equals owner")
        refuse(pending.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, resolution: "unresolved", height: "null").replacingOccurrences(of: f.context.realms.fi.pin, with: String(repeating: "c", count: 64)))]"#), .invalidFormat, "foreign sponsor realm")
        refuse(text.replacingOccurrences(of: #""attempts":[]"#, with: #""attempts":[\#(attempt(1, resolution: "unresolved", height: "null"))]"#), .invalidFormat, "ledger without backup confirmation")
        // Allocated catalogue: allocation/binding grammar, realm allocated unsupported, binding without allocation.
        let bootstrap = String(decoding: IdentityCatalogueCodec.encode(f.context), as: UTF8.self)
        func catalogue(_ s: String) throws -> AllocatedCatalogueState { try AllocatedCatalogueCodec.decode(Data(s.utf8), context: f.context) }
        XCTAssertEqual(try catalogue(bootstrap), .init(context: f.context, allocated: false))
        XCTAssertEqual(try AllocatedCatalogueCodec.encode(.init(context: f.context, allocated: false)), IdentityCatalogueCodec.encode(f.context), "unallocated bytes are the bootstrap bytes")
        let bindingJSON = #"{"genesis":"\#(base.genesis)","program":"\#(base.program)","identity":"\#(base.identity)","owner":"\#(base.owner)","name":"alice_fixture"}"#
        XCTAssertThrowsError(try catalogue(bootstrap.replacingOccurrences(of: #""binding":null"#, with: #""binding":\#(bindingJSON)"#))) { XCTAssertEqual($0 as? OwnerStoreError, .invalidFormat) }
        XCTAssertThrowsError(try catalogue(bootstrap.replacingOccurrences(of: #""slot":"fi","origin":"\#(f.context.realms.fi.origin)","pin":"\#(f.context.realms.fi.pin)","protocol":"identity-v3","allocation":"unallocated""#, with: #""slot":"fi","origin":"\#(f.context.realms.fi.origin)","pin":"\#(f.context.realms.fi.pin)","protocol":"identity-v3","allocation":"allocated""#))) { XCTAssertEqual($0 as? OwnerStoreError, .invalidTransition) }
        XCTAssertThrowsError(try catalogue(bootstrap.replacingOccurrences(of: #""version":5,"minReader":5"#, with: #""version":6,"minReader":6"#))) { XCTAssertEqual($0 as? OwnerStoreError, .unsupportedVersion) }
        let allocated = bootstrap.replacingOccurrences(of: #""allocation":"unallocated","binding":null"#, with: #""allocation":"allocated","binding":\#(bindingJSON)"#)
        XCTAssertEqual(try catalogue(allocated).binding?.name, "alice_fixture")
        XCTAssertEqual(try AllocatedCatalogueCodec.encode(try catalogue(allocated)), Data(allocated.utf8))
        // Old bootstrap reader/store still refuse the allocated form; nothing was rewritten.
        XCTAssertThrowsError(try IdentityCatalogueCodec.decode(Data(allocated.utf8), expectedInstallID: f.context.installID, expectedRealms: f.context.realms)) { XCTAssertEqual($0 as? IdentityCatalogueError, .unsupportedState) }
        XCTAssertEqual(calls.filter { !["identity", "lookup"].contains($0) }, [])
    }

    @MainActor func testAwaitedVerifierKeepsSoleOperationAndLateResultsHaveNoEffect() async throws {
        // Reentry while the verifier is awaited is busy and does not cancel the active operation.
        do {
            let f = try OwnerFixture(); let c = f.coordinator()
            let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            let gate = GateVerifier()
            let task = Task { @MainActor in try await c.recoverVerified(op, entropy: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", verifier: gate) }
            await gate.entered()
            XCTAssertThrowsError(try c.begin(deadline: .now.advanced(by: .seconds(1)))) { XCTAssertEqual($0 as? OwnerStoreError, .busy) }
            XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .busy) }
            XCTAssertThrowsError(try c.reserveNewOwner(op)) { XCTAssertEqual($0 as? OwnerStoreError, .busy) }
            XCTAssertFalse(c.isBroken)
            gate.release(.evidence)
            let pair = try await task.value
            XCTAssertEqual(pair.catalogue.binding?.name, "alice_fixture")
        }
        // Deadline passes while awaiting: late evidence writes nothing; the permit never existed.
        do {
            let f = try OwnerFixture(); let c = f.coordinator()
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            let op = try c.begin(deadline: deadline)
            let gate = GateVerifier()
            let task = Task { @MainActor in try await c.recoverVerified(op, entropy: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", verifier: gate) }
            await gate.entered()
            try await Task.sleep(until: deadline.advanced(by: .milliseconds(20)), clock: .continuous)
            gate.release(.evidence)
            await assertThrows(.cancelled) { try await task.value }
            XCTAssertFalse(f.io.events.contains { $0.hasPrefix("write:") || $0.hasPrefix("mkdir:") || $0.hasPrefix("keyCreate") })
            XCTAssertEqual(f.entropyCalls, 0)
            XCTAssertFalse(try f.coordinator().loadRetained().catalogue.allocated)
        }
        // Foreign correlation, no-name and thrown verifier: zero writes, operation ended.
        for outcome in [GateVerifier.Outcome.foreign, .none, .failure] {
            let f = try OwnerFixture(); let c = f.coordinator()
            let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            let gate = GateVerifier(); gate.release(outcome)
            await assertThrows(outcome == .failure ? .backendFailure : .authorityRequired) { try await c.recoverVerified(op, entropy: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", verifier: gate) }
            XCTAssertFalse(f.io.events.contains { $0.hasPrefix("write:") || $0.hasPrefix("mkdir:") || $0.hasPrefix("keyCreate") }, "\(outcome)")
            XCTAssertThrowsError(try c.reserveNewOwner(op)) { XCTAssertEqual($0 as? OwnerStoreError, .authorityRequired) }
            XCTAssertFalse(c.isBroken)
        }
        // Cancellation after reservation preserves allocation; a stale/foreign permit cannot initialize.
        do {
            let f = try OwnerFixture(); let c = f.coordinator()
            let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            let permit = try c.reserveNewOwner(op)
            try c.cancel(op)
            XCTAssertThrowsError(try c.initializeNew(permit, operation: op)) { XCTAssertEqual($0 as? OwnerStoreError, .authorityRequired) }
            let op2 = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            XCTAssertThrowsError(try c.initializeNew(permit, operation: op2)) { XCTAssertEqual($0 as? OwnerStoreError, .authorityRequired) }
            let op3 = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            // Allocated with no owner artifacts is owner loss for every coordinator, never a second reservation.
            XCTAssertThrowsError(try c.reserveNewOwner(op3)) { XCTAssertEqual($0 as? OwnerStoreError, .continuity) }
            XCTAssertTrue(c.isBroken)
            XCTAssertEqual(f.entropyCalls, 0)
            let reopened = f.coordinator()
            XCTAssertThrowsError(try reopened.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .continuity) }
            // Another coordinator's permit over the same root is foreign too.
            let g = try OwnerFixture(); let d = g.coordinator()
            let opD = try d.begin(deadline: .now.advanced(by: .seconds(30))); let foreign = try d.reserveNewOwner(opD)
            let e = g.coordinator() // explicit retirement before a fresh coordinator
            let opE = try e.begin(deadline: .now.advanced(by: .seconds(30)))
            XCTAssertThrowsError(try e.initializeNew(foreign, operation: opE)) { XCTAssertEqual($0 as? OwnerStoreError, .authorityRequired) }
            XCTAssertEqual(g.entropyCalls, 0)
        }
    }

    @MainActor func testConsistencyMatrixRefusesWithoutCleanupAndLockedIsRetryable() async throws {
        func committed() throws -> OwnerFixture {
            let f = try OwnerFixture(); let c = f.coordinator()
            let op = try c.begin(deadline: .now.advanced(by: .seconds(30)))
            _ = try c.initializeNew(c.reserveNewOwner(op), operation: op); try c.finish(op)
            f.io.events = []; return f
        }
        func expect(_ f: OwnerFixture, _ error: OwnerStoreError, _ label: String) {
            let data = f.io.data; let kinds = f.io.kinds; let keys = [f.catalogue.key, f.owner.key]
            let c = f.coordinator()
            XCTAssertThrowsError(try c.loadRetained(), label) { XCTAssertEqual($0 as? OwnerStoreError, error, label) }
            XCTAssertEqual(f.io.data, data, label); XCTAssertEqual(f.io.kinds, kinds, label); XCTAssertEqual([f.catalogue.key, f.owner.key], keys, label)
            XCTAssertFalse(f.io.events.contains { $0.hasPrefix("write:") || $0.hasPrefix("remove:") || $0.hasPrefix("keyCreate") || $0.hasPrefix("mkdir") || $0.hasPrefix("rename") }, label)
            XCTAssertEqual(f.coreCalls.filter { $0 != "identity" }, [], label)
            XCTAssertFalse(f.io.events.contains { $0.hasPrefix("open:2") } && ![.invalidFormat, .unsupportedVersion, .bindingMismatch, .contextMismatch, .authenticationFailed].contains(error), "owner box is not opened on a structural refusal, " + label)
        }
        // Unallocated + any owner artifact/key: never promote, never delete.
        for artifact in ["owner", "owner/state.enc", "owner/state.enc.tmp", "owner/write.pending"] {
            for kind in [CataloguePathKind.directory, .regularFile, .other] {
                let f = try OwnerFixture(); f.io.kinds[f.path(artifact)] = kind
                if artifact != "owner" { f.io.kinds[f.path("owner")] = .directory }
                expect(f, .artifactsPresent, "unallocated \(artifact) \(kind)")
            }
        }
        do { let f = try OwnerFixture(); f.owner.key = 2; expect(f, .artifactsPresent, "unallocated with owner key only") }
        // Realm artifacts/keys refuse this unallocated-realm slice before any owner work.
        for artifact in ["realms", "realms/fi", "realms/ru", "realms/fi/state.enc", "realms/ru/write.pending"] {
            let f = try committed(); f.io.kinds[f.path(artifact)] = .directory; expect(f, .artifactsPresent, artifact)
        }
        for slot in [CatalogueForeignStore.fi, .ru] {
            let f = try committed(); let inner = f.catalogue.foreign; f.catalogue.foreign = { $0 == slot || inner($0) }; expect(f, .artifactsPresent, "foreign key \(slot)")
        }
        // Allocated owner loss: both absent (with or without directory), XOR, wrong inode, pending/temp.
        do { let f = try committed(); f.io.data[f.path("owner/state.enc")] = nil; f.owner.key = nil; expect(f, .continuity, "allocated both lost, dir kept") }
        do { let f = try committed(); f.io.data[f.path("owner/state.enc")] = nil; f.owner.key = nil; f.io.kinds[f.path("owner")] = nil; expect(f, .continuity, "allocated both lost, dir gone") }
        do { let f = try committed(); f.io.data[f.path("owner/state.enc")] = nil; expect(f, .continuity, "allocated file lost, key kept") }
        do { let f = try committed(); f.owner.key = nil; expect(f, .continuity, "allocated key lost, file kept") }
        do { let f = try committed(); f.io.kinds[f.path("owner/state.enc")] = .other; expect(f, .continuity, "symlinked owner file") }
        do { let f = try committed(); f.io.kinds[f.path("owner")] = .other; expect(f, .continuity, "symlinked owner directory") }
        for pending in ["owner/write.pending", "owner/state.enc.tmp", "catalogue.write.pending", "text-state.enc.tmp"] {
            let f = try committed(); f.io.data[f.path(pending)] = Data(); expect(f, .artifactsPresent, pending)
        }
        // Sealed with the other store's key: authentication, never repair.
        do { let f = try committed(); f.io.data[f.path("owner/state.enc")] = try f.catalogue.seal(f.io.data[f.path("owner/state.enc")]!.dropFirst(29), with: 1); expect(f, .authenticationFailed, "owner sealed with catalogue key") }
        // Swapped stores: catalogue plaintext inside the owner box and vice versa.
        do { let f = try committed(); f.io.data[f.path("owner/state.enc")] = try f.owner.seal(f.io.data[f.path("text-state.enc")]!.dropFirst(29), with: 2); expect(f, .unsupportedVersion, "catalogue document in owner store (version 5 token)") }
        do { let f = try committed(); f.io.data[f.path("text-state.enc")] = try f.catalogue.seal(f.io.data[f.path("owner/state.enc")]!.dropFirst(29), with: 1); expect(f, .unsupportedVersion, "owner document in catalogue store (version 1 token)") }
        // Foreign installation context in the owner box.
        do {
            let f = try committed()
            let other = try IdentityCatalogue(installID: "00000000-0000-0000-0000-00000000000f", ownerRef: f.context.ownerRef, realms: f.context.realms)
            let text = String(decoding: f.io.data[f.path("owner/state.enc")]!.dropFirst(29), as: UTF8.self).replacingOccurrences(of: f.context.installID, with: other.installID)
            f.io.data[f.path("owner/state.enc")] = try f.owner.seal(Data(text.utf8), with: 2); expect(f, .contextMismatch, "foreign install in owner")
        }
        // Read-only locked key/file before effects: retry after unlock, not broken.
        for lockFile in [false, true] {
            let f = try committed(); f.io.lockedPaths = lockFile ? [f.path("owner/state.enc")] : []; f.owner.locked = !lockFile
            let c = f.coordinator()
            XCTAssertThrowsError(try c.loadRetained()) { XCTAssertEqual($0 as? OwnerStoreError, .locked) }
            XCTAssertFalse(c.isBroken)
            f.io.lockedPaths = []; f.owner.locked = false
            XCTAssertEqual(try c.loadRetained().owner?.phase, "unregistered")
        }
    }

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
        let f = try OwnerFixture(); var c = f.coordinator()
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
            c = f.coordinator() // never reuse the retired writer after reopen
            let reopened = try c.loadRetained()
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
            // Continuity is reread before entropy; those read-only events are
            // required now. The final *effect* is still allocation's final sync.
            XCTAssertEqual(f.io.effects.last, "sync:" + f.root.path)
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

@MainActor final class GateVerifier: IsolatedTrustedOwnerVerifier {
    enum Outcome { case evidence, foreign, none, failure }
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var isEntered = false
    private var enteredTimeout: Task<Void, Never>?
    func entered() async {
        if isEntered { return }
        await withCheckedContinuation { enteredWaiters.append($0)
            // Test readiness watchdog only: fail, never hang if preparation
            // rejects before the external seam is called (e.g. a slow host).
            enteredTimeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !isEntered else { return }
                XCTFail("verifier was not entered within the bounded fixture wait")
                let pending = enteredWaiters; enteredWaiters = []
                pending.forEach { $0.resume() }
            }
        }
    }
    func release(_ o: Outcome) { outcome = o; let w = waiters; waiters = []; w.forEach { $0.resume(returning: o) } }
    func binding(for request: OwnerBindingRequest) async throws -> OwnerBindingEvidence? {
        isEntered = true; enteredTimeout?.cancel(); enteredTimeout = nil
        enteredWaiters.forEach { $0.resume() }; enteredWaiters = []
        let o: Outcome = await { if let outcome { return outcome }; return await withCheckedContinuation { waiters.append($0) } }()
        let v = request.material
        let binding = OwnerBinding(genesis: v.genesis, program: v.program, identity: v.identity, owner: v.owner, name: "alice_fixture")
        switch o {
        case .evidence: return .init(request: request, binding: binding, finalizedHeight: 101)
        case .foreign: return .init(request: .init(correlation: UUID(), material: v), binding: binding, finalizedHeight: 101)
        case .none: return nil
        case .failure: throw OwnerStoreError.backendFailure
        }
    }
    func expiry(for request: OwnerExpiryRequest) async throws -> OwnerExpiryEvidence? { nil }
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
    var lockedPaths: Set<String> = []
    var onEvent: ((String) -> Void)?
    var onEffect: ((String) -> Void)?
    var faultAt: Int?
    var faultAfter = false
    var faultError = OwnerStoreError.backendFailure
    var effects: [String] = []
    /// Fault seam: throw before or after exactly the N-th effect; never undo it.
    func effect(_ e: String, _ apply: () throws -> Void) throws {
        events.append(e)
        if e == failBefore { throw OwnerStoreError.backendFailure }
        let index = effects.count
        if faultAt == index, !faultAfter { throw faultError }
        try apply(); effects.append(e); onEffect?(e)
        if faultAt == index, faultAfter { throw faultError }
    }
    private func record(_ e: String) throws { events.append(e); if e == failBefore { throw OwnerStoreError.backendFailure } }
    func inspect(_ u: URL) throws -> CataloguePathKind { events.append("inspect:" + u.path); return kinds[u.path] ?? (data[u.path] == nil ? .absent : .regularFile) }
    func writeExclusive(_ bytes: Data, to u: URL) throws { try effect("write:" + u.path) { guard data[u.path] == nil, kinds[u.path] == nil else { throw OwnerStoreError.artifactsPresent }; data[u.path] = bytes } }
    func protectAndExclude(_ u: URL) throws { try effect("protectCatalogue:" + u.path) {} }
    func protectOwnerAndExclude(_ u: URL, policy: OwnerProtection) throws { try effect("protectOwner:" + u.path) {} }
    func createOwnerDirectory(_ u: URL) throws { try effect("mkdir:" + u.path) { guard kinds[u.path] == nil, data[u.path] == nil else { throw OwnerStoreError.artifactsPresent }; kinds[u.path] = .directory } }
    func fullSync(_ u: URL, directory: Bool) throws { try effect("sync:" + u.path) {} }
    func rename(_ u: URL, to d: URL) throws { try effect("rename:" + u.path) { data[d.path] = data.removeValue(forKey: u.path) } }
    func read(_ u: URL, maximumBytes: Int) throws -> Data { events.append("read:" + u.path); if lockedPaths.contains(u.path) { throw OwnerBackendLock.locked }; guard let bytes = data[u.path] else { throw OwnerStoreError.continuity }; guard bytes.count <= maximumBytes else { throw OwnerStoreError.limitExceeded }; return bytes }
    func removeIntent(_ u: URL) throws { try effect("remove:" + u.path) { data.removeValue(forKey: u.path) } }
}
final class OwnerFixtureCrypto: OwnerCryptography {
    let id: Int
    var key: Int?
    let io: OwnerFixtureIO
    var foreign: (CatalogueForeignStore) -> Bool = { _ in false }
    var locked = false
    var oversizedSeal = false
    init(_ id: Int, _ io: OwnerFixtureIO) { self.id = id; self.io = io }
    var framingOverhead: Int { 29 }
    func loadKey() throws -> Int? { io.events.append("keyLoad:\(id)"); io.onEvent?("keyLoad:\(id)"); if locked { throw OwnerBackendLock.locked }; return key }
    func createKey() throws -> Int { try io.effect("keyCreate:\(id)") { guard key == nil else { throw OwnerStoreError.keyMismatch }; key = id }; return id }
    func foreignKeyExists(_ slot: CatalogueForeignStore) throws -> Bool { io.events.append("foreign:\(slot.rawValue)"); return foreign(slot) }
    func seal(_ plaintext: Data, with key: Int) throws -> Data { try io.effect("seal:\(id)") {}; return Data(repeating: UInt8(key), count: oversizedSeal ? 65_566 : 29) + plaintext }
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
    private var previous: OwnerAllocationCoordinator<OwnerFixtureCrypto, OwnerFixtureCrypto>?
    private lazy var lease = OwnerNamespaceLease(root: root)
    func coordinator() -> OwnerAllocationCoordinator<OwnerFixtureCrypto, OwnerFixtureCrypto> {
        // Explicit controlled fixture handoff, not multiple live writers over one namespace.
        previous?.close()
        let holder = try! lease.acquire()
        let next = OwnerAllocationCoordinator(directory: root, context: context,
            files: LeasedFileIO(io, lease: lease, holder: holder),
            catalogueCrypto: LeasedCryptography(catalogue, lease: lease, holder: holder),
            ownerCrypto: LeasedCryptography(owner, lease: lease, holder: holder),
            entropy: { [self] in entropyCalls += 1; onEntropy?(); return Data(repeating: 0, count: 16) },
            core: .init(observed: { [self] in coreCalls.append($0) }))
        previous = next
        return next
    }
}
