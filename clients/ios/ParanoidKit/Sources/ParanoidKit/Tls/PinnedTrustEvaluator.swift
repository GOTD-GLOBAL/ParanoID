import CryptoKit
import Foundation
import Security

/// Why a pinned handshake was refused, one case per rule that can say no.
///
/// Numbers 1 to 8 are the eight leaf rules of `checkServerTrusted`
/// (`PinnedTls.java:54-70`), one number per rule. Number 9 is not one rule: it
/// is the group of session-level refusals, and five cases here carry it — two
/// with an Android counterpart (`protocolFloor` for the enabled-protocol list,
/// `clientAuthentication` for the `checkClientTrusted` throw) and three that
/// exist only because the URL loading system hands this client a challenge
/// object Android's socket factory never sees (`authenticationMethod`, `host`,
/// `missingTrust`).
///
/// `check` maps a failure back to its number so a log line or a test can name
/// the rule without matching on the message. Nothing here carries certificate
/// bytes or key material: the strings are OIDs, counts and short reasons.
public enum PinnedTrustFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// The pin is not 64 hexadecimal digits (`PinnedTls.java:18-21`).
    case pinFormat
    /// The realm is not an HTTPS origin without user info, query, fragment or
    /// path (`KeyClient.java:37-41`).
    case realmFormat
    /// The server sent something other than exactly one certificate (check 1).
    case chain(Int)
    /// `SHA256(subjectPublicKeyInfo)` is not the pin (check 2).
    case pin
    /// `now` is outside `notBefore ... notAfter` (check 3).
    case validity
    /// A critical extension this client does not evaluate (check 4).
    case criticalExtension(String)
    /// `basicConstraints` says `CA:TRUE` (check 4).
    case certificateAuthority
    /// `issuer` and `subject` differ, so the leaf is not self-issued (check 5).
    case notSelfIssued
    /// The signature algorithm is neither `ecdsa-with-SHA256` nor
    /// `sha256WithRSAEncryption`, or it does not match the key (check 5).
    case signatureAlgorithm(String)
    /// The self-signature does not verify under the leaf's own key (check 5).
    case signature
    /// `keyUsage` lacks `digitalSignature`, or `extendedKeyUsage` lacks
    /// `id-kp-serverAuth` (check 6).
    case serverAuth
    /// An EC key below 256 bits, an RSA key below 2048, or another key type
    /// altogether (check 7): the type as `kSecAttrKeyType` reports it and the
    /// size in bits.
    case keyStrength(String, Int)
    /// No `subjectAltName` entry names the pinned address (check 8).
    case address
    /// The leaf is not the DER of one X.509 certificate; the string is the
    /// `DERError` that stopped the walk.
    case unreadableCertificate(String)
    /// `Security.framework` would not build a usable public key out of the
    /// leaf.
    case unusableKey(String)
    /// The session offers a TLS floor below 1.2 (check 9; the counterpart of
    /// the enabled-protocol list of `PinnedTls.java:80-83`).
    case protocolFloor
    /// The server asked for a client certificate; this client has none
    /// (`PinnedTls.java:53`, check 9).
    case clientAuthentication
    /// An authentication method other than server trust or client certificate
    /// (check 9, no Android counterpart).
    case authenticationMethod(String)
    /// The challenge is for a host other than the pinned one (check 9, no
    /// Android counterpart).
    case host(String)
    /// A server-trust challenge arrived without a trust object (check 9, no
    /// Android counterpart).
    case missingTrust

    /// The number this failure belongs to: 1 to 8 name one leaf rule of
    /// `PinnedTls.java:54-70` each, and 9 is the session-level group described
    /// above rather than a single rule. `nil` for the two constructor rules
    /// and the two decoding failures.
    public var check: Int? {
        switch self {
        case .pinFormat, .realmFormat, .unreadableCertificate, .unusableKey: return nil
        case .chain: return 1
        case .pin: return 2
        case .validity: return 3
        case .criticalExtension, .certificateAuthority: return 4
        case .notSelfIssued, .signatureAlgorithm, .signature: return 5
        case .serverAuth: return 6
        case .keyStrength: return 7
        case .address: return 8
        case .protocolFloor, .clientAuthentication, .authenticationMethod, .host, .missingTrust: return 9
        }
    }

    public var description: String {
        let reason: String
        switch self {
        case .pinFormat: reason = "pin must be 64 hexadecimal digits"
        case .realmFormat: reason = "realm must be an HTTPS origin"
        case .chain(let count): reason = "one self-signed leaf required, got \(count) certificates"
        case .pin: reason = "server key mismatch"
        case .validity: reason = "certificate is not valid now"
        case .criticalExtension(let oid): reason = "unsupported critical extension \(oid)"
        case .certificateAuthority: reason = "leaf is a certificate authority"
        case .notSelfIssued: reason = "self-signed leaf required"
        case .signatureAlgorithm(let oid): reason = "unsupported signature algorithm \(oid)"
        case .signature: reason = "self-signature does not verify"
        case .serverAuth: reason = "server-auth certificate required"
        case .keyStrength(let type, let bits): reason = "weak public key: type \(type), \(bits) bits"
        case .address: reason = "no subjectAltName names this server"
        case .unreadableCertificate(let error): reason = "unreadable certificate: \(error)"
        case .unusableKey(let error): reason = "unusable public key: \(error)"
        case .protocolFloor: reason = "TLS 1.2 is the minimum supported version"
        case .clientAuthentication: reason = "client authentication unsupported"
        case .authenticationMethod(let method): reason = "unsupported authentication method \(method)"
        case .host(let host): reason = "challenge is for \(host), not the pinned server"
        case .missingTrust: reason = "server trust missing from the challenge"
        }
        if let check { return "pinned server verification failed (check \(check)): \(reason)" }
        return "pinned server verification failed: \(reason)"
    }
}

