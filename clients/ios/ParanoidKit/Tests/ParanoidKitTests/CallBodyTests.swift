import Foundation
import ParanoidKit
import XCTest

/// The call-v2 body and the controller that mints and accepts one.
///
/// Two things are checked here, and they are the same subject from two sides:
/// every row of the kind table (`clients/core/src/voice_v1.rs:41-100`,
/// `docs/protocol/voice-v1.md:39-53`, `docs/protocol/call-v2.md:21-27`) is
/// accepted or refused as the core would, and the controller that produces
/// those controls walks `idle -> starting -> authorizing -> outgoing/incoming
/// -> connecting -> connected -> ended` over fake ports without ever opening a
/// microphone or a camera on its own.
///
/// The two wall-clock rules have no counterpart in the core at all — it is
/// clock-free — so the only place they can be checked is here
/// (`voice-v1.md:116-118`).
final class CallBodyTests: XCTestCase {
    // MARK: - Fixture

    /// A canonical lowercase UUIDv4, the only shape `call_id` may take.
    static let callId = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
    static let callerNonce = String(repeating: "a", count: 64)
    static let calleeNonce = String(repeating: "b", count: 64)
    /// One fixed wall clock for every body below; `sent_ms` equals it, so the
    /// control is neither stale nor dated in the future.
    static let wall: Int64 = 1_800_000_000_000

    static let fingerprintBytes = (0..<32).map { String(format: "%02X", $0) }
    static let fingerprint = fingerprintBytes.joined().lowercased()
    static let ufrag = "abcd1234"
    static let password = "abcdefghijklmnopqrstuvwx"

    /// A call-v2 description: the two sections in the order audio then video,
    /// one `a=sendrecv` each, the transport attributes carried once by the
    /// audio section. Its exact structure is `SdpExtractTests`' subject; what
    /// matters here is that a real description is what the body carries.
    static let sdp = ([
        "v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0", "a=group:BUNDLE 0 1",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111", "c=IN IP4 0.0.0.0", "a=mid:0",
        "a=ice-ufrag:\(ufrag)", "a=ice-pwd:\(password)",
        "a=fingerprint:sha-256 " + fingerprintBytes.joined(separator: ":"), "a=setup:actpass",
        "a=sendrecv", "a=rtcp-mux", "a=rtpmap:111 opus/48000/2",
        "a=candidate:1 1 udp 2122260223 127.0.0.1 40000 typ host",
        "m=video 9 UDP/TLS/RTP/SAVPF 96 98", "c=IN IP4 0.0.0.0", "a=mid:1",
        "a=sendrecv", "a=rtcp-mux", "a=rtpmap:96 H264/90000", "a=rtpmap:98 VP8/90000",
    ] as [String]).joined(separator: "\r\n") + "\r\n"

    /// The same description as an answer would carry it: one `a=setup` value
    /// of its own, and therefore a different text and a different digest.
    static let answerSdp = sdp.replacingOccurrences(of: "a=setup:actpass", with: "a=setup:active")

    static var description: CallDescription {
        guard let description = CallDescription(sdp: sdp) else {
            preconditionFailure("the fixture description is the one this client sends")
        }
        return description
    }

    /// The identity as it stands after an offer: both nonces and the digest.
    static var identity: CallIdentity {
        CallIdentity(callId: callId, callerNonce: callerNonce, calleeNonce: calleeNonce,
                     offerDigest: CallBody.digest(of: sdp))
    }

    // MARK: - Helpers

    /// The members of `body` with `change` applied, as one JSON object text.
    private func text(_ body: CallBody, _ change: (inout [String: Any]) -> Void = { _ in }) -> String {
        var members = body.members
        change(&members)
        guard let data = try? JSONSerialization.data(withJSONObject: members, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            preconditionFailure("the members of a call body are always JSON")
        }
        return text
    }

    /// Asserts that the receive path takes this document.
    @discardableResult
    private func accepted(_ json: String,
                          wallMillis: Int64 = CallBodyTests.wall,
                          _ message: String,
                          file: StaticString = #filePath,
                          line: UInt = #line) -> CallBody? {
        do {
            return try CallBody.accept(json, wallMillis: wallMillis)
        } catch {
            XCTFail("\(message): refused as \(error.rawValue)", file: file, line: line)
            return nil
        }
    }

    /// Asserts that the receive path refuses this document, and for the stated
    /// reason: "refused" and "refused by the rule that should have refused it"
    /// are different claims, and only the second one keeps a hole visible.
    private func refused(_ json: String,
                         _ expected: CallBody.Rejection,
                         wallMillis: Int64 = CallBodyTests.wall,
                         _ message: String,
                         file: StaticString = #filePath,
                         line: UInt = #line) {
        do {
            _ = try CallBody.accept(json, wallMillis: wallMillis)
            XCTFail("\(message): accepted", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, message, file: file, line: line)
        }
    }

    // MARK: - The controls this client sends

    func testEveryControlThisClientSendsIsOneTheCoreWouldTake() throws {
        let fresh = CallIdentity(callId: Self.callId, callerNonce: Self.callerNonce)
        let ready = CallIdentity(callId: Self.callId, callerNonce: Self.callerNonce,
                                 calleeNonce: Self.calleeNonce)
        let bodies: [(String, CallBody)] = [
            ("knock", .knock(fresh, sentMillis: Self.wall)),
            ("ready", .ready(ready, sentMillis: Self.wall)),
            ("offer", .offer(ready, description: Self.description, sentMillis: Self.wall)),
            ("answer", .answer(Self.identity, description: Self.description, sentMillis: Self.wall)),
            ("heartbeat", .heartbeat(Self.identity, seq: 2, sentMillis: Self.wall)),
            ("media on", .media(Self.identity, seq: 3, cameraOn: true, sentMillis: Self.wall)),
            ("media off", .media(Self.identity, seq: 4, cameraOn: false, sentMillis: Self.wall)),
            ("end before ready", .end(fresh, seq: 2, reason: .cancel, sentMillis: Self.wall)),
            ("end after ready", .end(ready, seq: 2, reason: .hangup, sentMillis: Self.wall)),
            ("end after offer", .end(Self.identity, seq: 5, reason: .busy, sentMillis: Self.wall)),
        ]
        for (name, body) in bodies {
            XCTAssertNoThrow(try body.validate(), "\(name) must pass the table")
            XCTAssertEqual(body.version, 2, "\(name) is a v2 control")
            XCTAssertEqual(body.expiresMillis - body.sentMillis, 45_000,
                           "\(name) expires 45 s after it was sent")
            XCTAssertEqual(Set(body.members.keys), Set(CallBody.fields),
                           "\(name) carries exactly the fifteen members")
            // The document this client writes is one it would also accept.
            let decoded = accepted(text(body), "\(name) round trips")
            XCTAssertEqual(decoded, body, "\(name) survives the wire unchanged")
        }
    }

