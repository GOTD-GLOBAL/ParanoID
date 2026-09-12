import Foundation

/// Where a committed candidate goes.
///
/// It is Android's `KeyClient.Commit` (`SelfServiceClient.java:12`): one
/// synchronous method that returns only once the snapshot is durable on the
/// device. `SnapshotStore` is the implementation the application uses; the
/// host tests substitute a store over an in-memory file system that can fail a
/// chosen step.
public protocol SnapshotSink {
    /// Durably commits `snapshot`. Throwing means the candidate is **not** on
    /// the device, and the caller must freeze.
    func save(_ snapshot: String) throws
}

extension SnapshotStore: SnapshotSink {
    /// The five durable steps of `SnapshotStore.commit(_:)`, under the name
    /// the service adapter calls them by.
    public func save(_ snapshot: String) throws {
        try commit(snapshot)
    }
}

/// The application adapter over the unchanged v2 opaque transport: the port of
/// `clients/android/src/org/paranoid/text/SelfServiceClient.java`.
///
/// It owns the one copy of the core state text and it is the only thing that
/// moves it forward. Every operation follows the same order, which is the
/// security property of `docs/protocol/first-contact-v1.md:173-178` and
/// `docs/clients/core/self-service.md:97-100`:
///
/// 1. ask the core for a candidate (`CoreBridge.command`),
/// 2. check the candidate is one this build may keep,
/// 3. **persist it**, whole, through `SnapshotSink`,
/// 4. only then adopt it in memory, hand it to a listener, show it, or send
///    anything that depends on it.
///
/// A failed commit is terminal: `isBroken` stays set for the rest of the
/// process, every later call throws `SelfServiceError.frozen`, and because
/// `updateTrust()` is the only place a realm and a pin can be obtained, a
/// frozen client also takes the application off the network — no lane can dial
/// a server it cannot get an address for. Nothing in this file opens a
/// connection: there is no URL loading code here, and no request is ever sent
/// from the state owner.
///
/// The state text holds private keys and message plaintext. It never leaves
/// this object except through `SnapshotSink`, and nothing here logs it.
public final class SelfServiceClient {
    /// A call control that arrived inside an accepted `receive_v2` candidate.
    /// It is delivered **after** that candidate is durable, never before
    /// (`SelfServiceClient.java:14,84-85`).
    public typealias CallListener = ([String: Any]) throws -> Void
    /// The envelope identifier of a message the server has accepted, after the
    /// acceptance is durable (`SelfServiceClient.java:15`).
    public typealias AcceptedListener = (String) -> Void

    /// Invoked on the state owner only after the entire candidate committed.
    public var callListener: CallListener?
    /// Invoked after an acceptance committed.
    public var acceptedListener: AcceptedListener?

    /// Terminal once set: a commit failed, so no candidate may be adopted and
    /// nothing may be sent (`SelfServiceClient.java:78`).
    public private(set) var isBroken = false

    private let sink: SnapshotSink
    private let trust: ServiceTrust
    private let token: String
    private var state: String
    private var stateVersion: Int

    /// Opens the client over the retained wrapper, or starts a configured but
    /// empty one.
    ///
    /// The opening rules are `SelfServiceClient.java:23-44` in order:
    ///
    /// - a wrapper version other than 4 is `unsupportedSnapshot` and the bytes
    ///   are left untouched;
    /// - `realm` and `tls_pin` are checked the way the TLS layer checks them,
    ///   and `token` is empty or 64 hexadecimal digits;
    /// - a core schema other than 0 or 3 is `unsupportedSnapshot`;
    /// - a schema-0 state is validated by running `upgrade_v2` as a **dry
    ///   run**: the candidate is inspected and thrown away, nothing is
    ///   committed and nothing is adopted. A crash between creating an identity
    ///   and completing the schema leaves exactly that state, and the clean
    ///   upgrader is the only thing that can say whether it is usable;
    /// - the realm of the wrapper must be the realm the core state was created
    ///   for.
    ///
    /// Trust comes from the saved wrapper when there is one — saved trust
    /// always wins over a compiled default, and a fixture that disagrees with
    /// it is refused rather than applied (`SelfServiceClient.java:47-51`).
    /// With nothing saved, the fixture is used, and only then the compiled
    /// default, which in a Debug build without `-paranoid-allow-hosted` does
    /// not exist at all.
    ///
    /// - Parameters:
    ///   - saved: the stored wrapper, or `nil` for a container with no state
    ///     file.
    ///   - sink: where candidates are committed.
    ///   - fixture: the realm and pin of a local stand, from the launch
    ///     arguments (step 30).
    ///   - compiled: the built-in default; `ServiceTrust.hostedDefault()` by
    ///     default.
    /// - Throws: `SelfServiceError`, `PinnedTrustFailure` or `CoreError`.
    public init(saved: String?,
                sink: SnapshotSink,
                fixture: ServiceTrust? = nil,
                compiled: ServiceTrust? = ServiceTrust.hostedDefault()) throws {
        self.sink = sink
        guard let saved else {
            guard let trust = fixture ?? compiled else { throw SelfServiceError.trustUnavailable }
            self.trust = trust
            self.token = ""
            self.state = ""
            self.stateVersion = Snapshot.legacyStateVersion
            return
        }
        let snapshot = try Snapshot.open(saved)
        if let fixture, fixture != snapshot.trust { throw SelfServiceError.savedTrustWins }
        self.trust = snapshot.trust
        self.token = snapshot.token
        self.state = snapshot.state
        self.stateVersion = snapshot.stateVersion
        if snapshot.stateVersion == Snapshot.legacyStateVersion {
            try dryRunUpgrade()
        }
        guard try coreRealm() == snapshot.trust.realm else { throw SelfServiceError.realmMismatch }
    }