/// The eight leaf checks of `PinnedTls.java:54-70`, on `Security.framework`.
///
/// One server, one pinned key, no certificate authority anywhere: the pin is
/// `SHA-256` of the leaf's `subjectPublicKeyInfo` DER, exactly the value
/// `docs/protocol/key-enrollment-v1.md:41-42` stores in a credential and
/// `docs/protocol/realtime-v1.md:39-41` requires every session to be scoped to.
/// A connection is accepted only when all of them hold:
///
/// 1. the server sent exactly one certificate;
/// 2. `SHA256(subjectPublicKeyInfo)` equals the pin, compared in constant time;
/// 3. `notBefore <= now <= notAfter`;
/// 4. no critical extension this client does not evaluate, and
///    `basicConstraints` is absent or `CA:FALSE`;
/// 5. `issuer` and `subject` are byte-identical **and** the self-signature
///    verifies under the leaf's own key;
/// 6. `keyUsage` has `digitalSignature` and `extendedKeyUsage` has
///    `id-kp-serverAuth`;
/// 7. an EC key of at least 256 bits or an RSA key of at least 2048;
/// 8. a `subjectAltName` entry names the pinned address — an `iPAddress` when
///    the realm holds an IP literal, otherwise a `dNSName` compared without
///    case; never a common name, never a wildcard.
///
/// A ninth number covers what belongs to the session rather than to the
/// certificate — the TLS floor, the refusal of client certificates, and the
/// three challenge rules that have no Android counterpart. That group is
/// `PinnedSessionDelegate`'s, not this type's.
///
/// ## What a live handshake proves, and what only a parsed certificate does
///
/// `clients/ios/check-pinned-tls.py` dials real loopback servers through this
/// type and `PinnedSessionDelegate`, and its fixtures break checks **1, 2, 3,
/// 6, 7 and 8** — one server per broken rule, each refused before any HTTP
/// request reached it. A seventh fixture breaks check 9 by capping a server at
/// TLS 1.1, and it only runs where the local OpenSSL still offers TLS 1.1;
/// otherwise that line prints `SKIPPED`.
///
/// Checks **4 and 5** have no socket fixture. They are proven on parsed
/// certificates instead, by `PinnedTrustTests`: a leaf OpenSSL issues with an
/// unknown critical extension and one with `CA:TRUE` for check 4, and the
/// stand's own leaf with one bit of `signatureValue` flipped for check 5 —
/// the case `SecTrustEvaluateWithError` with the leaf as its own anchor would
/// accept. The corrupted leaf also goes through `PinnedSessionDelegate` on a
/// real `SecTrust`, so what those two checks never see is a socket, not the
/// shipped code path: `evaluate(leaf:at:)` is what the `SecTrust` overload
/// calls. A claim that all eight are proven by a live handshake would be
/// wrong, and this paragraph is what keeps it from being made.
///
/// ## Why the self-signature is verified by hand
///
/// The obvious shortcut — hand the leaf to `SecTrustEvaluateWithError` with
/// itself as the anchor — does not do check 5. An anchor is trusted by fiat:
/// the system stops the path at it and never verifies its self-signature, so a
/// certificate carrying a valid `subjectPublicKeyInfo` and arbitrary garbage in
/// `signatureValue` would evaluate as trusted. Android's `leaf.verify(...)`
/// (`PinnedTls.java:63`) does check it, so this client checks it too, with
/// `SecKeyVerifySignature` over the `tbsCertificate` octets `X509Leaf` slices
/// out. No `SecTrustEvaluate*` call exists in this file; `SecTrust` is used
/// only as the container the URL loading system hands over the chain in.
public struct PinnedTrustEvaluator: Sendable {
    /// SHA-256, so 32 octets and 64 hexadecimal digits.
    public static let pinBytes = 32