    func testTheCameraFlagFollowsTheKindTable() throws {
        let ready = CallIdentity(callId: Self.callId, callerNonce: Self.callerNonce,
                                 calleeNonce: Self.calleeNonce)
        // knock/ready/offer/answer: this client can always negotiate a camera
        // section, which is a capability and not an intent (`call-v2.md:25`).
        XCTAssertTrue(CallBody.knock(ready, sentMillis: Self.wall).video)
        XCTAssertTrue(CallBody.ready(ready, sentMillis: Self.wall).video)
        XCTAssertTrue(CallBody.offer(ready, description: Self.description, sentMillis: Self.wall).video)
        XCTAssertTrue(CallBody.answer(Self.identity, description: Self.description,
                                      sentMillis: Self.wall).video)
        // media: the sender's current camera state.
        XCTAssertTrue(CallBody.media(Self.identity, seq: 2, cameraOn: true, sentMillis: Self.wall).video)
        XCTAssertFalse(CallBody.media(Self.identity, seq: 2, cameraOn: false, sentMillis: Self.wall).video)
        // heartbeat/end: never.
        XCTAssertFalse(CallBody.heartbeat(Self.identity, seq: 2, sentMillis: Self.wall).video)
        XCTAssertFalse(CallBody.end(Self.identity, seq: 2, reason: .hangup, sentMillis: Self.wall).video)
    }

    func testAnOfferBindsItsOwnSdpAndAnAnswerCarriesTheCallersDigest() throws {
        let ready = CallIdentity(callId: Self.callId, callerNonce: Self.callerNonce,
                                 calleeNonce: Self.calleeNonce)
        let offer = CallBody.offer(ready, description: Self.description, sentMillis: Self.wall)
        XCTAssertEqual(offer.offerDigest, CallBody.digest(of: Self.sdp),
                       "the offer digest is the SHA-256 of this exact SDP")
        // The answer's own SDP is a different text; its digest member still
        // names the caller's offer (`voice_v1.rs:95-97`).
        let answerSdp = Self.sdp.replacingOccurrences(of: "a=setup:actpass", with: "a=setup:active")
        let answer = CallBody.answer(Self.identity,
                                     description: CallDescription(sdp: answerSdp)!,
                                     sentMillis: Self.wall)
        XCTAssertEqual(answer.offerDigest, offer.offerDigest)
        XCTAssertNotEqual(CallBody.digest(of: answerSdp), answer.offerDigest)
        XCTAssertNoThrow(try answer.validate())
        refused(text(offer) { $0["offer_digest"] = CallBody.digest(of: "other") }, .sdp,
                "an offer whose digest is not its own SDP")
    }

    // MARK: - The document: fifteen members, each of its own type

    func testTheDocumentMustCarryExactlyTheFifteenMembers() throws {
        let body = CallBody.heartbeat(Self.identity, seq: 2, sentMillis: Self.wall)
        accepted(text(body), "the canonical heartbeat")
        for field in CallBody.fields {
            refused(text(body) { $0.removeValue(forKey: field) }, .malformed, "missing \(field)")
        }
        refused(text(body) { $0["extra"] = 1 }, .malformed, "an unknown member")
        refused(text(body) { $0["video"] = NSNull() }, .malformed, "a null member")
        refused("[]", .malformed, "an array is not a body")
        refused("{", .malformed, "a truncated document")
        refused(text(body) + " trailing", .malformed, "trailing text after the object")
    }

    func testVideoMustBeARealBooleanAndTheNumbersRealIntegers() throws {
        let body = CallBody.media(Self.identity, seq: 2, cameraOn: true, sentMillis: Self.wall)
        accepted(text(body), "the canonical media control")
        refused(text(body) { $0["video"] = "true" }, .malformed, "video as a string")
        refused(text(body) { $0["video"] = 1 }, .malformed, "video as a number")
        refused(text(body) { $0["seq"] = "2" }, .malformed, "seq as a string")
        // JSON's number grammar allows `2.0` and `2e1`; the core's `serde`
        // derivation and `org.json` both refuse them for an integer member,
        // and the verbatim token check here refuses them too.
        for field in ["v", "seq", "sent_ms", "expires_ms"] {
            let document = text(body).replacingOccurrences(
                of: "\"\(field)\":\(body.members[field]!)",
                with: "\"\(field)\":\(body.members[field]!).0")
            XCTAssertNotEqual(document, text(body), "the \(field) token was rewritten")
            refused(document, .malformed, "\(field) written as a decimal")
        }
        refused(text(body).replacingOccurrences(of: "\"seq\":2", with: "\"seq\":2e0"),
                .malformed, "seq written in exponent form")
    }

    func testAnUnknownKindAndAV1BodyAreRefused() throws {
        let body = CallBody.knock(CallIdentity(callId: Self.callId, callerNonce: Self.callerNonce),
                                  sentMillis: Self.wall)
        refused(text(body) { $0["kind"] = "hello" }, .kind, "an unknown kind")
        refused(text(body) { $0["kind"] = "" }, .kind, "an empty kind")
        refused(text(body) { $0["v"] = 1 }, .version, "a v1 body")
        refused(text(body) { $0["v"] = 3 }, .version, "a v3 body")
    }

    // MARK: - The kind table, row by row

    func testKnockCarriesNoCalleeNonceNoDigestAndSequenceZero() throws {
        let knock = CallBody.knock(CallIdentity(callId: Self.callId, callerNonce: Self.callerNonce),
                                   sentMillis: Self.wall)
        accepted(text(knock), "the canonical knock")
        refused(text(knock) { $0["seq"] = 1 }, .context, "a knock at seq 1")
        refused(text(knock) { $0["callee_nonce"] = Self.calleeNonce }, .context,
                "a knock that already knows a callee nonce")
        refused(text(knock) { $0["offer_digest"] = CallBody.digest(of: Self.sdp) }, .context,
                "a knock with an offer digest")
        refused(text(knock) { $0["reason"] = "hangup" }, .reason, "a knock with a reason")
        refused(text(knock) { $0["sdp"] = Self.sdp }, .context, "a knock with an SDP")
        refused(text(knock) { $0["fingerprint"] = Self.fingerprint }, .context,
                "a knock with a fingerprint")
        refused(text(knock) { $0["ice_ufrag"] = Self.ufrag }, .context, "a knock with an ICE ufrag")
        refused(text(knock) { $0["ice_pwd"] = Self.password }, .context, "a knock with an ICE password")
        refused(text(knock) { $0["call_id"] = "not-a-uuid" }, .identity, "a knock with no call identifier")
        refused(text(knock) { $0["call_id"] = Self.callId.uppercased() }, .identity,
                "a call identifier that is not canonical")
        refused(text(knock) { $0["caller_nonce"] = String(repeating: "a", count: 63) }, .identity,
                "a short caller nonce")
        refused(text(knock) { $0["caller_nonce"] = String(repeating: "A", count: 64) }, .identity,
                "an uppercase caller nonce")
    }

    func testReadyCarriesTheCalleeNonceAndStillNoDigest() throws {
        let ready = CallBody.ready(CallIdentity(callId: Self.callId, callerNonce: Self.callerNonce,
                                                calleeNonce: Self.calleeNonce),
                                   sentMillis: Self.wall)
        accepted(text(ready), "the canonical ready")
        refused(text(ready) { $0["callee_nonce"] = "" }, .context, "a ready without its own nonce")
        refused(text(ready) { $0["seq"] = 2 }, .context, "a ready at seq 2")
        refused(text(ready) { $0["offer_digest"] = CallBody.digest(of: Self.sdp) }, .context,
                "a ready with an offer digest")
        refused(text(ready) { $0["sdp"] = Self.sdp }, .context, "a ready with an SDP")
    }

