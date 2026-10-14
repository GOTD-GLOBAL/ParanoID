import Foundation
import XCTest
@testable import ParanoidKit

// RFC-0030 / draft ADR-0017; MR-02/06/07/14. These backends are fault
// doubles, NOT encryption or evidence of native disk durability.
final class CatalogueStoreTests: XCTestCase {
    func testForeignAncestorRefusesBeforeInspectingDescendants() throws {
        for name in ["owner", "realms", "realms/fi", "realms/ru"] {
            let f = try CatalogueFixture()
            f.io.kinds[f.path(name)] = .other // e.g. symlink, never follow it
            XCTAssertThrowsError(try f.store().inspectFresh()) { XCTAssertEqual($0 as? CatalogueStoreError, .artifactsPresent) }
            XCTAssertFalse(f.trace.events.contains { $0.hasPrefix("inspect:" + f.path(name) + "/") })
            XCTAssertNil(f.crypto.key)
        }
    }

    func testReadOnlyFaultsNeverCreateRepairOrEchoBackendErrors() throws {
        for retained in [false, true] {
            let baseline = try CatalogueFixture()
            if retained { baseline.seed(); _ = try baseline.store().loadRetained() }
            else { try baseline.store().inspectFresh() }
            for step in 1...baseline.trace.events.count {
                let f = try CatalogueFixture()
                if retained { f.seed() }
                let before = f.io.files
                let store = f.store()
                XCTAssertTrue(f.trace.events.isEmpty, "construction has no backend effects")
                f.trace.failAt = step
                if retained {
                    XCTAssertThrowsError(try store.loadRetained()) { XCTAssertEqual($0 as? CatalogueStoreError, .backendFailure) }
                } else {
                    XCTAssertThrowsError(try store.inspectFresh()) { XCTAssertEqual($0 as? CatalogueStoreError, .backendFailure) }
                }
                XCTAssertTrue(store.isBroken)
                XCTAssertEqual(f.io.files, before)
                XCTAssertFalse(f.trace.events.contains { $0.hasPrefix("write:") || $0.hasPrefix("remove:") || $0 == "key-create" })
            }
        }
    }

    func testRetainedKeyIsComparedAgainAfterIntentParentSync() throws {
        let f = try CatalogueFixture()
        f.seed()
        let store = f.store()
        _ = try store.loadRetained()
        let previous = f.io.files[f.path("text-state.enc")]
        f.trace.onEvent = { event in
            if event == "key-load" && f.io.files[f.path("catalogue.write.pending")] != nil {
                f.crypto.key = .init(id: 99)
            }
        }
        XCTAssertThrowsError(try store.commit(f.context)) { XCTAssertEqual($0 as? CatalogueStoreError, .keyMismatch) }
        XCTAssertEqual(f.io.files[f.path("text-state.enc")], previous)
        XCTAssertNotNil(f.io.files[f.path("catalogue.write.pending")])
        XCTAssertFalse(f.trace.events.contains("seal"))
    }

    func testMarkerRemovalAmbiguityCanBeUndetectableToNewInstance() throws {
        for failFinalSync in [false, true] {
            let f = try CatalogueFixture()
            let store = f.store()
            try store.inspectFresh()
            f.trace.onEvent = { event in
                if event == "remove:" + f.path("catalogue.write.pending") {
                    f.trace.failAt = f.trace.events.count + (failFinalSync ? 1 : 0)
                    f.trace.afterEffect = !failFinalSync
                }
            }
            XCTAssertThrowsError(try store.commit(f.context))
            XCTAssertTrue(store.isBroken)
            XCTAssertNil(f.io.files[f.path("catalogue.write.pending")])
            f.trace.failAt = nil
            f.trace.onEvent = nil
            XCTAssertEqual(try f.store().loadRetained(), f.context)
            XCTAssertThrowsError(try store.commit(f.context)) { XCTAssertEqual($0 as? CatalogueStoreError, .broken) }
        }
    }

