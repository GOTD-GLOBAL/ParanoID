import Foundation
import ParanoidKit
import XCTest

/// Host-side checks of `SdpExtract` against the rules the core applies to a
/// call-v2 description (`clients/core/src/voice_v1.rs:103-256`).
///
/// The fixture is the shape of the core's own vector
/// (`clients/core/tests/voice_calls.rs:176`): bundled `m=audio` then
/// `m=video`, one `a=sendrecv` each, the transport attributes carried once by
/// the audio section. The simulator spike
/// (`App/ParanoIDTests/SdpCompatibilityTests.swift`) measures the real
/// libwebrtc description against the real core; this file pins the reader
/// alone, including the placements libwebrtc may choose — the same four
/// attributes repeated in the video section, or hoisted to session level —
/// and the ones the core refuses.
final class SdpExtractTests: XCTestCase {
    private static let fingerprintBytes = (0..<32).map { String(format: "%02X", $0) }
    private static let fingerprintLine = "a=fingerprint:sha-256 " + fingerprintBytes.joined(separator: ":")
    private static let fingerprint = fingerprintBytes.joined().lowercased()
    private static let ufrag = "abcd1234"
    private static let password = "abcdefghijklmnopqrstuvwx"
    private static let transport = [
        "a=ice-ufrag:\(ufrag)", "a=ice-pwd:\(password)", fingerprintLine, "a=setup:actpass",
    ]
    private static let session = ["v=0", "o=- 1 2 IN IP4 127.0.0.1", "s=-", "t=0 0", "a=group:BUNDLE 0 1"]
    private static let audio = [
        "m=audio 9 UDP/TLS/RTP/SAVPF 111", "c=IN IP4 0.0.0.0", "a=mid:0", "a=sendrecv", "a=rtcp-mux",
        "a=rtpmap:111 opus/48000/2", "a=candidate:1 1 udp 2122260223 127.0.0.1 40000 typ host",
    ]
    private static let video = [
        "m=video 0 UDP/TLS/RTP/SAVPF 96 97 98", "c=IN IP4 0.0.0.0", "a=mid:1", "a=bundle-only",
        "a=sendrecv", "a=rtcp-mux", "a=rtpmap:96 H264/90000", "a=rtpmap:97 VP8/90000",
        "a=rtpmap:98 rtx/90000", "a=fmtp:98 apt=97",
    ]

    /// One description, CRLF-terminated as SDP is, with the four transport
    /// attributes placed where the argument says.
    private static func sdp(sessionLevel: [String] = [], inAudio: [String] = transport,
                            inVideo: [String] = []) -> String {
        (session + sessionLevel + audio + inAudio + video + inVideo)
            .map { $0 + "\r\n" }.joined()
    }

    // MARK: what the reader hands to the call body

    func testReadsTheTransportContextAndTheSurveyOfBothSections() throws {
        let text = Self.sdp()
        let extract = try XCTUnwrap(SdpExtract(sdp: text))
        XCTAssertEqual(extract.fingerprint, Self.fingerprint)
        XCTAssertEqual(extract.iceUfrag, Self.ufrag)
        XCTAssertEqual(extract.icePwd, Self.password)
        XCTAssertEqual(extract.setup, "actpass")
        XCTAssertEqual(extract.byteCount, text.utf8.count)
        // `str::lines()` yields no empty line for the final CRLF, and the
        // count the core limits to 512 excludes `v=0`.
        XCTAssertEqual(extract.lineCount, Self.session.count + Self.audio.count + Self.transport.count
            + Self.video.count - 1)
        XCTAssertTrue(extract.fitsFrameBudget)
        XCTAssertEqual(SdpExtract.maxSdpBytes, 9000)
        XCTAssertEqual(extract.candidateCount, 1)
        XCTAssertEqual(extract.cryptoCount, 0)
        XCTAssertEqual(extract.blockedDirectionCount, 0)
        XCTAssertEqual(extract.mediaKinds, ["audio", "video"])

        let audio = try XCTUnwrap(extract.sections.first)
        XCTAssertEqual(audio.port, 9)
        XCTAssertEqual(audio.transport, "UDP/TLS/RTP/SAVPF")
        XCTAssertEqual(audio.payloadTypes, ["111"])
        XCTAssertEqual(audio.codecs, ["opus/48000/2"])
        XCTAssertEqual(audio.sendrecvCount, 1)
        XCTAssertEqual(audio.rtcpMuxCount, 1)
        XCTAssertEqual(audio.candidateCount, 1)
        XCTAssertTrue(audio.declaresEveryMapping)

        let video = try XCTUnwrap(extract.sections.last)
        // A bundle-only video section may advertise port 0.
        XCTAssertEqual(video.port, 0)
        XCTAssertEqual(video.payloadTypes, ["96", "97", "98"])
        XCTAssertEqual(video.codecs, ["h264/90000", "vp8/90000", "rtx/90000"])
        XCTAssertEqual(video.rtpmap.first, "a=rtpmap:96 H264/90000")
        XCTAssertEqual(video.sendrecvCount, 1)
        XCTAssertEqual(video.candidateCount, 0)
        XCTAssertTrue(video.declaresEveryMapping)
        XCTAssertEqual(extract.rtpmap.count, 4)
    }

