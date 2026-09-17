import AVFoundation
import Foundation
import ParanoidKit
import WebRTC
import XCTest

@testable import ParanoID

/// When the one local description of a call may leave this device, and the
/// proof that it leaves exactly once.
///
/// The subject is `WebRtcAudioEngine.PublicationGate`, the port of
/// `maybePublishDescription` / `hasUsableRelayCandidate`
/// (`clients/android/src/org/paranoid/text/WebRtcAudioEngine.java:409-460`).
/// Most of this file drives it with a **fake candidate feed**: synthetic
/// call-v2 descriptions whose `a=candidate:` lines are written by hand, so
/// that every branch — relay with no relay candidate, the 500 ms coalescing
/// window, an empty `complete`, a description over the frame budget — is a
/// decision this test makes rather than one it waits for.
///
/// Four tests at the end run the real engine on the real libwebrtc of this
/// platform, in the simulator: a direct engine publishes one offer and never a
/// second; a relay-only engine with no reachable relay publishes nothing at
/// all; the camera is refused without permission and reports itself
/// unavailable with no camera; and the configuration is the one the protocol
/// demands.
///
/// Every address in the fake feed is from a documentation range (RFC 5737:
/// `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) and the relay engine
/// dials a loopback alias. Nothing here names this machine, and nothing here
/// reaches the network beyond `lo0`.
final class SdpPublishGatingTests: XCTestCase {
    // MARK: - Direct

    /// Without a relay there is no trickle and no coalescing: the description
    /// is worth sending once gathering is finished, and not before.
    func testDirectPublishesOnlyWhenGatheringIsComplete() {
        let gate = WebRtcAudioEngine.PublicationGate(relayOnly: false)
        let sdp = Self.sdp(candidates: [Self.hostCandidate])

        XCTAssertEqual(gate.evaluate(sdp: sdp, ready: true, gatheringComplete: false), .wait)
        XCTAssertEqual(gate.publications, 0)
        XCTAssertEqual(gate.evaluate(sdp: sdp, ready: true, gatheringComplete: true), .publish(sdp))
        XCTAssertEqual(gate.publications, 1)
    }

    /// libwebrtc can report `complete` before it has found an interface, and
    /// such a description cannot connect two peers
    /// (`WebRtcAudioEngine.java:425-428`).
    func testDirectNeverPublishesADescriptionWithoutCandidates() {
        let gate = WebRtcAudioEngine.PublicationGate(relayOnly: false)
        let empty = Self.sdp(candidates: [])
        XCTAssertFalse(empty.contains("a=candidate:"))

        XCTAssertEqual(gate.evaluate(sdp: empty, ready: true, gatheringComplete: true), .wait)
        XCTAssertEqual(gate.publications, 0)
        // The candidate that arrives afterwards is what publishes it.
        let gathered = Self.sdp(candidates: [Self.hostCandidate])
        XCTAssertEqual(gate.evaluate(sdp: gathered, ready: true, gatheringComplete: true), .publish(gathered))
    }

    // MARK: - Relay

    /// A relay-only description with no relay candidate cannot connect, so it
    /// is never published — not while gathering runs, and not when gathering
    /// completes. The controller's 45-second window is what ends the attempt.
    func testRelayNeverPublishesWithoutAUsableRelayCandidate() {
        let unusable: [(String, String)] = [
            ("host", Self.hostCandidate),
            ("server reflexive", Self.serverReflexiveCandidate),
            ("relay over TCP", Self.relayOverTcpCandidate),
            ("relay on component 2", Self.relayOnSecondComponent),
            ("relay over IPv6", Self.relayOverIPv6Candidate),
            ("relay on 0.0.0.0", Self.relayWithoutAddress),
            ("relay on port 0", Self.relayWithoutPort),
        ]
        for (name, candidate) in unusable {
            let gate = WebRtcAudioEngine.PublicationGate(relayOnly: true)
            let sdp = Self.sdp(candidates: [candidate])
            XCTAssertFalse(WebRtcAudioEngine.PublicationGate.hasUsableRelayCandidate(sdp), name)
            XCTAssertEqual(gate.evaluate(sdp: sdp, ready: true, gatheringComplete: false), .wait, name)
            XCTAssertEqual(gate.evaluate(sdp: sdp, ready: true, gatheringComplete: true), .wait, name)
            XCTAssertEqual(gate.publications, 0, name)
            XCTAssertFalse(gate.coalescing, name)
        }

        // All of them together are still not one usable relay candidate; the
        // one that is publishes immediately.
        let gate = WebRtcAudioEngine.PublicationGate(relayOnly: true)
        let crowd = Self.sdp(candidates: unusable.map(\.1))
        XCTAssertEqual(gate.evaluate(sdp: crowd, ready: true, gatheringComplete: true), .wait)
        let usable = Self.sdp(candidates: unusable.map(\.1) + [Self.relayCandidate])
        XCTAssertEqual(gate.evaluate(sdp: usable, ready: true, gatheringComplete: true), .publish(usable))
    }

