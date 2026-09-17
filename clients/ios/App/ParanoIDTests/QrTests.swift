import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ParanoidKit
import XCTest

/// The QR round trip, on the simulator, with a contact the core itself
/// produced.
///
/// The claim under test is narrow and the whole point of the feature: the
/// string a peer scans is the `contact` member of the core's view, byte for
/// byte. Nothing on the way may normalise it — not the QR encoder, not the
/// decoder, not the scanner and not the paste field — because
/// `docs/protocol/key-enrollment-v1.md:91-96` has the raw text enter Rust's
/// strict typed parser, where a duplicate or unknown member is a failure
/// rather than a collapsed key. The two bounds
/// of that paragraph are tested here as well: 2048 bytes for a QR payload and
/// 4096 for a text import.
///
/// A real contact needs no server. `server_status_v2` only compares the
/// enrollment it is handed against the local credential
/// (`clean_service.rs:796-810`), and the credential fingerprint is a digest
/// over public fields (`key-protocol/src/lib.rs:57-71`), so this test can
/// register a freshly created identity with itself and let
/// `prepare_contact_v2` build the genuine `paranoid-contact-v2` text —
/// real keys, real signatures, around 900 bytes of it. That text, and not a
/// hand-written imitation, is what goes through `CIQRCodeGenerator` and comes
/// back through `CIDetector`.
///
/// Nothing here prints a snapshot, a contact or a fingerprint: one line with
/// byte counts is the whole output.
final class QrTests: XCTestCase {
    private static let realm = "https://127.0.0.2:38443"
    private static let pin = String(repeating: "a", count: 64)

    // MARK: - the round trip

