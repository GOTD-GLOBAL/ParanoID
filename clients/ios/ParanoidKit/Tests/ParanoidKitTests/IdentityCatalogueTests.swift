import Foundation
import ParanoidKit
import XCTest

/// RFC-0030 / draft ADR-0017; REQ-CLIENT-001, REQ-MULTI-001, MR-02/06/14.
/// Synthetic public metadata only. No persistence, random secrets or network.
final class IdentityCatalogueTests: XCTestCase {
    private let installID = "11111111-1111-4111-8111-111111111111"
    private let ownerRef = "22222222-2222-4222-8222-222222222222"
    private let fiOrigin = "https://fi.example.invalid:38444"
    private let ruOrigin = "https://ru.example.invalid:38444"
    private let fiPin = String(repeating: "a", count: 64)
    private let ruPin = String(repeating: "b", count: 64)

    private func context() throws -> IdentityCatalogue.Realms {
        try .init(fi: .init(origin: fiOrigin, pin: fiPin, protocolKind: "identity-v3"),
                  ru: .init(origin: ruOrigin, pin: ruPin, protocolKind: "identity-v3"))
    }

    private func fresh() throws -> IdentityCatalogue {
        try .init(installID: installID, ownerRef: ownerRef, realms: context())
    }

    private func realm(_ slot: String, _ origin: String, _ pin: String) -> String {
        #"{"slot":"\#(slot)","origin":"\#(origin)","pin":"\#(pin)","protocol":"identity-v3","allocation":"unallocated"}"#
    }

    private var fixture: String {
        #"{"version":5,"minReader":5,"kind":"catalogue","installID":"\#(installID)","owner":{"ref":"\#(ownerRef)","allocation":"unallocated","binding":null},"realms":[\#(realm("fi", fiOrigin, fiPin)),\#(realm("ru", ruOrigin, ruPin))]}"#
    }

    func testRejectsNoncanonicalUUIDsAtConstruction() throws {
        for bad in ["", installID.uppercased().replacingOccurrences(of: "11111111", with: "ABCDEFAB"),
                    "11111111111141118111111111111111", "{" + installID + "}",
                    installID + " ", "g" + installID.dropFirst(),
                    "１１１１１１１１-1111-4111-8111-111111111111"] {
            XCTAssertThrowsError(try IdentityCatalogue(installID: bad, ownerRef: ownerRef, realms: context()))
            XCTAssertThrowsError(try IdentityCatalogue(installID: installID, ownerRef: bad, realms: context()))
        }
        let canonical = "abcdefab-cdef-0000-0000-abcdefabcdef"
        XCTAssertEqual(try IdentityCatalogue(installID: canonical, ownerRef: canonical,
                                             realms: context()).installID, canonical)
    }

