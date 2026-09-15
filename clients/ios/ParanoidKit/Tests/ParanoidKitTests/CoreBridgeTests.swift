import Foundation
import ParanoidKit
import XCTest

/// Host-side checks of the Swift adapter over the C-ABI bridge: the same
/// `create_identity` -> `upgrade_v2` path the Android client takes before
/// its first network request (`SelfServiceClient.java:80-84`), the error
/// mapping of `nativeCall` (`:55-61`) and the verbatim snapshot span that
/// replaces the `org.json` state comparison (`:73-76`).
final class CoreBridgeTests: XCTestCase {
    private static let realm = "https://127.0.0.2:38443"
    private static let pin = String(repeating: "a", count: 64)
    private static let createIdentity =
        #"{"op":"create_identity","realm":"\#(realm)","pin":"\#(pin)"}"#
    private static let upgradeV2 = #"{"op":"upgrade_v2"}"#
    private static let view = #"{"op":"view"}"#

    private func rejection(_ body: @autoclosure () throws -> CoreReply,
                           file: StaticString = #filePath, line: UInt = #line) -> CoreError? {
        var caught: CoreError?
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            caught = error as? CoreError
            XCTAssertNotNil(caught, "expected CoreError, got \(error)", file: file, line: line)
        }
        return caught
    }

    // MARK: CoreBridge.command

    func testCreateIdentityThenUpgradeV2ReachesVersion3() throws {
        let created = try CoreBridge.command(state: "", request: Self.createIdentity)
        XCTAssertEqual(created.stateVersion, 0)
        XCTAssertNil(created.object["error"])
        let legacy = try XCTUnwrap(created.state)

        let upgraded = try CoreBridge.command(state: legacy, request: Self.upgradeV2)
        XCTAssertEqual(upgraded.stateVersion, 3)
        let state = try XCTUnwrap(upgraded.state)
        XCTAssertNotEqual(state, legacy)

        // The reply carries the same identity the legacy snapshot was created with.
        let publicBundle = try XCTUnwrap(upgraded.object["public"] as? [String: Any])
        XCTAssertEqual(publicBundle["realm"] as? String, Self.realm)
        XCTAssertNotNil(upgraded.object["request"], "credential request must be present after upgrade")
    }

    func testViewOnGarbageStateIsRejectedAsInvalidState() {
        XCTAssertEqual(rejection(try CoreBridge.command(state: "garbage state", request: Self.view)),
                       .rejected("invalid_state"))
        XCTAssertEqual(rejection(try CoreBridge.command(state: "{\"version\":3}", request: Self.view)),
                       .rejected("invalid_state"))
    }

    func testMalformedRequestIsRejectedAsInvalidRequest() {
        XCTAssertEqual(rejection(try CoreBridge.command(state: "", request: "not json")),
                       .rejected("invalid_request"))
        XCTAssertEqual(rejection(try CoreBridge.command(state: "", request: Self.view)),
                       .rejected("invalid_state"))
    }

    func testRequestOverTheCoreLimitIsRejectedAsInputLimit() {
        let request = String(repeating: "a", count: 65537)
        XCTAssertEqual(rejection(try CoreBridge.command(state: "", request: request)),
                       .rejected("input_limit"))
    }

    func testInteriorNulIsRefusedBeforeTheCall() {
        XCTAssertEqual(rejection(try CoreBridge.command(state: "", request: "{\"op\":\"view\"}\0")),
                       .rejected("invalid_request"))
        XCTAssertEqual(rejection(try CoreBridge.command(state: "\0", request: Self.view)),
                       .rejected("invalid_request"))
    }

    // MARK: verbatim state span as the next input and as the comparison key

    func testVerbatimStateIsStableUnderViewAndRepeatedUpgrade() throws {
        let created = try CoreBridge.command(state: "", request: Self.createIdentity)
        let upgraded = try CoreBridge.command(state: try XCTUnwrap(created.state), request: Self.upgradeV2)
        let state = try XCTUnwrap(upgraded.state)

        // `view` and a second `upgrade_v2` on schema 3 do not change the
        // snapshot: the text comes back byte-identical, which is what makes
        // `next == current` a valid replacement for the org.json comparison.
        let viewed = try CoreBridge.command(state: state, request: Self.view)
        XCTAssertEqual(viewed.state, state)
        XCTAssertEqual(Array(try XCTUnwrap(viewed.state).utf8), Array(state.utf8))
        let again = try CoreBridge.command(state: state, request: Self.upgradeV2)
        XCTAssertEqual(again.state, state)
        XCTAssertEqual(again.stateVersion, 3)
    }

    func testStateSpanOfACoreReplyDecodesToTheSameObject() throws {
        let created = try CoreBridge.command(state: "", request: Self.createIdentity)
        let span = try XCTUnwrap(created.state)
        XCTAssertNotNil(created.text.range(of: span), "span must be a substring of the reply")
        let decodedSpan = try JSONSerialization.jsonObject(with: Data(span.utf8)) as? NSDictionary
        let decodedMember = created.object["state"] as? NSDictionary
        XCTAssertNotNil(decodedSpan)
        XCTAssertEqual(decodedSpan, decodedMember)
    }

    // MARK: JsonSpan

    func testJsonSpanExtractsStateByteForByteWithEscapedQuotesAndNestedObjects() throws {
        let state = #"{"conversations":{"acc\"ount":{"history":[{"text":"кавычка \" бэкслеш \\ скобка } и ] é é 😀"}],"state":"decoy"}},"legacy":{"state":{"state":[1,{"a":"}"}]},"tab":"\t"},"version":3}"#
        let reply = #"{"cursor":7,"public":{"state":"decoy"},"request":null,"state":\#(state),"z":[{"state":"decoy"}]}"#
        let span = try XCTUnwrap(JsonSpan.state(in: reply))
        XCTAssertEqual(span, state)
        XCTAssertEqual(Array(span.utf8), Array(state.utf8))
        XCTAssertEqual(JsonSpan.value(of: "cursor", in: reply), "7")
        XCTAssertEqual(JsonSpan.value(of: "request", in: reply), "null")
        XCTAssertEqual(JsonSpan.value(of: "z", in: reply), #"[{"state":"decoy"}]"#)
    }

    func testJsonSpanKeepsWhitespaceAndScalarValuesVerbatim() {
        let text = " {\n\t\"a\" : 1 ,\r\n \"state\" : { \"v\" : 3 , \"s\" : \"x \\\" y\" } , \"b\" : [ ] }\n"
        XCTAssertEqual(JsonSpan.state(in: text), "{ \"v\" : 3 , \"s\" : \"x \\\" y\" }")
        XCTAssertEqual(JsonSpan.value(of: "a", in: text), "1")
        XCTAssertEqual(JsonSpan.value(of: "b", in: text), "[ ]")
        XCTAssertEqual(JsonSpan.state(in: #"{"state":"a\"b\\c"}"#), #""a\"b\\c""#)
        XCTAssertEqual(JsonSpan.state(in: #"{"state":-12.5e3,"x":0}"#), "-12.5e3")
        XCTAssertEqual(JsonSpan.state(in: #"{"state":true}"#), "true")
        XCTAssertEqual(JsonSpan.state(in: #"{"x":"state","state":false}"#), "false")
        XCTAssertEqual(JsonSpan.state(in: #"{"state":{"k":1}}"#), #"{"k":1}"#)
    }

    func testJsonSpanIgnoresNestedKeysAndRejectsWhatIsNotAnObjectMember() {
        XCTAssertNil(JsonSpan.state(in: #"{"outer":{"state":{"v":3}}}"#))
        XCTAssertNil(JsonSpan.state(in: #"{"list":[{"state":1}],"other":"state"}"#))
        XCTAssertNil(JsonSpan.state(in: "{}"))
        XCTAssertNil(JsonSpan.state(in: ""))
        XCTAssertNil(JsonSpan.state(in: #"[{"state":1}]"#))
        XCTAssertNil(JsonSpan.state(in: #""state""#))
        XCTAssertNil(JsonSpan.state(in: #"{"state":{"v":3}"#), "truncated object")
        XCTAssertNil(JsonSpan.state(in: #"{"state":{"v":3},"a":1"#), "truncated after the member")
        XCTAssertNil(JsonSpan.state(in: #"{"state":{"v":3}} x"#), "trailing garbage")
        XCTAssertNil(JsonSpan.state(in: #"{"state":{"v":3},"a":{"b":1}"#), "truncated later member")
        XCTAssertNil(JsonSpan.state(in: #"{"state":"unterminated}"#), "truncated string")
        XCTAssertNil(JsonSpan.state(in: #"{"state":[1,2}}"#), "mismatched brackets")
        XCTAssertNil(JsonSpan.state(in: #"{"state":{"a":"\x"}}"#), "invalid escape")
        XCTAssertNil(JsonSpan.state(in: #"{"state" {"v":3}}"#), "missing colon")
        XCTAssertNil(JsonSpan.state(in: #"{"a":1 "state":2}"#), "missing comma")
    }
}
