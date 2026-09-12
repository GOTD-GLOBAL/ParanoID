import CryptoKit
import Foundation
import ParanoidKit
import WebRTC
import XCTest

/// Go/no-go spike for encrypted calls on iOS: does the SDP that libwebrtc
/// `150.7871.01` produces on this platform survive the core's `call`
/// validator (`clients/core/src/voice_v1.rs`) unchanged?
///
/// The call body is **v2** ([call-v2](../../../../docs/protocol/call-v2.md)):
/// fifteen members, the fourteen of v1 plus a real JSON boolean `video`, and a
/// complete description carries exactly two media sections, `m=audio` then
/// `m=video`, each with exactly one `a=sendrecv`, bundled on the audio
/// section's transport. A v1 body no longer deserialises at all, which this
/// file also measures.
///
/// The peer connection is configured exactly like Android's
/// (`WebRtcAudioEngine.java:238-284`: default encoder/decoder factories,
/// unified plan, max-bundle, RTCP mux required, TCP candidates disabled,
/// gather-once, candidate pool 0, no ICE servers), carries one audio track and
/// one video track that starts disabled, and restricts the senders with
/// `setCodecPreferences`: `audio/opus` on every transceiver, then H.264 first,
/// VP8 as the mandatory fallback and the helper formats
/// (`rtx`/`red`/`ulpfec`/`flexfec-03`) on the video transceiver — the iOS
/// counterpart of the `RtpCapabilities.CodecCapability` filters in
/// `WebRtcAudioEngine.java:263-284`, and the owner's codec decision of
/// 2026-09-11. Anything outside that list (VP9, AV1) is dropped here, in
/// configuration, never out of the finished text.
///
/// The description is then sent through the core between two synthetic
/// identities, the hand-off `clients/core/tests/voice_calls.rs` performs: the
/// caller runs `send_call_v1` with the `offer` and the callee accepts it with
/// `receive_v2`, then the same for the `answer` in the other direction, and
/// once more for the new `media` kind that announces camera state without a
/// description.
///
/// The SDP is never rewritten (`docs/protocol/voice-v1.md`: the sender does
/// not munge SDP). Extra `a=rtpmap` lines are tolerated by the core as long as
/// their payload type also appears in the `m=` line (`voice_v1.rs:203-225,250-254`);
/// only a real `invalid_call_sdp` from the core is a failure, and the answer
/// to one is a WebRTC-side configuration change, never a patch to the core.
///
/// The survey (size against the 9000-byte cap, line and candidate counts,
/// every `a=rtpmap` per section, `a=crypto` count, `a=setup`) is written to
/// `clients/ios/out/evidence/sdp-spike.json`. ICE credentials are per-call
/// secrets: the file records their length, never their value, and the copy of
/// the SDP it keeps has both lines masked.
final class SdpCompatibilityTests: XCTestCase {
    private static let realm = "https://127.0.0.2:38443"
    private static let pin = String(repeating: "a", count: 64)
    private static let timeout: TimeInterval = 30
    /// `expires_ms - sent_ms` must stay at or below 45 s (`voice_v1.rs:51`).
    private static let callWindowMs = 30_000
    /// The video codecs the core whitelists (`voice_v1.rs:11-18`), lowercased
    /// exactly as it compares them.
    private static let videoCodecs: Set<String> = [
        "h264/90000", "vp8/90000", "rtx/90000", "red/90000", "ulpfec/90000", "flexfec-03/90000",
    ]

    // MARK: - The spike

    func testLibwebrtcOfferAndAnswerAreAcceptedByTheCore() throws {
        var evidence: [String: Any] = [
            "webrtc": "150.7871.01",
            "core": "send_call_v1 + receive_v2 (schema 3), call body v2",
            "protocol": "call-v2 (docs/protocol/call-v2.md), validator clients/core/src/voice_v1.rs",
            "configuration": "unifiedPlan, maxBundle, rtcpMux require, tcp disabled, gatherOnce, pool 0, no ICE servers",
            "codec_preferences": "audio: opus only; video: H.264 first, VP8 fallback, rtx/red/ulpfec/flexfec-03 helpers",
            "video_capabilities": Self.factory
                .rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo)
                .codecs.map { $0.mimeType },
        ]
        defer { Self.write(evidence) }