    func testWrongInodeTypesAndCorruptFrameRefuseWithoutRepair() throws {
        for kind in [CataloguePathKind.directory, .other] {
            let f = try CatalogueFixture()
            f.seed()
            f.io.kinds[f.path("text-state.enc")] = kind
            XCTAssertThrowsError(try f.store().loadRetained()) { XCTAssertEqual($0 as? CatalogueStoreError, .continuity) }
            for name in CatalogueFixture.forbidden {
                let g = try CatalogueFixture()
                g.io.kinds[g.path(name)] = kind
                XCTAssertThrowsError(try g.store().inspectFresh()) { XCTAssertEqual($0 as? CatalogueStoreError, .artifactsPresent) }
            }
        }
        let f = try CatalogueFixture()
        f.seed()
        f.io.files[f.path("text-state.enc")] = Data([254])
        let before = f.io.files
        XCTAssertThrowsError(try f.store().loadRetained()) { XCTAssertEqual($0 as? CatalogueStoreError, .backendFailure) }
        XCTAssertEqual(f.io.files, before)
    }

    func testFirstWriteAuthorityIsConsumedBeforeBackendEffects() throws {
        let f = try CatalogueFixture()
        let store = f.store()
        try store.inspectFresh()
        var observed = false
        f.trace.onEvent = { event in
            guard event == "write:" + f.path("catalogue.write.pending") else { return }
            f.trace.onEvent = nil
            observed = true
            let before = f.trace.events
            XCTAssertThrowsError(try store.commit(f.context)) { XCTAssertEqual($0 as? CatalogueStoreError, .authorityRequired) }
            XCTAssertThrowsError(try store.inspectFresh()) { XCTAssertEqual($0 as? CatalogueStoreError, .broken) }
            XCTAssertEqual(f.trace.events, before)
        }
        XCTAssertThrowsError(try store.commit(f.context))
        XCTAssertTrue(observed)
        XCTAssertTrue(store.isBroken)
    }

    func testEveryFaultBoundaryPreservesEvidenceAndTerminallyFreezes() throws {
        for retained in [false, true] {
            let baseline = try CatalogueFixture()
            let successful = baseline.store()
            if retained { baseline.seed(); _ = try successful.loadRetained() }
            else { try successful.inspectFresh() }
            baseline.trace.events.removeAll()
            try successful.commit(baseline.context)
            let steps = baseline.trace.events.count
            print("CATALOGUE_FAULT_MATRIX retained=\(retained) boundaries=\(steps) beforeAndAfterCases=\(steps * 2)")
            for afterEffect in [false, true] {
                for step in 1...steps {
                    let f = try CatalogueFixture()
                    let store = f.store()
                    if retained { f.seed(); _ = try store.loadRetained() }
                    else { try store.inspectFresh() }
                    f.trace.events.removeAll()
                    f.trace.failAt = step
                    f.trace.afterEffect = afterEffect
                    XCTAssertThrowsError(try store.commit(f.context), "step \(step), after \(afterEffect), retained \(retained)")
                    XCTAssertTrue(store.isBroken)
                    XCTAssertEqual(f.trace.events.count, step, "no compensating cleanup or later effects")
                    let evidence = f.io.files
                    let key = f.crypto.key
                    XCTAssertThrowsError(try store.commit(f.context)) { XCTAssertEqual($0 as? CatalogueStoreError, .broken) }
                    XCTAssertEqual(f.io.files, evidence)
                    XCTAssertEqual(f.crypto.key, key)
                    XCTAssertEqual(f.trace.events.count, step)
                    f.trace.failAt = nil
                    if evidence[f.path("catalogue.write.pending")] != nil || evidence[f.path("text-state.enc.tmp")] != nil {
                        XCTAssertThrowsError(try f.store().loadRetained())
                        XCTAssertThrowsError(try f.store().inspectFresh())
                    }
                    // After marker removal, a new instance may open a valid pair.
                    // This is not universal detection of ambiguous crashes.
                    XCTAssertEqual(f.io.files, evidence)
                    XCTAssertEqual(f.crypto.key, key)
                }
            }
        }
    }

