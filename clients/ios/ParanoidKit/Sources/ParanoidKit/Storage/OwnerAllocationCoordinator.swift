import Foundation

enum OwnerStoreError: Error, Equatable {
    case busy, authorityRequired, cancelled, locked, invalidDirectory, artifactsPresent, continuity
    case contextMismatch, invalidFormat, unsupportedVersion, limitExceeded, invalidTransition
    case bindingMismatch, authenticationFailed, keyMismatch, readbackMismatch, backendFailure, broken
}
enum OwnerProtection { case ownerComplete }
/// The only backend error the coordinator classifies: a precisely reported
/// read-only lock (e.g. errSecInteractionNotAllowed / EPERM-class protection).
/// Adapters throw it instead of a generic error; anything else is failure.
enum OwnerBackendLock: Error { case locked }
protocol OwnerFileIO: CatalogueFileIO {
    /// Create-only, no-follow, mode 0700. Never compensate by deleting evidence.
    func createOwnerDirectory(_ url: URL) throws
    /// Set AND read back complete protection plus backup exclusion on this inode.
    func protectOwnerAndExclude(_ url: URL, policy: OwnerProtection) throws
}
protocol OwnerCryptography: CatalogueCryptography {
    // Conformance promises WhenUnlockedThisDeviceOnly, nonsynchronizable keys.
    // Existing messaging KeychainKey is NOT a conformance simply by account change.
}
struct OwnerRetained: Equatable { let catalogue: AllocatedCatalogueState; let owner: OwnerEnvelopeV1? }
final class OwnerOperation {
    fileprivate let deadline: ContinuousClock.Instant
    fileprivate init(_ deadline: ContinuousClock.Instant) { self.deadline = deadline }
}
/// Successor permit for exactly one append after a checked ledger.
final class OwnerAppendPermit {
    fileprivate let operation: OwnerOperation
    fileprivate let name: String
    fileprivate let revision: UInt64
    fileprivate var consumed = false
    fileprivate init(_ operation: OwnerOperation, name: String, revision: UInt64) { self.operation = operation; self.name = name; self.revision = revision }
}
/// Process-local, one-use dispatch capability. The bytes are exactly what the
/// ledger retained; a ticket exists only after the increment was durable.
final class OwnerDispatchTicket {
    let attemptID: String
    private let transaction: Data
    private var consumed = false
    fileprivate init(attemptID: String, transaction: Data) { self.attemptID = attemptID; self.transaction = transaction }
    func take() throws -> Data { guard !consumed else { throw OwnerStoreError.authorityRequired }; consumed = true; return transaction }
}
// All permits above are nonpersistable classes with fileprivate initializers:
// only this coordinator mints them, and only after the named durable step.
final class OwnerCreationPermit {
    fileprivate let operation: OwnerOperation
    fileprivate let revision: UInt64
    fileprivate var consumed = false
    fileprivate init(_ operation: OwnerOperation, revision: UInt64) { self.operation = operation; self.revision = revision }
}

/// Isolated component, no application defaults or production entropy/verifier.
/// MainActor confines this small coordinator; no app/realm lock is acquired.
@MainActor final class OwnerAllocationCoordinator<C: CatalogueCryptography, O: OwnerCryptography> {
    private let directory: URL
    private let context: IdentityCatalogue
    private let files: any OwnerFileIO
    private let catalogueCrypto: C
    private let ownerCrypto: O
    private let entropy: () throws -> Data
    private let core: OwnerMaterialCore
    private var current: OwnerRetained?
    private var catalogueKey: C.Key?
    private var ownerKey: O.Key?
    private var active: OwnerOperation?
    private var revision: UInt64 = 0
    private var entered = false
    private var awaiting = false
    private var writing = false
    private(set) var isBroken = false

