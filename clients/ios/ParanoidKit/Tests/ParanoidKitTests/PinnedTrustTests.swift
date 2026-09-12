import Foundation
import Security
import XCTest
@testable import ParanoidKit

/// The nine checks of `PinnedTls.java:51-70`, one refusal at a time.
///
/// Nothing here touches the network, and no certificate is committed: every
/// fixture is generated while the test runs into a private temporary directory
/// that the teardown block removes, the rule of
/// `clients/ios/test/fixtures/README.md`. The valid leaf comes from the
/// repository's own `scripts/create-test-tls.py`, so the accepted certificate
/// is exactly the one `clients/ios/local_stand.py` gives the local server; the
/// certificates that must be refused come from `openssl req` with the one
/// property changed that the check under test is about.
///
/// The expected pin is never computed by the code under test: it is read from
/// the `public-connection.json` descriptor of the script, or produced by
/// OpenSSL over the DER of `subjectPublicKeyInfo` the same way the script does
/// (`openssl x509 -pubkey | openssl pkey -outform DER | sha256`). A test that
/// hashed the SPKI with the evaluator's own notion of where the SPKI is would
/// prove nothing about check 2.
final class PinnedTrustTests: XCTestCase {
    // MARK: - Check 1: exactly one certificate

    func testCertificateAuthorityChainIsRefusedBeforeAnyOtherCheck() throws {
        let workspace = try makeWorkspace()
        let chain = try chainedLeaf(in: workspace)
        // The pin is the chained leaf's own key, so check 2 would pass: only
        // the extra certificate can refuse this trust.
        let evaluator = try PinnedTrustEvaluator(host: "127.0.0.1", pin: chain.leaf.pin)
        let trust = try Self.trust(of: [chain.leaf.der, chain.authority.der])

        XCTAssertThrowsError(try evaluator.evaluate(trust)) { error in
            XCTAssertEqual(error as? PinnedTrustFailure, .chain(2))
            XCTAssertEqual((error as? PinnedTrustFailure)?.check, 1)
        }
        // Alone, the same leaf gets past check 1 and is refused by check 5:
        // it was signed by the authority, so it is not self-issued.
        XCTAssertThrowsError(try evaluator.evaluate(try Self.trust(of: [chain.leaf.der]))) { error in
            XCTAssertEqual(error as? PinnedTrustFailure, .notSelfIssued)
        }
    }

    // MARK: - Check 2: the pinned key

    func testTheLeafOfTheLocalStandScriptIsAcceptedUnderItsOwnPin() throws {
        let workspace = try makeWorkspace()
        let stand = try localStandIdentity(in: workspace)
        let evaluator = try PinnedTrustEvaluator(realm: stand.realm, pin: stand.identity.pin)

        XCTAssertEqual(evaluator.host, "127.0.0.1")
        XCTAssertEqual(evaluator.realm, "https://127.0.0.1:38443")
        XCTAssertNoThrow(try evaluator.evaluate(leaf: stand.identity.der))
        XCTAssertNoThrow(try evaluator.evaluate(try Self.trust(of: [stand.identity.der])))
    }