    func testFramedCapIsEnforcedBeforeDecodeAndBeforeCandidateWrite() throws {
        let f = try CatalogueFixture()
        f.seed()
        f.io.files[f.path("text-state.enc")] = Data(repeating: 0, count: 65_538)
        XCTAssertThrowsError(try f.store().loadRetained())
        XCTAssertEqual(f.io.readCaps, [65_536 + f.crypto.framingOverhead])
        XCTAssertFalse(f.trace.events.contains("open"))
        let g = try CatalogueFixture()
        let store = g.store()
        try store.inspectFresh()
        g.crypto.oversizedSeal = true
        XCTAssertThrowsError(try store.commit(g.context)) { XCTAssertEqual($0 as? CatalogueStoreError, .limitExceeded) }
        XCTAssertNil(g.io.files[g.path("text-state.enc.tmp")])
        XCTAssertNil(g.io.files[g.path("text-state.enc")])
        XCTAssertFalse(g.trace.events.contains("write:" + g.path("text-state.enc.tmp")))
        XCTAssertNotNil(g.io.files[g.path("catalogue.write.pending")])
    }

    func testCreatedKeyReadbackMustMatchExactlyBeforeSealing() throws {
        for missing in [false, true] {
            let f = try CatalogueFixture()
            let store = f.store()
            try store.inspectFresh()
            f.crypto.wrongCreatedReadback = true
            f.crypto.missingCreatedReadback = missing
            XCTAssertThrowsError(try store.commit(f.context)) { XCTAssertEqual($0 as? CatalogueStoreError, .keyMismatch) }
            XCTAssertNotNil(f.crypto.key)
            XCTAssertNotNil(f.io.files[f.path("catalogue.write.pending")])
            XCTAssertFalse(f.trace.events.contains("seal"))
            XCTAssertTrue(store.isBroken)
        }
    }

    func testRetainedKeyChangeRefusesLoadAndCommitBeforeWriting() throws {
        for loading in [false, true] {
            let f = try CatalogueFixture()
            f.seed()
            let store = f.store()
            _ = try store.loadRetained()
            f.crypto.key = .init(id: 99)
            f.trace.events.removeAll()
            if loading { XCTAssertThrowsError(try store.loadRetained()) { XCTAssertEqual($0 as? CatalogueStoreError, .keyMismatch) } }
            else { XCTAssertThrowsError(try store.commit(f.context)) { XCTAssertEqual($0 as? CatalogueStoreError, .keyMismatch) } }
            XCTAssertFalse(f.trace.events.contains { $0.hasPrefix("write:") })
        }
    }

    func testReadbackMustMatchExactlyAndPreserveIntentOnMismatch() throws {
        let f = try CatalogueFixture()
        let store = f.store()
        try store.inspectFresh()
        f.io.readOverride = Data([99])
        XCTAssertThrowsError(try store.commit(f.context)) { XCTAssertEqual($0 as? CatalogueStoreError, .readbackMismatch) }
        XCTAssertTrue(store.isBroken)
        XCTAssertNotNil(f.io.files[f.path("catalogue.write.pending")])
        XCTAssertFalse(f.trace.events.contains { $0.hasPrefix("remove:") })
        XCTAssertThrowsError(try f.store().loadRetained())
    }

