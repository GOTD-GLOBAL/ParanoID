import CoreGraphics
import CoreImage
import Foundation

/// The two QR bounds of the protocol and the one local encoder, the
/// counterpart of Android's `QrCodec.java`.
///
/// `docs/protocol/key-enrollment-v1.md:91-96` fixes both numbers: a QR
/// payload is at most 2048 bytes and a native or text import at most 4096,
/// and the raw text must reach Rust's
/// strict typed parser unchanged, so that duplicate or unknown members fail
/// there rather than being collapsed on the way. Nothing here parses a
/// contact, compares a fingerprint or confers trust: a QR carries public data
/// only, and the user still has to compare the full fingerprint on the other
/// phone (`docs/protocol/first-contact-v1.md:90-91`).
///
/// The string is therefore never rewritten. `checkedPayload` and
/// `checkedImport` measure it and hand back exactly what they were given, and
/// `image(for:)` encodes those very bytes, so the text a peer scans is the
/// `contact` member the core produced, byte for byte. Android re-serialises
/// that member through `org.json` before encoding it
/// (`MainActivity.java:612-614`); here it is sliced out of the reply verbatim
/// by `SelfServiceClient.contactText()` and passed straight through.
///
/// ZXing is replaced by `CIQRCodeGenerator` with `inputCorrectionLevel` `M`,
/// the level Android asks ZXing for (`QrCodec.java:16`). Decoding is not here:
/// the scanner reads `AVCaptureMetadataOutput` frames, which never leave the
/// capture session.
public enum QrCodec {
    /// Largest QR payload, in UTF-8 bytes (`key-enrollment-v1.md:93`,
    /// `QrCodec.java:12`).
    public static let payloadLimit = 2048

    /// Largest pasted or imported contact, in UTF-8 bytes
    /// (`key-enrollment-v1.md:94`; the core answers `qr_limit` above it,
    /// `clean_service.rs:831-833`).
    public static let importLimit = 4096

    /// Smallest side of a generated QR image, in pixels.
    ///
    /// Android renders the contact at 640 px (`MainActivity.java:614`) and the
    /// v15 scanner fix is the reason: a dense `paranoid-contact-v2` code needs
    /// enough pixels per module to survive a camera
    /// (`QrScanActivity.java:42-47`, `QrDenseSmoke.java:5-6`). The generator
    /// emits one pixel per module, so the image is scaled by a whole number
    /// with nearest-neighbour sampling — every module keeps the same integer
    /// size and no interpolation softens an edge.
    public static let minimumSide = 640

    /// The quiet zone around the code, in modules — the white margin a
    /// decoder needs to find the symbol at all. Four is what the standard
    /// asks for and what Android hands ZXing (`QrCodec.java:16`,
    /// `EncodeHintType.MARGIN`); `CIQRCodeGenerator` emits one, so the other
    /// three are added here rather than left to whatever the screen puts
    /// behind the image.
    public static let quietZoneModules = 4

    /// Why a payload was refused. Every case is a local bound; a contact that
    /// is merely wrong is the core's to reject.
    public enum Failure: Error, Equatable, Sendable {
        /// Nothing to encode or import (`QrCodec.java:12`).
        case empty
        /// Above the 2048-byte QR bound, so not a ParanoID contact QR.
        case payloadTooLong(bytes: Int)
        /// Above the 4096-byte import bound the core also enforces.
        case importTooLong(bytes: Int)
        /// `CIQRCodeGenerator` produced no image for these bytes.
        case notEncodable
    }

    /// `raw` unchanged, once it fits the 2048-byte QR bound.
    ///
    /// This is the rule on both sides of the camera: the contact this device
    /// shows is encoded through it, and a payload a scanned code carries is
    /// measured by it before anything else looks at it. The returned string
    /// is the argument, not a normalised copy of it.
    @discardableResult
    public static func checkedPayload(_ raw: String) throws -> String {
        let bytes = raw.utf8.count
        guard bytes > 0 else { throw Failure.empty }
        guard bytes <= payloadLimit else { throw Failure.payloadTooLong(bytes: bytes) }
        return raw
    }

    /// `raw` unchanged, once it fits the 4096-byte import bound.
    ///
    /// The paste field is wider than a QR because a contact may also arrive as
    /// text; the core applies the same 4096 bytes and answers `qr_limit`
    /// above it. Whitespace is not stripped here — the caller that trimmed a
    /// pasted field passes the trimmed text, and nothing else touches it.
    @discardableResult
    public static func checkedImport(_ raw: String) throws -> String {
        let bytes = raw.utf8.count
        guard bytes > 0 else { throw Failure.empty }
        guard bytes <= importLimit else { throw Failure.importTooLong(bytes: bytes) }
        return raw
    }

    /// The QR of `payload`, at least `minimumSide` pixels on a side.
    ///
    /// `payload` must be the exact text the peer is meant to receive: its
    /// UTF-8 bytes are what the code carries. The generator emits one pixel
    /// per module with a one-module quiet zone; the rest of the quiet zone is
    /// added, and the whole thing is then multiplied by the smallest whole
    /// number that reaches `minimumSide`.
    public static func image(for payload: String,
                             minimumSide: Int = minimumSide) throws -> CGImage {
        let text = try checkedPayload(payload)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw Failure.notEncodable
        }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let coded = filter.outputImage, coded.extent.width >= 1 else {
            throw Failure.notEncodable
        }
        // The missing three modules of the quiet zone, in white, so that the
        // code is found even against a dark background.
        let border = CGFloat(max(0, quietZoneModules - 1))
        let area = coded.extent.insetBy(dx: -border, dy: -border)
        let bordered = coded.composited(over: CIImage(color: .white).cropped(to: area))
        let scale = Self.scale(modules: bordered.extent.width, minimumSide: minimumSide)
        let scaled = bordered
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // No colour management: the image is one bit of information per
        // module and must reach the screen as written.
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let image = context.createCGImage(scaled, from: scaled.extent) else {
            throw Failure.notEncodable
        }
        return image
    }

    /// The whole-number factor that takes `modules` pixels to at least
    /// `minimumSide`, never below 1.
    private static func scale(modules: CGFloat, minimumSide: Int) -> CGFloat {
        guard modules >= 1, minimumSide > 0 else { return 1 }
        return max(1, (CGFloat(minimumSide) / modules).rounded(.up))
    }
}
