import CryptoKit
import Foundation
import ParanoidKit
import XCTest

/// Host-side checks of the hand-written ASN.1 walk over a real certificate.
///
/// The certificate is not committed: every run generates a throw-away identity
/// with `scripts/create-test-tls.py --ip 127.0.0.1` into a private temporary
/// directory and deletes it afterwards, exactly the way
/// `clients/ios/local_stand.py` makes the identity of the local stand. That
/// keeps the fixture rule of `clients/ios/test/fixtures/README.md` — no
/// private key and no certificate ever enters git — and it checks the walker
/// against what OpenSSL 3 really emits instead of against a frozen blob.
///
/// The descriptor the script prints (`public-connection.json`) carries
/// `tls_spki_sha256`, computed by OpenSSL over the DER of
/// `subjectPublicKeyInfo`. That digest is the server pin, so the first test is
/// the one that matters: the SPKI this walker slices out of `tbsCertificate`
/// must digest to exactly that value, or every pinned connection would fail.
final class X509LeafTests: XCTestCase {
    private struct FixtureFailure: Error, CustomStringConvertible {
        let description: String
    }

    private struct Fixture {
        /// DER of `server.crt`.
        let certificate: [UInt8]
        /// `tls_spki_sha256` from `public-connection.json` (64 lowercase hex).
        let spkiDigest: String
        /// `server_url` from the same descriptor.
        let serverURL: String
    }

    // MARK: - The generated certificate

    func testSubjectPublicKeyInfoDigestIsTheServerPinFromTheDescriptor() throws {
        let fixture = try loopbackFixture()
        let leaf = try X509Leaf(der: fixture.certificate)

        let digest = SHA256.hash(data: Data(leaf.subjectPublicKeyInfo)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, fixture.spkiDigest, "SPKI digest must equal tls_spki_sha256 of public-connection.json")
        XCTAssertEqual(fixture.serverURL, "https://127.0.0.1:38443")

        // The SPKI is the seventh field of the tbsCertificate and is carried
        // with its own header, so it is a contiguous run of the certificate.
        XCTAssertEqual(leaf.publicKeyAlgorithm, X509Leaf.OID.ecPublicKey)
        XCTAssertEqual(leaf.subjectPublicKeyInfo.first, 0x30)
        XCTAssertTrue(Self.contains(fixture.certificate, leaf.subjectPublicKeyInfo),
                      "subjectPublicKeyInfo must be verbatim certificate octets")
    }

    func testSubjectAlternativeNameCarriesOnlyTheLoopbackAddress() throws {
        let leaf = try X509Leaf(der: try loopbackFixture().certificate)
        let names = try XCTUnwrap(leaf.subjectAlternativeNames())
        XCTAssertEqual(names.ipAddresses, [[127, 0, 0, 1]])
        XCTAssertEqual(names.dnsNames, [])
        XCTAssertEqual(names.otherNameCount, 0)
        // `-addext subjectAltName=IP:…` leaves the extension non-critical;
        // the SAN-only rule lives in the evaluator, not in the certificate.
        let san = try XCTUnwrap(leaf.extensions.first { $0.oid == X509Leaf.OID.subjectAltName })
        XCTAssertFalse(san.isCritical)
    }

    func testKeyUsageAndExtendedKeyUsageAreTheServerAuthPair() throws {
        let leaf = try X509Leaf(der: try loopbackFixture().certificate)
        let usage = try XCTUnwrap(leaf.keyUsage())
        XCTAssertEqual(usage, X509Leaf.KeyUsage.digitalSignature)
        XCTAssertTrue(usage.contains(.digitalSignature))
        XCTAssertFalse(usage.contains(.keyCertSign))
        XCTAssertEqual(try leaf.extendedKeyUsage(), [X509Leaf.OID.serverAuth])
        XCTAssertTrue(try XCTUnwrap(leaf.extensions.first { $0.oid == X509Leaf.OID.keyUsage }).isCritical,
                      "keyUsage is generated as critical")
    }

