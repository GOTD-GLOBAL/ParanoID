/// `UInt8(ascii:)` is the only ASCII initialiser the standard library offers,
/// and the relay grammar reads UTF-16 code units the way Java does.
extension UInt16 {
    fileprivate init(ascii scalar: Unicode.Scalar) { self = UInt16(UInt8(ascii: scalar)) }
}

/// Why one TURN credential document was refused.
///
/// One case per `IOException` message of
/// `clients/android/src/org/paranoid/text/VoiceRelayConfig.java`, so a
/// rejection can be compared across the two clients instead of only counted.
/// `metadataEncoding` is the one case without a Java message of its own: there
/// the strict UTF-8 decoder raises `CharacterCodingException`, which is an
/// `IOException`, before the grammar is ever entered (`VoiceRelayConfig.java:63`).
public enum VoiceRelayError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Absent, empty, or more than 2048 bytes (`VoiceRelayConfig.java:60-61`).
    case metadataSize
    /// The body is not well-formed UTF-8 (`VoiceRelayConfig.java:63`).
    case metadataEncoding
    /// Not exactly the six fields, or `v` is not 1, or `ttl` is not 1200.
    case metadataSchema
    /// `urls` is not a list.
    case urlShape
    /// `urls` is not exactly the two `turn:` forms on the realm host, in order.
    case urlBinding
    /// `username` is not `<expires>:<32 lowercase hex>`.
    case usernameBinding
    /// `credential` is not canonical padded Base64 of exactly 20 bytes.
    case credentialEncoding
    /// The remaining wall-clock lifetime is outside 1 000 000..1 205 000 ms,
    /// the wall clock is negative, or the arithmetic overflows.
    case credentialLifetime
    /// The retained origin is not a literal canonical IPv4 HTTPS origin.
    case realm
    /// A field that must be a positive integer is missing or is not one.
    case positiveIntegerRequired
    /// A field that must be a string is missing or is not one.
    case stringRequired
    /// The document ends inside a token.
    case truncatedJson
    /// A structural character is not the one the grammar demands here.
    case jsonSyntax
    /// A raw control character inside a string.
    case jsonControl
    /// An escape this grammar does not define.
    case jsonEscape
    /// An unpaired UTF-16 surrogate produced by `\u` escapes.
    case jsonSurrogate
    /// An empty integer, or one with a leading zero.
    case jsonInteger
    /// An integer that does not fit in 64 signed bits.
    case jsonIntegerOverflow
    /// The same field twice.
    case duplicateField
    /// A field outside the six.
    case unknownField
    /// Neither `,` nor `}` after a member.
    case jsonSeparator
    /// Anything but whitespace after the object.
    case trailingInput

    /// The Java message, verbatim where Java has one.
    public var description: String {
        switch self {
        case .metadataSize: return "relay metadata size"
        case .metadataEncoding: return "relay metadata encoding"
        case .metadataSchema: return "relay metadata schema"
        case .urlShape: return "relay URL shape"
        case .urlBinding: return "relay URL binding"
        case .usernameBinding: return "relay username binding"
        case .credentialEncoding: return "relay credential encoding"
        case .credentialLifetime: return "relay credential lifetime"
        case .realm: return "relay realm"
        case .positiveIntegerRequired: return "relay positive integer required"
        case .stringRequired: return "relay string required"
        case .truncatedJson: return "relay truncated JSON"
        case .jsonSyntax: return "relay JSON syntax"
        case .jsonControl: return "relay JSON control"
        case .jsonEscape: return "relay JSON escape"
        case .jsonSurrogate: return "relay JSON surrogate"
        case .jsonInteger: return "relay JSON integer"
        case .jsonIntegerOverflow: return "relay JSON integer overflow"
        case .duplicateField: return "relay duplicate field"
        case .unknownField: return "relay unknown field"
        case .jsonSeparator: return "relay JSON separator"
        case .trailingInput: return "relay JSON trailing input"
        }
    }
}