    /// The first usable relay candidate opens a 500 ms window in which the
    /// rest may join it, and the description is published when that window
    /// has elapsed — once, however many candidates arrive inside it
    /// (`WebRtcAudioEngine.java:417-423`).
    func testRelayCoalescesOnceBeforePublishing() {
        let gate = WebRtcAudioEngine.PublicationGate(relayOnly: true)
        XCTAssertEqual(WebRtcAudioEngine.PublicationGate.coalescingMillis, 500)
        let first = Self.sdp(candidates: [Self.relayCandidate])

        XCTAssertEqual(gate.evaluate(sdp: first, ready: true, gatheringComplete: false), .coalesce)
        XCTAssertTrue(gate.coalescing)
        // Every further candidate inside the window asks for nothing more.
        let second = Self.sdp(candidates: [Self.relayCandidate, Self.secondRelayCandidate])
        XCTAssertEqual(gate.evaluate(sdp: second, ready: true, gatheringComplete: false), .wait)
        XCTAssertEqual(gate.evaluate(sdp: second, ready: true, gatheringComplete: false), .wait)
        XCTAssertEqual(gate.publications, 0)

        gate.coalescingWindowElapsed()
        XCTAssertEqual(gate.evaluate(sdp: second, ready: true, gatheringComplete: false), .publish(second))
        XCTAssertEqual(gate.publications, 1)
    }

    /// Gathering that finishes inside the window publishes at once: there is
    /// nothing left to coalesce.
    func testRelayPublishesImmediatelyWhenGatheringCompletesFirst() {
        let gate = WebRtcAudioEngine.PublicationGate(relayOnly: true)
        let sdp = Self.sdp(candidates: [Self.relayCandidate])

        XCTAssertEqual(gate.evaluate(sdp: sdp, ready: true, gatheringComplete: true), .publish(sdp))
        XCTAssertFalse(gate.coalescing, "a completed gathering needs no window")
        XCTAssertEqual(gate.publications, 1)
    }

    // MARK: - Readiness

    /// A description that has not been applied locally, or that is the other
    /// kind, is not this call's description yet.
    func testAnUnappliedDescriptionIsNeverPublished() {
        let gate = WebRtcAudioEngine.PublicationGate(relayOnly: false)
        let sdp = Self.sdp(candidates: [Self.hostCandidate])

        XCTAssertEqual(gate.evaluate(sdp: nil, ready: false, gatheringComplete: true), .wait)
        XCTAssertEqual(gate.evaluate(sdp: sdp, ready: false, gatheringComplete: true), .wait)
        XCTAssertEqual(gate.evaluate(sdp: "", ready: true, gatheringComplete: true), .wait)
        XCTAssertEqual(gate.publications, 0)
        XCTAssertFalse(gate.settled)
        XCTAssertEqual(gate.evaluate(sdp: sdp, ready: true, gatheringComplete: true), .publish(sdp))
    }

    // MARK: - Refusals