    func testOfferAndAnswerLiveOnlyAtSequenceOneWithBothNoncesAndADigest() throws {
        let ready = CallIdentity(callId: Self.callId, callerNonce: Self.callerNonce,
                                 calleeNonce: Self.calleeNonce)
        let offer = CallBody.offer(ready, description: Self.description, sentMillis: Self.wall)
        let answer = CallBody.answer(Self.identity, description: Self.description, sentMillis: Self.wall)
        accepted(text(offer), "the canonical offer")
        accepted(text(answer), "the canonical answer")
        for (name, body) in [("offer", offer), ("answer", answer)] {
            // There is no renegotiation and no ICE restart inside a call: a
            // description exists at seq 1 or not at all (`call-v2.md:56-58`).
            refused(text(body) { $0["seq"] = 0 }, .context, "a \(name) at seq 0")
            refused(text(body) { $0["seq"] = 2 }, .context, "a \(name) at seq 2")
            refused(text(body) { $0["callee_nonce"] = "" }, .context, "a \(name) without a callee nonce")
            refused(text(body) { $0["offer_digest"] = "" }, .context, "a \(name) without a digest")
            refused(text(body) { $0["reason"] = "hangup" }, .reason, "a \(name) with a reason")
            refused(text(body) { $0["sdp"] = "" }, .sdp, "a \(name) without an SDP")
            refused(text(body) { $0["fingerprint"] = "" }, .sdp, "a \(name) without a fingerprint")
            refused(text(body) { $0["fingerprint"] = Self.fingerprint.uppercased() }, .sdp,
                    "a \(name) whose fingerprint is not the canonical form")
            refused(text(body) { $0["ice_ufrag"] = "abc" }, .sdp, "a \(name) whose ICE ufrag is too short")
            refused(text(body) { $0["ice_pwd"] = String(repeating: "p", count: 21) }, .sdp,
                    "a \(name) whose ICE password is too short")
            refused(text(body) { $0["ice_pwd"] = String(repeating: "p", count: 257) }, .sdp,
                    "a \(name) whose ICE password is too long")
            refused(text(body) { $0["ice_ufrag"] = "abcd 234" }, .sdp,
                    "a \(name) whose ICE ufrag is not an ICE token")
            refused(text(body) { $0["sdp"] = String(repeating: "x", count: 12_289) }, .sdp,
                    "a \(name) over the 12288-byte SDP limit")
            // The core reads the description byte by byte and refuses one that
            // is not ASCII (`voice_v1.rs:108`).
            refused(text(body) { $0["sdp"] = "v=0\r\na=x:\u{00e9}\r\n" }, .sdp,
                    "a \(name) whose SDP is not ASCII")
        }
    }

    func testHeartbeatAndMediaLiveFromSequenceTwoWithTheFullContext() throws {
        let heartbeat = CallBody.heartbeat(Self.identity, seq: 2, sentMillis: Self.wall)
        let media = CallBody.media(Self.identity, seq: 7, cameraOn: true, sentMillis: Self.wall)
        accepted(text(heartbeat), "the canonical heartbeat")
        accepted(text(media), "the canonical media control")
        for (name, body) in [("heartbeat", heartbeat), ("media", media)] {
            refused(text(body) { $0["seq"] = 1 }, .context, "a \(name) at seq 1")
            refused(text(body) { $0["callee_nonce"] = "" }, .context, "a \(name) without a callee nonce")
            refused(text(body) { $0["offer_digest"] = "" }, .context, "a \(name) without a digest")
            refused(text(body) { $0["reason"] = "timeout" }, .reason, "a \(name) with a reason")
            refused(text(body) { $0["sdp"] = Self.sdp }, .context, "a \(name) carrying an SDP")
        }
        // A forged camera flag on a heartbeat is refused outright; the camera
        // state travels in a `media` control or nowhere (`call-v2.md:25`).
        refused(text(heartbeat) { $0["video"] = true }, .video, "a heartbeat that claims a camera")
        accepted(text(media) { $0["video"] = false }, "a media control may announce the camera off")
        refused(text(body: media, seq: CallBody.maxSequence + 1), .sequence,
                "a sequence above the signed 32-bit range")
        accepted(text(body: media, seq: CallBody.maxSequence), "the largest sequence")
    }

    func testEndCarriesOneOfTheSevenReasonsAndGrowsItsContextWithTheCall() throws {
        let fresh = CallIdentity(callId: Self.callId, callerNonce: Self.callerNonce)
        let ready = CallIdentity(callId: Self.callId, callerNonce: Self.callerNonce,
                                 calleeNonce: Self.calleeNonce)
        let before = CallBody.end(fresh, seq: 2, reason: .cancel, sentMillis: Self.wall)
        let afterReady = CallBody.end(ready, seq: 2, reason: .hangup, sentMillis: Self.wall)
        let afterOffer = CallBody.end(Self.identity, seq: 3, reason: .busy, sentMillis: Self.wall)
        accepted(text(before), "an end before ready")
        accepted(text(afterReady), "an end after ready and before the offer")
        accepted(text(afterOffer), "an end after the offer")
        for reason in CallBody.EndReason.allCases {
            accepted(text(afterOffer) { $0["reason"] = reason.rawValue }, "an end that says \(reason)")
        }
        refused(text(afterOffer) { $0["reason"] = "" }, .reason, "an end with no reason")
        refused(text(afterOffer) { $0["reason"] = "goodbye" }, .reason, "an end with an invented reason")
        refused(text(afterOffer) { $0["video"] = true }, .video, "an end that claims a camera")
        refused(text(afterOffer) { $0["seq"] = 1 }, .context, "an end at seq 1")
        // The one shape that cannot exist: a digest without the nonce that
        // must have come first (`voice_v1.rs:66-72`).
        refused(text(afterOffer) { $0["callee_nonce"] = "" }, .context,
                "an end that carries a digest but no callee nonce")
        refused(text(afterOffer) { $0["sdp"] = Self.sdp }, .context, "an end carrying an SDP")
    }

    // MARK: - The window and the receiver's clock

    func testTheWindowIsPositiveAndAtMostFortyFiveSeconds() throws {
        let body = CallBody.heartbeat(Self.identity, seq: 2, sentMillis: Self.wall)
        refused(text(body) { $0["expires_ms"] = Self.wall }, .window,
                "a control that expires when it was sent")
        refused(text(body) { $0["expires_ms"] = Self.wall - 1 }, .window,
                "a control that expired before it was sent")
        refused(text(body) { $0["expires_ms"] = Self.wall + 45_001 }, .window,
                "a window longer than 45 s")
        accepted(text(body) { $0["expires_ms"] = Self.wall + 45_000 }, "the longest window")
        accepted(text(body) { $0["expires_ms"] = Self.wall + 1 }, "the shortest window")
        refused(text(body) { $0["sent_ms"] = 0; $0["expires_ms"] = 45_000 }, .window,
                wallMillis: 1, "a control sent at time zero")
    }

