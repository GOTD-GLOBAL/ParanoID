import Foundation
import ParanoidCoreFFI
@testable import ParanoidKit
import XCTest

/// Public/synthetic fixtures only; positive vectors call the real Rust library.
/// REQ-CLIENT-001 / REQ-ID-002/003, RFC-0030: no network or persistent identity.
final class DevnetBridgeTests: XCTestCase {
    // Values below are public fixtures from bridge/tests/devnet.rs and
    // blockchain/solana/client/src/lib.rs, not application pins or wallet data.
    func testPublicThirtyTwoByteIdentityVectorUsesRustDerivation() throws {
        let reply = try DevnetBridge.command(
            request: #"{"op":"identity","entropy":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"#)
        XCTAssertEqual(reply.object["owner"] as? String,
                       "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx")
        XCTAssertNil(reply.object["entropy"])
    }

    func testPublicTwelveWordRecoveryAndExportUseRust() throws {
        let words = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"
        let recovered = try DevnetBridge.command(request: #"{"op":"recover","mnemonic":"\#(words)"}"#)
        XCTAssertEqual(recovered.object["entropy"] as? String, "AAAAAAAAAAAAAAAAAAAAAA==")
        let exported = try DevnetBridge.command(
            request: #"{"op":"export_mnemonic","entropy":"AAAAAAAAAAAAAAAAAAAAAA=="}"#)
        XCTAssertEqual(exported.object["mnemonic"] as? String, words)
    }

    func testPublicTwentyFourWordRecoveryAndExportUseRust() throws {
        let words = Array(repeating: "abandon", count: 23).joined(separator: " ") + " art"
        let recovered = try DevnetBridge.command(request: #"{"op":"recover","mnemonic":"\#(words)"}"#)
        XCTAssertEqual(recovered.object["entropy"] as? String,
                       "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        let exported = try DevnetBridge.command(
            request: #"{"op":"export_mnemonic","entropy":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}"#)
        XCTAssertEqual(exported.object["mnemonic"] as? String, words)
    }

    func testProgramInfoComesFromRust() throws {
        let reply = try DevnetBridge.command(request: #"{"op":"program_info"}"#)
        XCTAssertEqual(reply.object["program"] as? String, "C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas")
        XCTAssertEqual(reply.object["genesis"] as? String, "EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG")
        XCTAssertEqual(reply.object["rpc"] as? String, "https://api.devnet.solana.com")
        XCTAssertEqual(reply.object["sbf_size"] as? Int, 73800)
        XCTAssertNil(reply.object["error"])
    }

    func testExactByteLimitReachesRustUnchangedAndFreesOnce() throws {
        let valid = #"{"op":"program_info"}"#
        let request = valid + String(repeating: " ", count: 16384 - valid.utf8.count)
        XCTAssertEqual(request.utf8.count, 16384)
        let expected = try DevnetBridge.command(request: valid)
        var calls = 0
        var frees = 0
        let reply = try DevnetBridge.command(
            request: request,
            call: {
                calls += 1
                XCTAssertEqual(String(validatingCString: $0), request)
                return paranoid_devnet_command($0)
            },
            free: { frees += 1; paranoid_devnet_free($0) })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(frees, 1)
        XCTAssertEqual(reply.text, expected.text)
        XCTAssertEqual(reply.object as NSDictionary, expected.object as NSDictionary)
    }

    func testMultibyteLimitCountsUtf8RatherThanCharacters() {
        for (request, expected, expectedCalls) in [
            (String(repeating: "é", count: 8192), CoreError.rejected("invalid_request"), 1),
            (String(repeating: "é", count: 8192) + " ", .rejected("input_limit"), 0),
            (String(repeating: "😀", count: 4097), .rejected("input_limit"), 0),
        ] {
            XCTAssertLessThan(request.count, 16384)
            var calls = 0
            var frees = 0
            assertError(expected, try DevnetBridge.command(
                request: request,
                call: {
                    calls += 1
                    XCTAssertEqual(String(validatingCString: $0), request)
                    return paranoid_devnet_command($0)
                },
                free: { frees += 1; paranoid_devnet_free($0) }))
            XCTAssertEqual(calls, expectedCalls)
            XCTAssertEqual(frees, expectedCalls)
        }
    }

    func testInvalidEntropyPreservesRustErrorCode() {
        for entropy in ["AAAA", "not base64", ""] {
            assertError(.rejected("invalid_entropy"), try DevnetBridge.command(
                request: #"{"op":"identity","entropy":"\#(entropy)"}"#))
        }
    }

    func testMalformedRequestsAndExtraFieldsPreserveRustErrorCode() {
        for request in ["", "not json", "{}", "[]", #"{"op":"unknown"}"#,
                        #"{"op":"program_info","extra":true}"#,
                        #"{"op":"identity","op":"recover","entropy":"AAAA"}"#] {
            assertError(.rejected("invalid_request"), try DevnetBridge.command(request: request))
        }
    }

    func testVerbatimReplyAndDecodedValuesSurviveNativeFree() throws {
        // Synthetic noncanonical JSON checks copying, not a stubbed Rust vector.
        let value = String(repeating: "é😀", count: 40)
        let text = " \n{ \"z\" : \"\(value)\", \"a\" : 1, \"nested\" : { \"error\" : \"data\" } }\t"
        let fixture = ReplyFixture(text)
        let reply = try fixture.command()
        fixture.assertReleased()
        XCTAssertEqual(Array(reply.text.utf8), Array(text.utf8))
        XCTAssertEqual(reply.object["z"] as? String, value)
        XCTAssertEqual(reply.object["a"] as? Int, 1)
        XCTAssertEqual((reply.object["nested"] as? [String: Any])?["error"] as? String, "data")
    }

    func testNativeStringErrorsArePreservedAndFreedOnce() {
        for code in ["invalid_request", "native_failure", "future_rust_error", ""] {
            let fixture = ReplyFixture(#"{"error":"\#(code)"}"#)
            assertError(.rejected(code), try fixture.command())
            fixture.assertReleased()
        }
    }

    func testInvalidNativeUtf8IsNotLossilyRepairedAndIsFreedOnce() {
        // Invalid bytes inside a JSON string would be accepted after U+FFFD repair.
        let prefix = Array(#"{"value":""#.utf8)
        let suffix = Array(#""}"#.utf8)
        for invalid: [UInt8] in [[0xff], [0xc0, 0xaf], [0xed, 0xa0, 0x80], [0xe2, 0x82]] {
            let fixture = ReplyFixture(bytes: prefix + invalid + suffix)
            assertError(.nativeFailure, try fixture.command())
            fixture.assertReleased()
        }
    }

    func testNonStringNativeErrorIsNativeFailureAndFreedOnce() {
        for value in ["null", "1", "true", "[]", "{}"] {
            let fixture = ReplyFixture(#"{"error":\#(value)}"#)
            assertError(.nativeFailure, try fixture.command())
            fixture.assertReleased()
        }
    }

    func testNonObjectNativeJsonIsNativeFailureAndFreedOnce() {
        for text in ["[]", "[{}]", "null", "true", "42", #""text""#] {
            let fixture = ReplyFixture(text)
            assertError(.nativeFailure, try fixture.command())
            fixture.assertReleased()
        }
    }

    func testMalformedNativeJsonIsNativeFailureAndFreedOnce() {
        for text in ["", "not json", "{", "{} trailing", #"{"value":}"#] {
            let fixture = ReplyFixture(text)
            assertError(.nativeFailure, try fixture.command())
            fixture.assertReleased()
        }
    }

    func testNullReplyIsNativeFailureWithoutFree() {
        var calls = 0
        var frees = 0
        assertError(.nativeFailure, try DevnetBridge.command(
            request: #"{"op":"program_info"}"#,
            call: { _ in calls += 1; return nil },
            free: { _ in frees += 1 }))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(frees, 0)
    }

    func testOversizedRequestIsRefusedBeforeNativeCall() {
        let valid = #"{"op":"program_info"}"#
        let request = valid + String(repeating: " ", count: 16385 - valid.utf8.count)
        XCTAssertEqual(request.utf8.count, 16385)
        var calls = 0
        var frees = 0
        assertError(.rejected("input_limit"), try DevnetBridge.command(
            request: request,
            call: { calls += 1; return paranoid_devnet_command($0) },
            free: { frees += 1; paranoid_devnet_free($0) }))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(frees, 0)
    }

    func testEmbeddedNulIsRefusedBeforeNativeCall() {
        for request in ["\0", #"{"op":"program_info"}"# + "\0" + "ignored"] {
            var calls = 0
            var frees = 0
            assertError(.rejected("invalid_request"), try DevnetBridge.command(
                request: request,
                call: { calls += 1; return paranoid_devnet_command($0) },
                free: { frees += 1; paranoid_devnet_free($0) }))
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(frees, 0)
        }
    }

    /// Native contract faults need explicit allocations, never live Rust replies.
    /// The free callback checks unmodified bytes, erases and really deallocates.
    private final class ReplyFixture {
        private let original: [CChar]
        private var allocation: UnsafeMutablePointer<CChar>?
        private(set) var calls = 0
        private(set) var frees = 0

        init(bytes: [UInt8]) {
            precondition(!bytes.contains(0))
            original = bytes.map { CChar(bitPattern: $0) } + [0]
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: original.count)
            buffer.initialize(from: original, count: original.count)
            allocation = buffer
        }

        convenience init(_ text: String) { self.init(bytes: Array(text.utf8)) }

        func command() throws -> DevnetReply {
            try DevnetBridge.command(request: #"{"op":"program_info"}"#,
                                     call: { _ in self.calls += 1; return self.allocation },
                                     free: { self.free($0) })
        }

        private func free(_ returned: UnsafeMutablePointer<CChar>) {
            frees += 1
            XCTAssertEqual(returned, allocation)
            guard let buffer = allocation, buffer == returned else { return }
            XCTAssertEqual(Array(UnsafeBufferPointer(start: buffer, count: original.count)), original)
            release()
        }

        private func release() {
            guard let buffer = allocation else { return }
            buffer.update(repeating: 0, count: original.count)
            buffer.deinitialize(count: original.count)
            buffer.deallocate()
            allocation = nil
        }

        func assertReleased(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(calls, 1, file: file, line: line)
            XCTAssertEqual(frees, 1, file: file, line: line)
            XCTAssertNil(allocation, file: file, line: line)
        }

        // Clean up a failing test too, without counting it as the adapter's free.
        deinit { release() }
    }

    private func assertError(_ expected: CoreError,
                             _ body: @autoclosure () throws -> DevnetReply,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? CoreError, expected, file: file, line: line)
        }
    }

    func testInvalidMnemonicPreservesRustErrorCode() {
        assertError(.rejected("invalid_mnemonic"), try DevnetBridge.command(
            request: #"{"op":"recover","mnemonic":"abandon abandon"}"#))
    }

    func testPublicIdentityVectorUsesRustDerivation() throws {
        let reply = try DevnetBridge.command(
            request: #"{"op":"identity","entropy":"AAAAAAAAAAAAAAAAAAAAAA=="}"#)
        XCTAssertEqual(reply.object["owner"] as? String,
                       "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk")
        XCTAssertNil(reply.object["entropy"])
        let decoded = try JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? NSDictionary
        XCTAssertEqual(decoded, reply.object as NSDictionary)
    }
}
