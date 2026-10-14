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
@MainActor final class OwnerDispatchTicket {
    let attemptID: String
    private let transaction: Data
    private var consumed = false
    private let authorize: () throws -> Void
    fileprivate init(attemptID: String, transaction: Data, authorize: @escaping () throws -> Void) {
        self.attemptID = attemptID; self.transaction = transaction; self.authorize = authorize
    }
    func take() throws -> Data {
        guard !consumed else { throw OwnerStoreError.authorityRequired }
        try authorize()
        consumed = true
        return transaction
    }
}
// All permits above are nonpersistable classes with fileprivate initializers:
// only this coordinator mints them, and only after the named durable step.
final class OwnerCreationPermit {
    fileprivate let operation: OwnerOperation
    fileprivate let revision: UInt64
    fileprivate var consumed = false
    fileprivate init(_ operation: OwnerOperation, revision: UInt64) { self.operation = operation; self.revision = revision }
}

/// Race completion without a task group: an uncooperative external continuation
/// must not hold the caller or its authority past cancellation/deadline.
@MainActor private final class OwnerExternalWait<Value: Sendable> {
    var continuation: CheckedContinuation<Value, any Error>?
    var worker: Task<Void, Never>?
    var timer: Task<Void, Never>?
    func finish(_ result: Result<Value, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        worker?.cancel(); timer?.cancel(); worker = nil; timer = nil
        continuation.resume(with: result)
    }
}

/// Isolated component, no application defaults or production entropy/verifier.
/// MainActor confines this small coordinator; no app/realm lock is acquired.
@MainActor final class OwnerAllocationCoordinator<C: CatalogueCryptography, O: OwnerCryptography> {
    private let directory: URL
    private let context: IdentityCatalogue
    private let files: LeasedFileIO
    private let catalogueCrypto: LeasedCryptography<C>
    private let ownerCrypto: LeasedCryptography<O>
    private let incarnation = UUID()
    private var closed = false
    private let entropy: () throws -> Data
    private let core: OwnerMaterialCore
    private var current: OwnerRetained?
    private var catalogueKey: C.Key?
    private var ownerKey: O.Key?
    private var active: OwnerOperation?
    private var revision: UInt64 = 0
    private var entered = false
    private var awaiting: OwnerOperation?
    private var cancelWait: (() -> Void)?
    private var writing = false
    private(set) var isBroken = false