    /// The address the certificate must name: an IP literal or a DNS name,
    /// without brackets or port.
    public let host: String
    /// The pin, as the 32 octets it stands for.
    public let pin: [UInt8]
    /// The pin as 64 lowercase hexadecimal digits, the form a credential and a
    /// grant carry it in.
    public let pinHex: String
    /// The HTTPS origin this evaluator was built from, when it was built from
    /// one.
    public let realm: String?

    /// The extensions this client understands. A critical extension outside
    /// this set is refused by check 4, which is what
    /// `X509Certificate.hasUnsupportedCriticalExtension()` means on Android.
    private static let evaluatedExtensions: Set<String> = [
        X509Leaf.OID.keyUsage,
        X509Leaf.OID.basicConstraints,
        X509Leaf.OID.extendedKeyUsage,
        X509Leaf.OID.subjectAltName,
    ]

    /// - Parameters:
    ///   - host: the address the leaf must name, without brackets or port.
    ///   - pin: 64 hexadecimal digits, either case.
    /// - Throws: `PinnedTrustFailure.pinFormat` for anything else, and
    ///   `.realmFormat` for an empty host (`PinnedTls.java:48`).
    public init(host: String, pin: String) throws {
        guard !host.isEmpty else { throw PinnedTrustFailure.realmFormat }
        let normalized = try Self.checkedPin(pin)
        self.host = host
        self.pinHex = normalized
        self.pin = Self.octets(ofHex: normalized)
        self.realm = nil
    }

    /// The evaluator of a saved realm: the host comes from the origin, so the
    /// address that is pinned and the address that is dialled cannot drift
    /// apart.
    ///
    /// - Throws: `PinnedTrustFailure.realmFormat` or `.pinFormat`.
    public init(realm: String, pin: String) throws {
        let origin = try Self.checkedRealm(realm)
        let normalized = try Self.checkedPin(pin)
        self.host = try Self.host(inRealm: origin)
        self.pinHex = normalized
        self.pin = Self.octets(ofHex: normalized)
        self.realm = origin
    }

    // MARK: - The two saved strings

    /// The pin as it is stored: 64 hexadecimal digits, surrounding whitespace
    /// trimmed, folded to lower case (`PinnedTls.java:18-21`).
    public static func checkedPin(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == pinBytes * 2 else { throw PinnedTrustFailure.pinFormat }
        var lowered = ""
        lowered.reserveCapacity(trimmed.count)
        for character in trimmed.unicodeScalars {
            switch character {
            case "0"..."9", "a"..."f": lowered.unicodeScalars.append(character)
            case "A"..."F": lowered.unicodeScalars.append(Unicode.Scalar(character.value + 32)!)
            default: throw PinnedTrustFailure.pinFormat
            }
        }
        return lowered
    }

    /// The realm as it is stored: an HTTPS origin with a host, optionally a
    /// port, and nothing else — no user info, no path, no query, no fragment,
    /// at most 512 characters (`KeyClient.java:37-41`).
    ///
    /// The string is returned unchanged, because it is compared byte for byte
    /// against the `realm` of a credential, a grant and a session
    /// (`docs/protocol/realtime-v1.md:39-41`).
    public static func checkedRealm(_ raw: String) throws -> String {
        guard raw.count <= 512, !raw.isEmpty,
              let components = URLComponents(string: raw),
              components.scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty
        else { throw PinnedTrustFailure.realmFormat }
        return raw
    }

    /// The host of a checked realm, with the brackets of an IPv6 literal
    /// removed if `URLComponents` kept them.
    public static func host(inRealm realm: String) throws -> String {
        guard let host = URLComponents(string: realm)?.host, !host.isEmpty else {
            throw PinnedTrustFailure.realmFormat
        }
        if host.hasPrefix("["), host.hasSuffix("]") { return String(host.dropFirst().dropLast()) }
        return host
    }

    // MARK: - The certificate checks

