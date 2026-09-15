import Foundation
import ParanoidKit
import XCTest

/// `VoiceRelayConfig` against the Android relay-metadata smoke.
///
/// The vectors are not written here: `clients/ios/test/fixtures/voice-relay-vectors.json`
/// is a transcription of `clients/android/test/VoiceRelaySmoke.java`, every
/// `String.replace` of it carried over literally, and each vector names the
/// line of that file it comes from. So the two clients refuse the same 49
/// documents rather than each refusing its own 49, and a future change to
/// either parser has one place to disagree with.
///
/// The Java smoke only counts its rejections. These tests also compare the
/// reason, because "rejected" and "rejected for the reason the protocol gives"
/// are different claims: a document refused as malformed JSON when it should
/// have been refused for a relay host that is not the retained realm would
/// pass a count and hide a hole.
///
/// Nothing here reaches a network, a relay or a clock: both clocks are
/// arguments, and the credential in the fixture is Base64 of twenty zero
/// bytes — the canonical encoding of a 20-byte HMAC, never an issued one.
final class VoiceRelayConfigTests: XCTestCase {
    // MARK: - The fixture

    private struct Vectors: Decodable {
        struct Body: Decodable {
            let kind: String
            let value: String?
            let count: Int?
        }

        struct Constants: Decodable {
            let realm: String
            let wallMillis: Int64
            let monoNanos: Int64
            let expiresSeconds: Int64
            let username: String
            let credential: String
            let urls: [String]
            let body: String
        }

        struct Accepted: Decodable {
            let sourceLine: Int
            let note: String
            let realm: String?
            let wallMillis: Int64?
            let monoNanos: Int64?
            let usableAtReceipt: Bool
            let body: Body
        }

        struct Rejected: Decodable {
            let sourceLine: Int
            let note: String
            let reason: String
            let realm: String?
            let wallMillis: Int64?
            let monoNanos: Int64?
            let body: Body
        }

        struct Probe: Decodable {
            let sourceLine: Int
            let note: String
            let wallMillis: Int64
            let monoNanos: Int64
            let expected: Bool
        }

        let source: String
        let constants: Constants
        let accepted: [Accepted]
        let rejected: [Rejected]
        let usableProbes: [Probe]
    }