    // MARK: - trust, the gate in front of every connection

    /// The public transport trust: the origin to dial and the key to pin.
    ///
    /// This is `SelfServiceClient.java:48`. It returns no credential and it
    /// never changes the snapshot; it is the only way anything in this client
    /// learns where the server is, which is what makes a frozen client an
    /// offline one.
    ///
    /// - Throws: `SelfServiceError.frozen`.
    public func updateTrust() throws -> ServiceTrust {
        try healthy()
        return trust
    }

    // MARK: - identity

    /// Creates the identity if there is none and brings the state to schema 3,
    /// committing after each step.
    ///
    /// Both candidates are durable before this returns, which is why
    /// `sync()` on Android calls it before the first network request
    /// (`SelfServiceClient.java:186`): the identity and the clean channel
    /// schema exist on the device before anything about them is told to a
    /// server.
    ///
    /// - Throws: `SelfServiceError`, `CoreError`.
    public func createIdentity() throws {
        try healthy()
        if try state.isEmpty || isAbsent(view().object["request"]) {
            try apply(["op": "create_identity", "realm": trust.realm, "pin": trust.pin])
        }
        try apply(["op": "upgrade_v2"])
    }

    /// Whether a state exists at all (`SelfServiceClient.java:196`).
    public func hasIdentity() throws -> Bool {
        try healthy()
        return !state.isEmpty
    }

    /// Whether the enrollment of this device is active
    /// (`SelfServiceClient.java:195`).
    public func registered() throws -> Bool {
        try healthy()
        return try active()
    }

    /// The credential of the registration request, the object a challenge
    /// intent carries for `purpose == "register"`
    /// (`SelfServiceClient.java:175`).
    public func credential() throws -> [String: Any] {
        try healthy()
        guard let request = try view().object["request"] as? [String: Any],
              let credential = request["credential"] as? [String: Any]
        else { throw SelfServiceError.malformedReply("request.credential") }
        return credential
    }

    /// The enrollment of this device once the server has answered, the object
    /// a challenge intent draws `account`, `device` and `credential` from
    /// (`SelfServiceClient.java:177-179`), or `nil` before registration.
    public func enrollment() throws -> [String: Any]? {
        try healthy()
        return try view().object["enrollment"] as? [String: Any]
    }

    // MARK: - the durable step

    /// Commits the result of a registration: the server status and then the
    /// contact material (`SelfServiceClient.java:214-217`).
    ///
    /// Each of the two is its own candidate and its own commit, so an
    /// interrupted registration leaves a state the next launch can continue
    /// from.
    public func registrationResult(status: [String: Any]) throws {
        try apply(["op": "server_status_v2", "status": status])
        try apply(["op": "prepare_contact_v2"])
    }

    /// Reads a contact text without changing anything
    /// (`SelfServiceClient.java:100-102`): the fingerprint and account of the
    /// peer, for the confirmation screen.
    public func previewContact(_ raw: String) throws -> [String: Any] {
        try nativeCall(["op": "contact_text_v2", "text": raw]).object
    }

    /// Pairs with the contact in `raw` (`SelfServiceClient.java:103-105`).
    public func pair(_ raw: String, verified: Bool) throws {
        try apply(["op": "pair_contact_v2", "text": raw, "verified": verified])
    }

    /// Blocks or unblocks a paired account (`SelfServiceClient.java:106-108`).
    public func block(account: String, blocked: Bool) throws {
        try apply(["op": "block_contact_v2", "account": account, "blocked": blocked])
    }

    /// Enqueues one text message for `account`
    /// (`SelfServiceClient.java:109-112`).
    public func send(account: String, text: String) throws {
        guard try active() else { throw SelfServiceError.registrationRequired }
        try apply(["op": "send_v2", "account": account, "text": text])
    }