    func testTheReceiverRefusesExpiredAndFutureControls() throws {
        let body = CallBody.heartbeat(Self.identity, seq: 2, sentMillis: Self.wall)
        let expires = Self.wall + 45_000
        accepted(text(body), wallMillis: expires - 1, "a control that expires in a millisecond")
        refused(text(body), .expired, wallMillis: expires, "a control at its expiry")
        refused(text(body), .expired, wallMillis: expires + 1, "a control past its expiry")
        // A control dated ahead of this device by more than five seconds is
        // refused however valid it is (`voice-v1.md:116-117`).
        accepted(text(body), wallMillis: Self.wall - 5_000, "a control five seconds in the future")
        refused(text(body), .future, wallMillis: Self.wall - 5_001,
                "a control more than five seconds in the future")
        // Both rules are the receiver's alone: the body itself is one the core
        // takes without a word.
        XCTAssertNoThrow(try CallBody.decode(text(body)).validate(),
                         "the core is clock-free and accepts all three of those")
    }

    // MARK: - The description this client is willing to send

    func testADescriptionOverTheFrameBudgetIsNeverBuilt() throws {
        // The core's own limit is 12288 bytes, but a control travels inside
        // one frame2 envelope whose measured ceiling is 10040 bytes, so a
        // description this client sends is held to 9000.
        XCTAssertEqual(SdpExtract.maxSdpBytes, 9_000)
        XCTAssertLessThan(SdpExtract.maxSdpBytes, CallBody.maxSdpBytes)
        let padding = String(repeating: "a=candidate:1 1 udp 1 127.0.0.1 40000 typ host\r\n", count: 8)
        let large = Self.sdp + padding + "a=x:" + String(repeating: "y", count: 9_000) + "\r\n"
        XCTAssertGreaterThan(large.utf8.count, SdpExtract.maxSdpBytes)
        XCTAssertLessThan(large.utf8.count, CallBody.maxSdpBytes)
        XCTAssertNil(CallDescription(sdp: large), "a description over the frame budget is not sent")
        XCTAssertNil(CallDescription(sdp: "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"),
                     "a description the core would refuse is not sent")
        XCTAssertNotNil(CallDescription(sdp: Self.sdp))
    }

    /// One body with `seq` replaced by a number that no factory would mint.
    private func text(body: CallBody, seq: Int64) -> String {
        text(body) { $0["seq"] = seq }
    }

    // MARK: - The state machine over fake ports

    func testTheCallerWalksFromIntentToConnectedAndNeitherSideCapturesEarly() throws {
        let pair = CallPair()
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        XCTAssertEqual(pair.alice.currentState, .starting)
        let knock = try XCTUnwrap(pair.alicePorts.take())
        XCTAssertEqual(knock.body.kind, .knock)
        XCTAssertEqual(knock.body.seq, 0)
        XCTAssertEqual(pair.alicePorts.offers, 0, "a knock cannot create media")

        pair.deliver(to: pair.bob, from: CallPair.alice, knock)
        XCTAssertEqual(pair.bobPorts.offers + pair.bobPorts.answers, 0,
                       "an incoming knock cannot create media")
        let ready = try XCTUnwrap(pair.bobPorts.take())
        XCTAssertEqual(ready.body.kind, .ready)
        XCTAssertEqual(ready.body.seq, 0)
        XCTAssertTrue(CallBody.isHex32(ready.body.calleeNonce), "the slot minted a fresh nonce")

        pair.deliver(to: pair.alice, from: CallPair.bob, ready)
        XCTAssertEqual(pair.alicePorts.offers, 1, "ready permits only the explicit caller's media")
        XCTAssertEqual(pair.alice.currentState, .outgoing, "authorization moved the caller on")
        pair.alice.localDescription(pair.alice.generation, sdp: Self.sdp)
        let offer = try XCTUnwrap(pair.alicePorts.take())
        XCTAssertEqual(offer.body.kind, .offer)
        XCTAssertEqual(offer.body.seq, 1)
        XCTAssertEqual(offer.body.offerDigest, CallBody.digest(of: Self.sdp))

        pair.deliver(to: pair.bob, from: CallPair.alice, offer)
        XCTAssertEqual(pair.bob.currentState, .incoming, "a matching fresh offer rings")
        XCTAssertEqual(pair.bobPorts.answers, 0, "an incoming ring never captures")
        pair.alice.mediaState(pair.alice.generation, .connected)
        XCTAssertEqual(pair.alice.currentState, .outgoing,
                       "no engine may report a connection before the answer is known")

        pair.bob.answer(microphonePermission: true)
        XCTAssertEqual(pair.bobPorts.answers, 1, "only an explicit Answer creates the callee's media")
        XCTAssertEqual(pair.bob.currentState, .connecting)
        pair.bob.mediaState(pair.bob.generation, .connected)
        XCTAssertEqual(pair.bob.currentState, .connecting,
                       "and the callee not before its own answer has been sent")
        pair.bob.localDescription(pair.bob.generation, sdp: Self.answerSdp)
        let answer = try XCTUnwrap(pair.bobPorts.take())
        XCTAssertEqual(answer.body.kind, .answer)
        XCTAssertEqual(answer.body.seq, 1)
        XCTAssertEqual(answer.body.offerDigest, offer.body.offerDigest,
                       "the answer names the caller's offer")

        pair.deliver(to: pair.alice, from: CallPair.bob, answer)
        XCTAssertEqual(pair.alicePorts.remoteAnswers, 1)
        XCTAssertEqual(pair.alice.currentState, .connecting,
                       "signaling alone is not a connection")
        pair.alice.mediaState(pair.alice.generation, .connected)
        pair.bob.mediaState(pair.bob.generation, .connected)
        XCTAssertEqual(pair.alice.currentState, .connected, "the engine is what says connected")
        XCTAssertEqual(pair.bob.currentState, .connected)
        XCTAssertTrue(pair.alice.presentation.mediaActive)

        pair.alice.hangup()
        let end = try XCTUnwrap(pair.alicePorts.take())
        XCTAssertEqual(end.body.kind, .end)
        XCTAssertEqual(end.body.endReason, .hangup)
        XCTAssertEqual(end.body.seq, 2)
        XCTAssertEqual(pair.alice.currentState, .ended)
        XCTAssertFalse(pair.alice.isActive)
        XCTAssertGreaterThan(pair.alicePorts.closes, 0, "a local end disposes the media")
        pair.deliver(to: pair.bob, from: CallPair.alice, end)
        XCTAssertFalse(pair.bob.isActive, "the authenticated end ends the peer's call too")
        XCTAssertGreaterThan(pair.bobPorts.closes, 0)
    }

    func testEveryControlTheControllerSendsIsOneTheCoreWouldTake() throws {
        let pair = CallPair()
        pair.connect()
        pair.alice.video(true)
        pair.alice.hangup()
        let sent = pair.alicePorts.everySent + pair.bobPorts.everySent
        XCTAssertEqual(sent.map(\.body.kind), [.knock, .offer, .media, .end, .ready, .answer],
                       "one call is exactly these controls")
        for control in sent {
            XCTAssertNoThrow(try control.body.validate(), "\(control.body.kind) passes the table")
            XCTAssertNoThrow(try control.body.check(wallMillis: pair.time.wallMillis),
                             "\(control.body.kind) is fresh when it is sent")
        }
    }