        var caller = try party()
        var callee = try party()
        try pair(&caller, with: callee)
        try pair(&callee, with: caller)

        let callerPeer = try peer()
        defer { callerPeer.close() }
        let offerSdp = try localDescription(of: callerPeer, answer: false)
        // The masked description is recorded before it is parsed, so that a
        // description this client cannot use still lands in the evidence file.
        evidence["offer"] = Self.unparsed(offerSdp)
        let offer = try XCTUnwrap(SdpExtract(sdp: offerSdp), "offer SDP has no single transport context")
        evidence["offer"] = Self.survey(offer, sdp: offerSdp)
        assertCallV2Shape(offer, of: "offer")
        XCTAssertEqual(offer.setup, "actpass")

        let calleePeer = try peer()
        defer { calleePeer.close() }
        try apply(remote: offerSdp, type: .offer, to: calleePeer)
        let answerSdp = try localDescription(of: calleePeer, answer: true)
        evidence["answer"] = Self.unparsed(answerSdp)
        let answer = try XCTUnwrap(SdpExtract(sdp: answerSdp), "answer SDP has no single transport context")
        evidence["answer"] = Self.survey(answer, sdp: answerSdp)
        assertCallV2Shape(answer, of: "answer")
        XCTAssertTrue(["active", "passive"].contains(answer.setup))

        var call = Call(id: UUID().uuidString.lowercased(),
                        callerNonce: Self.nonce(), calleeNonce: Self.nonce())
        call.offerDigest = Self.sha256(offerSdp)

        var offerSurvey = try XCTUnwrap(evidence["offer"] as? [String: Any])
        let offerEvent = try record(&offerSurvey) {
            try transfer(
                body: Self.body(kind: "offer", seq: 1, video: true, call: call,
                                sdp: offerSdp, extract: offer),
                from: &caller, to: &callee)
        }
        evidence["offer"] = offerSurvey

        var answerSurvey = try XCTUnwrap(evidence["answer"] as? [String: Any])
        let answerEvent = try record(&answerSurvey) {
            try transfer(
                body: Self.body(kind: "answer", seq: 1, video: true, call: call,
                                sdp: answerSdp, extract: answer),
                from: &callee, to: &caller)
        }
        evidence["answer"] = answerSurvey

        // The peer receives the description byte for byte, which is what makes
        // the DTLS fingerprint and the ICE credentials usable at all.
        XCTAssertEqual(offerEvent["sdp"] as? String, offerSdp)
        XCTAssertEqual(offerEvent["kind"] as? String, "offer")
        XCTAssertEqual(offerEvent["fingerprint"] as? String, offer.fingerprint)
        XCTAssertEqual(offerEvent["video"] as? Bool, true)
        XCTAssertEqual(answerEvent["sdp"] as? String, answerSdp)
        XCTAssertEqual(answerEvent["kind"] as? String, "answer")
        XCTAssertEqual(answerEvent["fingerprint"] as? String, answer.fingerprint)
        XCTAssertEqual(answerEvent["video"] as? Bool, true)

        // Camera state travels as its own control, never as a second offer:
        // there is no renegotiation in a call (`call-v2.md`, `voice_v1.rs:61-62`).
        var mediaSurvey: [String: Any] = ["accepted": false, "kind": "media", "seq": 2, "video": false]
        let mediaEvent = try record(&mediaSurvey) {
            try transfer(body: Self.body(kind: "media", seq: 2, video: false, call: call),
                         from: &caller, to: &callee)
        }
        evidence["media"] = mediaSurvey
        XCTAssertEqual(mediaEvent["kind"] as? String, "media")
        XCTAssertEqual(mediaEvent["video"] as? Bool, false)
        XCTAssertEqual(mediaEvent["sdp"] as? String, "")