    /// Enqueues one call control and returns the immutable envelope
    /// identifier.
    ///
    /// This is durable enqueue, not server acceptance
    /// (`SelfServiceClient.java:113-123`): the identifier names a candidate
    /// that is already on the device.
    @discardableResult
    public func sendCall(account: String, body: [String: Any]) throws -> String {
        guard try active() else { throw SelfServiceError.registrationRequired }
        let before = Set(try pending().compactMap { $0["id"] as? String })
        try apply(["op": "send_call_v1", "account": account, "body": body])
        var identifier: String?
        for envelope in try pending() {
            guard let id = envelope["id"] as? String, !before.contains(id) else { continue }
            guard identifier == nil else { throw SelfServiceError.callEnqueueInvariant }
            identifier = id
        }
        guard let identifier else { throw SelfServiceError.callEnqueueInvariant }
        return identifier
    }

    /// Commits one received message and, only afterwards, hands any call
    /// control inside it to `callListener` (`SelfServiceClient.java:218-220`).
    public func received(message: [String: Any]) throws {
        try apply(["op": "receive_v2", "message": message])
    }

    /// Commits the server's acceptance of `envelope`, after checking that the
    /// answer is about that envelope and carries a real sequence
    /// (`SelfServiceClient.java:205-210`).
    ///
    /// - Throws: `SelfServiceError.invalidAcceptance` when the identifiers
    ///   disagree or the sequence is below 1.
    public func accepted(envelope: [String: Any], response: [String: Any]) throws {
        try healthy()
        guard let id = envelope["id"] as? String,
              response["id"] as? String == id,
              let sequence = (response["sequence"] as? NSNumber)?.int64Value,
              sequence >= 1
        else { throw SelfServiceError.invalidAcceptance }
        try apply(["op": "accepted_v2", "id": id])
        acceptedListener?(id)
    }

    // MARK: - proofs (core calls, never requests)

    /// Signs one request against a challenge the caller fetched, and returns
    /// the `Authorization` header value (`SelfServiceClient.java:198-200`).
    ///
    /// Nothing is committed: a proof is derived from the state, it does not
    /// change it.
    public func requestProof(challenge: [String: Any],
                             method: String,
                             path: String,
                             body: String) throws -> String {
        let reply = try nativeCall(["op": "sign_request_v2", "challenge": challenge,
                                    "method": method, "path": path, "body": body])
        guard let authorization = reply.object["authorization"] as? String else {
            throw SelfServiceError.malformedReply("authorization")
        }
        return authorization
    }

    /// Signs one realtime session operation
    /// (`SelfServiceClient.java:201-204`).
    public func sessionRequest(session: [String: Any],
                               operation: String,
                               id: String? = nil) throws -> [String: Any] {
        var request: [String: Any] = ["op": "sign_session_v2", "session": session, "operation": operation]
        if let id { request["id"] = id }
        return try nativeCall(request).object
    }

    // MARK: - reading the state

    /// The outbox, oldest first (`SelfServiceClient.java:211`).
    public func pending() throws -> [[String: Any]] {
        try healthy()
        guard let outbox = try view().object["outbox"] as? [[String: Any]] else {
            throw SelfServiceError.malformedReply("outbox")
        }
        return outbox
    }

    /// The highest sequence this device has accepted
    /// (`SelfServiceClient.java:212`).
    public func receiveCursor() throws -> Int64 {
        try healthy()
        guard let cursor = (try view().object["cursor"] as? NSNumber)?.int64Value else {
            throw SelfServiceError.malformedReply("cursor")
        }
        return cursor
    }

    /// The contact of this device, verbatim, once `prepare_contact_v2` has
    /// run; `nil` before that.
    ///
    /// The text is sliced out of the reply rather than re-encoded, because it
    /// is what a QR code and a paste carry and what the peer's core verifies.
    public func contactText() throws -> String? {
        try healthy()
        let reply = try view()
        // `null` before `prepare_contact_v2` has run; an object afterwards.
        guard reply.object["contact"] is [String: Any] else { return nil }
        guard let text = JsonSpan.value(of: "contact", in: reply.text) else {
            throw SelfServiceError.malformedReply("contact")
        }
        return text
    }