    func testARefusedIntentSendsNothingAndCapturesNothing() throws {
        let denied = CallPair()
        denied.alice.start(account: CallPair.bob, microphonePermission: false)
        XCTAssertNil(denied.alicePorts.take(), "a denied microphone enqueues nothing")
        XCTAssertEqual(denied.alicePorts.offers, 0)
        XCTAssertEqual(denied.alice.currentState, .ended)
        XCTAssertEqual(denied.alice.presentation.reason, .reject)

        let offline = CallPair()
        offline.alice.connection(false)
        offline.alice.start(account: CallPair.bob, microphonePermission: true)
        XCTAssertNil(offline.alicePorts.take(), "an offline call does not enter the durable outbox")
        XCTAssertEqual(offline.alice.presentation.reason, .unavailable)

        let nonsense = CallPair()
        nonsense.alice.start(account: "not-an-account", microphonePermission: true)
        XCTAssertNil(nonsense.alicePorts.take())
        XCTAssertEqual(nonsense.alice.currentState, .ended)
    }

    func testDurableControlsAreNotGatedOnTheFlickeringOnlineFlag() throws {
        // The lane's flag flickers on every server-forced reconnect; a control
        // that is durable-outboxed and expires on its own must not be lost to
        // it (`docs/project/current-state.md:19-22`, issue #19).
        let pair = CallPair()
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        let knock = try XCTUnwrap(pair.alicePorts.take())
        pair.bob.connection(false)
        pair.deliver(to: pair.bob, from: CallPair.alice, knock)
        let ready = try XCTUnwrap(pair.bobPorts.take())
        XCTAssertEqual(ready.body.kind, .ready, "an authenticated knock is answered whatever the flag says")

        pair.alice.connection(false)
        pair.deliver(to: pair.alice, from: CallPair.bob, ready)
        XCTAssertEqual(pair.alice.currentState, .outgoing,
                       "a ready during a transient offline moment still advances the caller")

        // And the ring, and the terminal end, for the same reason.
        pair.alice.localDescription(pair.alice.generation, sdp: Self.sdp)
        let offer = try XCTUnwrap(pair.alicePorts.take())
        pair.deliver(to: pair.bob, from: CallPair.alice, offer)
        XCTAssertEqual(pair.bob.currentState, .incoming, "an authenticated offer rings while offline")
        pair.bob.reject()
        let end = try XCTUnwrap(pair.bobPorts.take())
        XCTAssertEqual(end.body.endReason, .reject, "the terminal end is enqueued while offline")

        // The one thing the flag does decide: the user's Answer, which needs a
        // live lane before anything may capture.
        let answering = CallPair()
        answering.ring()
        answering.bob.connection(false)
        answering.bob.answer(microphonePermission: true)
        XCTAssertEqual(answering.bobPorts.answers, 0, "an offline Answer captures nothing")
        XCTAssertEqual(answering.bob.currentState, .ended)
        XCTAssertEqual(answering.bob.presentation.reason, .unavailable)
    }

    func testAnIncomingCallRingsWithoutMediaAndARefusedAnswerCapturesNothing() throws {
        let pair = CallPair()
        pair.ring()
        XCTAssertEqual(pair.bob.currentState, .incoming)
        XCTAssertFalse(pair.bob.presentation.mediaActive)
        XCTAssertEqual(pair.bobPorts.videoCalls, 0, "an incoming ring never opens the camera")
        pair.bob.answer(microphonePermission: false)
        XCTAssertEqual(pair.bobPorts.answers, 0, "a denied Answer closes without capture")
        XCTAssertFalse(pair.bob.isActive)
        XCTAssertEqual(pair.bob.presentation.reason, .reject)
        let end = try XCTUnwrap(pair.bobPorts.take())
        XCTAssertEqual(end.body.endReason, .reject, "the caller is told, and told the truth")
    }

    func testASecondCallIsAnsweredWithADetachedBusyEnd() throws {
        let pair = CallPair()
        pair.connect()
        let third = String(repeating: "c", count: 64)
        let identity = CallIdentity(callId: UUID().uuidString.lowercased(),
                                    callerNonce: String(repeating: "d", count: 64))
        pair.deliver(to: pair.alice, from: third,
                     CallBody.knock(identity, sentMillis: pair.time.wallMillis))
        let busy = try XCTUnwrap(pair.alicePorts.take())
        XCTAssertEqual(busy.account, third)
        XCTAssertEqual(busy.body.kind, .end)
        XCTAssertEqual(busy.body.endReason, .busy)
        XCTAssertEqual(busy.body.seq, 2)
        XCTAssertEqual(busy.body.callId, identity.callId, "the busy names the call it refuses")
        XCTAssertTrue(busy.body.calleeNonce.isEmpty, "a pre-ready busy knows no callee nonce")
        XCTAssertNoThrow(try busy.body.validate())
        XCTAssertEqual(pair.alice.currentState, .connected, "the live call is untouched")
        XCTAssertEqual(pair.alicePorts.closes, 0)

        // The same for an offer that arrives once the slot's owner is busy:
        // the slot is consumed, the peer is told, and nothing rings.
        let busyOnOffer = CallPair()
        busyOnOffer.ready()
        let offerBody = CallBody.offer(
            CallIdentity(callId: busyOnOffer.callId(of: busyOnOffer.bob),
                         callerNonce: busyOnOffer.callerNonce(of: busyOnOffer.bob),
                         calleeNonce: busyOnOffer.calleeNonce(of: busyOnOffer.bob)),
            description: Self.description, sentMillis: busyOnOffer.time.wallMillis)
        busyOnOffer.bob.start(account: CallPair.alice, microphonePermission: true)
        _ = busyOnOffer.bobPorts.take()
        busyOnOffer.deliver(to: busyOnOffer.bob, from: CallPair.alice, offerBody)
        let refused = try XCTUnwrap(busyOnOffer.bobPorts.take())
        XCTAssertEqual(refused.body.kind, .end)
        XCTAssertEqual(refused.body.endReason, .busy)
        XCTAssertFalse(refused.body.calleeNonce.isEmpty, "a post-ready busy carries the slot's nonce")
        XCTAssertEqual(refused.body.offerDigest, offerBody.offerDigest)
        XCTAssertNoThrow(try refused.body.validate())
    }

    func testReadinessIsBoundedToEightSlotsAndOnePerPeer() throws {
        let pair = CallPair()
        for index in 0..<CallController.maximumReadiness {
            let peer = String(repeating: String(format: "%x", index), count: 64)
            pair.deliver(to: pair.bob, from: peer, pair.knockBody())
            XCTAssertNotNil(pair.bobPorts.take(), "peer \(index) gets a readiness slot")
        }
        let ninth = String(repeating: "9", count: 64)
        pair.deliver(to: pair.bob, from: ninth, pair.knockBody())
        XCTAssertNil(pair.bobPorts.take(), "the ninth peer is refused work, not answered")

        // One slot per peer: a second call identifier from a peer that already
        // holds one is not a second slot.
        let single = CallPair()
        single.deliver(to: single.bob, from: CallPair.alice, single.knockBody())
        XCTAssertNotNil(single.bobPorts.take())
        single.deliver(to: single.bob, from: CallPair.alice, single.knockBody())
        XCTAssertNil(single.bobPorts.take(), "one readiness slot per peer")
    }