    // MARK: where the four attributes may sit (voice_v1.rs:236-242)

    func testAcceptsTheAttributesRepeatedInTheVideoSectionAndAtSessionLevel() throws {
        for text in [Self.sdp(inVideo: Self.transport), Self.sdp(sessionLevel: Self.transport, inAudio: [])] {
            let extract = try XCTUnwrap(SdpExtract(sdp: text))
            XCTAssertEqual(extract.fingerprint, Self.fingerprint)
            XCTAssertEqual(extract.iceUfrag, Self.ufrag)
            XCTAssertEqual(extract.icePwd, Self.password)
            XCTAssertEqual(extract.setup, "actpass")
        }
    }

    func testRefusesASecondTransportContext() {
        // Session level plus the audio section is two contexts, not one.
        XCTAssertNil(SdpExtract(sdp: Self.sdp(sessionLevel: Self.transport)))
        // Twice in the same section is the duplicate the core refuses too.
        XCTAssertNil(SdpExtract(sdp: Self.sdp(inAudio: Self.transport + Self.transport)))
        // None at all: nothing to put in the body.
        XCTAssertNil(SdpExtract(sdp: Self.sdp(inAudio: [])))
    }

    func testRefusesSectionsThatDisagree() {
        for conflict in ["a=ice-ufrag:other123", "a=ice-pwd:zyxwvutsrqponmlkjihgfe",
                         "a=setup:passive", "a=fingerprint:sha-256 " + (0..<32)
                             .map { String(format: "%02X", $0 + 1) }.joined(separator: ":")] {
            XCTAssertNil(SdpExtract(sdp: Self.sdp(inVideo: [conflict])),
                         "a second, different \(conflict.prefix(12)) must not resolve")
        }
    }

    func testRefusesWhatIsNotASha256FingerprintOrNotAnSdp() {
        let shortened = Self.fingerprintLine.replacingOccurrences(of: ":1F", with: "")
        for line in ["a=fingerprint:sha-1 AB:CD", shortened, "a=fingerprint:sha-256 ZZ:" + Self.fingerprintBytes
            .dropFirst().joined(separator: ":")] {
            XCTAssertNil(SdpExtract(sdp: Self.sdp(inAudio: [line] + Self.transport.dropLast(2)
                + ["a=setup:actpass"])))
        }
        XCTAssertNil(SdpExtract(sdp: "o=- 1 2 IN IP4 127.0.0.1\r\n"), "an SDP begins with v=0")
        XCTAssertNil(SdpExtract(sdp: ""))
    }

    // MARK: the survey the caller checks before the core is asked

    func testCountsTheLinesTheCoreRefuses() throws {
        let text = Self.sdp(inVideo: ["a=recvonly", "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:x",
                                      "a=candidate:2 1 udp 2122260222 127.0.0.1 40001 typ host"])
        let extract = try XCTUnwrap(SdpExtract(sdp: text))
        XCTAssertEqual(extract.blockedDirectionCount, 1)
        XCTAssertEqual(extract.cryptoCount, 1)
        XCTAssertEqual(extract.candidateCount, 2)
        XCTAssertEqual(extract.sections.last?.candidateCount, 1)
    }

    func testSpotsAMappingTheMediaLineDoesNotDeclare() throws {
        let text = Self.sdp().replacingOccurrences(of: "m=video 0 UDP/TLS/RTP/SAVPF 96 97 98",
                                                   with: "m=video 0 UDP/TLS/RTP/SAVPF 96 97")
        let extract = try XCTUnwrap(SdpExtract(sdp: text))
        XCTAssertTrue(extract.sections[0].declaresEveryMapping)
        XCTAssertFalse(extract.sections[1].declaresEveryMapping)
    }

    func testMeasuresTheDescriptionAgainstTheFrameCap() throws {
        let padding = "a=x:" + String(repeating: "p", count: SdpExtract.maxSdpBytes)
        let extract = try XCTUnwrap(SdpExtract(sdp: Self.sdp(inVideo: [padding])))
        XCTAssertGreaterThan(extract.byteCount, SdpExtract.maxSdpBytes)
        XCTAssertFalse(extract.fitsFrameBudget, "the frame carries less than the core's own 12288-byte limit")
    }

    /// The public line split is the one `str::lines()` performs on the core
    /// side, cut on UTF-8 bytes because Swift folds CRLF into one `Character`.
    func testLinesAreCutLikeRustStrLines() {
        XCTAssertEqual(SdpExtract.lines(of: "v=0\r\na=b\n\r\n"), ["v=0", "a=b", "", ""])
        XCTAssertEqual(SdpExtract.lines(of: "v=0"), ["v=0"])
    }
}