    /// Checks 1 to 8 on the chain the URL loading system offers.
    ///
    /// - Parameters:
    ///   - trust: the `SecTrust` of a server-trust challenge. It is read, never
    ///     evaluated: `SecTrustCopyCertificateChain` on an unevaluated trust
    ///     returns exactly the certificates the server sent.
    ///   - now: the moment check 3 is made against.
    /// - Throws: the `PinnedTrustFailure` of the first check that says no.
    public func evaluate(_ trust: SecTrust, at now: Date = Date()) throws {
        // Check 1: one certificate, so no intermediate and no authority.
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            throw PinnedTrustFailure.chain(0)
        }
        guard chain.count == 1, let leaf = chain.first else { throw PinnedTrustFailure.chain(chain.count) }
        try evaluate(leaf: [UInt8](SecCertificateCopyData(leaf) as Data), at: now)
    }

    /// Checks 2 to 8 on one DER certificate; check 1 is the caller's, because
    /// only the caller sees how many certificates arrived.
    ///
    /// - Throws: the `PinnedTrustFailure` of the first check that says no.
    public func evaluate(leaf der: [UInt8], at now: Date = Date()) throws {
        let leaf: X509Leaf
        do {
            leaf = try X509Leaf(der: der)
        } catch {
            throw PinnedTrustFailure.unreadableCertificate("\(error)")
        }

        // Check 2: the pinned key, compared without a timing signal.
        let digest = [UInt8](SHA256.hash(data: Data(leaf.subjectPublicKeyInfo)))
        guard Self.constantTimeEqual(digest, pin) else { throw PinnedTrustFailure.pin }

        // Check 3: validity, inclusive at both ends as `checkValidity()` is.
        guard now >= leaf.notBefore, now <= leaf.notAfter else { throw PinnedTrustFailure.validity }

        // Check 4: nothing critical this client would silently ignore, and no
        // certificate authority.
        for entry in leaf.extensions where entry.isCritical {
            guard Self.evaluatedExtensions.contains(entry.oid) else {
                throw PinnedTrustFailure.criticalExtension(entry.oid)
            }
        }
        do {
            if let constraints = try leaf.basicConstraints(), constraints.isCertificateAuthority {
                throw PinnedTrustFailure.certificateAuthority
            }
        } catch let error as DERError {
            throw PinnedTrustFailure.unreadableCertificate("\(error)")
        }

        // Check 5: self-issued by name and by signature.
        guard leaf.issuer == leaf.subject else { throw PinnedTrustFailure.notSelfIssued }
        let key = try publicKey(of: der)
        try verifySelfSignature(of: leaf, with: key)

        // Check 6: a server-authentication certificate.
        do {
            guard let usage = try leaf.keyUsage(), usage.contains(.digitalSignature),
                  let extended = try leaf.extendedKeyUsage(), extended.contains(X509Leaf.OID.serverAuth)
            else { throw PinnedTrustFailure.serverAuth }
        } catch let error as DERError {
            throw PinnedTrustFailure.unreadableCertificate("\(error)")
        }

        // Check 7: a key worth pinning.
        try checkStrength(of: key)

        // Check 8: the address, from the subjectAltName alone.
        do {
            guard try matchesSubjectAlternativeName(leaf) else { throw PinnedTrustFailure.address }
        } catch let error as DERError {
            throw PinnedTrustFailure.unreadableCertificate("\(error)")
        }
    }

    // MARK: - Check 5

    /// The leaf's public key, as `Security.framework` reads it out of the
    /// certificate. The pin is taken from the DER, not from here, so this key
    /// is only ever used for the cryptography of checks 5 and 7.
    private func publicKey(of der: [UInt8]) throws -> SecKey {
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            throw PinnedTrustFailure.unreadableCertificate("Security.framework refused the certificate")
        }
        guard let key = SecCertificateCopyKey(certificate) else {
            throw PinnedTrustFailure.unusableKey("no public key in the certificate")
        }
        return key
    }

    /// `SecKeyVerifySignature` over the `tbsCertificate` octets with the
    /// leaf's own key, the counterpart of `leaf.verify(leaf.getPublicKey())`.
    ///
    /// The two algorithms are the ones a pinned ParanoID server presents;
    /// anything else is refused rather than mapped to a weaker primitive, and
    /// `SecKeyIsAlgorithmSupported` is what rejects an ECDSA signature over an
    /// RSA key and the reverse.
    private func verifySelfSignature(of leaf: X509Leaf, with key: SecKey) throws {
        let algorithm: SecKeyAlgorithm
        switch leaf.signatureAlgorithm {
        case X509Leaf.OID.ecdsaWithSHA256: algorithm = .ecdsaSignatureMessageX962SHA256
        case X509Leaf.OID.sha256WithRSAEncryption: algorithm = .rsaSignatureMessagePKCS1v15SHA256
        default: throw PinnedTrustFailure.signatureAlgorithm(leaf.signatureAlgorithm)
        }
        guard SecKeyIsAlgorithmSupported(key, .verify, algorithm) else {
            throw PinnedTrustFailure.signatureAlgorithm(leaf.signatureAlgorithm)
        }
        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(key, algorithm,
                                             Data(leaf.tbsCertificate) as CFData,
                                             Data(leaf.signature) as CFData,
                                             &error)
        error?.release()
        guard verified else { throw PinnedTrustFailure.signature }
    }

    // MARK: - Check 7

    /// EC at 256 bits or more, RSA at 2048 or more, nothing else — the two
    /// `instanceof` arms of `PinnedTls.java:66-67`, read off the key instead of
    /// off the certificate.
    private func checkStrength(of key: SecKey) throws {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let type = attributes[kSecAttrKeyType as String] as? String,
              let bits = attributes[kSecAttrKeySizeInBits as String] as? Int
        else { throw PinnedTrustFailure.unusableKey("no key attributes") }
        if type == kSecAttrKeyTypeECSECPrimeRandom as String, bits >= 256 { return }
        if type == kSecAttrKeyTypeRSA as String, bits >= 2048 { return }
        throw PinnedTrustFailure.keyStrength(type, bits)
    }

    // MARK: - Check 8

    /// True when a `subjectAltName` entry names `host`.
    ///
    /// An IP literal is matched against `iPAddress` entries octet by octet and
    /// against nothing else; every other host is matched against `dNSName`
    /// entries without regard to case. There is no common-name fallback and no
    /// wildcard rule, so `*.example.org` names no host at all — `matchesSan`
    /// of `PinnedTls.java:33-46`, unchanged.
    private func matchesSubjectAlternativeName(_ leaf: X509Leaf) throws -> Bool {
        guard let names = try leaf.subjectAlternativeNames() else { return false }
        if let address = Self.literalAddress(host) {
            return names.ipAddresses.contains { $0 == address }
        }
        let wanted = Self.asciiLowercased(host)
        return names.dnsNames.contains { Self.asciiLowercased($0) == wanted }
    }

    /// The octets of an IP literal, or `nil` when the text is a name rather
    /// than an address (`literalIp`, `PinnedTls.java:22-32`).
    ///
    /// IPv4 is read by hand so that a leading zero — `127.0.0.01`, which some
    /// resolvers read as octal — is a name, not an address, and can therefore
    /// never match an `iPAddress` entry. IPv6 goes through `inet_pton`, the
    /// counterpart of `InetAddress.getByName` on a literal, after the same
    /// "hexadecimal digits, colons and dots only" filter that keeps a host name
    /// out of the resolver.
    static func literalAddress(_ raw: String) -> [UInt8]? {
        var text = raw
        if text.hasPrefix("["), text.hasSuffix("]"), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty else { return nil }
        if text.contains(":") {
            guard text.unicodeScalars.allSatisfy({ scalar in
                ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar)
                    || ("A"..."F").contains(scalar) || scalar == ":" || scalar == "."
            }) else { return nil }
            var address = in6_addr()
            guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
            return withUnsafeBytes(of: address) { [UInt8]($0) }
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var address: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                  part.count == 1 || !part.hasPrefix("0"),
                  let value = UInt8(part)
            else { return nil }
            address.append(value)
        }
        return address
    }

    /// `A`-`Z` folded to `a`-`z` and nothing else. A `dNSName` is IA5String, so
    /// ASCII folding is `equalsIgnoreCase` on every name that can occur, and it
    /// cannot fold two different names together the way Unicode case folding
    /// can.
    private static func asciiLowercased(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }))
    }

    // MARK: - Helpers

    /// Equality in time that does not depend on where the first difference is.
    ///
    /// The loop reads both buffers to the end and accumulates the difference,
    /// so a near-miss pin and a wholly wrong one take the same path
    /// (`MessageDigest.isEqual`, `PinnedTls.java:59`).
    static func constantTimeEqual(_ left: [UInt8], _ right: [UInt8]) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    /// The octets of a string of hexadecimal digit pairs that `checkedPin` has
    /// already accepted.
    private static func octets(ofHex text: String) -> [UInt8] {
        var octets: [UInt8] = []
        octets.reserveCapacity(text.count / 2)
        var high: UInt8?
        for scalar in text.unicodeScalars {
            let value: UInt8 = scalar.value >= UInt32(UInt8(ascii: "a"))
                ? UInt8(scalar.value - UInt32(UInt8(ascii: "a")) + 10)
                : UInt8(scalar.value - UInt32(UInt8(ascii: "0")))
            if let first = high {
                octets.append(first << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return octets
    }
}