    func testAWrongContextCannotRingAndACorrectOneStillCan() throws {
        let pair = CallPair()
        pair.ready()
        pair.alice.localDescription(pair.alice.generation, sdp: Self.sdp)
        let offer = try XCTUnwrap(pair.alicePorts.take())
        pair.deliver(to: pair.bob, from: CallPair.alice, offer) {
            $0["callee_nonce"] = String(repeating: "f", count: 64)
        }
        XCTAssertNotEqual(pair.bob.currentState, .incoming, "a wrong readiness nonce cannot ring")
        pair.deliver(to: pair.bob, from: CallPair.alice, offer) {
            $0["caller_nonce"] = String(repeating: "f", count: 64)
        }
        XCTAssertNotEqual(pair.bob.currentState, .incoming, "a wrong caller nonce cannot ring")
        pair.deliver(to: pair.bob, from: CallPair.alice, offer) { $0["sdp"] = Self.answerSdp }
        XCTAssertNotEqual(pair.bob.currentState, .incoming,
                          "an offer whose digest is not its SDP cannot ring")
        pair.deliver(to: pair.bob, from: CallPair.alice, offer)
        XCTAssertEqual(pair.bob.currentState, .incoming,
                       "an invalid event did not consume the legitimate slot")
        pair.deliver(to: pair.bob, from: CallPair.alice, offer)
        XCTAssertEqual(pair.bobPorts.answers, 0, "a duplicate offer cannot capture")
        XCTAssertEqual(pair.bob.currentState, .incoming, "a duplicate offer cannot reset the call")
    }

    func testAnAnswerIsBoundToTheOfferAndAppliedOnce() throws {
        let pair = CallPair()
        pair.ring()
        pair.bob.answer(microphonePermission: true)
        pair.bob.localDescription(pair.bob.generation, sdp: Self.answerSdp)
        let answer = try XCTUnwrap(pair.bobPorts.take())
        pair.deliver(to: pair.alice, from: CallPair.bob, answer) {
            $0["offer_digest"] = String(repeating: "f", count: 64)
        }
        XCTAssertEqual(pair.alicePorts.remoteAnswers, 0, "a wrong offer digest never enters the engine")
        pair.deliver(to: pair.alice, from: CallPair.bob, answer) {
            $0["caller_nonce"] = String(repeating: "f", count: 64)
        }
        XCTAssertEqual(pair.alicePorts.remoteAnswers, 0, "a wrong caller nonce never enters the engine")
        pair.deliver(to: pair.alice, from: CallPair.bob, answer)
        pair.deliver(to: pair.alice, from: CallPair.bob, answer)
        XCTAssertEqual(pair.alicePorts.remoteAnswers, 1, "the answer applies once")
        XCTAssertEqual(pair.alice.currentState, .connecting)
    }

    func testAnEndedCallNeverReopens() throws {
        let pair = CallPair()
        pair.ring()
        let offer = try XCTUnwrap(pair.bobPorts.lastReceivedOffer)
        pair.bob.reject()
        XCTAssertFalse(pair.bob.isActive)
        _ = pair.bobPorts.take()
        pair.deliver(to: pair.bob, from: CallPair.alice, offer)
        XCTAssertFalse(pair.bob.isActive, "a late offer cannot resurrect a rejected call")
        pair.deliver(to: pair.bob, from: CallPair.alice, pair.knockBody(callId: offer.body.callId))
        XCTAssertNil(pair.bobPorts.take(), "a retried knock of an ended call is not answered")
    }

    func testStaleGenerationCallbacksCannotMoveAnything() throws {
        let pair = CallPair()
        pair.connect()
        let stale = pair.alice.generation
        pair.alice.hangup()
        _ = pair.alicePorts.take()
        pair.alice.localDescription(stale, sdp: Self.sdp)
        pair.alice.mediaState(stale, .connected)
        XCTAssertFalse(pair.alice.mediaAuthorized(stale, authorized: true))
        pair.alice.mediaReady(stale)
        pair.alice.videoUnavailable(stale)
        XCTAssertFalse(pair.alice.isActive, "stale callbacks cannot recreate a call")
        XCTAssertNil(pair.alicePorts.take(), "stale callbacks cannot sign anything")

        // A new intent has a fresh generation, and the old one still reaches
        // nothing.
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        XCTAssertNotEqual(pair.alice.generation, stale)
        XCTAssertTrue(pair.alice.isActive)
        pair.alice.mediaState(stale, .failed)
        XCTAssertTrue(pair.alice.isActive, "an old media failure cannot end a new call")
    }

    func testTheCameraTravelsAsAMediaControlAndOpensNothingOnThePeer() throws {
        let pair = CallPair()
        pair.connect()
        XCTAssertNil(pair.alicePorts.take(), "no media control before anyone turns a camera on")
        XCTAssertEqual(pair.alicePorts.videoCalls, 0, "media authority alone never opens the camera")

        pair.alice.speaker(false)
        pair.alice.video(true)
        XCTAssertTrue(pair.alicePorts.video)
        XCTAssertTrue(pair.alicePorts.speaker, "camera on routes audio to the speakerphone")
        XCTAssertTrue(pair.alice.presentation.localVideo)
        let on = try XCTUnwrap(pair.alicePorts.take())
        XCTAssertEqual(on.body.kind, .media)
        XCTAssertTrue(on.body.video)
        XCTAssertGreaterThanOrEqual(on.body.seq, 2)
        XCTAssertNoThrow(try on.body.validate())

        pair.deliver(to: pair.bob, from: CallPair.alice, on)
        XCTAssertTrue(pair.bob.presentation.remoteVideo, "the peer learns the claim")
        XCTAssertEqual(pair.bobPorts.videoCalls, 0, "and opens no camera of its own")
        pair.deliver(to: pair.bob, from: CallPair.alice, on)
        XCTAssertTrue(pair.bob.presentation.remoteVideo, "a replayed media control is idempotent")

        pair.alice.video(false)
        XCTAssertFalse(pair.alicePorts.video)
        XCTAssertFalse(pair.alicePorts.speaker, "camera off restores the previous route")
        let off = try XCTUnwrap(pair.alicePorts.take())
        XCTAssertEqual(off.body.kind, .media)
        XCTAssertFalse(off.body.video)
        pair.deliver(to: pair.bob, from: CallPair.alice, off)
        XCTAssertFalse(pair.bob.presentation.remoteVideo, "the peer sees the camera go off")
        pair.deliver(to: pair.bob, from: CallPair.alice, on)
        XCTAssertFalse(pair.bob.presentation.remoteVideo,
                       "a lower-sequence replay of camera-on is ignored")
        XCTAssertTrue(pair.bob.isActive, "and none of it ended the call")
    }

    func testAVideoCallIntentWaitsForMediaAuthorityAndACameraFailureKeepsTheCall() throws {
        let intent = CallPair()
        intent.alice.start(account: CallPair.bob, microphonePermission: true, videoIntent: true)
        XCTAssertEqual(intent.alicePorts.videoCalls, 0, "a video intent waits for media authority")
        let knock = try XCTUnwrap(intent.alicePorts.take())
        intent.deliver(to: intent.bob, from: CallPair.alice, knock)
        intent.deliver(to: intent.alice, from: CallPair.bob, try XCTUnwrap(intent.bobPorts.take()))
        XCTAssertTrue(intent.alicePorts.video, "the camera opens only after ready and authorization")
        XCTAssertTrue(intent.alice.presentation.localVideo)
        XCTAssertNil(intent.alicePorts.take(),
                     "and its announcement waits until there is an answer to announce it after")

        let failing = CallPair()
        failing.connect()
        failing.alice.video(true)
        _ = failing.alicePorts.take()
        failing.alice.videoUnavailable(failing.alice.generation)
        XCTAssertFalse(failing.alicePorts.video, "a camera failure stops capture")
        XCTAssertFalse(failing.alice.presentation.localVideo)
        XCTAssertFalse(failing.alicePorts.speaker, "and restores the route")
        let announced = try XCTUnwrap(failing.alicePorts.take())
        XCTAssertEqual(announced.body.kind, .media)
        XCTAssertFalse(announced.body.video)
        XCTAssertTrue(failing.alice.isActive, "a camera failure never ends the call")
    }

