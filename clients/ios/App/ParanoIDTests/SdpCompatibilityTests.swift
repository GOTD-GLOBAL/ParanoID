import CryptoKit
import Foundation
import ParanoidKit
import WebRTC
import XCTest

/// Go/no-go spike for encrypted voice on iOS: does the SDP that libwebrtc
/// `150.7871.01` produces on this platform survive the core's `call` validator
/// (`clients/core/src/voice_v1.rs`) unchanged?
///
/// The peer connection is configured exactly like Android's
/// (`WebRtcAudioEngine.java:195-202`: unified plan, max-bundle, RTCP mux
/// required, TCP candidates disabled, gather-once, candidate pool 0, no ICE
/// servers), carries one audio track and restricts the sender to `audio/opus`
/// through `setCodecPreferences`, the iOS counterpart of the
/// `RtpCapabilities.CodecCapability` filter in `WebRtcAudioEngine.java:214-220`.
/// The description is then sent through the core between two synthetic
/// identities, the hand-off `clients/core/tests/voice_calls.rs` performs: the
/// caller runs `send_call_v1` with the `offer` and the callee accepts it with
/// `receive_v2`, then the same for the `answer` in the other direction.
///
/// The SDP is never rewritten (`docs/protocol/voice-v1.md`: the sender does
/// not munge SDP). Extra `a=rtpmap` lines are tolerated by the core as long as
/// their payload type also appears in the `m=` line (`voice_v1.rs:166-199`);
/// only a real `invalid_call_sdp` from the core is a failure, and the answer
/// to one is a WebRTC-side configuration change, never a patch to the core.
///
/// The survey (size, candidate count, every `a=rtpmap`, `a=crypto` count,
/// `a=setup`) is written to `clients/ios/out/evidence/sdp-spike.json`. ICE
/// credentials are per-call secrets: the file records their length, never
/// their value, and the copy of the SDP it keeps has both lines masked.
final class SdpCompatibilityTests: XCTestCase {
    private static let realm = "https://127.0.0.2:38443"
    private static let pin = String(repeating: "a", count: 64)
    private static let timeout: TimeInterval = 30
    /// `expires_ms - sent_ms` must stay at or below 45 s (`voice_v1.rs:36`).
    private static let callWindowMs = 30_000

    // MARK: - The spike

