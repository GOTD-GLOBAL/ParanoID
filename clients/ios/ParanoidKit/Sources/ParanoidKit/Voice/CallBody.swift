import CryptoKit
import Foundation

/// One call control, the fifteen members of a call-v2 body.
///
/// The wire contract is [voice-v1](../../../../../../docs/protocol/voice-v1.md)
/// with the [call-v2 deltas](../../../../../../docs/protocol/call-v2.md), and
/// the authority on it is the core validator
/// (`clients/core/src/voice_v1.rs:20-100`), which every control passes on the
/// way out (`send_call_v1`) and on the way in (`receive_v2` before the
/// `call_event` reaches the client). The Java counterpart is
/// `CallController.valid(JSONObject)`
/// (`clients/android/src/org/paranoid/text/CallController.java:322-346`).
///
/// This type exists because the core is deliberately clock-free and the
/// platform is not: a control the core accepts may still be stale or dated in
/// the future, and refusing those is the receiving client's job
/// (`voice-v1.md:116-118`: "Receiver accepts no control dated more than 5
/// seconds in the future. A clock change outside that tolerance ends the
/// negotiation/call."). So the checks come in three named steps rather than
/// one:
///
/// - ``decode(_:)`` — the document: exactly the fifteen members, each of its
///   own JSON type, `video` a real boolean and the four numbers real integers.
/// - ``validate()`` — the kind table: sequence, nonces, offer digest, reason,
///   camera flag and the SDP envelope, all of it clock-free, exactly what
///   `CallV1::validate` checks.
/// - ``check(wallMillis:)`` — the two wall-clock rules the core cannot make.
///
/// ``accept(_:wallMillis:)`` runs all three, and that is what the receive path
/// uses. A body that fails any of them is dropped: an invalid control can
/// never move a state machine, open a microphone or a camera, or answer a
/// peer.
///
/// ## What is deliberately not here
///
/// The structure of an SDP — two sections in the order audio then video, one
/// `a=sendrecv` each, one `opus/48000/2`, at least one `h264/90000` or
/// `vp8/90000`, at most sixteen candidates — is measured by ``SdpExtract`` on
/// the way out and by the core on both sides. This type checks only the
/// envelope the body itself carries: the length, that the text is ASCII, and
/// that the fingerprint and the two ICE members are well formed, because those
/// three are repeated members that the core cross-checks against the SDP text.
///
/// A body is never logged. The SDP, the ICE password and the two nonces are
/// call secrets, which is why there is no `description` here that would print
/// them by accident.
public struct CallBody: Equatable, Sendable {
    // MARK: - The vocabulary

    /// The seven controls of call-v2 (`voice_v1.rs:55-71`).
    ///
    /// `media` is the call-v2 addition (`call-v2.md:27`): an informative
    /// camera-on/off announcement at `seq >= 2` with both nonces and the exact
    /// offer digest. It never grants, changes or revokes media authority —
    /// "the receiving UI shows what the peer *claims*; actual frames come only
    /// from the authenticated DTLS-SRTP transport" (`call-v2.md:30-32`).
    public enum Kind: String, CaseIterable, Sendable {
        case knock, ready, offer, answer, heartbeat, media, end
    }

    /// The seven reasons an `end` may carry, and the only strings the `reason`
    /// member may ever hold (`voice_v1.rs:76-79`).
    public enum EndReason: String, CaseIterable, Sendable {
        case hangup, reject, cancel, busy, timeout, failed, unavailable
    }