    func testAPreReadyCancelReleasesTheSlotButNeverARingingCall() throws {
        let pair = CallPair()
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        pair.deliver(to: pair.bob, from: CallPair.alice, try XCTUnwrap(pair.alicePorts.take()))
        XCTAssertNotNil(pair.bobPorts.take(), "the readiness slot exists")
        pair.alice.hangup()
        let cancel = try XCTUnwrap(pair.alicePorts.take())
        XCTAssertEqual(cancel.body.endReason, .cancel)
        XCTAssertTrue(cancel.body.calleeNonce.isEmpty, "the caller cannot know an undelivered nonce")
        pair.deliver(to: pair.bob, from: CallPair.alice, cancel)

        // The slot is gone, so the same peer may knock again at once.
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        pair.deliver(to: pair.bob, from: CallPair.alice, try XCTUnwrap(pair.alicePorts.take()))
        XCTAssertNotNil(pair.bobPorts.take(), "a released slot is immediately reusable")

        // An empty-nonce end never reaches a ringing call: that context is
        // strict, and only the exact end terminates it.
        let ringing = CallPair()
        ringing.ring()
        ringing.alice.hangup()
        let exact = try XCTUnwrap(ringing.alicePorts.take())
        ringing.deliver(to: ringing.bob, from: CallPair.alice, exact) {
            $0["callee_nonce"] = ""
            $0["offer_digest"] = ""
        }
        XCTAssertTrue(ringing.bob.isActive, "an empty pre-ready end cannot terminate a ringing call")
        XCTAssertEqual(ringing.bob.currentState, .incoming)
        ringing.deliver(to: ringing.bob, from: CallPair.alice, exact)
        XCTAssertFalse(ringing.bob.isActive, "the exact ringing end still terminates")
    }

    func testAFailedDurableEnqueueGrantsNoMediaAuthority() throws {
        let pair = CallPair()
        pair.alicePorts.failSave = true
        pair.alice.start(account: CallPair.bob, microphonePermission: true)
        XCTAssertFalse(pair.alice.isActive, "a failed enqueue terminates locally")
        XCTAssertEqual(pair.alicePorts.offers, 0)
        XCTAssertEqual(pair.alice.presentation.reason, .failed)

        // The same once media exists: the offer that cannot be enqueued takes
        // the call with it.
        let ringing = CallPair()
        ringing.ready()
        ringing.alicePorts.failSave = true
        ringing.alice.localDescription(ringing.alice.generation, sdp: Self.sdp)
        XCTAssertFalse(ringing.alice.isActive)
        XCTAssertGreaterThan(ringing.alicePorts.closes, 0, "and the created media is disposed")
    }

    func testADescriptionTheCoreWouldRefuseEndsTheCallInsteadOfTravelling() throws {
        let pair = CallPair()
        pair.ready()
        pair.alice.localDescription(pair.alice.generation,
                                    sdp: String(repeating: "x", count: 9_001))
        XCTAssertFalse(pair.alice.isActive, "a description this client cannot send ends the call")
        XCTAssertGreaterThan(pair.alicePorts.closes, 0)
        let end = try XCTUnwrap(pair.alicePorts.take())
        XCTAssertEqual(end.body.endReason, .failed)
        XCTAssertNil(pair.alicePorts.take(), "and no SDP ever left this device")
    }

    func testLosingLocalAuthorityStopsEverythingWithoutTellingThePeer() throws {
        let revoked = CallPair()
        revoked.connect()
        revoked.alice.authorizationLost()
        XCTAssertFalse(revoked.alice.isActive)
        XCTAssertGreaterThan(revoked.alicePorts.closes, 0)
        XCTAssertNil(revoked.alicePorts.take(),
                     "a device that lost its authority does not sign a farewell")
        XCTAssertEqual(revoked.alice.presentation.reason, .unavailable)

        let blocked = CallPair()
        blocked.connect()
        blocked.bob.block(account: CallPair.alice)
        XCTAssertFalse(blocked.bob.isActive, "blocking a peer stops its call")
        XCTAssertGreaterThan(blocked.bobPorts.closes, 0)
    }
}

// MARK: - The fixtures the state machine runs on

/// The two clocks a call is measured on, moved by hand.
///
/// `@unchecked Sendable`: the controller and the test run on the same thread,
/// and the closures a `CallClock` stores have to be `@Sendable` because the
/// real clock is a global constant.
final class CallTestClock: @unchecked Sendable {
    /// The same instant every body in this file is dated at.
    private(set) var wallMillis: Int64 = CallBodyTests.wall
    private var monotonicNanoseconds: UInt64 = 10 * 1_000_000_000

    var clock: CallClock {
        CallClock(monotonic: MonotonicClock { self.monotonicNanoseconds },
                  wall: { self.wallMillis })
    }

    /// Moves both clocks together, the way time normally passes.
    func advance(millis: Int64) {
        wallMillis += millis
        monotonicNanoseconds += UInt64(millis) * 1_000_000
    }

    /// Moves the wall clock alone — the user, a time server or a broken RTC.
    /// The monotonic reading stays where it was, which is exactly the
    /// divergence `checkClock` exists to catch.
    func moveWall(millis: Int64) {
        wallMillis += millis
    }
}

/// A state owner that says yes: the test is the owner's thread.
final class CallTestOwner: CallOwner {
    let isOnOwner = true
}

/// One control as it was handed to the durable outbox.
struct CallTestSent {
    let account: String
    let body: CallBody
}

/// What the core answers once the peer's outbox already holds sixteen call
/// envelopes (`clean_service.rs:398`).
enum CallOutboxFull: Error {
    case callOutboxFull
}

/// The three ports of one side, and the record of everything they were asked
/// to do. It is `CallControllerSmoke.Port`
/// (`clients/android/test/CallControllerSmoke.java:24-45`).
final class CallTestPorts: CallController.SendPort, CallController.MediaPort, CallController.Observer {
    private var pending: [CallTestSent] = []
    /// Everything ever enqueued, including what has already been taken.
    private(set) var everySent: [CallTestSent] = []
    private(set) var offers = 0
    private(set) var answers = 0
    private(set) var remoteAnswers = 0
    private(set) var closes = 0
    private(set) var videoCalls = 0
    private(set) var muted = false
    private(set) var speaker = false
    private(set) var video = false
    /// The last offer this side was handed, for the replay checks.
    var lastReceivedOffer: CallTestSent?
    /// The durable outbox refuses everything: neither the local commit nor the
    /// server acceptance happened.
    var failSave = false
    /// The relay lane does not answer by itself, so the test decides when
    /// media authority arrives.
    var deferMedia = false
    /// No completion runs by itself: the test holds them and decides, one by
    /// one, when the server answered. It is
    /// `CallControllerSmoke.Port.deferSignals`.
    var deferSignals = false
    /// The completions this port is holding, oldest first.
    private(set) var deferred: [(Bool) -> Void] = []
    /// The server never answers a heartbeat, so the one outstanding heartbeat
    /// stays outstanding (`CallControllerSmoke.Port.holdHeartbeat`).
    var holdHeartbeat = false
    /// How many call envelopes the peer's outbox still holds: one per send
    /// whose completion has not run.
    private(set) var outstanding = 0
    /// When set, `send` refuses once the outbox already holds this many, the
    /// way the core answers `call_outbox_full` at
    /// `CallController.maximumPendingCallEnvelopes` (`clean_service.rs:398`).
    var callOutboxLimit: Int?
    private(set) var presentation: CallPresentation?
    /// Whether a media engine exists: opening a camera without one is a
    /// programming error, and the fixture says so out loud.
    private var engine = false
    weak var controller: CallController?