    func testFullTrustedContextIsRequiredOnLoadAndCommit() throws {
        let f = try CatalogueFixture()
        let c = f.context
        let changedRealm = try IdentityCatalogue.Realm(origin: "https://other.example.invalid", pin: c.realms.fi.pin, protocolKind: "identity-v3")
        let changedPin = try IdentityCatalogue.Realm(origin: c.realms.ru.origin, pin: c.realms.fi.pin, protocolKind: "identity-v3")
        let contexts = [
            try IdentityCatalogue(installID: c.ownerRef, ownerRef: c.ownerRef, realms: c.realms),
            try IdentityCatalogue(installID: c.installID, ownerRef: c.installID, realms: c.realms),
            try IdentityCatalogue(installID: c.installID, ownerRef: c.ownerRef, realms: .init(fi: changedRealm, ru: c.realms.ru)),
            try IdentityCatalogue(installID: c.installID, ownerRef: c.ownerRef, realms: .init(fi: c.realms.fi, ru: changedPin)),
            try IdentityCatalogue(installID: c.installID, ownerRef: c.ownerRef, realms: .init(fi: c.realms.ru, ru: c.realms.fi))
        ]
        for foreign in contexts {
            let g = try CatalogueFixture()
            g.seed()
            let reader = CatalogueStore(directory: g.root, context: foreign, files: g.io, crypto: g.crypto)
            XCTAssertThrowsError(try reader.loadRetained()) { XCTAssertEqual($0 as? CatalogueStoreError, .contextMismatch) }
            let h = try CatalogueFixture()
            let writer = h.store()
            try writer.inspectFresh()
            h.trace.events.removeAll()
            XCTAssertThrowsError(try writer.commit(foreign)) { XCTAssertEqual($0 as? CatalogueStoreError, .contextMismatch) }
            XCTAssertTrue(h.io.files.isEmpty)
            XCTAssertNil(h.crypto.key)
        }
    }

    func testRetainedCommitRevalidatesStrictBytesBeforeAnyWrite() throws {
        let f = try CatalogueFixture()
        let text = String(decoding: IdentityCatalogueCodec.encode(f.context), as: UTF8.self)
        let invalid: [Data] = [Data([0xff]), Data("{not-json}".utf8),
            Data(text.replacingOccurrences(of: "\"version\":5", with: "\"version\":4").utf8),
            Data(text.replacingOccurrences(of: "unallocated", with: "allocated").utf8),
            Data(text.replacingOccurrences(of: "\"binding\":null", with: "\"binding\":{}").utf8),
            Data(repeating: 32, count: 65_537)]
        for plaintext in invalid {
            for commit in [false, true] {
                let g = try CatalogueFixture()
                g.seed()
                let store = g.store()
                if commit { _ = try store.loadRetained() }
                g.crypto.boxes[Data([200])] = plaintext
                g.trace.events.removeAll()
                let before = g.io.files
                if commit { XCTAssertThrowsError(try store.commit(g.context)) }
                else { XCTAssertThrowsError(try store.loadRetained()) }
                XCTAssertTrue(store.isBroken)
                XCTAssertEqual(g.io.files, before)
                XCTAssertFalse(g.trace.events.contains { $0.hasPrefix("write:") })
            }
        }
    }

    func testEveryNamedArtifactAndForeignKeyRefusesWithoutMutation() throws {
        for name in CatalogueFixture.forbidden {
            for retained in [false, true] {
                let f = try CatalogueFixture()
                if retained { f.seed() }
                f.io.files[f.path(name)] = Data([77])
                let before = f.io.files
                let store = f.store()
                if retained { XCTAssertThrowsError(try store.loadRetained()) }
                else { XCTAssertThrowsError(try store.inspectFresh()) }
                XCTAssertTrue(store.isBroken, name)
                XCTAssertEqual(f.io.files, before, name)
                XCTAssertFalse(f.trace.events.contains { $0.hasPrefix("write:") || $0 == "key-create" })
            }
        }
        for slot in CatalogueForeignStore.allCases {
            let f = try CatalogueFixture()
            f.crypto.foreign.insert(slot)
            XCTAssertThrowsError(try f.store().inspectFresh())
            XCTAssertFalse(f.trace.events.contains("key-create"))
        }
    }

    func testInspectionUsesFullPathsAndErrorsAreNotAbsence() throws {
        let f = try CatalogueFixture()
        try f.store().inspectFresh()
        XCTAssertEqual(f.trace.events, f.inspectionTrace)
        for name in [""] + ["text-state.enc"] + CatalogueFixture.forbidden {
            let g = try CatalogueFixture()
            g.io.fail = "inspect:" + (name.isEmpty ? g.root.path : g.path(name))
            XCTAssertThrowsError(try g.store().inspectFresh()) { XCTAssertEqual($0 as? CatalogueStoreError, .backendFailure) }
            XCTAssertTrue(g.io.files.isEmpty)
            XCTAssertNil(g.crypto.key)
        }
    }