    init(directory: URL, context: IdentityCatalogue, files: LeasedFileIO, catalogueCrypto: LeasedCryptography<C>,
         ownerCrypto: LeasedCryptography<O>, entropy: @escaping () throws -> Data, core: OwnerMaterialCore = .init()) {
        self.directory = directory; self.context = context; self.files = files
        self.catalogueCrypto = catalogueCrypto; self.ownerCrypto = ownerCrypto
        self.entropy = entropy; self.core = core
    }
    private func checkLease() throws {
        guard !closed else { throw OwnerStoreError.authorityRequired }
        guard files.lease === catalogueCrypto.lease, files.lease === ownerCrypto.lease,
              files.holder === catalogueCrypto.holder, files.holder === ownerCrypto.holder,
              directory.isFileURL, directory.standardizedFileURL == files.lease.root.standardizedFileURL else {
            throw OwnerStoreError.contextMismatch
        }
        try files.lease.claim(files.holder, coordinator: incarnation)
        try files.bind(incarnation); try catalogueCrypto.bind(incarnation); try ownerCrypto.bind(incarnation)
        try files.lease.validate(files.holder, coordinator: incarnation)
    }
    func close() {
        closed = true; active = nil; cancelWait?()
        files.lease.close(files.holder, coordinator: incarnation)
    }
    private func path(_ s: String) -> URL { directory.appendingPathComponent(s) }
    private func checked<T>(_ operation: OwnerOperation? = nil, _ body: () throws -> T) throws -> T {
        guard !isBroken else { throw OwnerStoreError.broken }
        guard !entered, awaiting == nil else { throw OwnerStoreError.busy }
        entered = true; defer { entered = false }
        do {
            try checkLease()
            let result = try body()
            try checkLease()
            if let active { try require(active) }
            writing = false
            return result
        }
        catch {
            // A precisely classified read-only lock before any effect is retryable.
            if error is OwnerBackendLock, !writing {
                if operation == nil || active === operation { active = nil }
                throw OwnerStoreError.locked
            }
            let e = (error as? OwnerStoreError) ?? .backendFailure
            if e == .busy, !writing { throw e }
            if writing || [.continuity, .contextMismatch, .artifactsPresent, .keyMismatch,
                           .authenticationFailed, .readbackMismatch, .backendFailure, .invalidDirectory].contains(e) { isBroken = true }
            if operation == nil || active === operation { active = nil }
            throw e
        }
    }
    private func require(_ op: OwnerOperation) throws {
        guard active === op else { throw OwnerStoreError.authorityRequired }
        guard ContinuousClock.now < op.deadline, !Task.isCancelled else { throw OwnerStoreError.cancelled }
        try checkLease()
    }
    /// Unrelated calls remain busy; explicit cancel/close and the finite deadline
    /// revoke this wait even if the external verifier ignores task cancellation.
    private func awaitingExternal<T: Sendable>(_ operation: OwnerOperation, _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let wait = OwnerExternalWait<T>()
        let validate: @MainActor () throws -> Void = { [weak self] in
            guard let self else { throw OwnerStoreError.authorityRequired }
            try self.require(operation)
        }
        awaiting = operation
        let complete: @MainActor (Result<T, any Error>) -> Void = { [weak self] result in
            guard wait.continuation != nil else { return }
            if let self, self.awaiting === operation {
                self.awaiting = nil; self.cancelWait = nil
                if case .failure = result, self.active === operation { self.active = nil }
            }
            wait.finish(result)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wait.continuation = continuation
                cancelWait = { complete(.failure(OwnerStoreError.cancelled)) }
                if Task.isCancelled { complete(.failure(OwnerStoreError.cancelled)); return }
                wait.worker = Task { @MainActor in
                    // Cancellation can win before this queued task starts.
                    do { try validate() } catch { complete(.failure(error)); return }
                    do { complete(.success(try await body())) }
                    catch { complete(.failure(OwnerStoreError.backendFailure)) }
                }
                wait.timer = Task { @MainActor in
                    do { try await Task.sleep(until: operation.deadline, clock: .continuous) }
                    catch { return }
                    complete(.failure(OwnerStoreError.cancelled))
                }
            }
        } onCancel: {
            Task { @MainActor in complete(.failure(OwnerStoreError.cancelled)) }
        }
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
        let request = try checked(operation) {
            try require(operation)
            let old = try refresh(); current = old
            guard let owner = old.owner, owner.phase != "registryConfirmed" else { throw OwnerStoreError.invalidTransition }
            return OwnerBindingRequest(correlation: UUID(), material: owner)
        }
        let evidence = try await awaitingExternal(operation) { try await verifier.binding(for: request) }
        try checked(operation) {
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
    func resolveExpired(_ operation: OwnerOperation, proposedName: String, verifier: any IsolatedTrustedOwnerVerifier) async throws -> OwnerAppendPermit? {
        let request = try checked(operation) {
            try require(operation)
            let old = try refresh(); current = old
            guard let owner = old.owner, owner.phase == "registrationPending", OwnerScalars.name(proposedName) else { throw OwnerStoreError.invalidTransition }
            return OwnerExpiryRequest(correlation: UUID(), material: owner, proposedName: proposedName)
        }
        let evidence = try await awaitingExternal(operation) { try await verifier.expiry(for: request) }
        return try checked(operation) {
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
            guard !next.attempts.contains(where: { $0.intent.name == proposedName && $0.resolution == "nameTaken" }) else { throw OwnerStoreError.invalidTransition }
            if next != old.owner { try commitOwner(next, catalogue: old.catalogue) }
            try require(operation)
            return next.attempts.count < 8 ? OwnerAppendPermit(operation, name: proposedName, revision: revision) : nil
        }
    }
    func reserveSend(_ operation: OwnerOperation, attemptID: String) throws -> OwnerDispatchTicket {
        try checked(operation) {
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
            let issuedRevision = revision
            let expectedAttempt = next.attempts[index]
            return OwnerDispatchTicket(attemptID: attemptID, transaction: bytes) { [weak self] in
                guard let self else { throw OwnerStoreError.authorityRequired }
                try self.checked(operation) {
                    try self.require(operation)
                    guard self.revision == issuedRevision,
                          self.current?.owner?.phase == "registrationPending",
                          self.current?.owner?.attempts.first(where: { $0.intent.attemptID == attemptID }) == expectedAttempt else { throw OwnerStoreError.authorityRequired }
                }
            }
        }
    }
    func recordAssembled(_ operation: OwnerOperation, attemptID: String, signer: any IsolatedTrustedOwnerAssembler) throws -> OwnerAttempt {
        try checked(operation) {
            try require(operation)
            let old = try refresh()
            guard var next = old.owner, next.phase == "registrationPending", next.wordsBackupConfirmed,
                  let index = next.attempts.firstIndex(where: { $0.intent.attemptID == attemptID }),
                  next.attempts[index].stage == "ownerSigned", next.attempts[index].resolution == "unresolved" else { throw OwnerStoreError.invalidTransition }
            let request = OwnerAssemblyRequest(correlation: UUID(), material: next, attempt: next.attempts[index])
            try require(operation)
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
        try checked(operation) {
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
            try require(operation)
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
        try checked(operation) {
            try require(operation)
            let old = try refresh()
            guard var next = old.owner else { throw OwnerStoreError.invalidTransition }
            if next.wordsBackupConfirmed { return }
            next.wordsBackupConfirmed = true
            try commitOwner(next, catalogue: old.catalogue)
        }
    }
    func finish(_ operation: OwnerOperation) throws { try checked(operation) { try require(operation); active = nil } }
    /// Explicit cancellation: invalidates the operation's permits, never undoes durable allocation.
    func cancel(_ operation: OwnerOperation) throws {
        guard active === operation else { throw OwnerStoreError.authorityRequired }
        active = nil
        cancelWait?()
    }
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
        do {
            let catalogue = try readCatalogue()
            let snapshot = try OwnerRetained(catalogue: catalogue, owner: readOwner(catalogue, permitMissing: permitMissing))
            if let current, current != snapshot { throw OwnerStoreError.continuity }
            return snapshot
        } catch let lock as OwnerBackendLock { throw lock }
        catch {
            // Classify by origin: malformed RETAINED bytes are integrity loss.
            // Invalid proposed candidates elsewhere remain pre-effect refusals.
            isBroken = true
            throw error
        }
    }
    /// Read-only classification inside the active operation; grants nothing.
    func loadRetainedWhileActive(_ operation: OwnerOperation) throws -> OwnerRetained {
        try checked(operation) { try require(operation); let value = try refresh(); current = value; return value }
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
        guard let operation = active else { throw OwnerStoreError.authorityRequired }
        try require(operation)
        func step<T>(_ body: () throws -> T) throws -> T {
            try require(operation)
            let result = try body()
            try require(operation)
            return result
        }
        writing = true
        let parent = owner ? path("owner") : directory
        if owner && retained == nil {
            try step { try files.createOwnerDirectory(parent) }
            try step { try files.protectOwnerAndExclude(parent, policy: .ownerComplete) }
            try step { try files.fullSync(parent, directory: true) }
            try step { try files.fullSync(directory, directory: true) }
        }
        let intent = owner ? path("owner/write.pending") : path("catalogue.write.pending")
        let temporary = owner ? path("owner/state.enc.tmp") : path("text-state.enc.tmp")
        let destination = owner ? path("owner/state.enc") : path("text-state.enc")
        try step { try files.writeExclusive(Data((owner ? "owner-write-v1\n" : "catalogue-write-v1\n").utf8), to: intent) }
        try step {
            if owner { try files.protectOwnerAndExclude(intent, policy: .ownerComplete) } else { try files.protectAndExclude(intent) }
        }
        try step { try files.fullSync(intent, directory: false) }
        try step { try files.fullSync(parent, directory: true) }
        let key = try step { try retained ?? crypto.createKey() }
        guard try step({ try crypto.loadKey() }) == key else { throw OwnerStoreError.keyMismatch }
        let sealed = try step { try crypto.seal(plaintext, with: key) }; try frame(sealed)
        try step { try files.writeExclusive(sealed, to: temporary) }
        try step {
            if owner { try files.protectOwnerAndExclude(temporary, policy: .ownerComplete) } else { try files.protectAndExclude(temporary) }
        }
        try step { try files.fullSync(temporary, directory: false) }
        try step { try files.rename(temporary, to: destination) }
        guard try step({ try files.read(destination, maximumBytes: 65_565) }) == sealed else { throw OwnerStoreError.readbackMismatch }
        try step { try files.fullSync(parent, directory: true) }
        try step { try files.removeIntent(intent) }
        try step { try files.fullSync(parent, directory: true) }
        revision += 1
        // `writing` stays set through checked's final authority/adoption boundary.
        return key
    }
    func recoverVerified(_ operation: OwnerOperation, entropy: String, verifier: any IsolatedTrustedOwnerVerifier) async throws -> OwnerRetained {
        let request = try checked(operation) {
            try require(operation)
            let old = try refresh()
            guard !old.catalogue.allocated else { throw OwnerStoreError.invalidTransition }
            current = old
            return try OwnerBindingRequest(correlation: UUID(), material: core.identity(entropy: entropy, context: context))
        }
        let evidence = try await awaitingExternal(operation) { try await verifier.binding(for: request) }
        let value = try checked(operation) {
            try require(operation)
            guard let evidence, evidence.request == request else { throw OwnerStoreError.authorityRequired }
            try core.validate(evidence.binding, material: request.material)
            var value = request.material; value.binding = evidence.binding; value.phase = "registryConfirmed"
            return value
        }
        let permit = try reserveNewOwner(operation)
        try checked(operation) {
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
        try checked(operation) {
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
        try checked(operation) {
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
        try checked(operation) {
            try require(operation)
            guard permit.operation === operation, !permit.consumed, permit.revision == revision else { throw OwnerStoreError.authorityRequired }
            let old = try refresh(permitMissing: true)
            guard old.catalogue.allocated else { throw OwnerStoreError.invalidTransition }
            try require(operation)
            permit.consumed = true
            let raw = try entropy()
            try require(operation)
            guard raw.count == 16 else { throw OwnerStoreError.invalidFormat }
            let value = try core.identity(entropy: raw.base64EncodedString(), context: context)
            let plaintext = try OwnerEnvelopeCodec.encode(value, core: core)
            ownerKey = try replace(plaintext, owner: true, crypto: ownerCrypto, key: Optional<O.Key>.none)
            current = .init(catalogue: old.catalogue, owner: value)
            return value
        }
    }
}