    /// Why a body was refused.
    ///
    /// The core answers `invalid_call`, `invalid_call_sdp` or
    /// `call_sdp_mismatch` for the whole of this; these cases are finer so a
    /// test can say *which* rule refused a vector rather than only that
    /// something did. What must agree with the core is the verdict, never the
    /// label.
    public enum Rejection: String, Error, Equatable, Sendable {
        /// Not one JSON object of exactly the fifteen members, or a member of
        /// the wrong JSON type — `video` that is not a boolean, a number that
        /// is not an integer, a string where a number belongs, `null`.
        case malformed
        /// `v` is not 2. A v1 body is refused here: "There is no mixed v1/v2
        /// call" (`call-v2.md:17-18`).
        case version
        /// `kind` is not one of the seven.
        case kind
        /// `call_id` is not a canonical UUIDv4, or a nonce that must be
        /// present is not 64 lowercase hexadecimal digits.
        case identity
        /// `seq` is outside `0 ... 2147483647`.
        case sequence
        /// `sent_ms`/`expires_ms` are not a positive window of at most 45 000
        /// milliseconds.
        case window
        /// The kind table: the sequence, the nonces, the offer digest or the
        /// members that must be empty for this kind.
        case context
        /// `reason` is set on a control that carries none, or an `end` whose
        /// reason is not one of the seven.
        case reason
        /// `video` is true on a `heartbeat` or an `end` (`call-v2.md:25`).
        case video
        /// The SDP envelope: empty, over the limit, not ASCII, or a
        /// fingerprint or ICE member that is not well formed. Also an `offer`
        /// whose `offer_digest` is not the SHA-256 of its own SDP, which the
        /// core answers `call_sdp_mismatch` for.
        case sdp
        /// The receiver's clock is at or past `expires_ms`
        /// (`CallController.java:328`).
        case expired
        /// `sent_ms` is more than five seconds ahead of the receiver's clock
        /// (`voice-v1.md:116-117`).
        case future
    }

    // MARK: - The constants of the contract

    /// The integer `v` carries. A v1 body is not a call this client can hold.
    public static let version = 2
    /// The largest `expires_ms - sent_ms` (`voice_v1.rs:50`).
    public static let ttlMillis: Int64 = 45_000
    /// How far ahead of the receiver's clock a control may be dated
    /// (`voice-v1.md:116-117`).
    public static let futureSkewMillis: Int64 = 5_000
    /// `MAX_SDP` (`voice_v1.rs:10`): the largest SDP a body may carry at all.
    ///
    /// It is the receiving bound. Nothing generated here comes close: the
    /// control travels inside one frame2 envelope whose measured ceiling is
    /// about ten kilobytes, so a description this client sends is capped at
    /// ``SdpExtract/maxSdpBytes`` instead.
    public static let maxSdpBytes = 12_288
    /// `seq` is a signed 32-bit integer on the wire (`voice_v1.rs:47`).
    public static let maxSequence = Int64(Int32.max)
    /// The fifteen member names, in the order the documents list them
    /// (`voice-v1.md:41-53`, `call-v2.md:25`). A body with any other member
    /// set is not a call body.
    public static let fields = [
        "v", "kind", "call_id", "caller_nonce", "callee_nonce", "seq", "sent_ms", "expires_ms",
        "sdp", "fingerprint", "ice_ufrag", "ice_pwd", "offer_digest", "reason", "video",
    ]

    // MARK: - The fifteen members

    /// `v`, kept as it arrived so that a v1 body is refused with ``Rejection/version``
    /// rather than failing to decode at all.
    public let version: Int
    public let kind: Kind
    public let callId: String
    public let callerNonce: String
    public let calleeNonce: String
    public let seq: Int64
    public let sentMillis: Int64
    public let expiresMillis: Int64
    public let sdp: String
    public let fingerprint: String
    public let iceUfrag: String
    public let icePwd: String
    public let offerDigest: String
    /// Empty except on an `end`; ``endReason`` reads it as the enumeration.
    public let reason: String
    /// `knock`/`ready`/`offer`/`answer`: this sender can negotiate a camera
    /// section, which this client always can. `media`: the sender's current
    /// camera state. `heartbeat`/`end`: false (`call-v2.md:25`).
    public let video: Bool

    /// The reason of an `end`, or `nil` for every other kind.
    public var endReason: EndReason? { kind == .end ? EndReason(rawValue: reason) : nil }

    /// The identity members this control repeats.
    public var identity: CallIdentity {
        CallIdentity(callId: callId, callerNonce: callerNonce,
                     calleeNonce: calleeNonce, offerDigest: offerDigest)
    }