    func testZeroPinAndNeighbouringPinAreRefusedByTheConstantTimeComparison() throws {
        let workspace = try makeWorkspace()
        let identity = try localStandIdentity(in: workspace).identity

        for wrong in [String(repeating: "0", count: 64),
                      String(repeating: "f", count: 64),
                      Self.flippedLastDigit(of: identity.pin)] {
            let evaluator = try PinnedTrustEvaluator(host: "127.0.0.1", pin: wrong)
            XCTAssertThrowsError(try evaluator.evaluate(leaf: identity.der), wrong) { error in
                XCTAssertEqual(error as? PinnedTrustFailure, .pin)
                XCTAssertEqual((error as? PinnedTrustFailure)?.check, 2)
            }
        }
        // The comparison itself: same length, one bit apart, and lengths that
        // differ at all.
        XCTAssertTrue(PinnedTrustEvaluator.constantTimeEqual([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(PinnedTrustEvaluator.constantTimeEqual([1, 2, 3], [1, 2, 2]))
        XCTAssertFalse(PinnedTrustEvaluator.constantTimeEqual([0, 2, 3], [1, 2, 3]))
        XCTAssertFalse(PinnedTrustEvaluator.constantTimeEqual([1, 2, 3], [1, 2, 3, 4]))
        XCTAssertTrue(PinnedTrustEvaluator.constantTimeEqual([], []))
    }

    // MARK: - Check 3: validity

    func testExpiredAndNotYetValidCertificatesAreRefused() throws {
        let workspace = try makeWorkspace()
        let expired = try selfSigned("expired", in: workspace,
                                     validity: ["-not_before", "20200101000000Z", "-not_after", "20200401000000Z"])
        let future = try selfSigned("future", in: workspace,
                                    validity: ["-not_before", "20900101000000Z", "-not_after", "20900401000000Z"])

        for identity in [expired, future] {
            let evaluator = try PinnedTrustEvaluator(host: "127.0.0.1", pin: identity.pin)
            XCTAssertThrowsError(try evaluator.evaluate(leaf: identity.der)) { error in
                XCTAssertEqual(error as? PinnedTrustFailure, .validity)
                XCTAssertEqual((error as? PinnedTrustFailure)?.check, 3)
            }
        }
        // The expired leaf was valid in March 2020, and `now` is what decides:
        // phone time, not a cached verdict.
        let evaluator = try PinnedTrustEvaluator(host: "127.0.0.1", pin: expired.pin)
        let inside = try XCTUnwrap(ISO8601DateFormatter().date(from: "2020-03-01T00:00:00Z"))
        XCTAssertNoThrow(try evaluator.evaluate(leaf: expired.der, at: inside))
    }

    // MARK: - Check 4: critical extensions and CA:FALSE

    func testUnknownCriticalExtensionAndCertificateAuthorityLeafAreRefused() throws {
        let workspace = try makeWorkspace()
        let unknown = try selfSigned("unknown-critical", in: workspace,
                                     extensions: Self.serverExtensions() + ["-addext", "1.3.6.1.4.1.99999.1=critical,DER:05:00"])
        let authority = try selfSigned("ca-leaf", in: workspace,
                                       extensions: ["-addext", "subjectAltName=IP:127.0.0.1",
                                                    "-addext", "basicConstraints=critical,CA:TRUE",
                                                    "-addext", "keyUsage=critical,digitalSignature",
                                                    "-addext", "extendedKeyUsage=serverAuth"])

        XCTAssertThrowsError(try PinnedTrustEvaluator(host: "127.0.0.1", pin: unknown.pin)
            .evaluate(leaf: unknown.der)) { error in
            XCTAssertEqual(error as? PinnedTrustFailure, .criticalExtension("1.3.6.1.4.1.99999.1"))
            XCTAssertEqual((error as? PinnedTrustFailure)?.check, 4)
        }
        XCTAssertThrowsError(try PinnedTrustEvaluator(host: "127.0.0.1", pin: authority.pin)
            .evaluate(leaf: authority.der)) { error in
            XCTAssertEqual(error as? PinnedTrustFailure, .certificateAuthority)
            XCTAssertEqual((error as? PinnedTrustFailure)?.check, 4)
        }
        // A non-critical extension this client does not evaluate is fine: it
        // is what `hasUnsupportedCriticalExtension()` ignores too.
        let extra = try selfSigned("extra-noncritical", in: workspace,
                                   extensions: Self.serverExtensions() + ["-addext", "1.3.6.1.4.1.99999.1=DER:05:00"])
        XCTAssertNoThrow(try PinnedTrustEvaluator(host: "127.0.0.1", pin: extra.pin).evaluate(leaf: extra.der))
    }

    // MARK: - Check 5: self-issued, and the signature actually verified

    func testSignatureCorruptedInOneByteIsRefused() throws {
        let workspace = try makeWorkspace()
        let identity = try localStandIdentity(in: workspace).identity
        let evaluator = try PinnedTrustEvaluator(host: "127.0.0.1", pin: identity.pin)
        XCTAssertNoThrow(try evaluator.evaluate(leaf: identity.der))

        // The last octet of the certificate is the last octet of
        // `signatureValue`: flipping one bit there leaves the DER, the names
        // and the pinned key untouched, so only check 5 can notice. This is
        // the case `SecTrustEvaluateWithError` with the leaf as its own anchor
        // would accept.
        var corrupted = identity.der
        corrupted[corrupted.count - 1] ^= 0x01
        XCTAssertEqual(corrupted.count, identity.der.count)
        XCTAssertThrowsError(try evaluator.evaluate(leaf: corrupted)) { error in
            XCTAssertEqual(error as? PinnedTrustFailure, .signature)
            XCTAssertEqual((error as? PinnedTrustFailure)?.check, 5)
        }
        // And through the whole delegate path, on a real SecTrust.
        let delegate = PinnedSessionDelegate(evaluator: evaluator)
        XCTAssertEqual(delegate.decision(host: "127.0.0.1",
                                         authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                         trust: try Self.trust(of: [corrupted]),
                                         floor: .TLSv12),
                       .cancel(.signature))
    }

    func testSignatureAlgorithmsOutsideTheTwoAllowedOnesAreRefused() throws {
        let workspace = try makeWorkspace()
        // ecdsa-with-SHA512 over a P-256 key: a well-formed certificate that
        // verifies under OpenSSL and that this client still refuses, because
        // the mapping to a `SecKeyAlgorithm` is a closed list.
        let sha512 = try selfSigned("ecdsa-sha512", in: workspace, digest: "-sha512")
        XCTAssertThrowsError(try PinnedTrustEvaluator(host: "127.0.0.1", pin: sha512.pin)
            .evaluate(leaf: sha512.der)) { error in
            XCTAssertEqual(error as? PinnedTrustFailure, .signatureAlgorithm("1.2.840.10045.4.3.4"))
            XCTAssertEqual((error as? PinnedTrustFailure)?.check, 5)
        }
    }

    // MARK: - Check 6: digitalSignature and id-kp-serverAuth

    func testCertificateWithoutServerAuthenticationUsageIsRefused() throws {
        let workspace = try makeWorkspace()
        let noExtended = try selfSigned("no-eku", in: workspace,
                                        extensions: ["-addext", "subjectAltName=IP:127.0.0.1",
                                                     "-addext", "basicConstraints=critical,CA:FALSE",
                                                     "-addext", "keyUsage=critical,digitalSignature"])
        let wrongUsage = try selfSigned("no-digital-signature", in: workspace,
                                        extensions: ["-addext", "subjectAltName=IP:127.0.0.1",
                                                     "-addext", "basicConstraints=critical,CA:FALSE",
                                                     "-addext", "keyUsage=critical,keyEncipherment",
                                                     "-addext", "extendedKeyUsage=serverAuth"])
        let clientOnly = try selfSigned("client-auth", in: workspace,
                                        extensions: ["-addext", "subjectAltName=IP:127.0.0.1",
                                                     "-addext", "basicConstraints=critical,CA:FALSE",
                                                     "-addext", "keyUsage=critical,digitalSignature",
                                                     "-addext", "extendedKeyUsage=clientAuth"])

        for identity in [noExtended, wrongUsage, clientOnly] {
            XCTAssertThrowsError(try PinnedTrustEvaluator(host: "127.0.0.1", pin: identity.pin)
                .evaluate(leaf: identity.der)) { error in
                XCTAssertEqual(error as? PinnedTrustFailure, .serverAuth)
                XCTAssertEqual((error as? PinnedTrustFailure)?.check, 6)
            }
        }
    }

    // MARK: - Check 7: key strength

    func testRsaKeysBelowTwoThousandFortyEightBitsAreRefusedAndTwoThousandFortyEightIsAccepted() throws {
        let workspace = try makeWorkspace()
        let weak = try selfSigned("rsa-1024", in: workspace, key: ["rsa:1024"])
        XCTAssertThrowsError(try PinnedTrustEvaluator(host: "127.0.0.1", pin: weak.pin)
            .evaluate(leaf: weak.der)) { error in
            XCTAssertEqual(error as? PinnedTrustFailure, .keyStrength(kSecAttrKeyTypeRSA as String, 1024))
            XCTAssertEqual((error as? PinnedTrustFailure)?.check, 7)
        }
        // 2048-bit RSA is the other accepted shape, and it exercises the
        // PKCS#1 v1.5 arm of check 5.
        let strong = try selfSigned("rsa-2048", in: workspace, key: ["rsa:2048"])
        XCTAssertNoThrow(try PinnedTrustEvaluator(host: "127.0.0.1", pin: strong.pin).evaluate(leaf: strong.der))
    }

    // MARK: - Check 8: the address, from the subjectAltName alone

    func testCertificateForAnotherAddressIsRefused() throws {
        let workspace = try makeWorkspace()
        let elsewhere = try selfSigned("wrong-ip", in: workspace,
                                       extensions: Self.serverExtensions(subjectAltName: "IP:10.10.10.10"))
        let evaluator = try PinnedTrustEvaluator(host: "127.0.0.1", pin: elsewhere.pin)
        XCTAssertThrowsError(try evaluator.evaluate(leaf: elsewhere.der)) { error in
            XCTAssertEqual(error as? PinnedTrustFailure, .address)
            XCTAssertEqual((error as? PinnedTrustFailure)?.check, 8)
        }
        // The very same certificate is fine for the address it names.
        XCTAssertNoThrow(try PinnedTrustEvaluator(host: "10.10.10.10", pin: elsewhere.pin)
            .evaluate(leaf: elsewhere.der))
        // An IP literal never matches a dNSName, and a name never matches an
        // iPAddress: the two forms do not cross (`PinnedTls.java:36-43`).
        let named = try selfSigned("dns-name", in: workspace,
                                   extensions: Self.serverExtensions(subjectAltName: "DNS:Paranoid.Example"))
        XCTAssertThrowsError(try PinnedTrustEvaluator(host: "127.0.0.1", pin: named.pin).evaluate(leaf: named.der))
        XCTAssertNoThrow(try PinnedTrustEvaluator(host: "paranoid.example", pin: named.pin).evaluate(leaf: named.der))
        XCTAssertNoThrow(try PinnedTrustEvaluator(host: "PARANOID.EXAMPLE", pin: named.pin).evaluate(leaf: named.der))
        // No wildcard rule: the certificate names one name, not a suffix.
        XCTAssertThrowsError(try PinnedTrustEvaluator(host: "a.paranoid.example", pin: named.pin)
            .evaluate(leaf: named.der))
        // No common-name fallback: `/CN=127.0.0.1` with an unrelated SAN is
        // still the wrong server.
        let commonName = try selfSigned("common-name", in: workspace, subject: "/CN=127.0.0.1",
                                        extensions: Self.serverExtensions(subjectAltName: "DNS:paranoid.example"))
        XCTAssertThrowsError(try PinnedTrustEvaluator(host: "127.0.0.1", pin: commonName.pin)
            .evaluate(leaf: commonName.der)) { error in
            XCTAssertEqual(error as? PinnedTrustFailure, .address)
        }
    }

    func testIpLiteralsAreReadLikeTheAndroidClientReadsThem() {
        XCTAssertEqual(PinnedTrustEvaluator.literalAddress("127.0.0.1"), [127, 0, 0, 1])
        XCTAssertEqual(PinnedTrustEvaluator.literalAddress("0.0.0.0"), [0, 0, 0, 0])
        XCTAssertEqual(PinnedTrustEvaluator.literalAddress("255.255.255.255"), [255, 255, 255, 255])
        XCTAssertEqual(PinnedTrustEvaluator.literalAddress("[::1]")?.count, 16)
        XCTAssertEqual(PinnedTrustEvaluator.literalAddress("::1")?.last, 1)
        // A leading zero is an address to some resolvers and octal to others,
        // so it is a name here and matches no iPAddress entry at all.
        XCTAssertNil(PinnedTrustEvaluator.literalAddress("127.0.0.01"))
        XCTAssertNil(PinnedTrustEvaluator.literalAddress("127.0.0.256"))
        XCTAssertNil(PinnedTrustEvaluator.literalAddress("127.0.0"))
        XCTAssertNil(PinnedTrustEvaluator.literalAddress("127.0.0.1.5"))
        XCTAssertNil(PinnedTrustEvaluator.literalAddress("127.0.0."))
        XCTAssertNil(PinnedTrustEvaluator.literalAddress("paranoid.example"))
        XCTAssertNil(PinnedTrustEvaluator.literalAddress("localhost"))
        XCTAssertNil(PinnedTrustEvaluator.literalAddress(""))
        XCTAssertNil(PinnedTrustEvaluator.literalAddress("::zz"))
    }

    // MARK: - Check 9 and the delegate

    func testSessionConfigurationFloorsTlsAtOneTwoAndKeepsNothing() {
        let configuration = PinnedSessionDelegate.configuration()
        XCTAssertEqual(configuration.tlsMinimumSupportedProtocolVersion, .TLSv12)
        XCTAssertEqual(configuration.tlsMaximumSupportedProtocolVersion, .TLSv13)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testDelegateOffersACredentialOnlyAfterAllNineChecks() throws {
        let workspace = try makeWorkspace()
        let stand = try localStandIdentity(in: workspace)
        let evaluator = try PinnedTrustEvaluator(realm: stand.realm, pin: stand.identity.pin)
        let delegate = PinnedSessionDelegate(evaluator: evaluator)
        let trust = try Self.trust(of: [stand.identity.der])

        XCTAssertEqual(delegate.decision(host: "127.0.0.1",
                                         authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                         trust: trust, floor: .TLSv12),
                       .useCredential)
        XCTAssertEqual(delegate.decision(host: "127.0.0.1",
                                         authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                         trust: trust, floor: .TLSv13),
                       .useCredential)

        // Check 9: a session below TLS 1.2, and the client certificate this
        // client never has.
        // TLS 1.0 (0x0301) and TLS 1.1 (0x0302), by their wire versions: the
        // named cases are deprecated, which is precisely why a session must
        // never be allowed to offer them.
        for floor in [0x0301, 0x0302].compactMap({ tls_protocol_version_t(rawValue: UInt16($0)) }) {
            XCTAssertEqual(delegate.decision(host: "127.0.0.1",
                                             authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                             trust: trust, floor: floor),
                           .cancel(.protocolFloor))
        }
        XCTAssertEqual(delegate.decision(host: "127.0.0.1",
                                         authenticationMethod: NSURLAuthenticationMethodClientCertificate,
                                         trust: nil, floor: .TLSv12),
                       .cancel(.clientAuthentication))
        XCTAssertEqual(delegate.decision(host: "127.0.0.1",
                                         authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                                         trust: nil, floor: .TLSv12),
                       .cancel(.authenticationMethod(NSURLAuthenticationMethodHTTPBasic)))
        // A challenge for another host, and one without a trust at all.
        XCTAssertEqual(delegate.decision(host: "10.10.10.10",
                                         authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                         trust: trust, floor: .TLSv12),
                       .cancel(.host("10.10.10.10")))
        XCTAssertEqual(delegate.decision(host: "127.0.0.1",
                                         authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                         trust: nil, floor: .TLSv12),
                       .cancel(.missingTrust))
        // A wrong pin cancels through the delegate exactly as it throws
        // through the evaluator.
        let wrong = PinnedSessionDelegate(evaluator: try PinnedTrustEvaluator(host: "127.0.0.1",
                                                                             pin: String(repeating: "0", count: 64)))
        XCTAssertEqual(wrong.decision(host: "127.0.0.1",
                                      authenticationMethod: NSURLAuthenticationMethodServerTrust,
                                      trust: trust, floor: .TLSv12),
                       .cancel(.pin))

        // The URL loading system dispatches by selector: the delegate must
        // really implement the challenge callback, not merely a method that
        // looks like it.
        XCTAssertTrue(delegate.responds(to: #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))))
    }

    // MARK: - The two saved strings

    func testPinMustBeSixtyFourHexadecimalDigits() throws {
        XCTAssertThrowsError(try PinnedTrustEvaluator(host: "127.0.0.1", pin: "")) { error in
            XCTAssertEqual(error as? PinnedTrustFailure, .pinFormat)
        }
        for wrong in ["", " ", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
                      String(repeating: "g", count: 64),
                      "0x" + String(repeating: "a", count: 62),
                      String(repeating: "a", count: 32) + String(repeating: " ", count: 32)] {
            XCTAssertThrowsError(try PinnedTrustEvaluator.checkedPin(wrong), "[\(wrong)]") { error in
                XCTAssertEqual(error as? PinnedTrustFailure, .pinFormat)
            }
        }
        // Upper case is normalised, surrounding whitespace is trimmed, and the
        // octets are the digits the text names.
        let hosted = "8aa594a9148f610da9de671d7c7ae7c690e671e53eb0e8a3b931beeb888970ba"
        XCTAssertEqual(try PinnedTrustEvaluator.checkedPin(hosted.uppercased()), hosted)
        XCTAssertEqual(try PinnedTrustEvaluator.checkedPin("  \(hosted)\n"), hosted)
        let evaluator = try PinnedTrustEvaluator(host: "157.180.49.125", pin: hosted.uppercased())
        XCTAssertEqual(evaluator.pinHex, hosted)
        XCTAssertEqual(evaluator.pin.count, 32)
        XCTAssertEqual(Array(evaluator.pin.prefix(4)), [0x8a, 0xa5, 0x94, 0xa9])
        XCTAssertEqual(evaluator.pin.last, 0xba)
        XCTAssertNil(evaluator.realm)
        XCTAssertThrowsError(try PinnedTrustEvaluator(host: "", pin: hosted)) { error in
            XCTAssertEqual(error as? PinnedTrustFailure, .realmFormat)
        }
    }

    func testRealmMustBeAnHttpsOriginWithoutPathQueryOrUserInfo() throws {
        let pin = String(repeating: "a", count: 64)
        XCTAssertEqual(try PinnedTrustEvaluator.checkedRealm("https://157.180.49.125:38443"),
                       "https://157.180.49.125:38443")
        XCTAssertEqual(try PinnedTrustEvaluator(realm: "https://paranoid.example", pin: pin).host,
                       "paranoid.example")
        XCTAssertEqual(try PinnedTrustEvaluator(realm: "https://[::1]:38443", pin: pin).host, "::1")

        for wrong in ["http://127.0.0.1:38443",
                      "https://127.0.0.1:38443/",
                      "https://127.0.0.1:38443/v1/health",
                      "https://user@127.0.0.1:38443",
                      "https://127.0.0.1:38443?x=1",
                      "https://127.0.0.1:38443#top",
                      "https://",
                      "127.0.0.1:38443",
                      "",
                      "https://" + String(repeating: "a", count: 520)] {
            XCTAssertThrowsError(try PinnedTrustEvaluator.checkedRealm(wrong), "[\(wrong)]") { error in
                XCTAssertEqual(error as? PinnedTrustFailure, .realmFormat, "[\(wrong)]")
            }
            XCTAssertThrowsError(try PinnedTrustEvaluator(realm: wrong, pin: pin), "[\(wrong)]")
        }
    }

    func testGarbageInsteadOfACertificateIsRefusedWithoutCrashing() throws {
        let workspace = try makeWorkspace()
        let identity = try localStandIdentity(in: workspace).identity
        let evaluator = try PinnedTrustEvaluator(host: "127.0.0.1", pin: identity.pin)

        for der in [[UInt8](), [0x30], [UInt8](repeating: 0xff, count: 64),
                    Array(identity.der.prefix(identity.der.count / 2))] {
            XCTAssertThrowsError(try evaluator.evaluate(leaf: der)) { error in
                guard case .unreadableCertificate = error as? PinnedTrustFailure else {
                    return XCTFail("expected an unreadable certificate, got \(error)")
                }
            }
        }
    }

    // MARK: - Fixtures

    private struct FixtureFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// One generated certificate and the pin OpenSSL computes for it.
    private struct Identity {
        let der: [UInt8]
        let pin: String
    }

    /// A private directory, removed when the test method ends.
    private func makeWorkspace() throws -> URL {
        let version = try Self.run("openssl", ["version"])
        guard version.hasPrefix("OpenSSL 3") else {
            throw FixtureFailure(description: """
                OpenSSL 3 is required for the TLS fixtures (LibreSSL has no -addext); \
                `openssl version` said \(version.trimmingCharacters(in: .whitespacesAndNewlines))
                """)
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("paranoid-pinned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        return workspace
    }

    /// The identity of the local stand: `scripts/create-test-tls.py`, the same
    /// call `clients/ios/local_stand.py` makes, with the pin taken from the
    /// descriptor the script prints rather than computed here.
    private func localStandIdentity(in workspace: URL) throws -> (identity: Identity, realm: String) {
        let directory = workspace.appendingPathComponent("stand", isDirectory: true)
        let script = Self.repositoryRoot.appendingPathComponent("scripts/create-test-tls.py")
        _ = try Self.run("python3", [script.path, "--ip", "127.0.0.1", "--output", directory.path])
        let der = try Self.der(ofPEM: directory.appendingPathComponent("server.crt"))
        let descriptor = try Data(contentsOf: directory.appendingPathComponent("public-connection.json"))
        guard let object = try JSONSerialization.jsonObject(with: descriptor) as? [String: Any],
              let pin = object["tls_spki_sha256"] as? String,
              let realm = object["server_url"] as? String else {
            throw FixtureFailure(description: "public-connection.json is not the expected descriptor")
        }
        return (Identity(der: der, pin: pin), realm)
    }

    /// One self-signed certificate, `openssl req -x509`, with only the
    /// property under test changed.
    private func selfSigned(_ name: String, in workspace: URL,
                            key: [String] = ["ec", "-pkeyopt", "ec_paramgen_curve:prime256v1"],
                            digest: String = "-sha256",
                            subject: String = "/CN=ParanoID closed test",
                            validity: [String] = ["-days", "90"],
                            extensions: [String]? = nil) throws -> Identity {
        let certificate = workspace.appendingPathComponent("\(name).crt")
        _ = try Self.run("openssl", ["req", "-x509", "-newkey"] + key
            + ["-nodes", digest, "-subj", subject] + validity
            + (extensions ?? Self.serverExtensions())
            + ["-keyout", workspace.appendingPathComponent("\(name).key").path,
               "-out", certificate.path])
        return try identity(name, certificate: certificate, in: workspace)
    }

    /// A certificate authority and a leaf it signed: the chain check 1 exists
    /// for.
    private func chainedLeaf(in workspace: URL) throws -> (leaf: Identity, authority: Identity) {
        let authority = workspace.appendingPathComponent("authority.crt")
        _ = try Self.run("openssl", ["req", "-x509", "-newkey", "ec",
                                     "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-sha256",
                                     "-days", "90", "-subj", "/CN=ParanoID test authority",
                                     "-addext", "basicConstraints=critical,CA:TRUE",
                                     "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                                     "-keyout", workspace.appendingPathComponent("authority.key").path,
                                     "-out", authority.path])
        let request = workspace.appendingPathComponent("chained.csr")
        _ = try Self.run("openssl", ["req", "-new", "-newkey", "ec",
                                     "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-sha256",
                                     "-subj", "/CN=ParanoID chained leaf"]
            + Self.serverExtensions()
            + ["-keyout", workspace.appendingPathComponent("chained.key").path, "-out", request.path])
        let leaf = workspace.appendingPathComponent("chained.crt")
        _ = try Self.run("openssl", ["x509", "-req", "-in", request.path,
                                     "-CA", authority.path,
                                     "-CAkey", workspace.appendingPathComponent("authority.key").path,
                                     "-days", "90", "-sha256", "-copy_extensions", "copy",
                                     "-out", leaf.path])
        return (try identity("chained", certificate: leaf, in: workspace),
                try identity("authority", certificate: authority, in: workspace))
    }

    /// The four extensions `scripts/create-test-tls.py` writes.
    private static func serverExtensions(subjectAltName: String = "IP:127.0.0.1") -> [String] {
        ["-addext", "subjectAltName=\(subjectAltName)",
         "-addext", "basicConstraints=critical,CA:FALSE",
         "-addext", "keyUsage=critical,digitalSignature",
         "-addext", "extendedKeyUsage=serverAuth"]
    }

    /// The DER of a generated certificate and its pin, the latter computed by
    /// OpenSSL over the DER of `subjectPublicKeyInfo` — never by the code the
    /// tests are about.
    private func identity(_ name: String, certificate: URL, in workspace: URL) throws -> Identity {
        let publicKey = workspace.appendingPathComponent("\(name).pub.pem")
        let spki = workspace.appendingPathComponent("\(name).spki.der")
        _ = try Self.run("openssl", ["x509", "-in", certificate.path, "-pubkey", "-noout", "-out", publicKey.path])
        _ = try Self.run("openssl", ["pkey", "-pubin", "-in", publicKey.path, "-outform", "DER", "-out", spki.path])
        let digest = try Self.run("openssl", ["dgst", "-sha256", "-hex", spki.path])
        guard let hex = digest.split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines),
              hex.count == 64 else {
            throw FixtureFailure(description: "openssl dgst printed \(digest)")
        }
        return Identity(der: try Self.der(ofPEM: certificate), pin: hex)
    }

    /// A `SecTrust` holding exactly the certificates given, in order. It is
    /// never evaluated: it is only the container the URL loading system would
    /// hand the chain over in.
    private static func trust(of certificates: [[UInt8]]) throws -> SecTrust {
        let items = try certificates.map { der -> SecCertificate in
            guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
                throw FixtureFailure(description: "Security.framework refused a generated certificate")
            }
            return certificate
        }
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(items as CFArray, SecPolicyCreateBasicX509(), &trust)
        guard status == errSecSuccess, let trust else {
            throw FixtureFailure(description: "SecTrustCreateWithCertificates failed with \(status)")
        }
        return trust
    }

    private static func der(ofPEM url: URL) throws -> [UInt8] {
        let pem = try String(contentsOf: url, encoding: .utf8)
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64), !der.isEmpty else {
            throw FixtureFailure(description: "\(url.lastPathComponent) is not a PEM certificate")
        }
        return [UInt8](der)
    }

    /// The same pin with its last hexadecimal digit changed: a near miss, to
    /// be refused exactly like a wholly wrong one.
    private static func flippedLastDigit(of pin: String) -> String {
        String(pin.dropLast()) + (pin.hasSuffix("0") ? "1" : "0")
    }

    /// The repository root, from this file's own path:
    /// `clients/ios/ParanoidKit/Tests/ParanoidKitTests/PinnedTrustTests.swift`.
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    /// Runs a fixture command and returns its standard output; a non-zero exit
    /// fails the fixture rather than the check under test.
    @discardableResult
    private static func run(_ command: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // Both streams carry at most a few lines, far below the pipe buffer.
        let text = output.fileHandleForReading.readDataToEndOfFile()
        let failure = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureFailure(description: """
                \(command) \(arguments.first ?? "") exited \(process.terminationStatus): \
                \(String(decoding: failure, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                """)
        }
        return String(decoding: text, as: UTF8.self)
    }
}