    private static let vectors: Vectors = {
        var url = URL(fileURLWithPath: #filePath)
        // .../clients/ios/ParanoidKit/Tests/ParanoidKitTests/<this file>
        for _ in 0..<6 { url.deleteLastPathComponent() }
        url.appendPathComponent("clients/ios/test/fixtures/voice-relay-vectors.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // A missing or unreadable fixture must fail the run loudly, not be
        // skipped: an empty vector list would otherwise pass every test here.
        return try! decoder.decode(Vectors.self, from: Data(contentsOf: url))
    }()

    /// The body a vector hands to the parser, in the four forms the Java smoke
    /// uses: text, raw bytes, a run of zero bytes, and no body at all.
    private func bytes(_ body: Vectors.Body, line: UInt = #line) throws -> [UInt8]? {
        switch body.kind {
        case "text":
            return Array(try XCTUnwrap(body.value, "text body without a value", line: line).utf8)
        case "hex":
            let text = Array(try XCTUnwrap(body.value, "hex body without a value", line: line))
            XCTAssertEqual(text.count % 2, 0, "hex body of odd length", line: line)
            return stride(from: 0, to: text.count, by: 2).compactMap {
                UInt8(String(text[$0...$0 + 1]), radix: 16)
            }
        case "zeros":
            return [UInt8](repeating: 0,
                           count: try XCTUnwrap(body.count, "zeros body without a count", line: line))
        case "none":
            return nil
        default:
            XCTFail("unknown body kind \(body.kind)", line: line)
            return nil
        }
    }

    // MARK: - The transcription itself

    func testTheFixtureIsTheAndroidSmokeAndNothingElse() {
        let vectors = Self.vectors
        XCTAssertEqual(vectors.source, "clients/android/test/VoiceRelaySmoke.java")
        // VoiceRelaySmoke.java calls reject() 49 times: 18 before its first
        // comment, 17 after it, 11 realms in one loop, the two lifetime
        // boundaries of lines 70-71 and the overflowing expiry of line 77.
        XCTAssertEqual(vectors.rejected.count, 49)
        XCTAssertEqual(vectors.accepted.count, 6)
        XCTAssertEqual(vectors.usableProbes.count, 9)
        XCTAssertEqual(vectors.constants.realm, "https://127.0.0.1:38443")
        XCTAssertEqual(vectors.constants.expiresSeconds,
                       vectors.constants.wallMillis / 1000 + VoiceRelayConfig.requiredTtl)
        XCTAssertEqual(vectors.constants.urls, [
            "turn:127.0.0.1:\(VoiceRelayConfig.relayPort)?transport=udp",
            "turn:127.0.0.1:\(VoiceRelayConfig.relayPort)?transport=tcp",
        ])
        XCTAssertEqual(vectors.constants.username, "\(vectors.constants.expiresSeconds):0123456789abcdef0123456789abcdef")
        // The fixture body is the one the constants describe.
        XCTAssertTrue(vectors.constants.body.contains("\"username\":\"\(vectors.constants.username)\""))
        XCTAssertTrue(vectors.constants.body.contains("\"credential\":\"\(vectors.constants.credential)\""))
        XCTAssertLessThanOrEqual(vectors.constants.body.utf8.count, VoiceRelayConfig.maximumMetadataBytes)
        // Every rejection names a reason `VoiceRelayError` can actually give.
        for vector in vectors.rejected {
            XCTAssertFalse(vector.reason.isEmpty, "line \(vector.sourceLine): \(vector.note)")
        }
    }

    // MARK: - The valid document

    func testEveryAcceptedVectorIsAcceptedAndKeepsWhatTheIssuerSent() throws {
        let constants = Self.vectors.constants
        for vector in Self.vectors.accepted {
            let context = "VoiceRelaySmoke.java:\(vector.sourceLine) — \(vector.note)"
            let wall = vector.wallMillis ?? constants.wallMillis
            let mono = vector.monoNanos ?? constants.monoNanos
            let config = try VoiceRelayConfig.parse(try bytes(vector.body),
                                                    realm: vector.realm ?? constants.realm,
                                                    wallMilliseconds: wall,
                                                    monotonicNanoseconds: mono)
            XCTAssertEqual(config.urls, constants.urls, context)
            XCTAssertEqual(config.username, constants.username, context)
            XCTAssertEqual(config.password, constants.credential, context)
            XCTAssertEqual(config.usable(wallMilliseconds: wall, monotonicNanoseconds: mono),
                           vector.usableAtReceipt, context)
        }
    }

    func testTheReturnedUrlsAreTheTwoCanonicalFormsInOrder() throws {
        let config = try Self.canonicalConfig()
        XCTAssertEqual(config.urls.count, 2)
        XCTAssertTrue(config.urls[0].hasSuffix("?transport=udp"))
        XCTAssertTrue(config.urls[1].hasSuffix("?transport=tcp"))
        // Android hands back `Collections.unmodifiableList`
        // (`VoiceRelayConfig.java:30`) so a caller cannot move media
        // elsewhere; in Swift the array is a value, so a caller mutates its
        // own copy and the configuration is untouched.
        var copy = config.urls
        copy[0] = "turn:192.0.2.1:34781?transport=udp"
        XCTAssertEqual(config.urls, Self.vectors.constants.urls)
    }

    // MARK: - The 49 negatives

    func testEveryRejectedVectorIsRejectedForItsOwnReason() throws {
        let constants = Self.vectors.constants
        var rejected = 0
        for vector in Self.vectors.rejected {
            let context = "VoiceRelaySmoke.java:\(vector.sourceLine) — \(vector.note)"
            let body = try bytes(vector.body)
            do {
                _ = try VoiceRelayConfig.parse(body,
                                               realm: vector.realm ?? constants.realm,
                                               wallMilliseconds: vector.wallMillis ?? constants.wallMillis,
                                               monotonicNanoseconds: vector.monoNanos ?? constants.monoNanos)
                XCTFail("invalid issuer metadata accepted: \(context)")
            } catch let error as VoiceRelayError {
                XCTAssertEqual(error.description, vector.reason, context)
                rejected += 1
            }
        }
        XCTAssertEqual(rejected, 49, "every vector must be refused by VoiceRelayError, not by another error")
    }

    // MARK: - The admission window

    func testUsableSpendsTheWindowOnBothClocks() throws {
        let config = try Self.canonicalConfig()
        for probe in Self.vectors.usableProbes {
            XCTAssertEqual(config.usable(wallMilliseconds: probe.wallMillis,
                                         monotonicNanoseconds: probe.monoNanos),
                           probe.expected,
                           "VoiceRelaySmoke.java:\(probe.sourceLine) — \(probe.note)")
        }
    }

    /// The window the smoke walks, stated once in milliseconds: a document
    /// received with the full 1 200 000 ms of life may still open media 200 s
    /// later, and not one millisecond later than that
    /// (`VoiceRelayConfig.java:36,44-54`).
    func testTheAdmissionBudgetIsWhatTheReceiptLeftOverTheMinimum() throws {
        let constants = Self.vectors.constants
        let config = try Self.canonicalConfig()
        let budget = VoiceRelayConfig.maximumRemainingMilliseconds
            - VoiceRelayConfig.minimumRemainingMilliseconds
        XCTAssertEqual(budget, 205_000)
        // This receipt had 1 200 000 ms of life, so 200 000 ms of it may be spent.
        let spendable: Int64 = 200_000
        XCTAssertTrue(config.usable(wallMilliseconds: constants.wallMillis + spendable,
                                    monotonicNanoseconds: constants.monoNanos + spendable * 1_000_000))
        XCTAssertFalse(config.usable(wallMilliseconds: constants.wallMillis + spendable,
                                     monotonicNanoseconds: constants.monoNanos + spendable * 1_000_000 + 1))
    }

    // MARK: - Volatility

    func testTheDescriptionNeverCarriesTheCredentials() throws {
        let constants = Self.vectors.constants
        let config = try Self.canonicalConfig()
        for rendered in [config.description, config.debugDescription, "\(config)"] {
            XCTAssertEqual(rendered, "VoiceRelayConfig[redacted]")
            XCTAssertFalse(rendered.contains(constants.username))
            XCTAssertFalse(rendered.contains(constants.credential))
        }
    }

    // MARK: - Bounds the Java smoke states without a vector

    /// `VoiceRelayConfig.java:60` is a byte bound, and trailing whitespace is
    /// legal JSON, so the last accepted document and the first refused one are
    /// one space apart.
    func testTheSizeBoundIsMeasuredOnBytes() throws {
        let constants = Self.vectors.constants
        let body = Array(constants.body.utf8)
        let padding = VoiceRelayConfig.maximumMetadataBytes - body.count
        XCTAssertGreaterThan(padding, 0)
        let padded = body + [UInt8](repeating: UInt8(ascii: " "), count: padding)
        XCTAssertEqual(padded.count, VoiceRelayConfig.maximumMetadataBytes)
        _ = try VoiceRelayConfig.parse(padded, realm: constants.realm,
                                       wallMilliseconds: constants.wallMillis,
                                       monotonicNanoseconds: constants.monoNanos)
        XCTAssertEqual(Self.failure(padded + [UInt8(ascii: " ")]), .metadataSize)
        XCTAssertEqual(Self.failure([]), .metadataSize)
    }

    /// `VoiceRelayConfig.java:106` refuses a retained origin longer than 64
    /// characters before it looks at its shape at all.
    func testTheRealmLengthBoundComesBeforeTheShape() throws {
        let constants = Self.vectors.constants
        let body = Array(constants.body.utf8)
        let padded = "https://127.0.0.1:38443" + String(repeating: "0", count: 42)
        XCTAssertEqual(padded.count, 65)
        XCTAssertEqual(Self.failure(body, realm: padded), .realm)
    }

    // MARK: - Helpers

    private static func canonicalConfig() throws -> VoiceRelayConfig {
        try VoiceRelayConfig.parse(Array(vectors.constants.body.utf8),
                                   realm: vectors.constants.realm,
                                   wallMilliseconds: vectors.constants.wallMillis,
                                   monotonicNanoseconds: vectors.constants.monoNanos)
    }

    private static func failure(_ body: [UInt8]?, realm: String? = nil,
                                wallMilliseconds: Int64? = nil) -> VoiceRelayError? {
        do {
            _ = try VoiceRelayConfig.parse(body, realm: realm ?? vectors.constants.realm,
                                           wallMilliseconds: wallMilliseconds ?? vectors.constants.wallMillis,
                                           monotonicNanoseconds: vectors.constants.monoNanos)
            return nil
        } catch let error as VoiceRelayError {
            return error
        } catch {
            return nil
        }
    }
}