/// The answer to `GET /v2/voice/turn`, validated the way
/// [voice TURN v1](../../../../../../docs/protocol/voice-turn-v1.md) demands
/// and carried only in memory.
///
/// This is the port of
/// `clients/android/src/org/paranoid/text/VoiceRelayConfig.java:58-237`. It
/// parses nothing the server did not promise: the document is at most 2048
/// bytes, holds exactly the six fields `v`, `urls`, `username`, `credential`,
/// `expires` and `ttl` with no duplicate and no unknown name, `v` is 1, `ttl`
/// is 1200, and `urls` is exactly
/// `turn:<realm IPv4>:34781?transport=udp` then the same with `tcp` — the two
/// literal forms on the host of the **retained** HTTPS origin, so a response
/// can never move media to another host or ask for a DNS lookup.
/// `username` is the decimal `expires` followed by `:` and 32 lowercase hex
/// digits; `credential` is canonical padded Base64 of exactly 20 bytes, and
/// the re-encoding check is what refuses a decoder-tolerated last character
/// whose unused bits are not zero.
///
/// ## Why the document carries its own grammar
///
/// `Parser` is the same bounded, non-recursive grammar as Java's: six known
/// keys, three integers, two strings and one two-element array of strings, no
/// nesting, no floats, no `null`, no leading zero, no trailing input. A
/// general JSON reader would have to be trusted to normalise `1.0`, `1e0`,
/// `01`, a duplicate key and a `v` spelling of `v` exactly as the Android
/// client does, and it does not have to be: the document is small and its
/// shape is fixed. The grammar runs over UTF-16 code units, like Java's, so an
/// unpaired surrogate written as `\uD800` is refused rather than silently
/// replaced.
///
/// ## Lifetime is checked twice, on two clocks
///
/// On receipt the remaining wall-clock lifetime must be between 1 000 000 and
/// 1 205 000 ms: the 1200-second credential must still cover the 45-second
/// setup and the 15-minute maximum call under the existing five-second
/// clock-skew assumption, and it must not claim more life than the issuer can
/// have granted. `usable(wallMilliseconds:monotonicNanoseconds:)` is then
/// called again immediately before the `RTCPeerConnection` is created, because
/// disposing an older engine is asynchronous and waiting for it must not
/// extend this authority. It spends the same window on the monotonic clock —
/// at most `remaining − 1 000 000` ms may have elapsed since receipt — and
/// re-checks the wall clock, so neither a stalled disposal nor a wall-clock
/// rollback can buy time.
///
/// ## Volatile
///
/// These are bearer credentials for the relay. The type is deliberately not
/// `Codable` and its `description` is `VoiceRelayConfig[redacted]`
/// (`VoiceRelayConfig.java:56`): no snapshot, history, control message, saved
/// configuration, URL query, log line or evidence export may contain them
/// (`voice-turn-v1.md`, "Credentials are volatile").
public struct VoiceRelayConfig: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The credential must still promise at least this much wall-clock life
    /// when it arrives, and again when media is created
    /// (`VoiceRelayConfig.java:17`).
    public static let minimumRemainingMilliseconds: Int64 = 1_000_000
    /// And at most this much, or the issuer did not mint it
    /// (`VoiceRelayConfig.java:18`).
    public static let maximumRemainingMilliseconds: Int64 = 1_205_000
    /// `voice-turn-v1.md`: the response is at most 2048 UTF-8 bytes.
    public static let maximumMetadataBytes = 2048
    /// The only permitted relay port.
    public static let relayPort = 34781
    /// The only permitted `ttl`.
    public static let requiredTtl: Int64 = 1200
    /// The only permitted `v`.
    public static let requiredVersion: Int64 = 1

    /// Exactly two `turn:` URLs, UDP first, on the retained realm host.
    public let urls: [String]
    /// The temporary REST username, `<expires>:<32 lowercase hex>`.
    public let username: String
    /// The temporary REST password. Never log, persist or display it.
    public let password: String

    /// `expires` in milliseconds.
    private let expiresMilliseconds: Int64
    /// The monotonic reading taken when the document was accepted.
    private let receiptNanoseconds: Int64
    /// How much monotonic time may pass between receipt and media creation.
    private let admissionBudgetNanoseconds: Int64

    private init(urls: [String], username: String, password: String,
                 expiresMilliseconds: Int64, receiptNanoseconds: Int64,
                 remainingMilliseconds: Int64) {
        self.urls = urls
        self.username = username
        self.password = password
        self.expiresMilliseconds = expiresMilliseconds
        self.receiptNanoseconds = receiptNanoseconds
        // The receipt bounds make this multiplication safe (at most 205 000 ms).
        // Sub-millisecond elapsed time is preserved (`VoiceRelayConfig.java:36`).
        self.admissionBudgetNanoseconds =
            (remainingMilliseconds - Self.minimumRemainingMilliseconds) * 1_000_000
    }

    /// Re-check immediately before creating media, including after an
    /// asynchronous disposal of an older engine
    /// (`VoiceRelayConfig.java:44-54`).
    ///
    /// Both clocks must agree: no more than the admission budget of monotonic
    /// time may have passed since receipt, time may not have run backwards,
    /// and the wall clock must still leave the full minimum lifetime. Any
    /// overflow — a rolled-back or reset monotonic origin, a nonsense wall
    /// clock — is a refusal, never a wrap-around.
    public func usable(wallMilliseconds: Int64, monotonicNanoseconds: Int64) -> Bool {
        if wallMilliseconds < 0 { return false }
        let (elapsed, elapsedOverflow) =
            monotonicNanoseconds.subtractingReportingOverflow(receiptNanoseconds)
        if elapsedOverflow { return false }
        let (wallRemaining, wallOverflow) =
            expiresMilliseconds.subtractingReportingOverflow(wallMilliseconds)
        if wallOverflow { return false }
        return elapsed >= 0 && elapsed <= admissionBudgetNanoseconds
            && wallRemaining >= Self.minimumRemainingMilliseconds
    }

    public var description: String { "VoiceRelayConfig[redacted]" }
    public var debugDescription: String { description }

    /// Validate one issuer document against the retained origin and the two
    /// clocks (`VoiceRelayConfig.java:58-102`).
    ///
    /// - Parameters:
    ///   - bytes: the response body, exactly as it arrived.
    ///   - realm: the retained HTTPS origin; its literal IPv4 host is the only
    ///     host the URLs may name, and it is never resolved.
    ///   - wallMilliseconds: Unix milliseconds at receipt.
    ///   - monotonicNanoseconds: the monotonic reading at receipt, which
    ///     `usable(wallMilliseconds:monotonicNanoseconds:)` measures against.
    public static func parse(_ bytes: [UInt8]?, realm: String,
                             wallMilliseconds: Int64,
                             monotonicNanoseconds: Int64) throws -> VoiceRelayConfig {
        guard let bytes, !bytes.isEmpty, bytes.count <= maximumMetadataBytes else {
            throw VoiceRelayError.metadataSize
        }
        let host = try realmHost(realm)
        let text = String(decoding: bytes, as: UTF8.self)
        // `String(decoding:)` substitutes U+FFFD for a malformed sequence, so
        // a body that does not re-encode to itself was not well-formed UTF-8.
        // That is the strict decoder of `VoiceRelayConfig.java:63`.
        guard Array(text.utf8) == bytes else { throw VoiceRelayError.metadataEncoding }

        var parser = Parser(text)
        let fields = try parser.object()
        guard fields.count == 6 else { throw VoiceRelayError.metadataSchema }
        guard try number(fields, "v") == requiredVersion else { throw VoiceRelayError.metadataSchema }
        guard try number(fields, "ttl") == requiredTtl else { throw VoiceRelayError.metadataSchema }

        guard case .list(let values)? = fields["urls"] else { throw VoiceRelayError.urlShape }
        let udp = "turn:\(host):\(relayPort)?transport=udp"
        let tcp = "turn:\(host):\(relayPort)?transport=tcp"
        guard values.count == 2, values[0] == udp, values[1] == tcp else {
            throw VoiceRelayError.urlBinding
        }

        let expires = try number(fields, "expires")
        let username = try string(fields, "username")
        let password = try string(fields, "credential")
        guard isBoundUsername(username, expires: expires) else {
            throw VoiceRelayError.usernameBinding
        }
        guard isCanonicalTwentyByteBase64(password) else {
            throw VoiceRelayError.credentialEncoding
        }

        let (expiresMilliseconds, expiresOverflow) = expires.multipliedReportingOverflow(by: 1000)
        if expiresOverflow { throw VoiceRelayError.credentialLifetime }
        let (remaining, remainingOverflow) =
            expiresMilliseconds.subtractingReportingOverflow(wallMilliseconds)
        if remainingOverflow { throw VoiceRelayError.credentialLifetime }
        guard wallMilliseconds >= 0, remaining >= minimumRemainingMilliseconds,
              remaining <= maximumRemainingMilliseconds else {
            throw VoiceRelayError.credentialLifetime
        }
        return VoiceRelayConfig(urls: [udp, tcp], username: username, password: password,
                                expiresMilliseconds: expiresMilliseconds,
                                receiptNanoseconds: monotonicNanoseconds,
                                remainingMilliseconds: remaining)
    }

    // MARK: - The retained origin

    /// The literal canonical IPv4 host of an HTTPS origin; this check never
    /// resolves a hostname (`VoiceRelayConfig.java:104-117`).
    ///
    /// It is the anchored `https://<octet>.<octet>.<octet>.<octet>[:<port>]`
    /// of the Java pattern, written out: nothing before, nothing after, no
    /// user-info, no path, no query, no fragment, no brackets, no name. An
    /// octet may not carry a leading zero and may not exceed 255; a port may
    /// not start with `0`, may not be longer than five digits and may not
    /// exceed 65535.
    private static func realmHost(_ realm: String) throws -> String {
        guard realm.utf16.count <= 64 else { throw VoiceRelayError.realm }
        let scheme = Array("https://".utf8)
        let text = Array(realm.utf8)
        guard text.count > scheme.count, Array(text.prefix(scheme.count)) == scheme else {
            throw VoiceRelayError.realm
        }
        var index = scheme.count
        var octets: [String] = []
        for octet in 0..<4 {
            if octet > 0 {
                guard index < text.count, text[index] == UInt8(ascii: ".") else {
                    throw VoiceRelayError.realm
                }
                index += 1
            }
            let start = index
            while index < text.count, isDigit(text[index]) { index += 1 }
            guard index > start else { throw VoiceRelayError.realm }
            octets.append(String(decoding: text[start..<index], as: UTF8.self))
        }
        if index < text.count {
            guard text[index] == UInt8(ascii: ":") else { throw VoiceRelayError.realm }
            index += 1
            guard index < text.count, text[index] >= UInt8(ascii: "1"),
                  text[index] <= UInt8(ascii: "9") else { throw VoiceRelayError.realm }
            let start = index
            index += 1
            while index < text.count, isDigit(text[index]), index - start < 5 { index += 1 }
            guard index == text.count, let port = Int(String(decoding: text[start..<index], as: UTF8.self)),
                  port <= 65535 else { throw VoiceRelayError.realm }
        }
        for octet in octets {
            guard octet.utf8.count <= 3 else { throw VoiceRelayError.realm }
            guard octet.utf8.count == 1 || !octet.hasPrefix("0") else { throw VoiceRelayError.realm }
            guard let value = Int(octet), value <= 255 else { throw VoiceRelayError.realm }
        }
        return octets.joined(separator: ".")
    }

    // MARK: - The two credential members

    /// `^<expires>:[0-9a-f]{32}$` (`VoiceRelayConfig.java:77`), measured on
    /// UTF-8 bytes: every byte the pattern accepts is ASCII, so a multi-byte
    /// scalar can never satisfy it.
    private static func isBoundUsername(_ username: String, expires: Int64) -> Bool {
        let prefix = Array("\(expires):".utf8)
        let text = Array(username.utf8)
        guard text.count == prefix.count + 32 else { return false }
        guard Array(text.prefix(prefix.count)) == prefix else { return false }
        return text.suffix(32).allSatisfy { isDigit($0) || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f")) }
    }

    /// `^[A-Za-z0-9+/]{27}=$` decoding to exactly 20 bytes, re-encoding to
    /// itself (`VoiceRelayConfig.java:79-87`).
    ///
    /// 27 alphabet characters carry 162 bits and 20 bytes are 160, so the
    /// round trip through a tolerant decoder is precisely the statement that
    /// the two unused low bits of the last character are zero. That is checked
    /// here directly instead of decoding and re-encoding.
    private static func isCanonicalTwentyByteBase64(_ password: String) -> Bool {
        let text = Array(password.utf8)
        guard text.count == 28, text[27] == UInt8(ascii: "=") else { return false }
        var last: UInt8?
        for character in text.prefix(27) {
            guard let value = base64Value(character) else { return false }
            last = value
        }
        // The two low bits of the 27th character fall outside the 20 bytes.
        return (last ?? 0xff) & 0b11 == 0
    }

    private static func base64Value(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return character - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return character - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0") + 52
        case UInt8(ascii: "+"): return 62
        case UInt8(ascii: "/"): return 63
        default: return nil
        }
    }

    private static func isDigit(_ character: UInt8) -> Bool {
        character >= UInt8(ascii: "0") && character <= UInt8(ascii: "9")
    }

    // MARK: - Typed field access

    private static func number(_ fields: [String: Value], _ key: String) throws -> Int64 {
        guard case .integer(let value)? = fields[key], value > 0 else {
            throw VoiceRelayError.positiveIntegerRequired
        }
        return value
    }

    private static func string(_ fields: [String: Value], _ key: String) throws -> String {
        guard case .text(let value)? = fields[key] else { throw VoiceRelayError.stringRequired }
        return value
    }

    /// The three shapes the six known fields may take.
    enum Value: Equatable {
        case integer(Int64)
        case text(String)
        case list([String])
    }

    /// The bounded, non-recursive grammar shared with Android
    /// (`VoiceRelayConfig.java:132-237`), running over UTF-16 code units so
    /// that a `\u` escape is measured exactly as Java measures it.
    struct Parser {
        private let source: [UInt16]
        private var position = 0

        init(_ source: String) { self.source = Array(source.utf16) }

        /// Java's `" \r\n\t".indexOf(...) >= 0`.
        private static let whitespace: Set<UInt16> = [0x20, 0x0d, 0x0a, 0x09]

        private mutating func space() {
            while position < source.count, Self.whitespace.contains(source[position]) { position += 1 }
        }

        private mutating func take() throws -> UInt16 {
            guard position < source.count else { throw VoiceRelayError.truncatedJson }
            defer { position += 1 }
            return source[position]
        }

        private mutating func expect(_ expected: Unicode.Scalar) throws {
            space()
            guard try take() == UInt16(expected.value) else { throw VoiceRelayError.jsonSyntax }
        }

        /// One JSON string, escapes resolved, with unpaired surrogates refused.
        private mutating func text() throws -> String {
            try expect("\"")
            var units: [UInt16] = []
            while true {
                var next = try take()
                if next == UInt16(ascii: "\"") { break }
                if next < 32 { throw VoiceRelayError.jsonControl }
                if next == UInt16(ascii: "\\") {
                    next = try take()
                    switch next {
                    case UInt16(ascii: "\""), UInt16(ascii: "\\"), UInt16(ascii: "/"): break
                    case UInt16(ascii: "b"): next = 0x08
                    case UInt16(ascii: "f"): next = 0x0c
                    case UInt16(ascii: "n"): next = 0x0a
                    case UInt16(ascii: "r"): next = 0x0d
                    case UInt16(ascii: "t"): next = 0x09
                    case UInt16(ascii: "u"):
                        var value: UInt16 = 0
                        for _ in 0..<4 {
                            guard let digit = Self.hexValue(try take()) else {
                                throw VoiceRelayError.jsonEscape
                            }
                            value = value &* 16 &+ UInt16(digit)
                        }
                        next = value
                    default: throw VoiceRelayError.jsonEscape
                    }
                }
                units.append(next)
            }
            var index = 0
            while index < units.count {
                let unit = units[index]
                if Self.isHighSurrogate(unit) {
                    index += 1
                    guard index < units.count, Self.isLowSurrogate(units[index]) else {
                        throw VoiceRelayError.jsonSurrogate
                    }
                } else if Self.isLowSurrogate(unit) {
                    throw VoiceRelayError.jsonSurrogate
                }
                index += 1
            }
            return String(decoding: units, as: UTF16.self)
        }

        /// One non-negative integer with no leading zero and no sign, exponent
        /// or fraction (`VoiceRelayConfig.java:193-203`).
        private mutating func integer() throws -> Int64 {
            space()
            let start = position
            while position < source.count, source[position] >= UInt16(ascii: "0"),
                  source[position] <= UInt16(ascii: "9") { position += 1 }
            let digits = String(decoding: source[start..<position], as: UTF16.self)
            guard !digits.isEmpty,
                  digits.count == 1 || !digits.hasPrefix("0") else { throw VoiceRelayError.jsonInteger }
            guard let value = Int64(digits) else { throw VoiceRelayError.jsonIntegerOverflow }
            return value
        }

        /// Exactly two strings in brackets; nothing else is an array here.
        private mutating func urls() throws -> [String] {
            try expect("[")
            var values: [String] = []
            values.append(try text())
            try expect(",")
            values.append(try text())
            try expect("]")
            return values
        }

        /// The whole document: one object of the six known fields, then
        /// whitespace and nothing more.
        mutating func object() throws -> [String: Value] {
            var fields: [String: Value] = [:]
            try expect("{")
            while true {
                let key = try text()
                guard fields[key] == nil else { throw VoiceRelayError.duplicateField }
                try expect(":")
                let value: Value
                switch key {
                case "v", "expires", "ttl": value = .integer(try integer())
                case "username", "credential": value = .text(try text())
                case "urls": value = .list(try urls())
                default: throw VoiceRelayError.unknownField
                }
                fields[key] = value
                space()
                let next = try take()
                if next == UInt16(ascii: "}") { break }
                guard next == UInt16(ascii: ",") else { throw VoiceRelayError.jsonSeparator }
            }
            space()
            guard position == source.count else { throw VoiceRelayError.trailingInput }
            return fields
        }

        /// Java's `"0123456789abcdefABCDEF".indexOf(digit)` folded to a value.
        private static func hexValue(_ unit: UInt16) -> Int? {
            switch unit {
            case UInt16(ascii: "0")...UInt16(ascii: "9"): return Int(unit - UInt16(ascii: "0"))
            case UInt16(ascii: "a")...UInt16(ascii: "f"): return Int(unit - UInt16(ascii: "a")) + 10
            case UInt16(ascii: "A")...UInt16(ascii: "F"): return Int(unit - UInt16(ascii: "A")) + 10
            default: return nil
            }
        }

        private static func isHighSurrogate(_ unit: UInt16) -> Bool { unit >= 0xd800 && unit <= 0xdbff }
        private static func isLowSurrogate(_ unit: UInt16) -> Bool { unit >= 0xdc00 && unit <= 0xdfff }
    }
}