        print("SdpCompatibilityTests: offer \(offer.byteCount) B of \(SdpExtract.maxSdpBytes), "
            + "\(offer.candidateCount) candidates, sections \(offer.mediaKinds), "
            + "\(offer.rtpmap.count) rtpmap, setup=\(offer.setup); answer \(answer.byteCount) B, "
            + "\(answer.candidateCount) candidates, \(answer.rtpmap.count) rtpmap, setup=\(answer.setup)")
    }

    /// The v1 body this file used to send no longer exists on the wire: the
    /// core's `CallV1` requires `video`, so a fourteen-member body fails
    /// deserialisation and never reaches the validator — `invalid_request`,
    /// not a call rejection (`call-v2.md`, "There is no mixed v1/v2 call").
    func testV1CallBodyIsRefusedBeforeValidation() throws {
        var caller = try party()
        var callee = try party()
        try pair(&caller, with: callee)
        try pair(&callee, with: caller)

        let call = Call(id: UUID().uuidString.lowercased(),
                        callerNonce: Self.nonce(), calleeNonce: Self.nonce())
        var legacy = Self.body(kind: "knock", seq: 0, video: false, call: call)
        legacy["v"] = 1
        legacy["callee_nonce"] = ""
        legacy.removeValue(forKey: "video")

        XCTAssertThrowsError(try CoreBridge.command(
            state: caller.state,
            request: Self.request(["op": "send_call_v1", "account": callee.account, "body": legacy]))
        ) { error in
            XCTAssertEqual(error as? CoreError, .rejected("invalid_request"))
        }
    }

    /// The SDP is only worth sending when `SdpExtract` reads back the same
    /// values the core cross-checks against the text, from either of the two
    /// sections that repeat them.
    func testExtractMatchesTheDescriptionItCameFrom() throws {
        let peer = try peer()
        defer { peer.close() }
        let sdp = try localDescription(of: peer, answer: false)
        let extract = try XCTUnwrap(SdpExtract(sdp: sdp))
        XCTAssertTrue(sdp.contains("a=ice-ufrag:\(extract.iceUfrag)\r\n"))
        XCTAssertTrue(sdp.contains("a=ice-pwd:\(extract.icePwd)\r\n"))
        XCTAssertEqual(extract.fingerprint.count, 64)
        XCTAssertTrue(extract.fingerprint.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(extract.mediaKinds, ["audio", "video"])
        XCTAssertEqual(extract.sections.first?.codecs, ["opus/48000/2"])
        XCTAssertTrue(extract.rtpmap.allSatisfy { sdp.contains("\($0)\r\n") })
    }

    /// Every rule of `voice_v1.rs:236-256` that this client can break on its
    /// own, checked before the core is asked, so that a regression names the
    /// rule instead of reporting one `invalid_call_sdp`.
    private func assertCallV2Shape(_ extract: SdpExtract, of kind: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(extract.mediaKinds, ["audio", "video"],
                       "\(kind): call-v2 is audio then video", file: file, line: line)
        XCTAssertEqual(extract.cryptoCount, 0,
                       "\(kind): SDES keying would introduce a second keying authority",
                       file: file, line: line)
        XCTAssertEqual(extract.blockedDirectionCount, 0,
                       "\(kind): a directional attribute other than sendrecv", file: file, line: line)
        XCTAssertLessThanOrEqual(extract.candidateCount, 16, "\(kind): candidate limit",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(extract.lineCount, 512, "\(kind): line limit", file: file, line: line)
        // The core's own limit is 12288 bytes, but the control frame carries
        // less; the cap this client enforces is `SdpExtract.maxSdpBytes`.
        XCTAssertTrue(extract.fitsFrameBudget,
                      "\(kind): \(extract.byteCount) B is above the \(SdpExtract.maxSdpBytes) B cap",
                      file: file, line: line)
        for section in extract.sections {
            XCTAssertEqual(section.transport, "UDP/TLS/RTP/SAVPF", "\(kind)/\(section.kind): transport",
                           file: file, line: line)
            XCTAssertEqual(section.sendrecvCount, 1, "\(kind)/\(section.kind): one a=sendrecv",
                           file: file, line: line)
            XCTAssertTrue(section.declaresEveryMapping,
                          "\(kind)/\(section.kind): a=rtpmap payload type missing from the m= line",
                          file: file, line: line)
            XCTAssertLessThanOrEqual(section.rtcpMuxCount, 1, "\(kind)/\(section.kind): a=rtcp-mux",
                                     file: file, line: line)
        }
        guard extract.sections.count == 2 else { return }
        let audio = extract.sections[0], video = extract.sections[1]
        XCTAssertEqual(audio.rtcpMuxCount, 1, "\(kind): the audio section carries the transport",
                       file: file, line: line)
        XCTAssertGreaterThan(audio.port ?? 0, 0, "\(kind): audio port", file: file, line: line)
        XCTAssertNotNil(video.port, "\(kind): video port", file: file, line: line)
        XCTAssertEqual(audio.codecs.filter { $0 == "opus/48000/2" }.count, 1,
                       "\(kind): exactly one Opus mapping", file: file, line: line)
        XCTAssertTrue(video.codecs.allSatisfy(Self.videoCodecs.contains),
                      "\(kind): video codecs outside the whitelist: \(video.codecs)",
                      file: file, line: line)
        XCTAssertTrue(video.codecs.contains { $0 == "h264/90000" || $0 == "vp8/90000" },
                      "\(kind): neither H.264 nor VP8", file: file, line: line)
    }

    // MARK: - WebRTC

    /// One shared factory, as on Android, with SSL initialised once and the
    /// bundled encoder/decoder factories the video section needs
    /// (`WebRtcAudioEngine.java:240-243`). The internal tracer stays off: on
    /// iOS it only runs after an explicit `RTCStartInternalCapture`, the
    /// counterpart of Android's `setEnableInternalTracer(false)`.
    /// `RTCAudioSession` is put in manual mode with audio disabled so that
    /// building a description never opens the microphone; this spike creates
    /// offers, it does not carry media.
    private nonisolated(unsafe) static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    /// `WebRtcAudioEngine.java:244-251` in Swift.
    private static func configuration() -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.tcpCandidatePolicy = .disabled
        config.continualGatheringPolicy = .gatherOnce
        config.iceCandidatePoolSize = 0
        return config
    }

    /// A peer with the two pre-negotiated sections of a call-v2 client: one
    /// audio track, and one video track that exists from the start and stays
    /// disabled until an explicit camera toggle, so that camera on and off is
    /// never a renegotiation (`WebRtcAudioEngine.java:253-284`).
    private func peer() throws -> RTCPeerConnection {
        let factory = Self.factory
        let connection = try XCTUnwrap(factory.peerConnection(
            with: Self.configuration(),
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: nil))
        let source = factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["googEchoCancellation": "true",
                                  "googAutoGainControl": "true",
                                  "googNoiseSuppression": "true"]))
        let track = factory.audioTrack(with: source, trackId: "voice")
        XCTAssertNotNil(connection.add(track, streamIds: ["voice"]))
        let opus = factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindAudio)
            .codecs.filter { $0.mimeType.lowercased() == "audio/opus" }
        // The core accepts exactly one `opus/48000/2` mapping and nothing that
        // is not in the `m=` line, so a build without Opus is unusable.
        XCTAssertFalse(opus.isEmpty, "Opus unavailable in this libwebrtc build")
        for transceiver in connection.transceivers {
            // `setCodecPreferences:error:` declares its out-parameter as
            // `NSError ** _Nullable`, so the importer keeps an empty `error:`
            // label beside the thrown error instead of dropping it.
            try transceiver.setCodecPreferences(opus, error: ())
        }
        let videoSource = factory.videoSource()
        let videoTrack = factory.videoTrack(with: videoSource, trackId: "video")
        videoTrack.isEnabled = false
        XCTAssertNotNil(connection.add(videoTrack, streamIds: ["voice"]))
        let video = videoPreferences(of: factory)
        for transceiver in connection.transceivers where transceiver.mediaType == .video {
            try transceiver.setCodecPreferences(video, error: ())
        }
        return connection
    }

    /// `WebRtcAudioEngine.java:273-283` in Swift: H.264 first (hardware,
    /// owner decision 2026-09-11), VP8 as the mandatory fallback, then the
    /// helper formats. VP9, AV1 and anything else the core does not whitelist
    /// never enter the offer, because they are never preferred.
    private func videoPreferences(of factory: RTCPeerConnectionFactory) -> [RTCRtpCodecCapability] {
        var preferred: [RTCRtpCodecCapability] = []
        var fallback: [RTCRtpCodecCapability] = []
        var helpers: [RTCRtpCodecCapability] = []
        for codec in factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs {
            switch codec.mimeType.lowercased() {
            case "video/h264": preferred.append(codec)
            case "video/vp8": fallback.append(codec)
            case "video/rtx", "video/red", "video/ulpfec", "video/flexfec-03": helpers.append(codec)
            default: continue
            }
        }
        XCTAssertFalse(fallback.isEmpty, "VP8 unavailable in this libwebrtc build")
        XCTAssertFalse(preferred.isEmpty, "H.264 unavailable in this libwebrtc build")
        return preferred + fallback + helpers
    }

    private func apply(remote sdp: String, type: RTCSdpType, to connection: RTCPeerConnection) throws {
        let applied = expectation(description: "remote description")
        let failure = Slot<Error>()
        connection.setRemoteDescription(RTCSessionDescription(type: type, sdp: sdp)) { error in
            failure.set(error)
            applied.fulfill()
        }
        wait(for: [applied], timeout: Self.timeout)
        if let error = failure.value { throw error }
    }

    /// Creates the description, applies it and waits for gather-once to
    /// finish, the point at which Android reads the SDP
    /// (`TextEngine.java:135-144`).
    private func localDescription(of connection: RTCPeerConnection, answer: Bool) throws -> String {
        let created = expectation(description: answer ? "answer" : "offer")
        let description = Slot<RTCSessionDescription>()
        let failure = Slot<Error>()
        let handler: @Sendable (RTCSessionDescription?, Error?) -> Void = { sdp, error in
            description.set(sdp)
            failure.set(error)
            created.fulfill()
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        if answer {
            connection.answer(for: constraints, completionHandler: handler)
        } else {
            connection.offer(for: constraints, completionHandler: handler)
        }
        wait(for: [created], timeout: Self.timeout)
        if let error = failure.value { throw error }

        let applied = expectation(description: "local description")
        connection.setLocalDescription(try XCTUnwrap(description.value)) { error in
            failure.set(error)
            applied.fulfill()
        }
        wait(for: [applied], timeout: Self.timeout)
        if let error = failure.value { throw error }

        let deadline = Date().addingTimeInterval(Self.timeout)
        while connection.iceGatheringState != .complete, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(connection.iceGatheringState, .complete, "ICE gathering did not finish")
        return try XCTUnwrap(connection.localDescription?.sdp)
    }

    /// A completion-handler result handed back to the waiting test.
    private final class Slot<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        var value: Value? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ value: Value?) {
            lock.lock()
            stored = value
            lock.unlock()
        }
    }

    // MARK: - Core

    /// One synthetic identity, prepared for first contact:
    /// `create_identity` -> `upgrade_v2` -> `server_status_v2` ->
    /// `prepare_contact_v2`, the sequence of
    /// `clients/core/tests/voice_calls.rs::ready`. `received` is the transport
    /// sequence this party has already accepted; the core refuses anything at
    /// or below its cursor. `sent` is how many envelopes this party has put in
    /// its outbox: nothing here runs `accepted_v2`, so the outbox keeps every
    /// one of them and the newest is the last.
    private struct Party {
        var state: String
        let account: String
        let contact: [String: Any]
        var received = 0
        var sent = 0
    }

    /// The identifiers every control of one call repeats.
    private struct Call {
        let id: String
        let callerNonce: String
        let calleeNonce: String
        /// `sha256(offer SDP)`, empty until the offer exists.
        var offerDigest = ""
    }

    private func party() throws -> Party {
        let created = try CoreBridge.command(
            state: "",
            request: Self.request(["op": "create_identity", "realm": Self.realm, "pin": Self.pin]))
        let upgraded = try CoreBridge.command(
            state: try XCTUnwrap(created.state), request: #"{"op":"upgrade_v2"}"#)
        let credential = try XCTUnwrap(
            (upgraded.object["request"] as? [String: Any])?["credential"] as? [String: Any])
        // The credential fingerprint the server echoes back is computed by the
        // core itself, so the test never reimplements the transcript.
        let validated = try CoreBridge.command(
            state: "",
            request: Self.request(["op": "validate_request",
                                   "descriptor": ["type": "paranoid-request-v1", "credential": credential]]))
        let status = try CoreBridge.command(
            state: try XCTUnwrap(upgraded.state),
            request: Self.request(["op": "server_status_v2",
                                   "status": ["mode": "active",
                                              "account": try XCTUnwrap(credential["account"] as? String),
                                              "device": try XCTUnwrap(credential["device"] as? String),
                                              "credential": try XCTUnwrap(validated.object["fingerprint"] as? String)]]))
        let prepared = try CoreBridge.command(
            state: try XCTUnwrap(status.state), request: #"{"op":"prepare_contact_v2"}"#)
        return Party(state: try XCTUnwrap(prepared.state),
                     account: try XCTUnwrap(credential["account"] as? String),
                     contact: try XCTUnwrap(prepared.object["contact"] as? [String: Any]))
    }

    /// Out-of-band verified pairing, the trust level a call needs.
    private func pair(_ party: inout Party, with other: Party) throws {
        let paired = try CoreBridge.command(
            state: party.state,
            request: Self.request(["op": "pair_contact_v2",
                                   "text": Self.request(other.contact),
                                   "verified": true]))
        party.state = try XCTUnwrap(paired.state)
    }

    /// `send_call_v1` on one side, `receive_v2` on the other; returns the
    /// `call_event` body the recipient surfaced.
    private func transfer(body: [String: Any], from sender: inout Party,
                          to recipient: inout Party) throws -> [String: Any] {
        let sent = try CoreBridge.command(
            state: sender.state,
            request: Self.request(["op": "send_call_v1", "account": recipient.account, "body": body]))
        sender.state = try XCTUnwrap(sent.state)
        let outbox = try XCTUnwrap(sent.object["outbox"] as? [[String: Any]])
        sender.sent += 1
        XCTAssertEqual(outbox.count, sender.sent, "one control envelope per send")
        let envelope = try XCTUnwrap(outbox.last)
        recipient.received += 1
        let message: [String: Any] = [
            "id": try XCTUnwrap(envelope["id"] as? String),
            "sender": sender.account,
            "sequence": recipient.received,
            "ciphertext": try XCTUnwrap(envelope["ciphertext"] as? String),
        ]
        let received = try CoreBridge.command(
            state: recipient.state,
            request: Self.request(["op": "receive_v2", "message": message]))
        recipient.state = try XCTUnwrap(received.state)
        XCTAssertEqual(received.object["acceptance"] as? String, "accepted")
        let event = try XCTUnwrap(received.object["call_event"] as? [String: Any])
        XCTAssertEqual(event["account"] as? String, sender.account)
        return try XCTUnwrap(event["body"] as? [String: Any])
    }

    /// A `call` control body (`voice_v1.rs:20-40`): the fourteen v1 members
    /// plus `video`, which must be a real JSON boolean. `offer`/`answer`
    /// carry the description and its three transport members; `media` (and
    /// every other kind) leaves all four empty.
    private static func body(kind: String, seq: Int, video: Bool, call: Call,
                             sdp: String = "", extract: SdpExtract? = nil) -> [String: Any] {
        let sentMs = Int(Date().timeIntervalSince1970 * 1000)
        return [
            "v": 2,
            "kind": kind,
            "call_id": call.id,
            "caller_nonce": call.callerNonce,
            "callee_nonce": call.calleeNonce,
            "seq": seq,
            "sent_ms": sentMs,
            "expires_ms": sentMs + callWindowMs,
            "sdp": sdp,
            "fingerprint": extract?.fingerprint ?? "",
            "ice_ufrag": extract?.iceUfrag ?? "",
            "ice_pwd": extract?.icePwd ?? "",
            "offer_digest": call.offerDigest,
            "reason": "",
            "video": video,
        ]
    }

    // MARK: - Evidence

    /// Runs one transfer and records what the core answered, so that a real
    /// rejection reaches `sdp-spike.json` instead of only the test log.
    private func record(_ survey: inout [String: Any],
                        _ work: () throws -> [String: Any]) throws -> [String: Any] {
        do {
            let event = try work()
            survey["accepted"] = true
            survey["acceptance"] = "accepted"
            return event
        } catch let error as CoreError {
            survey["accepted"] = false
            if case .rejected(let code) = error {
                survey["core_error"] = code
            } else {
                survey["core_error"] = "native_failure"
            }
            throw error
        }
    }

    /// What is known about a description before `SdpExtract` has read it.
    private static func unparsed(_ sdp: String) -> [String: Any] {
        ["accepted": false, "sdp_bytes": sdp.utf8.count, "sdp_masked": mask(sdp)]
    }

    private static func survey(_ extract: SdpExtract, sdp: String) -> [String: Any] {
        [
            "accepted": false,
            "sdp_bytes": extract.byteCount,
            // The core's own limit is 12288 bytes (`voice_v1.rs:10`); the
            // frame2 path carries at most 10040, so this client caps below it.
            "sdp_cap": SdpExtract.maxSdpBytes,
            "sdp_frame_ceiling": 10040,
            "sdp_core_limit": 12288,
            "fits_frame_budget": extract.fitsFrameBudget,
            "lines": extract.lineCount,
            "line_limit": 512,
            "candidates": extract.candidateCount,
            "candidate_limit": 16,
            "sections": extract.sections.map { section in
                [
                    "kind": section.kind,
                    "port": section.port.map { $0 as Any } ?? NSNull(),
                    "transport": section.transport,
                    "payload_types": section.payloadTypes,
                    "rtpmap": section.rtpmap,
                    "codecs": section.codecs,
                    "sendrecv": section.sendrecvCount,
                    "rtcp_mux": section.rtcpMuxCount,
                    "candidates": section.candidateCount,
                ] as [String: Any]
            },
            "rtpmap": extract.rtpmap,
            "crypto": extract.cryptoCount,
            "blocked_directions": extract.blockedDirectionCount,
            "setup": extract.setup,
            "fingerprint": extract.fingerprint,
            // Per-call ICE secrets: shape only, never the value.
            "ice_ufrag_length": extract.iceUfrag.count,
            "ice_pwd_length": extract.icePwd.count,
            "sdp_masked": mask(sdp),
        ]
    }

    /// The SDP with the ICE credentials removed, safe to keep in evidence and
    /// to paste into a report.
    private static func mask(_ sdp: String) -> String {
        SdpExtract.lines(of: sdp).map { line -> String in
            for prefix in ["a=ice-ufrag:", "a=ice-pwd:"] where line.hasPrefix(prefix) {
                return prefix + "***"
            }
            // A candidate line carries this machine's addresses, and the
            // evidence file travels into a pull request. Keep the shape the
            // core validates (component, transport, priority, type) and drop
            // the address and port, which say where this Mac lives.
            if line.hasPrefix("a=candidate:") {
                var fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                if fields.count > 6 {
                    fields[0] = "a=candidate:***"
                    fields[4] = "***"
                    fields[5] = "***"
                    for index in stride(from: 6, to: fields.count - 1, by: 2)
                    where fields[index] == "raddr" || fields[index] == "rport" {
                        fields[index + 1] = "***"
                    }
                    return fields.joined(separator: " ")
                }
                return "a=candidate:***"
            }
            // c= and o= carry a connection address for the same reason.
            if line.hasPrefix("c=") { return "c=IN IP4 ***" }
            if line.hasPrefix("o=") {
                let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                if fields.count >= 6 { return fields[0...2].joined(separator: " ") + " IN IP4 ***" }
                return "o=- *** *** IN IP4 ***"
            }
            return line
        }.joined(separator: "\n")
    }

    /// `clients/ios/out/evidence/sdp-spike.json`, derived from this file's own
    /// location so that the plain `xcodebuild test` command needs no extra
    /// argument; `PARANOID_IOS_EVIDENCE_DIR` overrides it.
    private static var evidenceURL: URL {
        if let override = ProcessInfo.processInfo.environment["PARANOID_IOS_EVIDENCE_DIR"] {
            return URL(fileURLWithPath: override).appendingPathComponent("sdp-spike.json")
        }
        // .../clients/ios/App/ParanoIDTests/SdpCompatibilityTests.swift
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("out/evidence/sdp-spike.json")
    }

    private static func write(_ evidence: [String: Any]) {
        let url = evidenceURL
        do {
            let data = try JSONSerialization.data(
                withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            XCTFail("evidence not written to \(url.path): \(error)")
        }
    }

    // MARK: - Small helpers

    private static func request(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func nonce() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