    func testTrustDescriptorsRequireExactPinAndProtocol() throws {
        for pin in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                    fiPin.uppercased(), String(repeating: "g", count: 64), fiPin + "\n"] {
            XCTAssertThrowsError(try IdentityCatalogue.Realm(origin: fiOrigin, pin: pin,
                                                              protocolKind: "identity-v3"))
        }
        for kind in ["", "identity-v2", "Identity-v3", "identity-v3 "] {
            XCTAssertThrowsError(try IdentityCatalogue.Realm(origin: fiOrigin, pin: fiPin,
                                                              protocolKind: kind))
        }
    }

    func testOriginsAreValidatedWithoutNormalization() throws {
        let invalid = ["", "http://fi.example.invalid", "HTTPS://fi.example.invalid",
                       "https://Fi.example.invalid", fiOrigin + "/", fiOrigin + "?x",
                       fiOrigin + "#x", "https://u:p@fi.example.invalid", "https://fi.example.invalid.",
                       "https://fi..invalid", "https://-fi.invalid", "https://fi-.invalid",
                       "https://f_i.invalid", "https://fi%2einvalid", "https://ф.invalid",
                       "https://fi.invalid:443", "https://fi.invalid:0444", "https://fi.invalid:0",
                       "https://fi.invalid:65536", "https://fi.invalid:", "https://fi.invalid:+444",
                       "https://01.2.3.4", "https://256.2.3.4", "https://127.1", "https://123",
                       "https://[::1]", " " + fiOrigin, fiOrigin + "\n",
                       "https://" + String(repeating: "a", count: 64) + ".invalid",
                       "https://" + String(repeating: "a.", count: 128) + "invalid"]
        for origin in invalid {
            XCTAssertThrowsError(try IdentityCatalogue.Realm(origin: origin, pin: fiPin,
                                                              protocolKind: "identity-v3"), origin)
        }
        for origin in [fiOrigin, "https://fi.invalid", "https://192.0.2.1:65535",
                       "https://0.0.0.0:1", "https://xn--example.invalid", "https://a-b.invalid"] {
            XCTAssertEqual(try IdentityCatalogue.Realm(origin: origin, pin: fiPin,
                                                       protocolKind: "identity-v3").origin, origin)
        }
    }

    func testExpectedRealmPairsMustBeDistinct() throws {
        let descriptors = try context()
        XCTAssertThrowsError(try IdentityCatalogue.Realms(fi: descriptors.fi, ru: descriptors.fi))
        let sharedPin = try IdentityCatalogue.Realm(origin: ruOrigin, pin: fiPin, protocolKind: "identity-v3")
        XCTAssertNoThrow(try IdentityCatalogue.Realms(fi: descriptors.fi, ru: sharedPin))
        let differentPin = try IdentityCatalogue.Realm(origin: fiOrigin, pin: ruPin, protocolKind: "identity-v3")
        XCTAssertNoThrow(try IdentityCatalogue.Realms(fi: descriptors.fi, ru: differentPin))
    }

    private func decode(_ text: String) throws -> IdentityCatalogue {
        try IdentityCatalogueCodec.decode(Data(text.utf8), expectedInstallID: installID, expectedRealms: context())
    }

    func testFreshRoundTrip() throws {
        XCTAssertEqual(try decode(fixture), try fresh())
        XCTAssertEqual(try IdentityCatalogueCodec.decode(IdentityCatalogueCodec.encode(fresh()),
            expectedInstallID: installID, expectedRealms: context()), try fresh())
    }

    func testDecodedCatalogueMustMatchFullExpectedContext() throws {
        for (old, replacement) in [(installID, ownerRef), (fiOrigin, "https://other.invalid:38444"),
                                   (fiPin, String(repeating: "c", count: 64)),
                                   (ruOrigin, "https://other.invalid:38444"),
                                   (ruPin, String(repeating: "c", count: 64))] {
            XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: old, with: replacement)))
        }
        let trust = try context()
        XCTAssertThrowsError(try IdentityCatalogueCodec.decode(Data(fixture.utf8),
            expectedInstallID: "malformed", expectedRealms: trust))
        XCTAssertThrowsError(try IdentityCatalogueCodec.decode(Data(fixture.utf8),
            expectedInstallID: installID, expectedRealms: .init(fi: trust.ru, ru: trust.fi)))
        let shared = try IdentityCatalogue.Realms(fi: trust.fi,
            ru: .init(origin: ruOrigin, pin: fiPin, protocolKind: "identity-v3"))
        let sharedValue = try IdentityCatalogue(installID: installID, ownerRef: ownerRef, realms: shared)
        XCTAssertEqual(try IdentityCatalogueCodec.decode(IdentityCatalogueCodec.encode(sharedValue),
            expectedInstallID: installID, expectedRealms: shared), sharedValue)
        XCTAssertThrowsError(try IdentityCatalogueCodec.decode(IdentityCatalogueCodec.encode(sharedValue),
            expectedInstallID: installID, expectedRealms: .init(fi: shared.ru, ru: shared.fi)))
    }

    func testRejectsTrailingDataButAcceptsJSONWhitespace() throws {
        for suffix in ["{}", "[]", "true", "x", "\0", " ,", "\u{00a0}"] {
            XCTAssertThrowsError(try decode(fixture + suffix))
        }
        XCTAssertEqual(try decode(" \t\r\n" + fixture + " \t\r\n"), try fresh())
    }

    func testRejectsDuplicateFieldsAtEachObjectDepth() throws {
        let mutations = [(#""version":5"#, #""version":5,"version":5"#),
                         (#""ref":""#, #""binding":null,"ref":""#),
                         (#""slot":"fi""#, #""slot":"fi","slot":"fi""#),
                         (#""slot":"ru""#, #""slot":"ru","slot":"ru""#)]
        for (old, replacement) in mutations {
            XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: old, with: replacement)))
        }
    }

    func testValidEscapedKeysAndValuesRoundTrip() throws {
        let escaped = fixture
            .replacingOccurrences(of: #""version""#, with: #""\u0076ersion""#)
            .replacingOccurrences(of: #""owner""#, with: #""\u006fwner""#)
            .replacingOccurrences(of: #""ref""#, with: #""r\u0065f""#)
            .replacingOccurrences(of: #""fi""#, with: #""\u0066i""#)
            .replacingOccurrences(of: "https://", with: #"https:\/\/"#)
            .replacingOccurrences(of: "identity-v3", with: #"identity-\u00763"#)
        XCTAssertEqual(try decode(escaped), try fresh())
        XCTAssertEqual(IdentityCatalogueCodec.encode(try decode(escaped)), Data(fixture.utf8))
    }

    func testEscapedEquivalentDuplicatesRefuseAtEveryDepth() throws {
        for (old, replacement) in [
            (#""version":5"#, #""version":5,"\u0076ersion":5"#),
            (#""binding":null"#, #""binding":null,"bind\u0069ng":null"#),
            (#""slot":"fi""#, #""slot":"fi","\u0073lot":"fi""#),
            (#""slot":"ru""#, #""slot":"ru","slo\u0074":"ru""#)
        ] {
            XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: old, with: replacement))) {
                XCTAssertEqual($0 as? IdentityCatalogueError, .invalidSchema)
            }
        }
    }

    func testRawPayloadLimitPrecedesUTF8AndParsing() throws {
        let exact = Data((fixture + String(repeating: " ", count: 65_536 - fixture.utf8.count)).utf8)
        XCTAssertEqual(exact.count, 65_536)
        XCTAssertEqual(try IdentityCatalogueCodec.decode(exact, expectedInstallID: installID,
                                                        expectedRealms: context()), try fresh())
        for data in [exact + Data([32]), Data(repeating: 255, count: 65_537)] {
            XCTAssertThrowsError(try IdentityCatalogueCodec.decode(data, expectedInstallID: installID,
                                                                   expectedRealms: context())) {
                XCTAssertEqual(String(describing: $0), "limitExceeded")
            }
        }
    }

    func testMalformedUTF8IsRejectedBeforeJSONInterpretation() throws {
        let invalid: [[UInt8]] = [[0xff], [0xc0, 0xaf], [0xe2, 0x82], [0xed, 0xa0, 0x80],
                                  [0xf4, 0x90, 0x80, 0x80], [0x80]]
        for bytes in invalid {
            for data in [Data(bytes), Data(fixture.utf8) + Data(bytes),
                         Data(#"{"secret":""#.utf8) + Data(bytes) + Data(#""}"#.utf8)] {
                XCTAssertThrowsError(try IdentityCatalogueCodec.decode(data, expectedInstallID: installID,
                                                                       expectedRealms: context())) {
                    XCTAssertEqual(String(describing: $0), "invalidUTF8")
                }
            }
        }
    }

    func testUnsupportedVersionsAreNotCoerced() throws {
        for field in ["version", "minReader"] {
            for number in ["0", "4", "6", "9999999999999999999999999999999999999"] {
                XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: "\"" + field + "\":5",
                    with: "\"" + field + "\":" + number))) {
                    XCTAssertEqual(String(describing: $0), "unsupportedVersion")
                }
            }
            for token in ["true", "false", "null", "\"5\"", "5.0", "5e0", "5E+0", "05", "+5", "-5", "[]", "{}"] {
                XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: "\"" + field + "\":5",
                    with: "\"" + field + "\":" + token)))
            }
        }
    }

    func testAllocatedOrBoundStateIsExplicitlyUnsupported() throws {
        for slot in ["owner", "fi", "ru"] {
            let needle = slot == "owner" ? #""allocation":"unallocated","binding""#
                : realm(slot, slot == "fi" ? fiOrigin : ruOrigin, slot == "fi" ? fiPin : ruPin)
            let changed = needle.replacingOccurrences(of: "unallocated", with: "allocated")
            XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: needle, with: changed))) {
                XCTAssertEqual(String(describing: $0), "unsupportedState")
            }
        }
        for binding in ["{}", "[]", "false", "0", "\"confirmed\"", #"{"nickname":"test"}"#] {
            XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: #""binding":null"#,
                with: #""binding":\#(binding)"#))) {
                XCTAssertEqual(String(describing: $0), "unsupportedState")
            }
        }
    }

    func testNullLiteralCannotContainWhitespace() throws {
        for null in ["n ull", "nu\tll", "nul\nl", "n u l l"] {
            XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: "null", with: null)))
        }
    }

    func testDecodedStringBoundRefusesBeforeSchemaComparison() throws {
        for text in [String(repeating: "a", count: 301), String(repeating: "é", count: 151),
                     String(repeating: #"\u0061"#, count: 301)] {
            let input = fixture.replacingOccurrences(of: "catalogue", with: text)
            XCTAssertThrowsError(try decode(input)) {
                XCTAssertEqual($0 as? IdentityCatalogueError, .limitExceeded)
            }
        }
        XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: "catalogue",
            with: String(repeating: "a", count: 300)))) {
            XCTAssertEqual($0 as? IdentityCatalogueError, .invalidSchema)
        }
    }

    func testWellFormedSurrogatePairIsValidJSONButNotSchemaText() throws {
        for text in [#"\uD83D\uDE00"#, #"\u0022"#, #"\""#, #"\\"#, #"\b\f\n\r\t"#] {
            XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: "catalogue", with: text))) {
                XCTAssertEqual($0 as? IdentityCatalogueError, .invalidSchema)
            }
        }
    }

    func testMalformedEscapesAndSurrogatesRefuse() throws {
        for text in [#"\x41"#, #"\uZZZZ"#, #"\u123"#, #"\uD800"#, #"\uDC00"#,
                     #"\uD800\u0041"#, #"\uD800\uD800"#, #"\uD800 \uDC00"#,
                     #"\uD800x"#, #"\uD800\uZZZZ"#, "raw\ncontrol", "raw\u{0000}"] {
            XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: "catalogue", with: text))) {
                XCTAssertEqual($0 as? IdentityCatalogueError, .invalidJSON)
            }
        }
        for truncated in [#"{"kind":"\"#, #"{"kind":"\u"#, #"{"kind":"\uD800\u"#] {
            XCTAssertThrowsError(try decode(truncated))
        }
    }

    func testMalformedJSONAndTrailingCommasRefuse() throws {
        let malformed = ["", "{}", "[]", "null", "true", "5", #""text""#,
                         "\u{feff}" + fixture, "/*comment*/" + fixture,
                         fixture.replacingOccurrences(of: ":5,", with: ":5,,"),
                         fixture.replacingOccurrences(of: #""kind":"#, with: #""kind" "#),
                         fixture.replacingOccurrences(of: #""binding":null"#, with: #""binding":nulll"#),
                         fixture.replacingOccurrences(of: "},", with: "},,"),
                         fixture.replacingOccurrences(of: "}", with: ",}"),
                         fixture.replacingOccurrences(of: "]", with: ",]"),
                         fixture.replacingOccurrences(of: #""owner":{"#, with: #""owner":{{"#)]
        for text in malformed { XCTAssertThrowsError(try decode(text)) }
        for end in fixture.utf8.indices {
            XCTAssertThrowsError(try IdentityCatalogueCodec.decode(Data(fixture.utf8.prefix(upTo: end)),
                expectedInstallID: installID, expectedRealms: context()))
        }
    }

    func testEitherRealmOrderAndObjectFieldOrderAreAccepted() throws {
        let fi = realm("fi", fiOrigin, fiPin)
        let ru = realm("ru", ruOrigin, ruPin)
        let reordered = #" { "realms" : [\#(ru),\#(fi)], "owner" : {"binding":null,"allocation":"unallocated","ref":"\#(ownerRef)"}, "kind":"catalogue", "minReader":5, "installID":"\#(installID)", "version":5 } "#
            .replacingOccurrences(of: #""slot":"fi","origin":"\#(fiOrigin)""#,
                                  with: #""origin":"\#(fiOrigin)","slot":"fi""#)
        XCTAssertEqual(try decode(reordered), try fresh())
        XCTAssertEqual(IdentityCatalogueCodec.encode(try decode(reordered)), Data(fixture.utf8))
        XCTAssertEqual(try decode(fixture.replacingOccurrences(of: ",", with: " ,\n\t\r ")), try fresh())
    }

    func testExactlyTwoKnownUniqueSlotsAreRequired() throws {
        let fi = realm("fi", fiOrigin, fiPin)
        let ru = realm("ru", ruOrigin, ruPin)
        for realms in ["", fi, ru, fi + "," + fi, ru + "," + ru,
                       fi + "," + ru + "," + fi,
                       realm("us", fiOrigin, fiPin) + "," + ru,
                       realm("FI", fiOrigin, fiPin) + "," + ru] {
            XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: fi + "," + ru, with: realms)))
        }
    }

    // Foundation only builds negative fixtures; it is never the production validator.
    private func mutateObject(_ location: String,
                              _ mutate: (inout [String: Any]) -> Void) throws -> String {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        if location == "root" {
            mutate(&object)
        } else if location == "owner" {
            var owner = try XCTUnwrap(object["owner"] as? [String: Any])
            mutate(&owner)
            object["owner"] = owner
        } else {
            var realms = try XCTUnwrap(object["realms"] as? [[String: Any]])
            mutate(&realms[location == "fi" ? 0 : 1])
            object["realms"] = realms
        }
        return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    func testMissingAndUnknownFieldsRefuseAtEveryDepth() throws {
        let fields = ["root": ["version", "minReader", "kind", "installID", "owner", "realms"],
                      "owner": ["ref", "allocation", "binding"],
                      "fi": ["slot", "origin", "pin", "protocol", "allocation"],
                      "ru": ["slot", "origin", "pin", "protocol", "allocation"]]
        for (location, keys) in fields {
            for key in keys {
                XCTAssertThrowsError(try decode(mutateObject(location) { $0.removeValue(forKey: key) }))
            }
            XCTAssertThrowsError(try decode(mutateObject(location) { $0["unknown"] = NSNull() }))
        }
    }

    func testWrongFieldTypesRefuseAtEveryDepth() throws {
        for location in ["root", "owner", "fi", "ru"] {
            var fields: [String: Any] = [:]
            _ = try mutateObject(location) { fields = $0 }
            for (key, original) in fields {
                let wrong: [Any]
                if key == "version" || key == "minReader" {
                    wrong = [NSNull(), true, "5", [], [:]]
                } else if original is String {
                    wrong = [NSNull(), true, 5, [], [:]]
                } else if key == "binding" {
                    wrong = [true, 5, "null", [], [:]]
                } else {
                    wrong = [NSNull(), true, 5, "object", []]
                }
                for value in wrong {
                    XCTAssertThrowsError(try decode(mutateObject(location) { $0[key] = value }))
                }
            }
        }
    }

    func testInvalidSchemaValuesAreNotRepaired() throws {
        for (old, replacement) in [("catalogue", "realm"), ("identity-v3", "identity-v2"),
                                   ("unallocated", "pending"), ("unallocated", "UNALLOCATED"),
                                   (ownerRef, "owner-public-key"), (installID, "{" + installID + "}"),
                                   (fiOrigin, fiOrigin + "/"), (fiPin, fiPin.uppercased())] {
            XCTAssertThrowsError(try decode(fixture.replacingOccurrences(of: old, with: replacement)))
        }
    }

    func testDeepUnknownInputAndErrorsStayBoundedWithoutPayloadDisclosure() throws {
        let nested = String(repeating: "[", count: 20_000) + "0" + String(repeating: "]", count: 20_000)
        let sentinel = "SYNTHETIC_PAYLOAD_MUST_NOT_LEAK"
        let inputs = [#"{"unknown":\#(nested)}"#,
                      #"{"owner":{"unknown":\#(nested)}}"#,
                      #"{"realms":[{"unknown":\#(nested)}]}"#,
                      #"{"owner":{"binding":\#(nested)}}"#,
                      #"{"installID":\#(nested)}"#,
                      String(repeating: "[", count: 30_000),
                      fixture.replacingOccurrences(of: "catalogue", with: sentinel),
                      #"{"\#(sentinel)":null}"#]
        for input in inputs {
            XCTAssertThrowsError(try decode(input)) {
                XCTAssertTrue($0 is IdentityCatalogueError)
                XCTAssertFalse(String(describing: $0).contains(sentinel))
                XCTAssertLessThan(String(describing: $0).utf8.count, 32)
            }
        }
    }

    func testNoncanonicalNumericHostAliasesRefuse() throws {
        for origin in ["https://0x7f000001", "https://0x7f.0.0.1", "https://127.0.0.0x1",
                       "https://0x7f.0x0.0x0.0x1", "https://a.123", "https://0177.0.0.1"] {
            XCTAssertThrowsError(try IdentityCatalogue.Realm(origin: origin, pin: fiPin,
                                                              protocolKind: "identity-v3"))
        }
    }

    func testMaximumCanonicalHostRoundTripsWithinWriterBound() throws {
        let prefix = String(repeating: "a", count: 63) + "."
            + String(repeating: "b", count: 63) + "." + String(repeating: "c", count: 63) + "."
        let suffix = ".invalid"
        let host = prefix + String(repeating: "d", count: 253 - prefix.utf8.count - suffix.utf8.count) + suffix
        XCTAssertEqual(host.utf8.count, 253)
        let longest = try IdentityCatalogue.Realm(origin: "https://" + host + ":65535",
                                                  pin: fiPin, protocolKind: "identity-v3")
        let realms = try IdentityCatalogue.Realms(fi: longest, ru: context().ru)
        let value = try IdentityCatalogue(installID: installID, ownerRef: ownerRef, realms: realms)
        let data = IdentityCatalogueCodec.encode(value)
        XCTAssertLessThan(data.count, 65_536)
        XCTAssertEqual(try IdentityCatalogueCodec.decode(data, expectedInstallID: installID,
                                                        expectedRealms: realms), value)
        XCTAssertThrowsError(try IdentityCatalogue.Realm(origin: "https://" + host + "x:65535",
                                                          pin: fiPin, protocolKind: "identity-v3"))
    }

    func testFreshValueSerializesDeterministically() throws {
        let value = try fresh()
        XCTAssertEqual(value.installID, installID)
        XCTAssertEqual(value.ownerRef, ownerRef)
        XCTAssertEqual(value.realms, try context())
        XCTAssertEqual(IdentityCatalogueCodec.encode(value), Data(fixture.utf8))
        XCTAssertEqual(IdentityCatalogueCodec.encode(value), IdentityCatalogueCodec.encode(value))
        func requireSendable<T: Sendable & Equatable>(_ value: T) -> T { value }
        XCTAssertEqual(requireSendable(value), value)
    }
}