    func send(account: String, body: CallBody, completion: @escaping (Bool) -> Void) throws {
        if let callOutboxLimit, outstanding >= callOutboxLimit { throw CallOutboxFull.callOutboxFull }
        if !failSave {
            pending.append(CallTestSent(account: account, body: body))
            everySent.append(CallTestSent(account: account, body: body))
        }
        outstanding += 1
        let settle: (Bool) -> Void = { [weak self] accepted in
            self?.outstanding -= 1
            completion(accepted)
        }
        if deferSignals {
            deferred.append(settle)
        } else if holdHeartbeat, body.kind == .heartbeat {
            // The server has not answered this one, and it never will.
        } else {
            settle(!failSave)
        }
    }

    /// Runs the completion this port has been holding since it was the `index`
    /// -th one enqueued.
    func settle(_ index: Int, accepted: Bool) {
        deferred[index](accepted)
    }

    /// The most recent held completion — the one that belongs to the call this
    /// test is actually looking at.
    func settleLast(accepted: Bool) {
        deferred[deferred.count - 1](accepted)
    }

    func offer(generation: CallGeneration) throws {
        offers += 1
        grantAuthority(generation)
    }

    func answer(generation: CallGeneration, remoteSdp: String) throws {
        answers += 1
        grantAuthority(generation)
    }

    func remoteAnswer(generation: CallGeneration, remoteSdp: String) throws {
        remoteAnswers += 1
    }

    func mute(_ muted: Bool) throws {
        self.muted = muted
    }

    func speaker(_ speaker: Bool) throws {
        self.speaker = speaker
    }

    func video(_ enabled: Bool) throws {
        if enabled, !engine { throw CallMediaError.cameraDenied }
        video = enabled
        videoCalls += 1
    }

    func close() {
        closes += 1
        engine = false
        video = false
    }

    func changed(_ presentation: CallPresentation) {
        self.presentation = presentation
    }

    /// The next control this side enqueued, or `nil` when it enqueued none.
    func take() -> CallTestSent? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// How many enqueued controls have not been taken yet. It is
    /// `CallControllerSmoke.Port.sent.size()`.
    var pendingCount: Int { pending.count }

    private func grantAuthority(_ generation: CallGeneration) {
        guard !deferMedia, let controller, controller.mediaAuthorized(generation, authorized: true)
        else { return }
        engine = true
        controller.mediaReady(generation)
    }
}

/// Two controllers over one clock, the way `CallControllerSmoke.Pair` runs two
/// phones (`clients/android/test/CallControllerSmoke.java:46-54`).
///
/// Delivery goes through the wire form on purpose: a control is encoded, and
/// the receiving side decodes it, checks it against the kind table and against
/// its own clock, exactly as it would after the core handed it a `call_event`.
final class CallPair {
    static let alice = String(repeating: "a", count: 64)
    static let bob = String(repeating: "b", count: 64)

    let time = CallTestClock()
    let owner = CallTestOwner()
    let alicePorts = CallTestPorts()
    let bobPorts = CallTestPorts()
    let alice: CallController
    let bob: CallController

    init() {
        alice = CallController(clock: time.clock, owner: owner, sender: alicePorts,
                               media: alicePorts, observer: alicePorts)
        bob = CallController(clock: time.clock, owner: owner, sender: bobPorts,
                             media: bobPorts, observer: bobPorts)
        alicePorts.controller = alice
        bobPorts.controller = bob
        alice.connection(true)
        bob.connection(true)
    }

    /// Hands one control to the other side through its wire form, optionally
    /// rewriting a member on the way — which is what an attacker or a broken
    /// peer would do.
    func deliver(to controller: CallController,
                 from account: String,
                 _ sent: CallTestSent,
                 _ change: ((inout [String: Any]) -> Void)? = nil) {
        deliver(to: controller, from: account, sent.body, change)
    }

    func deliver(to controller: CallController,
                 from account: String,
                 _ body: CallBody,
                 _ change: ((inout [String: Any]) -> Void)? = nil) {
        if body.kind == .offer {
            (controller === alice ? alicePorts : bobPorts).lastReceivedOffer =
                CallTestSent(account: account, body: body)
        }
        var members = body.members
        change?(&members)
        guard let data = try? JSONSerialization.data(withJSONObject: members, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            preconditionFailure("the members of a call body are always JSON")
        }
        controller.received(account: account, json: json)
    }

    /// A knock from an unrelated caller, for the admission checks.
    func knockBody(callId: String = UUID().uuidString.lowercased()) -> CallBody {
        CallBody.knock(CallIdentity(callId: callId, callerNonce: String(repeating: "e", count: 64)),
                       sentMillis: time.wallMillis)
    }

    /// Alice calls Bob and Bob answers `ready`: both sides are authorized and
    /// no description exists yet.
    func ready() {
        alice.start(account: Self.bob, microphonePermission: true)
        guard let knock = alicePorts.take() else { return }
        deliver(to: bob, from: Self.alice, knock)
        guard let ready = bobPorts.take() else { return }
        deliver(to: alice, from: Self.bob, ready)
    }

    /// …and the offer reaches Bob, which rings.
    func ring() {
        ready()
        alice.localDescription(alice.generation, sdp: CallBodyTests.sdp)
        guard let offer = alicePorts.take() else { return }
        deliver(to: bob, from: Self.alice, offer)
    }

    /// …and Bob answers, and both engines report a connection.
    func connect() {
        ring()
        bob.answer(microphonePermission: true)
        bob.localDescription(bob.generation, sdp: CallBodyTests.answerSdp)
        guard let answer = bobPorts.take() else { return }
        deliver(to: alice, from: Self.bob, answer)
        alice.mediaState(alice.generation, .connected)
        bob.mediaState(bob.generation, .connected)
    }

    /// The identity members the readiness slot of `controller` is holding, read
    /// back out of the controls it sent.
    func callId(of controller: CallController) -> String {
        (controller === alice ? alicePorts : bobPorts).everySent.last?.body.callId ?? ""
    }

    func callerNonce(of controller: CallController) -> String {
        (controller === alice ? alicePorts : bobPorts).everySent.last?.body.callerNonce ?? ""
    }

    func calleeNonce(of controller: CallController) -> String {
        (controller === alice ? alicePorts : bobPorts).everySent.last?.body.calleeNonce ?? ""
    }
}