    /// Builds a body member by member.
    ///
    /// Nothing is checked here: a test needs to be able to build the bodies
    /// the table refuses. The factories below are the way a control this
    /// client sends is built, and ``validate()`` is what says whether a body
    /// is one the core would take.
    public init(version: Int = CallBody.version,
                kind: Kind,
                callId: String,
                callerNonce: String,
                calleeNonce: String = "",
                seq: Int64,
                sentMillis: Int64,
                expiresMillis: Int64,
                sdp: String = "",
                fingerprint: String = "",
                iceUfrag: String = "",
                icePwd: String = "",
                offerDigest: String = "",
                reason: String = "",
                video: Bool) {
        self.version = version
        self.kind = kind
        self.callId = callId
        self.callerNonce = callerNonce
        self.calleeNonce = calleeNonce
        self.seq = seq
        self.sentMillis = sentMillis
        self.expiresMillis = expiresMillis
        self.sdp = sdp
        self.fingerprint = fingerprint
        self.iceUfrag = iceUfrag
        self.icePwd = icePwd
        self.offerDigest = offerDigest
        self.reason = reason
        self.video = video
    }

    // MARK: - The controls this client sends

    /// `knock`: the caller's explicit call action, seq 0, no callee nonce and
    /// no offer digest (`voice_v1.rs:56-58`).
    ///
    /// `video` is true because this client can always negotiate a camera
    /// section; it is a capability, not an intent, and it opens no camera
    /// anywhere (`call-v2.md:25,60-62`).
    public static func knock(_ identity: CallIdentity, sentMillis: Int64) -> CallBody {
        CallBody(kind: .knock, callId: identity.callId, callerNonce: identity.callerNonce,
                 seq: 0, sentMillis: sentMillis, expiresMillis: expiry(after: sentMillis),
                 video: true)
    }

    /// `ready`: the receiver's readiness slot answered, seq 0, its fresh
    /// callee nonce, still no offer digest and no media of any kind
    /// (`voice_v1.rs:59`, `voice-v1.md:85-87`).
    public static func ready(_ identity: CallIdentity, sentMillis: Int64) -> CallBody {
        CallBody(kind: .ready, callId: identity.callId, callerNonce: identity.callerNonce,
                 calleeNonce: identity.calleeNonce, seq: 0, sentMillis: sentMillis,
                 expiresMillis: expiry(after: sentMillis), video: true)
    }

    /// `offer`: seq 1, both nonces and the SHA-256 of this exact SDP
    /// (`voice_v1.rs:60-62`). There is no renegotiation, so an offer exists
    /// only at seq 1 and only once per call (`call-v2.md:56-58`).
    public static func offer(_ identity: CallIdentity,
                             description: CallDescription,
                             sentMillis: Int64) -> CallBody {
        CallBody(kind: .offer, callId: identity.callId, callerNonce: identity.callerNonce,
                 calleeNonce: identity.calleeNonce, seq: 1, sentMillis: sentMillis,
                 expiresMillis: expiry(after: sentMillis), sdp: description.sdp,
                 fingerprint: description.fingerprint, iceUfrag: description.iceUfrag,
                 icePwd: description.icePwd, offerDigest: digest(of: description.sdp),
                 video: true)
    }

    /// `answer`: seq 1, both nonces and the digest of the **caller's** offer,
    /// which the callee carries over from the offer it accepted.
    public static func answer(_ identity: CallIdentity,
                              description: CallDescription,
                              sentMillis: Int64) -> CallBody {
        CallBody(kind: .answer, callId: identity.callId, callerNonce: identity.callerNonce,
                 calleeNonce: identity.calleeNonce, seq: 1, sentMillis: sentMillis,
                 expiresMillis: expiry(after: sentMillis), sdp: description.sdp,
                 fingerprint: description.fingerprint, iceUfrag: description.iceUfrag,
                 icePwd: description.icePwd, offerDigest: identity.offerDigest, video: true)
    }