    func testBasicConstraintsIsCriticalAndNotACertificateAuthority() throws {
        let leaf = try X509Leaf(der: try loopbackFixture().certificate)
        let constraints = try XCTUnwrap(leaf.basicConstraints())
        XCTAssertFalse(constraints.isCertificateAuthority, "CA:FALSE")
        XCTAssertNil(constraints.pathLength)
        let extn = try XCTUnwrap(leaf.extensions.first { $0.oid == X509Leaf.OID.basicConstraints })
        XCTAssertTrue(extn.isCritical)
        // Every extension is listed once, the four the leaf checks read are
        // there, and the only critical ones are basicConstraints and keyUsage:
        // OpenSSL 3 also writes a subject and an authority key identifier, and
        // both are non-critical, so the "no unknown critical extension" rule
        // has nothing to refuse here.
        let oids = leaf.extensions.map(\.oid)
        XCTAssertEqual(oids.count, Set(oids).count)
        for required in [X509Leaf.OID.basicConstraints, X509Leaf.OID.keyUsage,
                         X509Leaf.OID.extendedKeyUsage, X509Leaf.OID.subjectAltName] {
            XCTAssertTrue(oids.contains(required), "missing extension \(required)")
        }
        XCTAssertEqual(leaf.extensions.filter(\.isCritical).map(\.oid).sorted(),
                       [X509Leaf.OID.keyUsage, X509Leaf.OID.basicConstraints].sorted())
    }

    func testSelfIssuedShapeAndValidityAreExposedForTheTrustEvaluator() throws {
        let fixture = try loopbackFixture()
        let leaf = try X509Leaf(der: fixture.certificate)
        XCTAssertEqual(leaf.version, 3)
        XCTAssertEqual(leaf.issuer, leaf.subject, "self-signed leaf: issuer and subject DER are identical")
        XCTAssertEqual(leaf.signatureAlgorithm, X509Leaf.OID.ecdsaWithSHA256)

        // The signature is an ECDSA-Sig-Value over the tbsCertificate octets,
        // which are a verbatim run of the certificate (what check 5 verifies).
        XCTAssertTrue(Self.contains(fixture.certificate, leaf.tbsCertificate))
        XCTAssertEqual(leaf.tbsCertificate.first, 0x30)
        let signature = try DERElement.parse(leaf.signature)
        XCTAssertEqual(signature.tag, DERTag.sequence)
        XCTAssertEqual(try signature.children().map(\.tag), [DERTag.integer, DERTag.integer])

        let now = Date()
        XCTAssertLessThanOrEqual(leaf.notBefore, now)
        XCTAssertGreaterThan(leaf.notAfter, now)
        XCTAssertEqual(leaf.notAfter.timeIntervalSince(leaf.notBefore), 90 * 24 * 3600, accuracy: 1,
                       "create-test-tls.py issues for 90 days")
    }

    func testTruncatedOrPaddedCertificateIsRejectedWithoutCrashing() throws {
        let certificate = try loopbackFixture().certificate
        XCTAssertNoThrow(try X509Leaf(der: certificate))

        // Every proper prefix: the outermost length always claims more octets
        // than are left, so the walk stops with `.truncated` instead of
        // reading past the buffer.
        for length in 0..<certificate.count {
            XCTAssertThrowsError(try X509Leaf(der: Array(certificate.prefix(length))),
                                 "prefix of \(length) octets must be refused") { error in
                XCTAssertEqual(error as? DERError, .truncated)
            }
        }
        XCTAssertThrowsError(try X509Leaf(der: certificate + [0x00])) { error in
            XCTAssertEqual(error as? DERError, .unexpected("trailing octets after the top-level element"))
        }
        // A certificate whose body is cut but whose outer length was patched
        // to match: the inner tbsCertificate now overruns its parent.
        var shortened = Array(certificate.dropLast(16))
        XCTAssertEqual(shortened[1], 0x82, "expected a two-octet outer length")
        let patched = shortened.count - 4
        shortened[2] = UInt8(patched >> 8)
        shortened[3] = UInt8(patched & 0xff)
        XCTAssertThrowsError(try X509Leaf(der: shortened))
    }

    // MARK: - DER rules, on hand-written encodings

    func testReaderRefusesLengthsAndTagsThatAreNotDer() {
        // Indefinite length (BER), long form for a length below 128, a length
        // with a leading zero octet, a multi-byte tag, a missing length octet.
        let cases: [([UInt8], DERError)] = [
            ([0x30, 0x80, 0x00, 0x00], .malformed("indefinite length")),
            ([0x02, 0x81, 0x01, 0x05], .malformed("non-minimal length")),
            ([0x02, 0x82, 0x00, 0x01, 0x05], .malformed("non-minimal length")),
            ([0x1f, 0x01, 0x00], .malformed("multi-byte tag")),
            ([0x30], .truncated),
            ([0x30, 0x03, 0x02, 0x01], .truncated),
        ]
        for (bytes, expected) in cases {
            XCTAssertThrowsError(try DERElement.parse(bytes), "\(bytes)") { error in
                XCTAssertEqual(error as? DERError, expected, "\(bytes)")
            }
        }
        XCTAssertEqual(try? DERElement.parse([0x02, 0x01, 0x05]).integer(), 5)
        XCTAssertEqual(try? DERElement.parse([0x30, 0x03, 0x02, 0x01, 0x05]).children().count, 1)
    }