    /// The core accepts 12288 bytes, but one frame2 envelope carries at most
    /// 10040, so this client caps at 9000 and refuses rather than trims: the
    /// SDP is never rewritten to fit.
    func testADescriptionAboveTheFrameBudgetIsRefused() {
        XCTAssertEqual(SdpExtract.maxSdpBytes, 9000)
        let gate = WebRtcAudioEngine.PublicationGate(relayOnly: false)
        let oversize = Self.sdp(candidates: [Self.hostCandidate], padding: 9000)
        XCTAssertGreaterThan(oversize.utf8.count, SdpExtract.maxSdpBytes)

        XCTAssertEqual(gate.evaluate(sdp: oversize, ready: true, gatheringComplete: true),
                       .refuse(.descriptionOversize))
        XCTAssertEqual(gate.publications, 0)
        XCTAssertTrue(gate.settled)
        // A refusal is final: the call is over, and a smaller description
        // afterwards is not a second chance.
        let fitting = Self.sdp(candidates: [Self.hostCandidate])
        XCTAssertEqual(gate.evaluate(sdp: fitting, ready: true, gatheringComplete: true), .wait)
        XCTAssertEqual(gate.publications, 0)

        // One byte under the cap still travels.
        let exact = Self.sdp(candidates: [Self.hostCandidate], padding: 0)
        let room = SdpExtract.maxSdpBytes - exact.utf8.count - "a=x-pad:\r\n".utf8.count
        let atTheCap = Self.sdp(candidates: [Self.hostCandidate], padding: room)
        XCTAssertEqual(atTheCap.utf8.count, SdpExtract.maxSdpBytes)
        let edge = WebRtcAudioEngine.PublicationGate(relayOnly: false)
        XCTAssertEqual(edge.evaluate(sdp: atTheCap, ready: true, gatheringComplete: true),
                       .publish(atTheCap))
    }

    /// Anything the core would refuse is refused here first, so that a
    /// configuration regression is named on this side instead of coming back
    /// as one `invalid_call_sdp`.
    func testADescriptionThatIsNotCallV2IsRefused() {
        let refused: [(String, String)] = [
            ("audio only", Self.sdp(candidates: [Self.hostCandidate], video: false)),
            ("a directional attribute other than sendrecv",
             Self.sdp(candidates: [Self.hostCandidate], direction: "a=sendonly")),
            ("SDES keying", Self.sdp(candidates: [Self.hostCandidate], crypto: true)),
            ("a video codec outside the whitelist",
             Self.sdp(candidates: [Self.hostCandidate], videoRtpmap: ["96 VP9/90000"])),
            ("neither H.264 nor VP8",
             Self.sdp(candidates: [Self.hostCandidate], videoRtpmap: ["96 rtx/90000"])),
            ("a payload type missing from the m= line",
             Self.sdp(candidates: [Self.hostCandidate],
                              videoRtpmap: ["96 H264/90000", "98 VP8/90000"],
                              videoPayloads: ["96", "97"])),
            ("more than sixteen candidates",
             Self.sdp(candidates: (0..<17).map { Self.host(port: 51_200 + $0) })),
        ]
        for (name, sdp) in refused {
            let gate = WebRtcAudioEngine.PublicationGate(relayOnly: false)
            XCTAssertNotNil(SdpExtract(sdp: sdp), "\(name): the fixture itself must parse")
            XCTAssertEqual(gate.evaluate(sdp: sdp, ready: true, gatheringComplete: true),
                           .refuse(.descriptionShape), name)
            XCTAssertEqual(gate.publications, 0, name)
        }
    }

    /// A description whose transport context cannot be read carries no
    /// fingerprint and no ICE credentials to put in the body.
    func testAnUnreadableDescriptionIsRefused() {
        let gate = WebRtcAudioEngine.PublicationGate(relayOnly: false)
        let headless = Self.sdp(candidates: [Self.hostCandidate])
            .replacingOccurrences(of: "v=0\r\n", with: "")
        XCTAssertNil(SdpExtract(sdp: headless))
        XCTAssertTrue(headless.contains("a=candidate:"))

        XCTAssertEqual(gate.evaluate(sdp: headless, ready: true, gatheringComplete: true),
                       .refuse(.descriptionUnreadable))
        XCTAssertEqual(gate.publications, 0)
    }

    // MARK: - Exactly once