    func testKeyFileContinuityNeverTreatsRetainedBothMissingAsFresh() throws {
        for hasKey in [false, true] {
            for hasFile in [false, true] {
                let f = try CatalogueFixture()
                f.seed()
                if !hasKey { f.crypto.key = nil }
                if !hasFile { f.io.files.removeValue(forKey: f.path("text-state.enc")) }
                let before = f.io.files
                if hasKey && hasFile { XCTAssertEqual(try f.store().loadRetained(), f.context) }
                else { XCTAssertThrowsError(try f.store().loadRetained()) }
                if !hasKey && !hasFile { XCTAssertNoThrow(try f.store().inspectFresh()) }
                else { XCTAssertThrowsError(try f.store().inspectFresh()) }
                XCTAssertEqual(f.io.files, before)
                XCTAssertFalse(f.trace.events.contains("key-create"))
            }
        }
    }

    func testFreshCommitRechecksAllContinuityBeforeIntent() throws {
        for name in CatalogueFixture.forbidden + ["text-state.enc"] {
            let f = try CatalogueFixture()
            let store = f.store()
            try store.inspectFresh()
            f.io.files[f.path(name)] = Data([88])
            f.trace.events.removeAll()
            let before = f.io.files
            XCTAssertThrowsError(try store.commit(f.context), name)
            XCTAssertEqual(f.io.files, before, name)
            XCTAssertFalse(f.trace.events.contains { $0.hasPrefix("write:") || $0 == "key-create" }, name)
        }
    }

    func testRootMustBeAnExplicitExistingDirectory() throws {
        for kind in [CataloguePathKind.absent, .regularFile, .other] {
            let f = try CatalogueFixture()
            f.io.kinds[f.root.path] = kind
            XCTAssertThrowsError(try f.store().inspectFresh()) { XCTAssertEqual($0 as? CatalogueStoreError, .invalidDirectory) }
            XCTAssertTrue(f.io.files.isEmpty)
        }
    }

    func testFreshAuthorityIsInstanceBoundAndSingleUse() throws {
        let f = try CatalogueFixture()
        let checked = f.store()
        try checked.inspectFresh()
        f.trace.events.removeAll()
        let unchecked = f.store()
        XCTAssertThrowsError(try unchecked.commit(f.context)) { XCTAssertEqual($0 as? CatalogueStoreError, .authorityRequired) }
        XCTAssertTrue(f.trace.events.isEmpty)
        XCTAssertThrowsError(try checked.inspectFresh()) { XCTAssertEqual($0 as? CatalogueStoreError, .authorityRequired) }
        XCTAssertTrue(checked.isBroken)
        XCTAssertThrowsError(try checked.commit(f.context)) { XCTAssertEqual($0 as? CatalogueStoreError, .broken) }
        XCTAssertTrue(f.trace.events.isEmpty)
    }

    func testFailedInstanceCannotRetryEvenAfterEvidenceLoss() throws {
        let f = try CatalogueFixture()
        let store = f.store()
        try store.inspectFresh()
        f.io.fail = "sync-directory:" + f.root.path
        XCTAssertThrowsError(try store.commit(f.context))
        f.io.fail = nil
        f.io.files.removeAll() // simulate total evidence loss, never store cleanup
        let before = f.trace.events
        XCTAssertThrowsError(try store.commit(f.context)) { XCTAssertEqual($0 as? CatalogueStoreError, .broken) }
        XCTAssertThrowsError(try store.inspectFresh()) { XCTAssertEqual($0 as? CatalogueStoreError, .broken) }
        XCTAssertThrowsError(try store.loadRetained()) { XCTAssertEqual($0 as? CatalogueStoreError, .broken) }
        XCTAssertEqual(f.trace.events, before)
        XCTAssertThrowsError(try f.store().loadRetained())
    }

    func testSuccessfulStoreAndRetainedInstanceReuseTheKey() throws {
        let f = try CatalogueFixture()
        let store = f.store()
        try store.inspectFresh()
        try store.commit(f.context)
        try store.commit(f.context)
        let retained = f.store()
        XCTAssertEqual(try retained.loadRetained(), f.context)
        try retained.commit(f.context)
        XCTAssertEqual(f.trace.events.filter { $0 == "key-create" }.count, 1)
    }