    /// `heartbeat`: seq at least 2, both nonces, the offer digest, no camera
    /// flag (`voice_v1.rs:63-65,84-86`).
    public static func heartbeat(_ identity: CallIdentity,
                                 seq: Int64,
                                 sentMillis: Int64) -> CallBody {
        CallBody(kind: .heartbeat, callId: identity.callId, callerNonce: identity.callerNonce,
                 calleeNonce: identity.calleeNonce, seq: seq, sentMillis: sentMillis,
                 expiresMillis: expiry(after: sentMillis), offerDigest: identity.offerDigest,
                 video: false)
    }

    /// `media`: the same context as a heartbeat, carrying this sender's
    /// current camera state (`call-v2.md:27`).
    public static func media(_ identity: CallIdentity,
                             seq: Int64,
                             cameraOn: Bool,
                             sentMillis: Int64) -> CallBody {
        CallBody(kind: .media, callId: identity.callId, callerNonce: identity.callerNonce,
                 calleeNonce: identity.calleeNonce, seq: seq, sentMillis: sentMillis,
                 expiresMillis: expiry(after: sentMillis), offerDigest: identity.offerDigest,
                 video: cameraOn)
    }

    /// `end`: seq at least 2 with one of the seven reasons.
    ///
    /// An end before `ready` carries neither nonce nor digest; after `ready`
    /// but before an offer it carries the callee nonce and an empty digest;
    /// after the offer it carries both. The identity handed in is what decides
    /// which of the three this is, and `validate()` refuses the one shape that
    /// cannot occur — a digest without a callee nonce (`voice_v1.rs:66-72`).
    public static func end(_ identity: CallIdentity,
                           seq: Int64,
                           reason: EndReason,
                           sentMillis: Int64) -> CallBody {
        CallBody(kind: .end, callId: identity.callId, callerNonce: identity.callerNonce,
                 calleeNonce: identity.calleeNonce, seq: seq, sentMillis: sentMillis,
                 expiresMillis: expiry(after: sentMillis), offerDigest: identity.offerDigest,
                 reason: reason.rawValue, video: false)
    }

    /// `sent_ms + 45 000`, saturating rather than wrapping: a wrapped window
    /// would read as a control that never expires. A saturated one is refused
    /// by ``validate()`` like any other impossible window.
    private static func expiry(after sentMillis: Int64) -> Int64 {
        let (sum, overflow) = sentMillis.addingReportingOverflow(ttlMillis)
        return overflow ? .max : sum
    }

    // MARK: - The clock-free table

    /// Whether this body is one the core would accept (`voice_v1.rs:41-100`).
    ///
    /// - Throws: the ``Rejection`` naming the first rule it fails.
    public func validate() throws(Rejection) {
        guard version == Self.version else { throw .version }
        guard Self.isCanonicalCallId(callId), Self.isHex32(callerNonce) else { throw .identity }
        guard (0...Self.maxSequence).contains(seq) else { throw .sequence }
        guard sentMillis > 0, expiresMillis > sentMillis,
              expiresMillis - sentMillis <= Self.ttlMillis
        else { throw .window }

        let context: Bool
        switch kind {
        case .knock:
            context = seq == 0 && calleeNonce.isEmpty && offerDigest.isEmpty
        case .ready:
            context = seq == 0 && Self.isHex32(calleeNonce) && offerDigest.isEmpty
        case .offer, .answer:
            context = seq == 1 && Self.isHex32(calleeNonce) && Self.isHex32(offerDigest)
        case .heartbeat, .media:
            context = seq >= 2 && Self.isHex32(calleeNonce) && Self.isHex32(offerDigest)
        case .end:
            // A pre-ready end carries neither nonce nor digest, a post-ready
            // one the nonce alone, a post-offer one both; a digest without a
            // nonce is the shape that cannot exist.
            context = seq >= 2
                && (calleeNonce.isEmpty || Self.isHex32(calleeNonce))
                && (offerDigest.isEmpty || Self.isHex32(offerDigest))
                && (!calleeNonce.isEmpty || offerDigest.isEmpty)
        }
        guard context else { throw .context }

        if kind == .end {
            guard endReason != nil else { throw .reason }
        } else {
            guard reason.isEmpty else { throw .reason }
        }
        if kind == .heartbeat || kind == .end {
            guard !video else { throw .video }
        }

        if kind == .offer || kind == .answer {
            guard !sdp.isEmpty, sdp.utf8.count <= Self.maxSdpBytes, sdp.utf8.allSatisfy({ $0 < 128 }),
                  Self.isHex32(fingerprint),
                  Self.isIceToken(iceUfrag, minimum: 4), Self.isIceToken(icePwd, minimum: 22)
            else { throw .sdp }
            // Only the offer binds its own SDP; an answer carries the
            // caller's digest, which is the call context and not its own text
            // (`voice_v1.rs:95-97`).
            if kind == .offer, offerDigest != Self.digest(of: sdp) { throw .sdp }
        } else {
            guard sdp.isEmpty, fingerprint.isEmpty, iceUfrag.isEmpty, icePwd.isEmpty
            else { throw .context }
        }
    }