    /// There is one description per call and one publication of it. Every
    /// further gathering event, candidate and elapsed window says nothing.
    func testExactlyOnePublicationPerCall() {
        for relayOnly in [false, true] {
            let gate = WebRtcAudioEngine.PublicationGate(relayOnly: relayOnly)
            let sdp = Self.sdp(candidates: [Self.relayCandidate, Self.hostCandidate])
            XCTAssertEqual(gate.evaluate(sdp: sdp, ready: true, gatheringComplete: true), .publish(sdp))

            for _ in 0..<10 {
                XCTAssertEqual(gate.evaluate(sdp: sdp, ready: true, gatheringComplete: true), .wait)
                gate.coalescingWindowElapsed()
                let more = Self.sdp(candidates: [Self.relayCandidate, Self.secondRelayCandidate])
                XCTAssertEqual(gate.evaluate(sdp: more, ready: true, gatheringComplete: true), .wait)
            }
            XCTAssertEqual(gate.publications, 1, "relayOnly: \(relayOnly)")
        }
    }

    // MARK: - The real engine

    /// The direct lane end to end: libwebrtc on this platform produces one
    /// offer, the gate lets exactly one through, and it is a call-v2
    /// description inside the frame budget.
    func testDirectEnginePublishesItsOfferExactlyOnce() throws {
        let published = expectation(description: "one offer")
        let recorder = Recorder { event in
            if case .localDescription = event { published.fulfill() }
        }
        let engine = Self.engine(relay: nil, recorder: recorder)
        defer { Self.close(engine, in: self) }

        engine.createOffer()
        wait(for: [published], timeout: Self.timeout)

        let descriptions = recorder.descriptions
        XCTAssertEqual(descriptions.count, 1)
        let (kind, sdp) = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(kind, .offer)
        XCTAssertTrue(sdp.contains("a=candidate:"))
        XCTAssertLessThanOrEqual(sdp.utf8.count, SdpExtract.maxSdpBytes)
        let extract = try XCTUnwrap(SdpExtract(sdp: sdp))
        XCTAssertEqual(extract.mediaKinds, ["audio", "video"])
        XCTAssertTrue(WebRtcAudioEngine.PublicationGate.isCallV2(extract))
        XCTAssertEqual(extract.setup, "actpass")

        // The candidates keep arriving after the first publication; none of
        // them may produce a second one.
        let settled = expectation(description: "no second publication")
        settled.isInverted = true
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(recorder.descriptions.count, 1)
        XCTAssertEqual(recorder.failures, [])

        let reported = expectation(description: "statistics")
        let report = Slot<String>()
        engine.statistics { json in
            report.set(json)
            reported.fulfill()
        }
        wait(for: [reported], timeout: Self.timeout)
        let parsed = try JSONSerialization.jsonObject(
            with: Data(try XCTUnwrap(report.value).utf8)) as? [String: Any]
        XCTAssertFalse((parsed?["stats"] as? [[String: Any]] ?? []).isEmpty)

        print("SdpPublishGatingTests: offer \(sdp.utf8.count) B of \(SdpExtract.maxSdpBytes), "
            + "\(extract.candidateCount) candidates, sections \(extract.mediaKinds)")
    }

    /// The relay lane with a relay that answers nothing: the engine gathers,
    /// finds no relay candidate and publishes nothing at all. Silence is the
    /// correct outcome; the call controller's timeout ends the attempt.
    func testRelayOnlyEngineWithoutAReachableRelayPublishesNothing() throws {
        let recorder = Recorder()
        let engine = Self.engine(relay: try Self.relayCredential(), recorder: recorder)
        defer { Self.close(engine, in: self) }

        engine.createOffer()
        let silent = expectation(description: "no publication")
        silent.isInverted = true
        wait(for: [silent], timeout: 8)

        XCTAssertEqual(recorder.descriptions.count, 0)
        XCTAssertEqual(recorder.failures, [], "a relay that never answers is not an engine failure")
    }

    /// A camera toggle without the permission is refused before anything
    /// opens: no capture session, no event, and the call is untouched. The
    /// controller answers that refusal by staying audio-only (`call-v2.md`).
    func testCameraWithoutPermissionIsRefusedWithoutTouchingTheCall() {
        let recorder = Recorder()
        let engine = Self.engine(relay: nil, recorder: recorder, camera: false)
        defer { Self.close(engine, in: self) }

        XCTAssertThrowsError(try engine.setVideo(true)) { error in
            XCTAssertEqual(error as? CallMediaError, .cameraDenied)
        }
        XCTAssertEqual(recorder.events, [], "a refused toggle is not an engine event")
        // Turning it off is always accepted; there is nothing to permit. With
        // no media yet there is also nothing to apply, and nothing to report.
        XCTAssertNoThrow(try engine.setVideo(false))
        let quiet = expectation(description: "no event")
        quiet.isInverted = true
        wait(for: [quiet], timeout: 1)
        XCTAssertEqual(recorder.events, [])
    }

