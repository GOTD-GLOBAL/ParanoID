// core-bridge: the stdin/stdout fixture that puts the shipped iOS client on
// the far side of a pipe, so that a harness can drive it and the Android
// client through the same shared Rust core and compare what the two answer.
//
// It is the iOS counterpart of `clients/android/test/VoiceCoreBridge.java` and
// it speaks that fixture's line protocol byte for byte — one JSON object per
// line on stdin, one per line on stdout — so a single harness can hold both
// pipes open at once and hand each of them the same request:
//
//     {"kind":"core","state":"<state text>","request":{…}}
//         -> the core reply, verbatim, or {"error":"<code>"}
//     {"kind":"sealed_reopen","snapshot":{…}}
//         -> {"view":…,"writes":0,"sealed_bytes":N,"unchanged":true}
//
// Four more kinds are this fixture's own, the mirror images of
// `clients/ios/test/java/JavaCodecVector.java` and
// `clients/ios/test/java/QrCross.java`: they let the harness seal a snapshot
// here and open it there, and encode a QR here and decode it there, in both
// directions.
//
//     {"kind":"seal","key":"<base64 32 bytes>","text":"<plaintext>"}
//         -> {"sealed":"<base64>","bytes":N}
//     {"kind":"open","key":"<base64 32 bytes>","sealed":"<base64>"}
//         -> {"text":"<plaintext>","bytes":N}
//     {"kind":"qr_encode","text":"<payload>"}
//         -> {"png":"<base64>","width":N,"height":N,"payload_bytes":N}
//     {"kind":"qr_decode","png":"<base64>"}
//         -> {"text":"<payload>","width":N,"height":N}
//
// `qr_encode` is the shipped encoder, `QrCodec.image(for:)`. `qr_decode` is
// **not** shipped code: the application reads codes from
// `AVCaptureMetadataOutput` frames inside a capture session, which a
// command-line tool has no way to drive, so the reverse direction is read
// here with `Vision`. The cross-check that uses it says so.
//
// Everything below the protocol is the shipped client: `CoreBridge` reaches
// the core through the C ABI, `SnapshotCodec` is the storage codec the
// application uses and `SelfServiceClient` is the adapter the screens talk to.
// Nothing here re-implements a protocol step and nothing here is a stand-in
// for the core.
//
// The same private-pipe discipline as the Java fixtures: state text, keys,
// snapshots and plaintext arrive on stdin and leave on stdout, never through
// argv (where `ps` would show them) and never through a file. A refusal
// answers `{"fixture_error":"<type>"}` and nothing else, so no refused input
// is ever echoed back. Nothing here logs a line it was given.
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ParanoidKit
import UniformTypeIdentifiers
import Vision

// MARK: - Fixture failures

/// A refusal that belongs to the fixture rather than to the client.
private struct FixtureError: Error {
    let name: String
}

/// The name that travels in `fixture_error`: the type of the failure and
/// never its payload, the rule of `VoiceCoreBridge.java:41-43`.
private func name(of error: any Error) -> String {
    switch error {
    case let failure as FixtureError: return failure.name
    case is CoreError: return "CoreError"
    case is SnapshotCodecError: return "SnapshotCodecError"
    case let failure as SelfServiceError: return String(describing: failure).components(separatedBy: "(")[0]
    default: return String(describing: type(of: error))
    }
}

// MARK: - Reading one request

private func object(_ request: [String: Any], _ member: String) throws -> [String: Any] {
    guard let value = request[member] as? [String: Any] else {
        throw FixtureError(name: "IllegalArgumentException")
    }
    return value
}

private func string(_ request: [String: Any], _ member: String) throws -> String {
    guard let value = request[member] as? String else {
        throw FixtureError(name: "IllegalArgumentException")
    }
    return value
}

/// A base64 member decoded to exactly `bytes` bytes when a length is given.
private func data(_ request: [String: Any], _ member: String, bytes: Int? = nil) throws -> Data {
    guard let decoded = Data(base64Encoded: try string(request, member)) else {
        throw FixtureError(name: "IllegalArgumentException")
    }
    if let bytes, decoded.count != bytes { throw FixtureError(name: "IllegalArgumentException") }
    return decoded
}

/// One JSON object, encoded the way the Java fixtures encode theirs.
private func encode(_ value: [String: Any]) throws -> String {
    guard let raw = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: raw, encoding: .utf8)
    else {
        throw FixtureError(name: "JSONException")
    }
    return text
}

// MARK: - The four kinds

/// `kind:"core"`: one core command over the state text the line carries.
///
/// The reply is written out **verbatim**, exactly as the core produced it,
/// rather than re-encoded: the harness compares the two clients' replies as
/// decoded JSON, and a re-encoding here would hide a difference in what the
/// core actually wrote. A refused command answers `{"error":"<code>"}`, which
/// is the reply `CoreBridge.java` hands back unchanged and `CoreBridge.swift`
/// raises as `CoreError.rejected`.
private func core(_ request: [String: Any]) throws -> String {
    let state = try string(request, "state")
    let command = try encode(try object(request, "request"))
    do {
        return try CoreBridge.command(state: state, request: command).text
    } catch CoreError.rejected(let code) {
        return try encode(["error": code])
    }
}