    /// Everything a screen may see: no private key, no state text
    /// (`SelfServiceClient.java:155-168`).
    public func publicView() throws -> [String: Any] {
        try healthy()
        var safe: [String: Any] = ["identity": false, "active": false,
                                   "configured": !state.isEmpty, "dialogs": [[String: Any]]()]
        guard !state.isEmpty else { return safe }
        let reply = try view().object
        let request = reply["request"] as? [String: Any]
        safe["identity"] = request != nil
        safe["active"] = try active()
        // A missing member is `JSONObject.NULL` on Android; here it is
        // `NSNull`, so that a screen sees the same three-valued answer.
        safe["request"] = request.map { $0 as Any } ?? NSNull()
        safe["account"] = (request?["credential"] as? [String: Any])?["account"] as? String ?? ""
        safe["contact"] = (reply["contact"] as? [String: Any]).map { $0 as Any } ?? NSNull()
        safe["contact_fingerprint"] = reply["contact_fingerprint"] as? String ?? ""
        safe["dialogs"] = reply["dialogs"] as? [[String: Any]] ?? []
        safe["rejected_count"] = (reply["rejected_count"] as? NSNumber)?.int64Value ?? 0
        return safe
    }

    // MARK: - the core, the candidate and the commit

    private func healthy() throws {
        if isBroken { throw SelfServiceError.frozen }
    }

    private func nativeCall(_ request: [String: Any]) throws -> CoreReply {
        try healthy()
        return try CoreBridge.command(state: state, request: Self.encode(request))
    }

    private func view() throws -> CoreReply {
        try nativeCall(["op": "view"])
    }

    /// The realm the core state itself was created for
    /// (`SelfServiceClient.java:44`).
    private func coreRealm() throws -> String {
        guard let realm = (try view().object["public"] as? [String: Any])?["realm"] as? String else {
            throw SelfServiceError.malformedReply("public.realm")
        }
        return realm
    }

    /// Runs `upgrade_v2` on a schema-0 state and keeps nothing.
    ///
    /// Any failure at all — a rejected operation, a candidate that is not
    /// schema 3 — is `unsupportedSnapshot`, exactly as
    /// `SelfServiceClient.java:36-42`: the retained data is left alone and the
    /// user is told to install cleanly.
    private func dryRunUpgrade() throws {
        let candidate: CoreReply
        do {
            candidate = try CoreBridge.command(state: state, request: Self.encode(["op": "upgrade_v2"]))
        } catch {
            throw SelfServiceError.unsupportedSnapshot
        }
        guard candidate.stateVersion == Snapshot.cleanStateVersion else {
            throw SelfServiceError.unsupportedSnapshot
        }
    }

    private func active() throws -> Bool {
        guard !state.isEmpty, stateVersion == Snapshot.cleanStateVersion else { return false }
        guard let enrollment = try view().object["enrollment"] as? [String: Any] else { return false }
        return enrollment["mode"] as? String == "active"
    }

    /// One state transition, in the only order that is safe.
    ///
    /// The candidate is checked, then committed, then adopted. Between the
    /// commit and the adoption there is nothing that can fail silently: a
    /// throwing `save` sets `isBroken` and the in-memory state stays on the
    /// last durable snapshot, so a caller that ignores the error still cannot
    /// send anything derived from the candidate — every later call refuses.
    ///
    /// A `receive_v2` reply must carry an authenticated disposition; without
    /// one the candidate is dropped before it is written
    /// (`SelfServiceClient.java:69-72`). The call control inside an accepted
    /// candidate is delivered only after the commit, because a control the
    /// device has acted on but not stored would come back a second time.
    private func apply(_ request: [String: Any]) throws {
        let op = request["op"] as? String ?? ""
        let candidate = try nativeCall(request)
        var acceptance = ""
        if op == "receive_v2" {
            acceptance = candidate.object["acceptance"] as? String ?? ""
            guard ["accepted", "exact_duplicate", "rejected"].contains(acceptance) else {
                throw SelfServiceError.missingAcceptance
            }
        }
        guard let next = candidate.state, let version = candidate.stateVersion else {
            throw SelfServiceError.malformedReply("state")
        }
        guard version == Snapshot.legacyStateVersion || version == Snapshot.cleanStateVersion else {
            throw SelfServiceError.unsupportedSnapshot
        }
        // An operation that changed nothing writes nothing, and therefore also
        // announces nothing (`SelfServiceClient.java:75`).
        guard next != state else { return }
        let wrapper = Snapshot(trust: trust, token: token, state: next, stateVersion: version)
        do {
            try sink.save(wrapper.text)
        } catch {
            isBroken = true
            throw SelfServiceError.commitFailed
        }
        state = next
        stateVersion = version
        if op == "receive_v2", acceptance == "accepted",
           let event = candidate.object["call_event"] as? [String: Any] {
            try callListener?(event)
        }
    }

    /// `null` and "not there" are the same answer (`JSONObject.isNull`).
    private func isAbsent(_ value: Any?) -> Bool {
        value == nil || value is NSNull
    }

    private static func encode(_ request: [String: Any]) throws -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let text = String(data: data, encoding: .utf8)
        else { throw SelfServiceError.invalidRequest }
        return text
    }
}