    /// A camera that cannot start after the toggle was accepted — the
    /// permission revoked between the two, no device, a capture error —
    /// downgrades the call to audio and says so. It never ends the call
    /// (`call-v2.md`: "it never ends the call").
    func testACameraThatCannotStartDowngradesToAudioAndNeverEndsTheCall() throws {
        let unavailable = expectation(description: "camera unavailable")
        let published = expectation(description: "one offer")
        let recorder = Recorder { event in
            switch event {
            case .videoUnavailable: unavailable.fulfill()
            case .localDescription: published.fulfill()
            default: break
            }
        }
        // Granted when the toggle asks, gone when capture is about to start.
        let grants = Counter()
        let engine = WebRtcAudioEngine(relay: nil,
                                       microphoneGranted: { true },
                                       cameraAuthorized: { grants.next() == 1 },
                                       events: { recorder.record($0) })
        defer { Self.close(engine, in: self) }

        engine.createOffer()
        wait(for: [published], timeout: Self.timeout)
        try engine.setVideo(true)
        wait(for: [unavailable], timeout: Self.timeout)

        XCTAssertEqual(recorder.failures, [], "a camera failure is not a call failure")
        XCTAssertEqual(recorder.events.compactMap { event -> WebRtcAudioEngine.Failure? in
            guard case .videoUnavailable(let failure) = event else { return nil }
            return failure
        }, [.cameraPermission])
        // The call still has its one published description and nothing else.
        XCTAssertEqual(recorder.descriptions.count, 1)
    }

    /// The configuration of the two lanes, which is where every property of
    /// the description is decided (`WebRtcAudioEngine.java:244-251`).
    func testConfigurationIsRelayOnlyWithTheIssuedUrlsAndNeverCarriesStun() throws {
        let direct = WebRtcAudioEngine.configuration(relay: nil)
        XCTAssertEqual(direct.iceServers.count, 0)
        XCTAssertNotEqual(direct.iceTransportPolicy, .relay)

        let credential = try Self.relayCredential()
        let relay = WebRtcAudioEngine.configuration(relay: credential)
        XCTAssertEqual(relay.iceTransportPolicy, .relay)
        XCTAssertEqual(relay.iceServers.count, 1)
        let server = try XCTUnwrap(relay.iceServers.first)
        XCTAssertEqual(server.urlStrings, credential.urls)
        XCTAssertEqual(server.urlStrings.count, 2)
        XCTAssertTrue(server.urlStrings.allSatisfy { $0.hasPrefix("turn:") },
                      "no STUN server: this client never asks a third party where it lives")
        XCTAssertEqual(server.username, credential.username)
        XCTAssertEqual(server.credential, credential.password)

        for configuration in [direct, relay] {
            XCTAssertEqual(configuration.sdpSemantics, .unifiedPlan)
            XCTAssertEqual(configuration.bundlePolicy, .maxBundle)
            XCTAssertEqual(configuration.rtcpMuxPolicy, .require)
            XCTAssertEqual(configuration.tcpCandidatePolicy, .disabled)
            XCTAssertEqual(configuration.continualGatheringPolicy, .gatherOnce)
            XCTAssertEqual(configuration.iceCandidatePoolSize, 0)
        }
    }

