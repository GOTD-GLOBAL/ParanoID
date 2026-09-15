import Foundation

/// The fields of one X.509 certificate, read straight out of its DER.
///
/// The pinned trust check needs more of a certificate than `Security.framework`
/// hands out: `SecCertificateCopyValues` — the API that returns a parsed
/// certificate on macOS — does not exist on iOS, and the accessors that do
/// (`SecCertificateCopyKey`, `…CopySubjectSummary`) reach neither the
/// extensions, nor the validity dates, nor the `tbsCertificate` octets a
/// self-signature is computed over. So the leaf is walked here, by hand, with
/// `DERReader`, and `Security.framework` is used only for the cryptography
/// (`SecKeyVerifySignature`, key size) in `PinnedTrustEvaluator`.
///
/// This type only reads. It applies no policy: an expired certificate, a CA
/// certificate and a certificate for the wrong address all parse. Deciding
/// which of them a pinned connection may use is `PinnedTrustEvaluator`'s job
/// (the eight leaf checks of `PinnedTls.java:54-70`).
///
/// Every failure is a thrown `DERError`; nothing here traps, so a truncated or
/// hostile certificate from the network ends as a rejected handshake.
public struct X509Leaf: Sendable {
    /// One entry of the `extensions [3]` list, with its value still in DER.
    public struct Extension: Equatable, Sendable {
        /// Dotted decimal `extnID`.
        public let oid: String
        /// `critical`; absent in the encoding means `false` (DER writes no
        /// `DEFAULT` value, and an explicit `FALSE` is refused as malformed).
        public let isCritical: Bool
        /// The content octets of `extnValue`, i.e. the DER of the extension's
        /// own structure with the wrapping `OCTET STRING` removed.
        public let value: [UInt8]
    }

    /// `BasicConstraints` (RFC 5280 §4.2.1.9).
    public struct BasicConstraints: Equatable, Sendable {
        public let isCertificateAuthority: Bool
        public let pathLength: Int?
    }