    func testScalarDecodingFollowsTheDerRules() throws {
        XCTAssertEqual(try Sample.tlv(0x06, [0x55, 0x1d, 0x11]).parsed().objectIdentifier(),
                       X509Leaf.OID.subjectAltName)
        XCTAssertEqual(try Sample.tlv(0x06, [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]).parsed().objectIdentifier(),
                       X509Leaf.OID.serverAuth)
        XCTAssertThrowsError(try Sample.tlv(0x06, [0x55, 0x80, 0x81, 0x11]).parsed().objectIdentifier())
        XCTAssertThrowsError(try Sample.tlv(0x06, [0x55, 0x81]).parsed().objectIdentifier())

        XCTAssertEqual(try Sample.tlv(0x01, [0xff]).parsed().boolean(), true)
        XCTAssertThrowsError(try Sample.tlv(0x01, [0x01]).parsed().boolean())
        XCTAssertThrowsError(try Sample.tlv(0x02, [0x00, 0x05]).parsed().integer(), "non-minimal INTEGER")
        XCTAssertThrowsError(try Sample.tlv(0x02, [0x81]).parsed().integer(), "negative INTEGER")
        XCTAssertEqual(try Sample.tlv(0x02, [0x00, 0x80]).parsed().integer(), 128)

        // RFC 5280 reads a two-digit year below 50 as 20xx, 50 and above as
        // 19xx; a certificate time is always whole seconds in UTC.
        let formatter = ISO8601DateFormatter()
        XCTAssertEqual(try Sample.time("490101000000Z").parsed().time(),
                       try XCTUnwrap(formatter.date(from: "2049-01-01T00:00:00Z")))
        XCTAssertEqual(try Sample.time("500101000000Z").parsed().time(),
                       try XCTUnwrap(formatter.date(from: "1950-01-01T00:00:00Z")))
        XCTAssertEqual(try Sample.tlv(0x18, Array("20260911120000Z".utf8)).parsed().time(),
                       try XCTUnwrap(formatter.date(from: "2026-09-11T12:00:00Z")))
        XCTAssertThrowsError(try Sample.time("2609111200Z").parsed().time(), "no seconds")
        XCTAssertThrowsError(try Sample.time("260911120000+0300").parsed().time(), "offset instead of Z")
        XCTAssertThrowsError(try Sample.time("261311120000Z").parsed().time(), "month 13")
        XCTAssertThrowsError(try Sample.time("26091112000xZ").parsed().time(), "non-digit")
    }

    func testExtensionListRefusesDuplicatesAndEncodedDefaults() throws {
        let serverAuth = Sample.tlv(0x30, Sample.tlv(0x06, [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]))
        let eku = Sample.extensionEntry(oid: [0x55, 0x1d, 0x25], critical: nil, value: serverAuth)
        let criticalEku = Sample.extensionEntry(oid: [0x55, 0x1d, 0x25], critical: true, value: serverAuth)

        let plain = try X509Leaf(der: Sample.certificate(extensions: [eku]))
        XCTAssertEqual(try plain.extendedKeyUsage(), [X509Leaf.OID.serverAuth])
        XCTAssertEqual(plain.extensions.map(\.isCritical), [false])
        XCTAssertEqual(try X509Leaf(der: Sample.certificate(extensions: [criticalEku])).extensions.map(\.isCritical),
                       [true])

        // The same extnID twice would let a second, ignored copy contradict
        // the first; DER also forbids writing a DEFAULT value.
        XCTAssertThrowsError(try X509Leaf(der: Sample.certificate(extensions: [eku, criticalEku]))) { error in
            XCTAssertEqual(error as? DERError, .unexpected("extension 2.5.29.37 appears twice"))
        }
        let explicitFalse = Sample.extensionEntry(oid: [0x55, 0x1d, 0x25], critical: false, value: serverAuth)
        XCTAssertThrowsError(try X509Leaf(der: Sample.certificate(extensions: [explicitFalse]))) { error in
            XCTAssertEqual(error as? DERError, .malformed("critical FALSE must be omitted, not encoded"))
        }
        // A certificate whose signatureAlgorithm does not repeat the one
        // inside the tbsCertificate is refused outright.
        XCTAssertThrowsError(try X509Leaf(der: Sample.certificate(extensions: [eku], mismatchedAlgorithm: true)))
        XCTAssertEqual(try X509Leaf(der: Sample.certificate(extensions: [])).extensions, [])
    }

    // MARK: - Fixture generation