/// `kind:"sealed_reopen"`: seal the wrapper, open it, and check that opening
/// it changed neither the bytes nor the identity and wrote nothing.
///
/// It is `VoiceCoreBridge.java:23-35` step for step, over the iOS codec and
/// the iOS adapter. The wrapping key is generated here and never leaves this
/// process, as the Keychain item does not exist for a command-line tool.
private func sealedReopen(_ request: [String: Any]) throws -> String {
    let saved = try encode(try object(request, "snapshot"))
    let key = SymmetricKey(size: .bits256)
    let sealed = try SnapshotCodec.seal(key: key, value: saved)
    let reopened = try SnapshotCodec.open(key: key, value: sealed)
    guard saved == reopened else { throw FixtureError(name: "AssertionError") }
    let counter = WriteCounter()
    // No fixture and no compiled default: the trust of a saved wrapper is the
    // wrapper's own, so a reopening can never be handed another realm or pin.
    let client = try SelfServiceClient(saved: reopened, sink: counter, fixture: nil, compiled: nil)
    guard counter.writes == 0 else { throw FixtureError(name: "AssertionError") }
    return try encode([
        "view": try client.publicView(),
        "writes": counter.writes,
        "sealed_bytes": sealed.count,
        "unchanged": saved == reopened,
    ])
}

/// A sink that refuses nothing and only counts: opening a retained snapshot
/// must not commit (`VoiceCoreBridge.java:31-33`).
private final class WriteCounter: SnapshotSink {
    private(set) var writes = 0

    func save(_ snapshot: String) throws {
        writes += 1
    }
}

/// `kind:"seal"`: a snapshot blob for the Java codec to open.
private func seal(_ request: [String: Any]) throws -> String {
    let key = try data(request, "key", bytes: 32)
    let sealed = try SnapshotCodec.seal(key: SymmetricKey(data: key), value: try string(request, "text"))
    return try encode(["sealed": sealed.base64EncodedString(), "bytes": sealed.count])
}

/// `kind:"open"`: a blob the Java codec sealed.
private func open(_ request: [String: Any]) throws -> String {
    let key = try data(request, "key", bytes: 32)
    let sealed = try data(request, "sealed")
    let text = try SnapshotCodec.open(key: SymmetricKey(data: key), value: sealed)
    return try encode(["text": text, "bytes": sealed.count])
}

/// `kind:"qr_encode"`: the shipped encoder, rendered as a PNG.
///
/// `QrCodec.image(for:)` measures the payload against the 2048-byte QR bound
/// and encodes exactly the bytes it was given, so what travels back is what a
/// peer's camera would see on this phone's screen.
private func qrEncode(_ request: [String: Any]) throws -> String {
    let payload = try string(request, "text")
    let image = try QrCodec.image(for: payload)
    let png = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        png, UTType.png.identifier as CFString, 1, nil) else {
        throw FixtureError(name: "IOException")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw FixtureError(name: "IOException") }
    return try encode([
        "png": (png as Data).base64EncodedString(),
        "width": image.width,
        "height": image.height,
        "payload_bytes": payload.utf8.count,
    ])
}

/// `kind:"qr_decode"`: a PNG read back through `Vision`.
///
/// This is the fixture's own reader, not the application's: on a phone a code
/// arrives as an `AVCaptureMetadataOutput` string from a live capture session.
/// What it proves is that the pixels ZXing wrote carry the payload, not that
/// the shipped scanner was exercised.
private func qrDecode(_ request: [String: Any]) throws -> String {
    let png = try data(request, "png")
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw FixtureError(name: "IOException")
    }
    let barcodes = VNDetectBarcodesRequest()
    barcodes.symbologies = [.qr]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([barcodes])
    let payloads = (barcodes.results ?? []).compactMap { $0.payloadStringValue }
    guard payloads.count == 1, let text = payloads.first else {
        throw FixtureError(name: "NotFoundException")
    }
    return try encode(["text": text, "width": image.width, "height": image.height])
}

// MARK: - The run

/// Longest accepted request line, the bound of `VoiceCoreBridge.java:19`.
private let lineLimit = 10 * 1024 * 1024

if CommandLine.arguments.count != 1 {
    FileHandle.standardError.write(Data("usage: core-bridge (JSON lines on stdin)\n".utf8))
    exit(64)
}

while let line = readLine(strippingNewline: true) {
    var reply: String
    do {
        guard line.utf8.count <= lineLimit,
              let decoded = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let request = decoded as? [String: Any]
        else {
            throw FixtureError(name: "IllegalArgumentException")
        }
        switch try string(request, "kind") {
        case "core": reply = try core(request)
        case "sealed_reopen": reply = try sealedReopen(request)
        case "seal": reply = try seal(request)
        case "open": reply = try open(request)
        case "qr_encode": reply = try qrEncode(request)
        case "qr_decode": reply = try qrDecode(request)
        default: throw FixtureError(name: "IllegalArgumentException")
        }
    } catch {
        // Only the type of the failure travels: a JSON, codec or core message
        // must never carry the state, the key or the plaintext it refused.
        reply = (try? encode(["fixture_error": name(of: error)])) ?? "{\"fixture_error\":\"JSONException\"}"
    }
    print(reply)
    fflush(stdout)
}