    func testLibwebrtcOfferAndAnswerAreAcceptedByTheCore() throws {
        var evidence: [String: Any] = [
            "webrtc": "150.7871.01",
            "core": "send_call_v1 + receive_v2 (schema 3)",
            "configuration": "unifiedPlan, maxBundle, rtcpMux require, tcp disabled, gatherOnce, pool 0, no ICE servers",
            "codec_preferences": "audio/opus only",
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
        let offer = try XCTUnwrap(SdpExtract(sdp: offerSdp), "offer SDP has no single fingerprint/ICE/setup line")
        evidence["offer"] = Self.survey(offer, sdp: offerSdp)

        let calleePeer = try peer()
        defer { calleePeer.close() }
        try apply(remote: offerSdp, type: .offer, to: calleePeer)
        let answerSdp = try localDescription(of: calleePeer, answer: true)
        evidence["answer"] = Self.unparsed(answerSdp)
        let answer = try XCTUnwrap(SdpExtract(sdp: answerSdp), "answer SDP has no single fingerprint/ICE/setup line")
        evidence["answer"] = Self.survey(answer, sdp: answerSdp)

        XCTAssertEqual(offer.setup, "actpass")
        XCTAssertTrue(["active", "passive"].contains(answer.setup))
        XCTAssertEqual(offer.cryptoCount, 0, "SDES keying would introduce a second keying authority")
        XCTAssertEqual(answer.cryptoCount, 0)

        let callId = UUID().uuidString.lowercased()
        let callerNonce = Self.nonce()
        let calleeNonce = Self.nonce()
        let offerDigest = Self.sha256(offerSdp)

        var offerSurvey = try XCTUnwrap(evidence["offer"] as? [String: Any])
        let offerEvent = try record(&offerSurvey) {
            try transfer(
                body: Self.body(kind: "offer", sdp: offerSdp, extract: offer, callId: callId,
                                callerNonce: callerNonce, calleeNonce: calleeNonce, offerDigest: offerDigest),
                from: &caller, to: &callee)
        }
        evidence["offer"] = offerSurvey

        var answerSurvey = try XCTUnwrap(evidence["answer"] as? [String: Any])
        let answerEvent = try record(&answerSurvey) {
            try transfer(
                body: Self.body(kind: "answer", sdp: answerSdp, extract: answer, callId: callId,
                                callerNonce: callerNonce, calleeNonce: calleeNonce, offerDigest: offerDigest),
                from: &callee, to: &caller)
        }
        evidence["answer"] = answerSurvey

        // The peer receives the description byte for byte, which is what makes
        // the DTLS fingerprint and the ICE credentials usable at all.
        XCTAssertEqual(offerEvent["sdp"] as? String, offerSdp)
        XCTAssertEqual(offerEvent["kind"] as? String, "offer")
        XCTAssertEqual(offerEvent["fingerprint"] as? String, offer.fingerprint)
        XCTAssertEqual(answerEvent["sdp"] as? String, answerSdp)
        XCTAssertEqual(answerEvent["kind"] as? String, "answer")
        XCTAssertEqual(answerEvent["fingerprint"] as? String, answer.fingerprint)

        print("SdpCompatibilityTests: offer \(offer.byteCount) B, \(offer.candidateCount) candidates, "
            + "\(offer.rtpmap.count) rtpmap, setup=\(offer.setup); answer \(answer.byteCount) B, "
            + "\(answer.candidateCount) candidates, \(answer.rtpmap.count) rtpmap, setup=\(answer.setup)")
    }

    /// The SDP is only worth sending when `SdpExtract` reads back the same
    /// three values the core cross-checks against the text.
    func testExtractMatchesTheDescriptionItCameFrom() throws {
        let peer = try peer()
        defer { peer.close() }
        let sdp = try localDescription(of: peer, answer: false)
        let extract = try XCTUnwrap(SdpExtract(sdp: sdp))
        XCTAssertTrue(sdp.contains("a=ice-ufrag:\(extract.iceUfrag)\r\n"))
        XCTAssertTrue(sdp.contains("a=ice-pwd:\(extract.icePwd)\r\n"))
        XCTAssertEqual(extract.fingerprint.count, 64)
        XCTAssertTrue(extract.fingerprint.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase })
        XCTAssertTrue(extract.rtpmap.contains { $0.lowercased().hasSuffix(" opus/48000/2") })
    }

    // MARK: - WebRTC

    /// One shared factory, as on Android, with SSL initialised once. The
    /// internal tracer stays off: on iOS it only runs after an explicit
    /// `RTCStartInternalCapture`, the counterpart of Android's
    /// `setEnableInternalTracer(false)`. `RTCAudioSession` is put in manual
    /// mode with audio disabled so that building a description never opens the
    /// microphone; this spike creates offers, it does not carry media.
    private nonisolated(unsafe) static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        return RTCPeerConnectionFactory()
    }()

    /// `WebRtcAudioEngine.java:195-202` in Swift.
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
        return connection
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
    /// `clients/core/tests/voice_calls.rs::ready`.
    private struct Party {
        var state: String
        let account: String
        let contact: [String: Any]
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
        XCTAssertEqual(outbox.count, 1, "one control envelope per send")
        let envelope = try XCTUnwrap(outbox.first)
        let message: [String: Any] = [
            "id": try XCTUnwrap(envelope["id"] as? String),
            "sender": sender.account,
            "sequence": 1,
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

    /// A `call` control body (`voice_v1.rs:8-23`) around one description.
    private static func body(kind: String, sdp: String, extract: SdpExtract, callId: String,
                            callerNonce: String, calleeNonce: String, offerDigest: String) -> [String: Any] {
        let sentMs = Int(Date().timeIntervalSince1970 * 1000)
        return [
            "v": 1,
            "kind": kind,
            "call_id": callId,
            "caller_nonce": callerNonce,
            "callee_nonce": calleeNonce,
            "seq": 1,
            "sent_ms": sentMs,
            "expires_ms": sentMs + callWindowMs,
            "sdp": sdp,
            "fingerprint": extract.fingerprint,
            "ice_ufrag": extract.iceUfrag,
            "ice_pwd": extract.icePwd,
            "offer_digest": offerDigest,
            "reason": "",
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
            "sdp_limit": 6144,
            "candidates": extract.candidateCount,
            "candidate_limit": 16,
            "rtpmap": extract.rtpmap,
            "crypto": extract.cryptoCount,
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