    func testCommitReopenUsesOnlySealedBytesAndFinishesAfterFinalSync() throws {
        let f = try CatalogueFixture()
        let store = f.store()
        try store.inspectFresh()
        f.trace.events.removeAll()
        try store.commit(f.context)
        let intent = f.path("catalogue.write.pending")
        let temp = f.path("text-state.enc.tmp")
        let final = f.path("text-state.enc")
        XCTAssertEqual(f.trace.events, f.inspectionTrace + [
            "write:" + intent, "sync-file:" + intent, "sync-directory:" + f.root.path,
            "key-create", "key-load", "seal", "write:" + temp, "protect:" + temp,
            "sync-file:" + temp, "rename:" + temp + "->" + final, "read:" + final,
            "sync-directory:" + f.root.path, "remove:" + intent, "sync-directory:" + f.root.path
        ])
        XCTAssertEqual(f.io.files.count, 1)
        XCTAssertNotEqual(f.io.files[final], IdentityCatalogueCodec.encode(f.context))
        XCTAssertEqual(try f.store().loadRetained(), f.context)
        XCTAssertFalse(store.isBroken)
    }

    func testIntentParentSyncFailurePrecedesKeyAndCandidateCreation() throws {
        let f = try CatalogueFixture()
        let store = f.store()
        try store.inspectFresh()
        f.io.fail = "sync-directory:" + f.root.path
        XCTAssertThrowsError(try store.commit(f.context))
        XCTAssertTrue(store.isBroken)
        XCTAssertNil(f.crypto.key)
        XCTAssertNil(f.io.files[f.path("text-state.enc.tmp")])
        XCTAssertEqual(f.io.files[f.path("catalogue.write.pending")], Data("catalogue-write-v1\n".utf8))
    }
}