    /// The codec preferences are the whole codec policy: H.264 first, VP8 as
    /// the mandatory fallback, the helper formats after them, and nothing the
    /// core does not whitelist. They are applied to a transceiver, never to
    /// finished SDP text.
    func testVideoPreferencesAreH264ThenVp8ThenHelpersAndNothingElse() throws {
        WebRtcAudioEngine.prepareProcess()
        let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                               decoderFactory: RTCDefaultVideoDecoderFactory())
        let preferences = try WebRtcAudioEngine.videoPreferences(of: factory)
        let names = preferences.map { $0.mimeType.lowercased() }

        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(names.contains("video/h264"), "H.264 first, owner decision 2026-09-11")
        XCTAssertTrue(names.contains("video/vp8"), "VP8 is the mandatory fallback")
        XCTAssertFalse(names.contains("video/vp9"))
        XCTAssertFalse(names.contains("video/av1"))
        let allowed = ["video/h264", "video/vp8", "video/rtx", "video/red", "video/ulpfec",
                       "video/flexfec-03"]
        XCTAssertTrue(names.allSatisfy(allowed.contains), "outside the whitelist: \(names)")
        let firstVp8 = try XCTUnwrap(names.firstIndex(of: "video/vp8"))
        XCTAssertTrue(names.prefix(firstVp8).allSatisfy { $0 == "video/h264" })
        let helpers = ["video/rtx", "video/red", "video/ulpfec", "video/flexfec-03"]
        let firstHelper = names.firstIndex { helpers.contains($0) } ?? names.count
        XCTAssertTrue(names.suffix(from: firstHelper).allSatisfy(helpers.contains))
    }

    // MARK: - The engine under test

    private static let timeout: TimeInterval = 30

    private static func engine(relay: VoiceRelayConfig?,
                               recorder: Recorder,
                               camera: Bool = false) -> WebRtcAudioEngine {
        WebRtcAudioEngine(relay: relay,
                          microphoneGranted: { true },
                          cameraAuthorized: { camera },
                          events: { recorder.record($0) })
    }

    /// Closing is asynchronous and releases the camera, the tracks and the
    /// connection; a test that returned before it finished would leave them
    /// to the next one.
    private static func close(_ engine: WebRtcAudioEngine, in test: XCTestCase) {
        let released = test.expectation(description: "engine closed")
        engine.close { released.fulfill() }
        test.wait(for: [released], timeout: timeout)
    }

    /// Everything one engine reported, in order.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [WebRtcAudioEngine.Event] = []
        private let notify: @Sendable (WebRtcAudioEngine.Event) -> Void

        init(_ notify: @escaping @Sendable (WebRtcAudioEngine.Event) -> Void = { _ in }) {
            self.notify = notify
        }

        func record(_ event: WebRtcAudioEngine.Event) {
            lock.lock()
            stored.append(event)
            lock.unlock()
            notify(event)
        }

        var events: [WebRtcAudioEngine.Event] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var descriptions: [(WebRtcAudioEngine.DescriptionKind, String)] {
            events.compactMap { event in
                guard case .localDescription(let kind, let sdp) = event else { return nil }
                return (kind, sdp)
            }
        }

        var failures: [WebRtcAudioEngine.Failure] {
            events.compactMap { event in
                guard case .failed(let failure) = event else { return nil }
                return failure
            }
        }
    }

    /// How many times a permission probe has been asked, so that a test can
    /// answer differently the second time — the permission revoked between
    /// the toggle and the capture.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
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

    // MARK: - The fake candidate feed

    /// `203.0.113.7` is RFC 5737 documentation space, and the relay this
    /// client would really use is the realm's own IPv4 host.
    private static let relayCandidate =
        "a=candidate:3843983744 1 udp 41885439 203.0.113.7 34781 typ relay raddr 0.0.0.0 rport 0 generation 0"
    private static let secondRelayCandidate =
        "a=candidate:3843983750 1 udp 41885438 203.0.113.7 34782 typ relay raddr 0.0.0.0 rport 0 generation 0"
    private static let hostCandidate = host(port: 51234)
    private static let serverReflexiveCandidate =
        "a=candidate:842163049 1 udp 1686052607 198.51.100.4 51234 typ srflx raddr 192.0.2.10 rport 51234 generation 0"
    private static let relayOverTcpCandidate =
        "a=candidate:3843983745 1 tcp 41885439 203.0.113.7 34781 typ relay raddr 0.0.0.0 rport 0 generation 0"
    private static let relayOnSecondComponent =
        "a=candidate:3843983746 2 udp 41885439 203.0.113.7 34781 typ relay raddr 0.0.0.0 rport 0 generation 0"
    private static let relayOverIPv6Candidate =
        "a=candidate:3843983747 1 udp 41885439 2001:db8::1 34781 typ relay raddr :: rport 0 generation 0"
    private static let relayWithoutAddress =
        "a=candidate:3843983748 1 udp 41885439 0.0.0.0 34781 typ relay raddr 0.0.0.0 rport 0 generation 0"
    private static let relayWithoutPort =
        "a=candidate:3843983749 1 udp 41885439 203.0.113.7 0 typ relay raddr 0.0.0.0 rport 0 generation 0"

    private static func host(port: Int) -> String {
        "a=candidate:1510613869 1 udp 2122260223 192.0.2.10 \(port) typ host generation 0"
    }

    /// The DTLS fingerprint of the fake feed: 32 colon-separated bytes, the
    /// only form `SdpExtract` and the core accept.
    private static let fingerprint =
        (1...32).map { String(format: "%02X", $0) }.joined(separator: ":")

    /// One synthetic call-v2 description: `m=audio` then `m=video`, bundled on
    /// the audio section's transport, with the candidate lines the test wrote.
    ///
    /// The defaults are the shape libwebrtc produces and the core accepts; a
    /// named argument breaks exactly one rule, so a refusal names the rule it
    /// broke.
    private static func sdp(candidates: [String],
                                    padding: Int = 0,
                                    video: Bool = true,
                                    direction: String = "a=sendrecv",
                                    crypto: Bool = false,
                                    videoRtpmap: [String] = ["96 H264/90000", "97 rtx/90000"],
                                    videoPayloads: [String]? = nil) -> String {
        var lines = [
            "v=0",
            "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=group:BUNDLE 0 1",
            "a=msid-semantic: WMS voice",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "c=IN IP4 0.0.0.0",
            "a=rtcp:9 IN IP4 0.0.0.0",
        ]
        lines.append(contentsOf: candidates)
        lines.append(contentsOf: [
            "a=ice-ufrag:Uf1G",
            "a=ice-pwd:0123456789abcdef01234567",
            "a=fingerprint:sha-256 \(fingerprint)",
            "a=setup:actpass",
            "a=mid:0",
            direction,
            "a=rtcp-mux",
            "a=rtpmap:111 opus/48000/2",
        ])
        if crypto {
            lines.append("a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:" + String(repeating: "A", count: 40))
        }
        if video {
            let payloads = videoPayloads ?? videoRtpmap.map { String($0.prefix(while: { $0 != " " })) }
            lines.append(contentsOf: [
                "m=video 0 UDP/TLS/RTP/SAVPF " + payloads.joined(separator: " "),
                "c=IN IP4 0.0.0.0",
                "a=ice-ufrag:Uf1G",
                "a=ice-pwd:0123456789abcdef01234567",
                "a=fingerprint:sha-256 \(fingerprint)",
                "a=setup:actpass",
                "a=mid:1",
                "a=sendrecv",
                "a=rtcp-mux",
            ])
            lines.append(contentsOf: videoRtpmap.map { "a=rtpmap:\($0)" })
        }
        if padding > 0 {
            lines.append("a=x-pad:" + String(repeating: "A", count: padding))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// One validated relay credential on a loopback alias, so that a
    /// relay-only engine has somewhere to dial that nothing answers. The
    /// document is the issuer's own shape (`voice-turn-v1.md`); the credential
    /// is a constant of this test and grants nothing anywhere.
    private static func relayCredential() throws -> VoiceRelayConfig {
        let host = "127.0.0.22"
        let wall = Int64(Date().timeIntervalSince1970 * 1000)
        let expires = (wall + 1_100_000) / 1000
        let body = """
        {"v":1,"urls":["turn:\(host):34781?transport=udp","turn:\(host):34781?transport=tcp"],\
        "username":"\(expires):\(String(repeating: "a", count: 32))",\
        "credential":"\(String(repeating: "A", count: 27))=","expires":\(expires),"ttl":1200}
        """
        return try VoiceRelayConfig.parse(Array(body.utf8),
                                          realm: "https://\(host):38443",
                                          wallMilliseconds: wall,
                                          monotonicNanoseconds: Int64(DispatchTime.now().uptimeNanoseconds))
    }
}