    // MARK: - The two rules the core cannot make

    /// The freshness of a received control against this device's wall clock.
    ///
    /// The core holds no clock at all, so a control that is long expired or
    /// dated in the future passes it untouched; both are refused here, before
    /// the control can reach a state machine
    /// (`voice-v1.md:116-118`, `CallController.java:327-328`). "First-seen
    /// expired controls are rejected as well; wall-clock jumps terminate
    /// active negotiations rather than extend consent" (`voice-v1.md:92-93`).
    ///
    /// - Parameter wallMillis: UTC milliseconds as this device reads them.
    public func check(wallMillis: Int64) throws(Rejection) {
        guard wallMillis < expiresMillis else { throw .expired }
        guard sentMillis - wallMillis <= Self.futureSkewMillis else { throw .future }
    }

    // MARK: - Reading one off the wire

    /// The document alone: exactly the fifteen members, each of its own JSON
    /// type (`CallController.java:322-326`).
    ///
    /// `video` must be a real boolean — `1` and `"true"` are refused, which is
    /// what `call-v2.md:23` means by "non-boolean `video` is rejected" — and
    /// the four numbers must be written as integers: the verbatim token is
    /// read back out of the text, so `2.0`, `2e1` and a quoted `"2"` are all
    /// refused, as they are by the core's `serde` derivation and by
    /// `org.json` on the Java side.
    ///
    /// Duplicate members are not reachable here and are therefore not
    /// detected: a received body is re-serialised by the core from its own
    /// validated struct (`clean_service.rs:157-161`), and `serde` refuses a
    /// duplicate member long before that.
    ///
    /// - Throws: ``Rejection/malformed``, ``Rejection/kind`` for an unknown
    ///   `kind`.
    public static func decode(_ json: String) throws(Rejection) -> CallBody {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: Data(json.utf8))
        } catch let rejection as Rejection {
            throw rejection
        } catch {
            throw .malformed
        }
        // The decoder would take `2.0` and `2e1` for an integer; the core and
        // `org.json` would not, so the number is re-read as it was written.
        for field in ["v", "seq", "sent_ms", "expires_ms"] {
            guard let token = JsonSpan.value(of: field, in: json), isIntegerToken(token) else {
                throw .malformed
            }
        }
        guard let kind = Kind(rawValue: wire.kind) else { throw .kind }
        return CallBody(version: wire.v, kind: kind, callId: wire.callId,
                        callerNonce: wire.callerNonce, calleeNonce: wire.calleeNonce,
                        seq: wire.seq, sentMillis: wire.sentMillis,
                        expiresMillis: wire.expiresMillis, sdp: wire.sdp,
                        fingerprint: wire.fingerprint, iceUfrag: wire.iceUfrag,
                        icePwd: wire.icePwd, offerDigest: wire.offerDigest,
                        reason: wire.reason, video: wire.video)
    }

    /// One received control: the document, the table and the clock, in that
    /// order. This is the only entry the receive path uses.
    public static func accept(_ json: String, wallMillis: Int64) throws(Rejection) -> CallBody {
        let body = try decode(json)
        try body.validate()
        try body.check(wallMillis: wallMillis)
        return body
    }

    // MARK: - Writing one

    /// The body as the members of a JSON object, ready to be placed in the
    /// core's `send_call_v1` request.
    ///
    /// It carries the SDP, the ICE password and both nonces: it is call
    /// material, never a thing to log.
    public var members: [String: Any] {
        [
            "v": version, "kind": kind.rawValue, "call_id": callId,
            "caller_nonce": callerNonce, "callee_nonce": calleeNonce, "seq": seq,
            "sent_ms": sentMillis, "expires_ms": expiresMillis, "sdp": sdp,
            "fingerprint": fingerprint, "ice_ufrag": iceUfrag, "ice_pwd": icePwd,
            "offer_digest": offerDigest, "reason": reason, "video": video,
        ]
    }

    /// The body as one JSON object text, members sorted.
    ///
    /// - Throws: ``Rejection/malformed`` if the members cannot be serialised,
    ///   which they always can.
    public func encoded() throws(Rejection) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: members,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { throw .malformed }
        return text
    }

    // MARK: - The shapes the members must have

    /// Lowercase hexadecimal SHA-256, the form every digest and nonce member
    /// takes (`paranoid_key_protocol::digest`, `key-protocol/src/lib.rs:22-27`).
    public static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 64 lowercase hexadecimal digits (`hex32`, `key-protocol/src/lib.rs:106-110`).
    public static func isHex32(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    /// A canonical lowercase UUIDv4, `8-4-4-4-12` with the version nibble `4`
    /// and an RFC 4122 variant nibble.
    ///
    /// The core takes any string its UUID parser round-trips at version 4
    /// (`intro_v2.rs:7-9`), which does not look at the variant nibble; this is
    /// the Java form (`CallController.java:329`), which does. Both accept
    /// every identifier either client generates, and the stricter one is the
    /// safe direction: this client refuses a call identifier it would never
    /// mint itself.
    public static func isCanonicalCallId(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5,
              groups.map(\.count) == [8, 4, 4, 4, 12],
              groups.allSatisfy({ $0.utf8.allSatisfy(isLowerHexDigit) })
        else { return false }
        return groups[2].first == "4" && "89ab".contains(groups[3].first ?? " ")
    }

    /// An RFC 5245 ICE token of a bounded length: `minimum ... 256` characters
    /// of `[A-Za-z0-9+/]` (`voice_v1.rs:262-267`).
    public static func isIceToken(_ value: String, minimum: Int) -> Bool {
        (minimum...256).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "/")
        }
    }

    private static func isLowerHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }

    /// A JSON number written as a non-negative integer, with no sign, no
    /// fraction, no exponent and no leading zero. Every number of a call body
    /// is one of those.
    private static func isIntegerToken(_ token: String) -> Bool {
        let digits = Array(token.utf8)
        guard (1...19).contains(digits.count),
              digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return false }
        return digits.count == 1 || digits[0] != UInt8(ascii: "0")
    }

    // MARK: - The decoded document

    /// The fifteen members as JSON types, before anything is read into them.
    ///
    /// The keyed container is dynamic so that `allKeys` holds every member the
    /// document actually has: with a fixed `CodingKeys` enumeration an unknown
    /// member is invisible, and "unknown … fields are rejected"
    /// (`voice-v1.md:39`) would not be checkable at all.
    private struct Wire: Decodable {
        let v: Int
        let kind: String
        let callId: String
        let callerNonce: String
        let calleeNonce: String
        let seq: Int64
        let sentMillis: Int64
        let expiresMillis: Int64
        let sdp: String
        let fingerprint: String
        let iceUfrag: String
        let icePwd: String
        let offerDigest: String
        let reason: String
        let video: Bool

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(_ name: String) { stringValue = name }
            init?(stringValue: String) { self.init(stringValue) }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let members = try decoder.container(keyedBy: Key.self)
            guard Set(members.allKeys.map(\.stringValue)) == Set(CallBody.fields),
                  members.allKeys.count == CallBody.fields.count
            else { throw Rejection.malformed }
            v = try members.decode(Int.self, forKey: Key("v"))
            kind = try members.decode(String.self, forKey: Key("kind"))
            callId = try members.decode(String.self, forKey: Key("call_id"))
            callerNonce = try members.decode(String.self, forKey: Key("caller_nonce"))
            calleeNonce = try members.decode(String.self, forKey: Key("callee_nonce"))
            seq = try members.decode(Int64.self, forKey: Key("seq"))
            sentMillis = try members.decode(Int64.self, forKey: Key("sent_ms"))
            expiresMillis = try members.decode(Int64.self, forKey: Key("expires_ms"))
            sdp = try members.decode(String.self, forKey: Key("sdp"))
            fingerprint = try members.decode(String.self, forKey: Key("fingerprint"))
            iceUfrag = try members.decode(String.self, forKey: Key("ice_ufrag"))
            icePwd = try members.decode(String.self, forKey: Key("ice_pwd"))
            offerDigest = try members.decode(String.self, forKey: Key("offer_digest"))
            reason = try members.decode(String.self, forKey: Key("reason"))
            video = try members.decode(Bool.self, forKey: Key("video"))
        }
    }
}