private enum FixtureFailure: Error { case injected }
private final class CatalogueTrace {
    var events: [String] = []
    var failAt: Int?
    var afterEffect = false
    var onEvent: ((String) throws -> Void)?
    func step<T>(_ event: String, _ body: () throws -> T) throws -> T {
        events.append(event)
        try onEvent?(event)
        let failing = events.count == failAt
        if failing && !afterEffect { throw FixtureFailure.injected }
        let value = try body()
        if failing { throw FixtureFailure.injected }
        return value
    }
}
private final class CatalogueIOFake: CatalogueFileIO {
    let trace: CatalogueTrace
    var files: [String: Data] = [:]
    var directories: Set<String> = []
    var kinds: [String: CataloguePathKind] = [:]
    var fail: String?
    var readOverride: Data?
    var readCaps: [Int] = []
    init(_ trace: CatalogueTrace) { self.trace = trace }
    func step<T>(_ event: String, _ body: () throws -> T) throws -> T {
        try trace.step(event) {
            if fail == event { throw FixtureFailure.injected }
            return try body()
        }
    }
    func inspect(_ url: URL) throws -> CataloguePathKind {
        try step("inspect:" + url.path) {
            if let kind = kinds[url.path] { return kind }
            if directories.contains(url.path) { return .directory }
            return files[url.path] == nil ? .absent : .regularFile
        }
    }
    func writeExclusive(_ bytes: Data, to url: URL) throws {
        try step("write:" + url.path) {
            guard files[url.path] == nil else { throw FixtureFailure.injected }
            files[url.path] = bytes
        }
    }
    func protectAndExclude(_ url: URL) throws { try step("protect:" + url.path) {} }
    func fullSync(_ url: URL, directory: Bool) throws {
        try step((directory ? "sync-directory:" : "sync-file:") + url.path) {}
    }
    func rename(_ source: URL, to destination: URL) throws {
        try step("rename:" + source.path + "->" + destination.path) {
            files[destination.path] = files.removeValue(forKey: source.path)
        }
    }
    func read(_ url: URL, maximumBytes: Int) throws -> Data {
        try step("read:" + url.path) {
            readCaps.append(maximumBytes)
            guard let bytes = files[url.path], bytes.count <= maximumBytes else { throw FixtureFailure.injected }
            return readOverride ?? bytes
        }
    }
    func removeIntent(_ url: URL) throws {
        try step("remove:" + url.path) {
            guard files.removeValue(forKey: url.path) != nil else { throw FixtureFailure.injected }
        }
    }
}
private final class CatalogueCryptoFake: CatalogueCryptography {
    struct Key: Equatable { let id: Int }
    let trace: CatalogueTrace
    var key: Key?
    var foreign: Set<CatalogueForeignStore> = []
    let framingOverhead = 1 // Deliberately not the real envelope; test token only.
    var boxes: [Data: Data] = [:]
    var nextBox: UInt8 = 0
    var wrongCreatedReadback = false
    var missingCreatedReadback = false
    var oversizedSeal = false
    init(_ trace: CatalogueTrace) { self.trace = trace }
    func loadKey() throws -> Key? {
        try trace.step("key-load") {
            if wrongCreatedReadback && trace.events.contains("key-create") {
                return missingCreatedReadback ? nil : Key(id: 99)
            }
            return key
        }
    }
    func createKey() throws -> Key {
        try trace.step("key-create") {
            guard key == nil else { throw FixtureFailure.injected }
            let created = Key(id: 1)
            key = created
            return created
        }
    }
    func foreignKeyExists(_ slot: CatalogueForeignStore) throws -> Bool {
        try trace.step("foreign-key:" + slot.rawValue) { foreign.contains(slot) }
    }
    func seal(_ plaintext: Data, with key: Key) throws -> Data {
        try trace.step("seal") {
            nextBox += 1
            let token = oversizedSeal ? Data(repeating: 0, count: 65_538) : Data([nextBox])
            boxes[token] = plaintext
            return token
        }
    }
    func open(_ sealed: Data, with key: Key) throws -> Data {
        try trace.step("open") {
            guard let plaintext = boxes[sealed] else { throw FixtureFailure.injected }
            return plaintext
        }
    }
}
private final class CatalogueFixture {
    let root = URL(fileURLWithPath: "/synthetic-catalogue/" + UUID().uuidString, isDirectory: true)
    let context: IdentityCatalogue
    let trace = CatalogueTrace()
    let io: CatalogueIOFake
    let crypto: CatalogueCryptoFake
    init() throws {
        context = try IdentityCatalogue(installID: "11111111-1111-4111-8111-111111111111",
            ownerRef: "22222222-2222-4222-8222-222222222222",
            realms: .init(fi: .init(origin: "https://fi.example.invalid:38444", pin: String(repeating: "a", count: 64), protocolKind: "identity-v3"),
                          ru: .init(origin: "https://ru.example.invalid:38444", pin: String(repeating: "b", count: 64), protocolKind: "identity-v3")))
        io = CatalogueIOFake(trace)
        crypto = CatalogueCryptoFake(trace)
        io.directories.insert(root.path)
    }
    static let forbidden = ["text-state.enc.tmp", "catalogue.write.pending", "owner", "realms", "realms/fi", "realms/ru"]
        + ["owner", "realms/fi", "realms/ru"].flatMap { dir in
            ["state.enc", "state.enc.tmp", "write.pending"].map { dir + "/" + $0 }
        }
    var inspectionTrace: [String] {
        ["inspect:" + root.path, "inspect:" + path("text-state.enc")]
            + Self.forbidden.map { "inspect:" + path($0) }
            + ["foreign-key:owner", "foreign-key:fi", "foreign-key:ru", "key-load"]
    }
    func seed() {
        crypto.key = .init(id: 1)
        let token = Data([200])
        crypto.boxes[token] = IdentityCatalogueCodec.encode(context)
        io.files[path("text-state.enc")] = token
    }
    func path(_ name: String) -> String { root.appendingPathComponent(name).path }
    func store() -> CatalogueStore<CatalogueCryptoFake> {
        CatalogueStore(directory: root, context: context, files: io, crypto: crypto)
    }
}