    func testRealContactSurvivesTheQrRoundTripByteForByte() throws {
        let contact = try Self.realContact()
        // The core writes its reply through `serde_json::Value`, whose object
        // is a sorted map, so the contact begins at `bundle` and not at the
        // `type` its Rust struct declares first (`contact_v2.rs:5-12`). The
        // text is therefore sliced out and never re-encoded: an encoder here
        // would choose its own member order, escapes and spacing, and the
        // string the peer's strict parser has to see — duplicate and unknown
        // members included — would no longer be the one the core wrote.
        XCTAssertTrue(contact.hasPrefix(#"{"bundle":"#), "the core's own contact text")
        XCTAssertTrue(contact.contains(#""type":"paranoid-contact-v2""#))
        XCTAssertLessThanOrEqual(contact.utf8.count, QrCodec.payloadLimit)

        let image = try QrCodec.image(for: contact)
        XCTAssertGreaterThanOrEqual(image.width, QrCodec.minimumSide)
        XCTAssertEqual(image.width, image.height)

        let decoded = try XCTUnwrap(Self.decode(image).first, "the generated code must be readable")
        XCTAssertEqual(decoded, contact)
        XCTAssertEqual(Array(decoded.utf8), Array(contact.utf8), "byte for byte, not merely equal as text")

        print("QrTests: contact bytes=\(contact.utf8.count) qr=\(image.width)x\(image.height) px")
    }

    /// The round trip, finished: the string that comes back out of the code is
    /// accepted by *another* identity's core, which answers with the same
    /// contact fingerprint the first identity shows on its own screen.
    ///
    /// This is what byte-exactness is for. `contact_text_v2` verifies the root
    /// signature, the realm and pin, the Olm digest, every peer key and the
    /// device signature over the parsed fields
    /// (`contact_v2.rs:43-74`), so a single altered character anywhere in the
    /// text ends the flow instead of pairing with something else. Both
    /// identities are created against the same realm and pin, which is the
    /// situation two phones of one alpha are in.
    func testScannedContactIsAcceptedByThePeerCoreWithTheSameFingerprint() throws {
        let mine = try Self.registeredState()
        let peer = try Self.registeredState()
        let contact = try Self.contactText(of: mine)
        let view = try Self.command(state: mine, ["op": "view"])
        let fingerprint = try XCTUnwrap(view.object["contact_fingerprint"] as? String)
        let account = try XCTUnwrap((view.object["request"] as? [String: Any])?["credential"]
            as? [String: Any])["account"] as? String

        let decoded = try XCTUnwrap(Self.decode(try QrCodec.image(for: contact)).first)
        XCTAssertEqual(Array(decoded.utf8), Array(contact.utf8))

        // Exactly what the scanner hands over: the payload it read, measured
        // and not otherwise touched.
        let preview = try Self.command(state: peer,
                                       ["op": "contact_text_v2",
                                        "text": try QrCodec.checkedPayload(decoded)])
        XCTAssertEqual(preview.object["fingerprint"] as? String, fingerprint,
                       "both phones must show the same fingerprint to compare")
        XCTAssertEqual(preview.object["account"] as? String, account)
        XCTAssertEqual(fingerprint.count, 64)
    }

    /// The boundary of the QR bound: exactly 2048 bytes still encodes at error
    /// correction level M and still decodes to the same bytes. Android asks
    /// ZXing for the same level and the same limit (`QrCodec.java:12-16`).
    func testBoundaryPayloadOf2048BytesEncodesAndDecodesByteForByte() throws {
        let payload = Self.contactShaped(bytes: 2048)
        XCTAssertEqual(payload.utf8.count, 2048)
        XCTAssertEqual(try QrCodec.checkedPayload(payload), payload)

        let image = try QrCodec.image(for: payload)
        XCTAssertGreaterThanOrEqual(image.width, QrCodec.minimumSide)
        let decoded = try XCTUnwrap(Self.decode(image).first, "2048 bytes at level M must decode")
        XCTAssertEqual(Array(decoded.utf8), Array(payload.utf8))
    }

    /// One byte more is refused, and refused by this client rather than by the
    /// encoder: `CIQRCodeGenerator` is perfectly willing to encode 2049 bytes
    /// at level M, so the bound being tested is the protocol's.
    func testPayloadOf2049BytesIsRefusedByTheProtocolBoundNotByTheEncoder() throws {
        let payload = Self.contactShaped(bytes: 2049)
        XCTAssertEqual(payload.utf8.count, 2049)

        XCTAssertThrowsError(try QrCodec.checkedPayload(payload)) { error in
            XCTAssertEqual(error as? QrCodec.Failure, .payloadTooLong(bytes: 2049))
        }
        XCTAssertThrowsError(try QrCodec.image(for: payload)) { error in
            XCTAssertEqual(error as? QrCodec.Failure, .payloadTooLong(bytes: 2049))
        }

        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        XCTAssertNotNil(filter.outputImage, "the refusal above is ours, not the encoder's")
    }

    /// The code carries its own quiet zone: the corner of the image is white.
    ///
    /// `CIQRCodeGenerator` leaves one module of margin, and a decoder wants
    /// four (`QrCodec.java:16`, `EncodeHintType.MARGIN`), so `QrCodec` adds
    /// the other three instead of relying on whatever the screen happens to
    /// draw behind the image.
    func testGeneratedCodeCarriesItsOwnQuietZone() throws {
        let image = try QrCodec.image(for: Self.realContact())
        XCTAssertEqual(Self.cornerBrightness(of: image), 255, "the margin around the code is white")
    }

    /// An empty string is not a payload either (`QrCodec.java:12`).
    func testEmptyPayloadIsRefused() {
        XCTAssertThrowsError(try QrCodec.checkedPayload("")) { error in
            XCTAssertEqual(error as? QrCodec.Failure, .empty)
        }
        XCTAssertThrowsError(try QrCodec.checkedImport("")) { error in
            XCTAssertEqual(error as? QrCodec.Failure, .empty)
        }
    }

    // MARK: - what the core, and only the core, decides

    /// A text with a non-ASCII member and a text with a duplicated member both
    /// pass through this client unchanged — the same bytes come out of
    /// `checkedPayload` and `checkedImport` — and are then refused by the core
    /// as `invalid_contact` (`clean_service.rs:834`).
    ///
    /// That is the rule of `key-enrollment-v1.md:91-92`: the raw text reaches
    /// Rust's strict typed parser, which rejects unknown and duplicate fields,
    /// instead of being pre-judged or repaired here. The duplicate is added to
    /// the *genuine* contact, so nothing but the duplicated member can be the
    /// reason it fails.
    func testUnicodeAndDuplicateMembersAreRefusedByTheCoreAndNotBySwift() throws {
        let state = try Self.registeredState()
        let contact = try Self.contactText(of: state)
        let type = try XCTUnwrap(JsonSpan.value(of: "type", in: contact))

        let unicode = #"{"комментарий":"тест ✓","# + String(contact.dropFirst())
        let duplicate = "{\"type\":\(type)," + String(contact.dropFirst())

        for text in [unicode, duplicate] {
            XCTAssertLessThanOrEqual(text.utf8.count, QrCodec.payloadLimit)
            XCTAssertEqual(Array(try QrCodec.checkedPayload(text).utf8), Array(text.utf8),
                           "this client hands the text over untouched")
            XCTAssertEqual(Array(try QrCodec.checkedImport(text).utf8), Array(text.utf8))

            XCTAssertThrowsError(try Self.command(state: state,
                                                  ["op": "contact_text_v2", "text": text])) { error in
                XCTAssertEqual(error as? CoreError, .rejected("invalid_contact"),
                               "the verdict is the core's")
            }
        }
    }

    /// The import bound is the core's bound: 4096 bytes are accepted here and
    /// reach the core, 4097 are refused before it, and the core answers
    /// `qr_limit` to anything above its own 4096
    /// (`clean_service.rs:831-833`).
    func testImportBoundIsTheCoreBound() throws {
        XCTAssertEqual(QrCodec.payloadLimit, 2048)
        XCTAssertEqual(QrCodec.importLimit, 4096)

        let state = try Self.registeredState()
        let widest = Self.contactShaped(bytes: 4096)
        XCTAssertEqual(try QrCodec.checkedImport(widest), widest)
        XCTAssertThrowsError(try Self.command(state: state,
                                              ["op": "contact_text_v2", "text": widest])) { error in
            XCTAssertEqual(error as? CoreError, .rejected("invalid_contact"),
                           "4096 bytes are measured by the parser, not by the limit")
        }

        let wider = Self.contactShaped(bytes: 4097)
        XCTAssertThrowsError(try QrCodec.checkedImport(wider)) { error in
            XCTAssertEqual(error as? QrCodec.Failure, .importTooLong(bytes: 4097))
        }
        XCTAssertThrowsError(try Self.command(state: state,
                                              ["op": "contact_text_v2", "text": wider])) { error in
            XCTAssertEqual(error as? CoreError, .rejected("qr_limit"))
        }
    }

    // MARK: - a contact the core made

    /// A freshly created identity, registered with the enrollment it would
    /// have received, with its contact material prepared.
    private static func registeredState() throws -> String {
        var state = try XCTUnwrap(command(state: "",
                                          ["op": "create_identity", "realm": realm, "pin": pin]).state)
        state = try XCTUnwrap(command(state: state, ["op": "upgrade_v2"]).state)

        let view = try command(state: state, ["op": "view"])
        let credential = try XCTUnwrap((view.object["request"] as? [String: Any])?["credential"]
            as? [String: Any])
        // `Credential::bytes()`, in its order: the transcript is
        // length-prefixed public fields and its digest is the fingerprint the
        // server would have reported (`key-protocol/src/lib.rs:57-71`).
        let fields = try ["root", "account", "device", "auth", "realm", "pin", "olm"].map {
            try XCTUnwrap(credential[$0] as? String, "credential.\($0)")
        }
        let status: [String: Any] = [
            "mode": "active",
            "account": try XCTUnwrap(credential["account"] as? String),
            "device": try XCTUnwrap(credential["device"] as? String),
            "credential": digest(transcript(["paranoid-credential-v1"] + fields)),
        ]
        state = try XCTUnwrap(command(state: state, ["op": "server_status_v2", "status": status]).state)
        return try XCTUnwrap(command(state: state, ["op": "prepare_contact_v2"]).state)
    }

    /// The `contact` member of a view, sliced out of the reply verbatim — the
    /// very path `SelfServiceClient.contactText()` takes.
    private static func contactText(of state: String) throws -> String {
        let view = try command(state: state, ["op": "view"])
        XCTAssertNotNil(view.object["contact"] as? [String: Any])
        return try XCTUnwrap(JsonSpan.value(of: "contact", in: view.text))
    }

    private static func realContact() throws -> String {
        try contactText(of: registeredState())
    }

    private static func command(state: String, _ request: [String: Any]) throws -> CoreReply {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: request,
                                                               options: [.sortedKeys]),
                          as: UTF8.self)
        return try CoreBridge.command(state: state, request: text)
    }

    // MARK: - fixtures and tools

    /// `paranoid_key_protocol::transcript`: every field prefixed with its
    /// length as a big-endian `u32`.
    private static func transcript(_ fields: [String]) -> Data {
        var out = Data()
        for field in fields {
            let bytes = Array(field.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(contentsOf: bytes)
        }
        return out
    }

    /// `paranoid_key_protocol::digest`: lowercase hexadecimal SHA-256.
    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// A synthetic payload of exactly `bytes` ASCII bytes, shaped like a
    /// contact (`QrDenseSmoke.java:23-31`): the same member names, the same
    /// base64 and hexadecimal field widths, padded to the requested size. It
    /// is a size and character-set fixture only — the core refuses it, as the
    /// import test above shows.
    private static func contactShaped(bytes: Int) -> String {
        func pad(_ count: Int, _ character: Character) -> String {
            String(repeating: String(character), count: count)
        }
        var text = #"{"type":"paranoid-contact-v2","credential":{"account":""# + pad(64, "a")
        text += #"","realm":"\#(realm)","pin":""# + pad(64, "b")
        text += #"","olm":""# + pad(64, "c") + #"","auth":""# + pad(43, "D")
        text += #"","signature":""# + pad(86, "E")
        text += #""},"bundle":{"device":"unassigned","realm":"\#(realm)","curve":""# + pad(43, "F")
        text += #"","one_time_key":""# + pad(43, "G")
        text += #""},"fallback_key":""# + pad(43, "H") + #"","signature":""# + pad(86, "I")
        let tail = #"","padding":""#
        let closing = #""}"#
        let room = bytes - text.utf8.count - tail.utf8.count - closing.utf8.count
        XCTAssertGreaterThanOrEqual(room, 0, "the fixture is shorter than \(bytes) bytes")
        return text + tail + pad(max(0, room), "J") + closing
    }

    /// The grey value of the image's bottom-left pixel, read through a
    /// one-pixel grey context so that no assumption about the generated
    /// bitmap's component order is needed.
    private static func cornerBrightness(of image: CGImage) -> UInt8? {
        var pixel: UInt8 = 0
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        // The image is drawn at full size into a one-pixel window, so what
        // lands in it is the corner pixel and nothing else.
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixel
    }

    /// Every QR the detector finds in `image`, as strings. `CIDetector` is the
    /// decoder this client does not ship: the scanner reads
    /// `AVCaptureMetadataOutput` frames, and this is how a test reads back
    /// what the generator wrote.
    private static func decode(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)) ?? [])
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}