    /// `KeyUsage` (RFC 5280 §4.2.1.3); bit 0 is the first bit of the first
    /// octet of the `BIT STRING`.
    public struct KeyUsage: OptionSet, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let digitalSignature = KeyUsage(rawValue: 1 << 0)
        public static let contentCommitment = KeyUsage(rawValue: 1 << 1)
        public static let keyEncipherment = KeyUsage(rawValue: 1 << 2)
        public static let dataEncipherment = KeyUsage(rawValue: 1 << 3)
        public static let keyAgreement = KeyUsage(rawValue: 1 << 4)
        public static let keyCertSign = KeyUsage(rawValue: 1 << 5)
        public static let crlSign = KeyUsage(rawValue: 1 << 6)
        public static let encipherOnly = KeyUsage(rawValue: 1 << 7)
        public static let decipherOnly = KeyUsage(rawValue: 1 << 8)
    }

    /// `SubjectAltName` (RFC 5280 §4.2.1.6), split into the two name forms a
    /// pinned realm can carry. `otherNameCount` keeps the rest visible without
    /// decoding it, so a certificate that names the server only through a form
    /// this client does not match cannot look like an empty SAN.
    public struct SubjectAlternativeNames: Equatable, Sendable {
        /// `[7] iPAddress`, verbatim: four octets for IPv4, sixteen for IPv6.
        public let ipAddresses: [[UInt8]]
        /// `[2] dNSName`, as written (IA5String, no case folding here).
        public let dnsNames: [String]
        /// Number of general names of any other form.
        public let otherNameCount: Int
    }

    /// The object identifiers this client compares against.
    public enum OID {
        public static let keyUsage = "2.5.29.15"
        public static let subjectAltName = "2.5.29.17"
        public static let basicConstraints = "2.5.29.19"
        public static let extendedKeyUsage = "2.5.29.37"
        /// `id-kp-serverAuth`, the only extended key usage a pinned server may
        /// present.
        public static let serverAuth = "1.3.6.1.5.5.7.3.1"
        public static let ecPublicKey = "1.2.840.10045.2.1"
        public static let rsaEncryption = "1.2.840.113549.1.1.1"
        public static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
        public static let sha256WithRSAEncryption = "1.2.840.113549.1.1.11"
    }

    /// The certificate as it arrived.
    public let der: [UInt8]
    /// `tbsCertificate` with its header: the exact octets the signature is
    /// computed over.
    public let tbsCertificate: [UInt8]
    /// `version`, already decoded to 1, 2 or 3 (the encoding stores 0, 1, 2).
    public let version: Int
    /// `issuer` as encoded, for the byte comparison that decides whether the
    /// leaf is self-issued; the `Name` is never turned into a string.
    public let issuer: [UInt8]
    /// `subject` as encoded.
    public let subject: [UInt8]
    public let notBefore: Date
    public let notAfter: Date
    /// `subjectPublicKeyInfo` with its header: the octets whose SHA-256 is the
    /// server pin, and the DER `SecKeyCreateWithData` is fed after the
    /// algorithm is checked.
    public let subjectPublicKeyInfo: [UInt8]
    /// The algorithm identifier inside `subjectPublicKeyInfo`.
    public let publicKeyAlgorithm: String
    /// `signatureAlgorithm` of the certificate. RFC 5280 §4.1.1.2 requires it
    /// to repeat `tbsCertificate.signature`; a certificate where the two
    /// disagree does not parse.
    public let signatureAlgorithm: String
    /// `signatureValue`, the `BIT STRING` content without its unused-bit
    /// octet.
    public let signature: [UInt8]
    /// `extensions [3]`, in the order the certificate lists them, with no
    /// `extnID` appearing twice.
    public let extensions: [Extension]

    /// Walks one DER certificate.
    ///
    /// - Throws: `DERError` for anything that is not exactly one
    ///   `Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm,
    ///   signatureValue }` whose `tbsCertificate` holds the seven fields of
    ///   RFC 5280 §4.1 in order.
    public init(der: [UInt8]) throws {
        let certificate = try DERElement.parse(der)
        guard certificate.tag == DERTag.sequence else { throw DERError.unexpected("Certificate must be a SEQUENCE") }
        let top = try certificate.children()
        guard top.count == 3, top[0].tag == DERTag.sequence else {
            throw DERError.unexpected("Certificate must hold tbsCertificate, signatureAlgorithm and signatureValue")
        }
        let outerAlgorithm = try Self.algorithm(top[1])
        let (unused, signatureBits) = try top[2].bitString()
        guard unused == 0 else { throw DERError.malformed("signatureValue must be whole octets") }

        var fields = try top[0].children()[...]
        var version = 1
        if let first = fields.first, first.tag == DERTag.context(0) {
            let inner = try first.children()
            guard inner.count == 1 else { throw DERError.unexpected("version must be one INTEGER") }
            version = try inner[0].integer() + 1
            guard (2...3).contains(version) else { throw DERError.unexpected("unsupported certificate version") }
            fields = fields.dropFirst()
        }
        // serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo.
        guard fields.count >= 6 else { throw DERError.unexpected("tbsCertificate is missing fields") }
        let body = Array(fields.prefix(6))
        guard body[0].tag == DERTag.integer else { throw DERError.unexpected("serialNumber must be an INTEGER") }
        guard try Self.algorithm(body[1]) == outerAlgorithm else {
            throw DERError.unexpected("signatureAlgorithm does not repeat tbsCertificate.signature")
        }
        guard body[2].tag == DERTag.sequence, body[3].tag == DERTag.sequence,
              body[4].tag == DERTag.sequence, body[5].tag == DERTag.sequence else {
            throw DERError.unexpected("issuer, validity, subject and subjectPublicKeyInfo must be SEQUENCEs")
        }
        let validity = try body[3].children()
        guard validity.count == 2 else { throw DERError.unexpected("validity must hold notBefore and notAfter") }
        let publicKey = try body[5].children()
        guard publicKey.count == 2, publicKey[1].tag == DERTag.bitString else {
            throw DERError.unexpected("subjectPublicKeyInfo must hold an AlgorithmIdentifier and a BIT STRING")
        }

        self.der = der
        self.tbsCertificate = top[0].encoded
        self.version = version
        self.issuer = body[2].encoded
        self.subject = body[4].encoded
        self.notBefore = try validity[0].time()
        self.notAfter = try validity[1].time()
        self.subjectPublicKeyInfo = body[5].encoded
        self.publicKeyAlgorithm = try Self.algorithm(publicKey[0])
        self.signatureAlgorithm = outerAlgorithm
        self.signature = signatureBits
        self.extensions = try Self.extensions(in: fields.dropFirst(6))
    }

    /// The `extnValue` octets of `oid`, or `nil` when the certificate carries
    /// no such extension.
    public func extensionValue(_ oid: String) -> [UInt8]? {
        extensions.first { $0.oid == oid }?.value
    }

    /// `BasicConstraints`, or `nil` when the extension is absent (which RFC
    /// 5280 reads as "not a CA").
    public func basicConstraints() throws -> BasicConstraints? {
        guard let value = extensionValue(OID.basicConstraints) else { return nil }
        let parts = try Self.sequence(value, "BasicConstraints", allowEmpty: true)
        var index = 0
        var isCA = false
        if index < parts.count, parts[index].tag == DERTag.boolean {
            isCA = try parts[index].boolean()
            guard isCA else { throw DERError.malformed("cA FALSE must be omitted, not encoded") }
            index += 1
        }
        var pathLength: Int?
        if index < parts.count, parts[index].tag == DERTag.integer {
            pathLength = try parts[index].integer()
            index += 1
        }
        guard index == parts.count else { throw DERError.unexpected("unexpected member in BasicConstraints") }
        return BasicConstraints(isCertificateAuthority: isCA, pathLength: pathLength)
    }

    /// `KeyUsage`, or `nil` when the extension is absent.
    public func keyUsage() throws -> KeyUsage? {
        guard let value = extensionValue(OID.keyUsage) else { return nil }
        let (unused, bytes) = try DERElement.parse(value).bitString()
        guard !bytes.isEmpty, bytes.count <= 2 else { throw DERError.unexpected("KeyUsage holds one to nine bits") }
        let bits = bytes.count * 8 - unused
        var usage = KeyUsage(rawValue: 0)
        for (offset, byte) in bytes.enumerated() {
            for bit in 0..<8 where byte & (UInt8(0x80) >> bit) != 0 {
                let position = offset * 8 + bit
                guard position < bits else { throw DERError.malformed("KeyUsage bit set inside the unused tail") }
                usage.insert(KeyUsage(rawValue: 1 << UInt16(position)))
            }
        }
        return usage
    }

    /// `ExtKeyUsageSyntax`, or `nil` when the extension is absent.
    public func extendedKeyUsage() throws -> [String]? {
        guard let value = extensionValue(OID.extendedKeyUsage) else { return nil }
        let parts = try Self.sequence(value, "ExtKeyUsageSyntax", allowEmpty: false)
        return try parts.map { try $0.objectIdentifier() }
    }

    /// `SubjectAltName`, or `nil` when the extension is absent.
    public func subjectAlternativeNames() throws -> SubjectAlternativeNames? {
        guard let value = extensionValue(OID.subjectAltName) else { return nil }
        let names = try Self.sequence(value, "SubjectAltName", allowEmpty: false)
        var ipAddresses: [[UInt8]] = []
        var dnsNames: [String] = []
        var others = 0
        for name in names {
            switch name.contextNumber {
            case 2 where !name.isConstructed:
                guard let text = String(bytes: name.content, encoding: .ascii) else {
                    throw DERError.malformed("dNSName is not IA5String")
                }
                dnsNames.append(text)
            case 7 where !name.isConstructed:
                guard name.content.count == 4 || name.content.count == 16 else {
                    throw DERError.malformed("iPAddress must be 4 or 16 octets")
                }
                ipAddresses.append(name.content)
            default:
                others += 1
            }
        }
        return SubjectAlternativeNames(ipAddresses: ipAddresses, dnsNames: dnsNames, otherNameCount: others)
    }

    // MARK: - Reading helpers

    /// The `algorithm` OID of an `AlgorithmIdentifier`; the optional
    /// parameters are left alone (they belong to `SecKeyCreateWithData`).
    private static func algorithm(_ element: DERElement) throws -> String {
        guard element.tag == DERTag.sequence else { throw DERError.unexpected("AlgorithmIdentifier must be a SEQUENCE") }
        let parts = try element.children()
        guard (1...2).contains(parts.count) else { throw DERError.unexpected("malformed AlgorithmIdentifier") }
        return try parts[0].objectIdentifier()
    }

    /// The members of a `SEQUENCE` that is the whole of `value`.
    private static func sequence(_ value: [UInt8], _ what: String, allowEmpty: Bool) throws -> [DERElement] {
        let element = try DERElement.parse(value)
        guard element.tag == DERTag.sequence else { throw DERError.unexpected("\(what) must be a SEQUENCE") }
        let parts = try element.children()
        guard allowEmpty || !parts.isEmpty else { throw DERError.unexpected("\(what) must not be empty") }
        return parts
    }

    /// The `extensions [3] EXPLICIT` list of a `tbsCertificate`, skipping the
    /// optional `issuerUniqueID [1]` / `subjectUniqueID [2]` before it.
    private static func extensions(in fields: ArraySlice<DERElement>) throws -> [Extension] {
        guard let wrapper = fields.first(where: { $0.tag == DERTag.context(3) }) else { return [] }
        let inner = try wrapper.children()
        guard inner.count == 1 else { throw DERError.unexpected("extensions must hold one SEQUENCE") }
        var result: [Extension] = []
        var seen: Set<String> = []
        for entry in try Self.sequence(inner[0].encoded, "Extensions", allowEmpty: false) {
            guard entry.tag == DERTag.sequence else { throw DERError.unexpected("Extension must be a SEQUENCE") }
            let parts = try entry.children()
            guard (2...3).contains(parts.count) else { throw DERError.unexpected("malformed Extension") }
            let oid = try parts[0].objectIdentifier()
            guard seen.insert(oid).inserted else { throw DERError.unexpected("extension \(oid) appears twice") }
            var isCritical = false
            if parts.count == 3 {
                isCritical = try parts[1].boolean()
                guard isCritical else { throw DERError.malformed("critical FALSE must be omitted, not encoded") }
            }
            guard let last = parts.last, last.tag == DERTag.octetString else {
                throw DERError.unexpected("extnValue must be an OCTET STRING")
            }
            result.append(Extension(oid: oid, isCritical: isCritical, value: last.content))
        }
        return result
    }
}