/// The identity members every control of one call repeats.
///
/// It is the Java `Slot` without the account and the deadline
/// (`CallController.java:53-59`): the call identifier, the caller's nonce, the
/// callee's nonce once a readiness slot has minted one, and the offer digest
/// once an offer exists. A control is bound to its call by all four together —
/// "Answer must match call ID/nonces and exact offer digest"
/// (`voice-v1.md:106`).
public struct CallIdentity: Equatable, Sendable {
    public let callId: String
    public let callerNonce: String
    /// Empty until the receiver's readiness slot mints it, then echoed by
    /// every later control of the call.
    public var calleeNonce: String
    /// Empty until an offer exists, then the SHA-256 of that exact offer SDP.
    public var offerDigest: String

    public init(callId: String, callerNonce: String, calleeNonce: String = "", offerDigest: String = "") {
        self.callId = callId
        self.callerNonce = callerNonce
        self.calleeNonce = calleeNonce
        self.offerDigest = offerDigest
    }
}

/// One local session description and the three members a call body repeats
/// beside it.
///
/// The core cross-checks all three against the SDP text
/// (`voice_v1.rs:167-188`), so they are read out of the description itself by
/// ``SdpExtract`` rather than gathered from the media engine separately. The
/// SDP is never rewritten on the way out: whatever the engine produced is what
/// travels, and anything the core would refuse is fixed through the engine's
/// configuration instead.
public struct CallDescription: Equatable, Sendable {
    public let sdp: String
    public let fingerprint: String
    public let iceUfrag: String
    public let icePwd: String

    public init(sdp: String, fingerprint: String, iceUfrag: String, icePwd: String) {
        self.sdp = sdp
        self.fingerprint = fingerprint
        self.iceUfrag = iceUfrag
        self.icePwd = icePwd
    }

    /// Reads the fingerprint and the ICE credentials out of one gathered
    /// description, or returns `nil` for one this client must not send.
    ///
    /// Two things make a description unsendable: a shape the core would refuse
    /// (``SdpExtract`` returns `nil` — no `v=0`, a transport attribute in two
    /// places with two values, an `a=fingerprint` that is not a 32-byte
    /// SHA-256) and a size the control frame cannot carry. The core's own
    /// limit is 12 288 bytes, but a call control travels inside one frame2
    /// envelope whose measured ceiling is 10 040 bytes, so the description is
    /// held to ``SdpExtract/maxSdpBytes`` — 9 000 — with room to spare. A
    /// description above that is a configuration bug on this side and is never
    /// handed to the core.
    public init?(sdp: String) {
        guard let extract = SdpExtract(sdp: sdp), extract.fitsFrameBudget else { return nil }
        self.init(sdp: sdp, fingerprint: extract.fingerprint,
                  iceUfrag: extract.iceUfrag, icePwd: extract.icePwd)
    }
}