    init(directory: URL, context: IdentityCatalogue, files: any OwnerFileIO, catalogueCrypto: C,
         ownerCrypto: O, entropy: @escaping () throws -> Data, core: OwnerMaterialCore = .init()) {
        self.directory = directory; self.context = context; self.files = files
        self.catalogueCrypto = catalogueCrypto; self.ownerCrypto = ownerCrypto
        self.entropy = entropy; self.core = core
    }
    private func path(_ s: String) -> URL { directory.appendingPathComponent(s) }
    private func checked<T>(_ body: () throws -> T) throws -> T {
        guard !isBroken else { throw OwnerStoreError.broken }
        guard !entered, !awaiting else { throw OwnerStoreError.busy }
        entered = true; defer { entered = false }
        do { return try body() }
        catch {
            // A precisely classified read-only lock before any effect is retryable.
            if error is OwnerBackendLock, !writing { active = nil; throw OwnerStoreError.locked }
            let e = (error as? OwnerStoreError) ?? .backendFailure
            if e == .busy { throw e }
            if writing || [.continuity, .contextMismatch, .artifactsPresent, .keyMismatch,
                           .authenticationFailed, .readbackMismatch, .backendFailure, .invalidDirectory].contains(e) { isBroken = true }
            active = nil
            throw e
        }
    }
    private func require(_ op: OwnerOperation) throws {
        guard active === op else { throw OwnerStoreError.authorityRequired }
        guard ContinuousClock.now < op.deadline, !Task.isCancelled else { throw OwnerStoreError.cancelled }
    }
    /// Sole-operation external wait: every other call is `busy` until it returns.
    /// No application/realm lock is held; only this coordinator is fenced.
    private func awaitingExternal<T>(_ operation: OwnerOperation, _ body: () async throws -> T) async throws -> T {
        awaiting = true; defer { awaiting = false }
        do { return try await body() }
        catch { if active === operation { active = nil }; throw OwnerStoreError.backendFailure }
    }
    func begin(deadline: ContinuousClock.Instant) throws -> OwnerOperation {
        try checked {
            guard active == nil else { throw OwnerStoreError.busy }
            guard ContinuousClock.now < deadline else { throw OwnerStoreError.cancelled }
            let op = OwnerOperation(deadline); active = op; return op
        }
    }
    private func commitOwner(_ next: OwnerEnvelopeV1, catalogue: AllocatedCatalogueState) throws {
        guard let key = ownerKey else { throw OwnerStoreError.continuity }
        ownerKey = try replace(OwnerEnvelopeCodec.encode(next, core: core), owner: true, crypto: ownerCrypto, key: key)
        current = .init(catalogue: catalogue, owner: next)
    }
    func confirmRegistry(_ operation: OwnerOperation, verifier: any IsolatedTrustedOwnerVerifier) async throws -> OwnerRetained {
        let request = try checked {
            try require(operation)
            let old = try refresh(); current = old
            guard let owner = old.owner, owner.phase != "registryConfirmed" else { throw OwnerStoreError.invalidTransition }
            return OwnerBindingRequest(correlation: UUID(), material: owner)
        }
        let evidence = try await awaitingExternal(operation) { try await verifier.binding(for: request) }
        try checked {
            try require(operation)
            guard let evidence, evidence.request == request else { throw OwnerStoreError.authorityRequired }
            let old = try refresh()
            guard var next = old.owner, next == request.material else { throw OwnerStoreError.continuity }
            try core.validate(evidence.binding, material: next)
            next.phase = "registryConfirmed"; next.binding = evidence.binding
            for index in next.attempts.indices where next.attempts[index].resolution == "unresolved" {
                next.attempts[index].resolution = "ownerBound"
                next.attempts[index].finalizedHeight = evidence.finalizedHeight
            }
            try commitOwner(next, catalogue: old.catalogue)
        }
        return try publishConfirmedBinding(operation)
    }
    func resolveExpired(_ operation: OwnerOperation, proposedName: String, verifier: any IsolatedTrustedOwnerVerifier) async throws -> OwnerAppendPermit {
        let request = try checked {
            try require(operation)
            let old = try refresh(); current = old
            guard let owner = old.owner, owner.phase == "registrationPending", OwnerScalars.name(proposedName) else { throw OwnerStoreError.invalidTransition }
            guard owner.attempts.count < 8 else { throw OwnerStoreError.limitExceeded }
            return OwnerExpiryRequest(correlation: UUID(), material: owner, proposedName: proposedName)
        }
        let evidence = try await awaitingExternal(operation) { try await verifier.expiry(for: request) }
        return try checked {
            try require(operation)
            guard let evidence, evidence.request == request else { throw OwnerStoreError.authorityRequired }
            let old = try refresh()
            guard var next = old.owner, next == request.material else { throw OwnerStoreError.continuity }
            let unresolved = Set(next.attempts.filter { $0.resolution == "unresolved" }.map(\.intent.attemptID))
            guard evidence.dispositions.count <= 8, Set(evidence.dispositions.map(\.attemptID)) == unresolved,
                  evidence.dispositions.count == unresolved.count else { throw OwnerStoreError.authorityRequired }
            guard next.attempts.allSatisfy({ evidence.finalizedHeight > $0.intent.lastValidHeight }) else { throw OwnerStoreError.invalidTransition }
            guard !next.attempts.contains(where: { $0.intent.name == proposedName && $0.resolution == "nameTaken" }) else { throw OwnerStoreError.invalidTransition }
            for d in evidence.dispositions {
                let index = next.attempts.firstIndex { $0.intent.attemptID == d.attemptID }!
                next.attempts[index].resolution = d.disposition.rawValue
                next.attempts[index].finalizedHeight = evidence.finalizedHeight
            }
            if next != old.owner { try commitOwner(next, catalogue: old.catalogue) }
            return OwnerAppendPermit(operation, name: proposedName, revision: revision)
        }
    }
    func reserveSend(_ operation: OwnerOperation, attemptID: String) throws -> OwnerDispatchTicket {
        try checked {
            try require(operation)
            let old = try refresh()
            guard var next = old.owner, next.phase == "registrationPending",
                  let index = next.attempts.firstIndex(where: { $0.intent.attemptID == attemptID }),
                  next.attempts[index].stage == "assembled", next.attempts[index].resolution == "unresolved",
                  let transaction = next.attempts[index].transaction else { throw OwnerStoreError.invalidTransition }
            guard next.attempts[index].sends < 3 else { throw OwnerStoreError.limitExceeded }
            let bytes = try OwnerScalars.wire(transaction)
            next.attempts[index].sends += 1
            try commitOwner(next, catalogue: old.catalogue)
            return OwnerDispatchTicket(attemptID: attemptID, transaction: bytes)
        }
    }
    func recordAssembled(_ operation: OwnerOperation, attemptID: String, signer: any IsolatedTrustedOwnerAssembler) throws -> OwnerAttempt {
        try checked {
            try require(operation)
            let old = try refresh()
            guard var next = old.owner, next.phase == "registrationPending", next.wordsBackupConfirmed,
                  let index = next.attempts.firstIndex(where: { $0.intent.attemptID == attemptID }),
                  next.attempts[index].stage == "ownerSigned", next.attempts[index].resolution == "unresolved" else { throw OwnerStoreError.invalidTransition }
            let request = OwnerAssemblyRequest(correlation: UUID(), material: next, attempt: next.attempts[index])
            let evidence = try signer.assembled(for: request)
            try require(operation)
            guard evidence.request == request else { throw OwnerStoreError.authorityRequired }
            next.attempts[index].stage = "assembled"
            next.attempts[index].transaction = evidence.transaction; next.attempts[index].signature = evidence.signature
            try commitOwner(next, catalogue: old.catalogue)
            return next.attempts[index]
        }
    }
    func recordOwnerSigned(_ operation: OwnerOperation, intent: OwnerAttemptIntent, signer: any IsolatedTrustedOwnerSigner, append: OwnerAppendPermit? = nil) throws -> OwnerAttempt {
        try checked {
            try require(operation)
            let old = try refresh()
            guard var next = old.owner, next.wordsBackupConfirmed, next.phase != "registryConfirmed" else { throw OwnerStoreError.invalidTransition }
            guard next.attempts.count < 8 else { throw OwnerStoreError.limitExceeded }
            guard next.attempts.allSatisfy({ $0.resolution != "unresolved" }) else { throw OwnerStoreError.invalidTransition }
            try intent.validate(context: context, owner: next.owner)
            guard !next.attempts.contains(where: { $0.intent.attemptID == intent.attemptID }) else { throw OwnerStoreError.invalidFormat }
            if next.attempts.isEmpty {
                guard append == nil else { throw OwnerStoreError.authorityRequired }
            } else {
                guard let append, append.operation === operation, !append.consumed, append.revision == revision, append.name == intent.name else { throw OwnerStoreError.authorityRequired }
                append.consumed = true
            }
            let request = OwnerSigningRequest(correlation: UUID(), material: next, intent: intent)
            let evidence = try signer.ownerSigned(for: request)
            try require(operation)
            guard evidence.request == request else { throw OwnerStoreError.authorityRequired }
            let attempt = OwnerAttempt(intent: intent, message: evidence.message, ownerSignature: evidence.ownerSignature)
            next.attempts.append(attempt); next.phase = "registrationPending"
            try commitOwner(next, catalogue: old.catalogue)
            return attempt
        }
    }
    func confirmWordsBackup(_ operation: OwnerOperation) throws {
        try checked {
            try require(operation)
            let old = try refresh()
            guard var next = old.owner else { throw OwnerStoreError.invalidTransition }
            if next.wordsBackupConfirmed { return }
            next.wordsBackupConfirmed = true
            try commitOwner(next, catalogue: old.catalogue)
        }
    }
    func finish(_ operation: OwnerOperation) throws { try checked { try require(operation); active = nil } }
    /// Explicit cancellation: invalidates the operation's permits, never undoes durable allocation.
    func cancel(_ operation: OwnerOperation) throws { try checked { guard active === operation else { throw OwnerStoreError.authorityRequired }; active = nil } }
    private func frame(_ bytes: Data) throws {
        guard (29...65_565).contains(bytes.count) else { throw OwnerStoreError.limitExceeded }
    }
    private func readCatalogue() throws -> AllocatedCatalogueState {
        guard directory.isFileURL, try files.inspect(directory) == .directory else { throw OwnerStoreError.invalidDirectory }
        for s in ["text-state.enc.tmp", "catalogue.write.pending", "realms", "realms/fi", "realms/ru"] + ["realms/fi", "realms/ru"].flatMap({ d in ["state.enc", "state.enc.tmp", "write.pending"].map { d + "/" + $0 } }) {
            guard try files.inspect(path(s)) == .absent else { throw OwnerStoreError.artifactsPresent }
        }
        for slot in [CatalogueForeignStore.fi, .ru] { guard try !catalogueCrypto.foreignKeyExists(slot) else { throw OwnerStoreError.artifactsPresent } }
        guard try files.inspect(path("text-state.enc")) == .regularFile,
              let key = try catalogueCrypto.loadKey() else { throw OwnerStoreError.continuity }
        if let catalogueKey, catalogueKey != key { throw OwnerStoreError.keyMismatch }
        let bytes = try files.read(path("text-state.enc"), maximumBytes: 65_565); try frame(bytes)
        let value = try AllocatedCatalogueCodec.decode(open(bytes, catalogueCrypto, key), context: context)
        catalogueKey = key
        return value
    }
    /// Any AEAD failure is `authenticationFailed`; bytes are never repaired.
    private func open<K: CatalogueCryptography>(_ sealed: Data, _ crypto: K, _ key: K.Key) throws -> Data {
        do { return try crypto.open(sealed, with: key) }
        catch let lock as OwnerBackendLock { throw lock }
        catch { throw OwnerStoreError.authenticationFailed }
    }
    /// Stops at a surviving parent: descendants of a non-directory `owner/`
    /// are never inspected through a foreign inode or symbolic link.
    private func readOwner(_ catalogue: AllocatedCatalogueState, permitMissing: Bool = false) throws -> OwnerEnvelopeV1? {
        let dir = try files.inspect(path("owner"))
        if !catalogue.allocated || permitMissing {
            guard dir == .absent, try ownerCrypto.loadKey() == nil,
                  try !catalogueCrypto.foreignKeyExists(.owner) else { throw OwnerStoreError.artifactsPresent }
            return nil
        }
        guard dir == .directory else { throw OwnerStoreError.continuity }
        let file = try files.inspect(path("owner/state.enc"))
        for s in ["owner/state.enc.tmp", "owner/write.pending"] { guard try files.inspect(path(s)) == .absent else { throw OwnerStoreError.artifactsPresent } }
        guard file == .regularFile || file == .absent else { throw OwnerStoreError.continuity }
        let key = try ownerCrypto.loadKey()
        guard try catalogueCrypto.foreignKeyExists(.owner) == (key != nil) else { throw OwnerStoreError.keyMismatch }
        guard file == .regularFile, let key else { throw OwnerStoreError.continuity }
        if let ownerKey, ownerKey != key { throw OwnerStoreError.keyMismatch }
        let bytes = try files.read(path("owner/state.enc"), maximumBytes: 65_565); try frame(bytes)
        let value = try OwnerEnvelopeCodec.decode(open(bytes, ownerCrypto, key), context: context, core: core)
        if let binding = catalogue.binding {
            guard value.phase == "registryConfirmed", value.binding == binding else { throw OwnerStoreError.bindingMismatch }
        }
        ownerKey = key; return value
    }
    private func refresh(permitMissing: Bool = false) throws -> OwnerRetained {
        let catalogue = try readCatalogue()
        let snapshot = try OwnerRetained(catalogue: catalogue, owner: readOwner(catalogue, permitMissing: permitMissing))
        if let current, current != snapshot { throw OwnerStoreError.continuity }
        return snapshot
    }
    /// Read-only classification inside the active operation; grants nothing.
    func loadRetainedWhileActive(_ operation: OwnerOperation) throws -> OwnerRetained {
        try checked { try require(operation); let value = try refresh(); current = value; return value }
    }
    func loadRetained() throws -> OwnerRetained {
        try checked {
            guard active == nil else { throw OwnerStoreError.busy }
            let value = try refresh(); current = value; return value
        }
    }
    /// No state is adopted until the second parent sync returns. A thrown effect
    /// leaves every key/temp/intent in place and latches this writer broken.
    private func replace<K: CatalogueCryptography>(_ plaintext: Data, owner: Bool, crypto: K, key retained: K.Key?) throws -> K.Key {
        guard plaintext.count <= 65_536 else { throw OwnerStoreError.limitExceeded }
        writing = true
        let parent = owner ? path("owner") : directory
        if owner && retained == nil {
            try files.createOwnerDirectory(parent)
            try files.protectOwnerAndExclude(parent, policy: .ownerComplete)
            try files.fullSync(parent, directory: true); try files.fullSync(directory, directory: true)
        }
        let intent = owner ? path("owner/write.pending") : path("catalogue.write.pending")
        let temporary = owner ? path("owner/state.enc.tmp") : path("text-state.enc.tmp")
        let destination = owner ? path("owner/state.enc") : path("text-state.enc")
        try files.writeExclusive(Data((owner ? "owner-write-v1\n" : "catalogue-write-v1\n").utf8), to: intent)
        if owner { try files.protectOwnerAndExclude(intent, policy: .ownerComplete) } else { try files.protectAndExclude(intent) }
        try files.fullSync(intent, directory: false); try files.fullSync(parent, directory: true)
        let key = try retained ?? crypto.createKey()
        guard try crypto.loadKey() == key else { throw OwnerStoreError.keyMismatch }
        let sealed = try crypto.seal(plaintext, with: key); try frame(sealed)
        try files.writeExclusive(sealed, to: temporary)
        if owner { try files.protectOwnerAndExclude(temporary, policy: .ownerComplete) } else { try files.protectAndExclude(temporary) }
        try files.fullSync(temporary, directory: false); try files.rename(temporary, to: destination)
        guard try files.read(destination, maximumBytes: 65_565) == sealed else { throw OwnerStoreError.readbackMismatch }
        try files.fullSync(parent, directory: true); try files.removeIntent(intent); try files.fullSync(parent, directory: true)
        writing = false; revision += 1
        return key
    }
    func recoverVerified(_ operation: OwnerOperation, entropy: String, verifier: any IsolatedTrustedOwnerVerifier) async throws -> OwnerRetained {
        let request = try checked {
            try require(operation)
            let old = try refresh()
            guard !old.catalogue.allocated else { throw OwnerStoreError.invalidTransition }
            current = old
            return try OwnerBindingRequest(correlation: UUID(), material: core.identity(entropy: entropy, context: context))
        }
        let evidence = try await awaitingExternal(operation) { try await verifier.binding(for: request) }
        let value = try checked {
            try require(operation)
            guard let evidence, evidence.request == request else { throw OwnerStoreError.authorityRequired }
            try core.validate(evidence.binding, material: request.material)
            var value = request.material; value.binding = evidence.binding; value.phase = "registryConfirmed"
            return value
        }
        let permit = try reserveNewOwner(operation)
        try checked {
            try require(operation)
            guard !permit.consumed, permit.revision == revision else { throw OwnerStoreError.authorityRequired }
            permit.consumed = true
            let old = try refresh(permitMissing: true)
            ownerKey = try replace(OwnerEnvelopeCodec.encode(value, core: core), owner: true, crypto: ownerCrypto, key: Optional<O.Key>.none)
            current = .init(catalogue: old.catalogue, owner: value)
        }
        return try publishConfirmedBinding(operation)
    }
    func publishConfirmedBinding(_ operation: OwnerOperation) throws -> OwnerRetained {
        try checked {
            try require(operation)
            let old = try refresh()
            guard let owner = old.owner, owner.phase == "registryConfirmed", let binding = owner.binding else { throw OwnerStoreError.invalidTransition }
            if old.catalogue.binding == binding { return old }
            guard old.catalogue.binding == nil, let key = catalogueKey else { throw OwnerStoreError.bindingMismatch }
            var next = old.catalogue; next.binding = binding
            catalogueKey = try replace(AllocatedCatalogueCodec.encode(next), owner: false, crypto: catalogueCrypto, key: key)
            let result = OwnerRetained(catalogue: next, owner: owner); current = result; return result
        }
    }
    func reserveNewOwner(_ operation: OwnerOperation) throws -> OwnerCreationPermit {
        try checked {
            try require(operation)
            let old = try refresh()
            guard !old.catalogue.allocated else { throw OwnerStoreError.invalidTransition }
            var next = old.catalogue; next.allocated = true
            guard let key = catalogueKey else { throw OwnerStoreError.continuity }
            catalogueKey = try replace(AllocatedCatalogueCodec.encode(next), owner: false, crypto: catalogueCrypto, key: key)
            current = .init(catalogue: next, owner: nil)
            return OwnerCreationPermit(operation, revision: revision)
        }
    }
    func initializeNew(_ permit: OwnerCreationPermit, operation: OwnerOperation) throws -> OwnerEnvelopeV1 {
        try checked {
            try require(operation)
            guard permit.operation === operation, !permit.consumed, permit.revision == revision else { throw OwnerStoreError.authorityRequired }
            permit.consumed = true
            let raw = try entropy()
            guard raw.count == 16 else { throw OwnerStoreError.invalidFormat }
            let value = try core.identity(entropy: raw.base64EncodedString(), context: context)
            let plaintext = try OwnerEnvelopeCodec.encode(value, core: core)
            let old = try refresh(permitMissing: true)
            guard old.catalogue.allocated else { throw OwnerStoreError.invalidTransition }
            ownerKey = try replace(plaintext, owner: true, crypto: ownerCrypto, key: Optional<O.Key>.none)
            current = .init(catalogue: old.catalogue, owner: value)
            return value
        }
    }
}