    /// One throw-away self-signed identity for `127.0.0.1`, made by the
    /// repository's own script and removed when the test method ends.
    private func loopbackFixture() throws -> Fixture {
        let version = try Self.run("openssl", ["version"])
        guard version.status == 0, version.output.hasPrefix("OpenSSL 3") else {
            throw FixtureFailure(description: """
                OpenSSL 3 is required for the TLS fixtures (LibreSSL has no -addext); \
                `openssl version` said \(version.output.trimmingCharacters(in: .whitespacesAndNewlines))
                """)
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("paranoid-x509-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }

        let identity = workspace.appendingPathComponent("tls", isDirectory: true)
        let script = Self.repositoryRoot.appendingPathComponent("scripts/create-test-tls.py")
        let created = try Self.run("python3", [script.path, "--ip", "127.0.0.1", "--output", identity.path])
        guard created.status == 0 else {
            throw FixtureFailure(description: "create-test-tls.py exited \(created.status): \(created.error)")
        }

        let pem = try String(contentsOf: identity.appendingPathComponent("server.crt"), encoding: .utf8)
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64), !der.isEmpty else {
            throw FixtureFailure(description: "server.crt is not a PEM certificate")
        }
        let descriptor = try Data(contentsOf: identity.appendingPathComponent("public-connection.json"))
        guard let object = try JSONSerialization.jsonObject(with: descriptor) as? [String: Any],
              let digest = object["tls_spki_sha256"] as? String,
              let url = object["server_url"] as? String else {
            throw FixtureFailure(description: "public-connection.json is not the expected descriptor")
        }
        return Fixture(certificate: Array(der), spkiDigest: digest, serverURL: url)
    }

    /// The repository root, from this file's own path:
    /// `clients/ios/ParanoidKit/Tests/ParanoidKitTests/X509LeafTests.swift`.
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    private static func run(_ command: String, _ arguments: [String]) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Both streams carry at most a JSON line, far below the pipe buffer.
        let text = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: text, as: UTF8.self),
                String(decoding: failure, as: UTF8.self))
    }

    /// True when `needle` appears in `haystack` as a contiguous run.
    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            Array(haystack[start..<(start + needle.count)]) == needle
        }
    }
}

/// Hand-written DER, so the rules that OpenSSL never breaks can be tested too.
private enum Sample {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var header: [UInt8] = [tag]
        switch content.count {
        case ..<0x80: header.append(UInt8(content.count))
        case ..<0x100: header += [0x81, UInt8(content.count)]
        default: header += [0x82, UInt8(content.count >> 8), UInt8(content.count & 0xff)]
        }
        return header + content
    }

    static func time(_ text: String) -> [UInt8] { tlv(0x17, Array(text.utf8)) }

    static func extensionEntry(oid: [UInt8], critical: Bool?, value: [UInt8]) -> [UInt8] {
        var content = tlv(0x06, oid)
        if let critical { content += tlv(0x01, [critical ? 0xff : 0x00]) }
        return tlv(0x30, content + tlv(0x04, value))
    }

    /// A v3 certificate with empty names and a stub key: enough structure for
    /// the walk, none of the cryptography (nothing here is ever verified).
    static func certificate(extensions: [[UInt8]], mismatchedAlgorithm: Bool = false) -> [UInt8] {
        let ecdsaWithSHA256 = tlv(0x30, tlv(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]))
        let sha256WithRSA = tlv(0x30, tlv(0x06, [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]))
        let key = tlv(0x30, tlv(0x30, tlv(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01])
                                + tlv(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]))
                      + tlv(0x03, [0x00, 0x04] + [UInt8](repeating: 0x07, count: 64)))
        var tbs = tlv(0xa0, tlv(0x02, [0x02]))          // [0] version v3
            + tlv(0x02, [0x01])                          // serialNumber
            + ecdsaWithSHA256                            // signature
            + tlv(0x30, [])                              // issuer: empty RDNSequence
            + tlv(0x30, time("260101000000Z") + time("260401000000Z"))
            + tlv(0x30, [])                              // subject
            + key
        if !extensions.isEmpty {
            tbs += tlv(0xa3, tlv(0x30, extensions.flatMap { $0 }))
        }
        return tlv(0x30, tlv(0x30, tbs)
                   + (mismatchedAlgorithm ? sha256WithRSA : ecdsaWithSHA256)
                   + tlv(0x03, [0x00] + tlv(0x30, tlv(0x02, [0x01]) + tlv(0x02, [0x01]))))
    }
}

private extension Array where Element == UInt8 {
    /// The single element these octets encode.
    func parsed() throws -> DERElement { try DERElement.parse(self) }
}
