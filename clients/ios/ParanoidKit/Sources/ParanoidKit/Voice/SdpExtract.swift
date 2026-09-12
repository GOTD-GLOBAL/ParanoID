/// The fields `send_call_v1` carries beside an SDP, read out of that SDP.
///
/// A `call` control repeats the DTLS fingerprint and the ICE credentials as
/// their own members, and the core cross-checks every one of them against the
/// SDP text before it accepts the control (`voice_v1.rs:126-152`): the
/// fingerprint must be the lowercase colon-free form of the `a=fingerprint`
/// line, and `ice_ufrag` / `ice_pwd` must equal their `a=` lines byte for
/// byte. Android reads the same three values with a line scan before calling
/// `CallController.localDescription` (`TextEngine.java:138-144`); this is the
/// iOS counterpart.
///
/// The scan never rewrites the SDP. libwebrtc's offer is sent exactly as
/// produced (`docs/protocol/voice-v1.md`: the sender does not munge SDP), so
/// anything the core would refuse is fixed through WebRTC configuration
/// instead, never by editing the text.
///
/// The remaining members are the survey the spike and the call layer need:
/// the byte count the 6144-byte limit applies to, the `a=setup` value, the
/// `a=rtpmap` lines, and the counts of `a=candidate` and `a=crypto` lines.
/// The core tolerates extra `a=rtpmap` entries (RED/CN/telephone-event) as
/// long as every payload type also appears in the `m=` line
/// (`voice_v1.rs:166-199`), and refuses any `a=crypto` line outright.
public struct SdpExtract: Equatable, Sendable {
    /// `a=fingerprint:sha-256 …`, lowercase and without the colons, the form
    /// the `fingerprint` member of a `call` body must carry.
    public let fingerprint: String
    /// The verbatim value of the single `a=ice-ufrag:` line.
    public let iceUfrag: String
    /// The verbatim value of the single `a=ice-pwd:` line.
    public let icePwd: String
    /// UTF-8 length of the whole SDP; the core refuses more than 6144 bytes.
    public let byteCount: Int
    /// The value of the single `a=setup:` line (`actpass` in an offer,
    /// `active` or `passive` in an answer).
    public let setup: String
    /// Every `a=rtpmap:` line, in order, verbatim.
    public let rtpmap: [String]
    /// Number of `a=candidate:` lines; the core refuses more than 16.
    public let candidateCount: Int
    /// Number of `a=crypto:` lines; the core refuses any.
    public let cryptoCount: Int

    /// Reads the fields out of one session description.
    ///
    /// Returns `nil` unless the text carries exactly one `a=fingerprint:`
    /// line with an `sha-256` value of 32 colon-separated hexadecimal bytes,
    /// exactly one `a=ice-ufrag:` line, exactly one `a=ice-pwd:` line and
    /// exactly one `a=setup:` line. That is stricter than Android's scan,
    /// which keeps the last occurrence, and matches what the core accepts:
    /// a second copy of any of these lines is refused as `invalid_call_sdp`
    /// (`voice_v1.rs:186-196`), so a description carrying one is not worth
    /// sending.
    public init?(sdp: String) {
        let lines = Self.lines(of: sdp)
        var fingerprints: [String] = []
        var ufrags: [String] = []
        var passwords: [String] = []
        var setups: [String] = []
        var rtpmap: [String] = []
        var candidates = 0
        var cryptos = 0
        for line in lines {
            if let value = Self.value(of: "a=fingerprint:", in: line) {
                guard let hex = Self.sha256Fingerprint(value) else { return nil }
                fingerprints.append(hex)
            } else if let value = Self.value(of: "a=ice-ufrag:", in: line) {
                ufrags.append(value)
            } else if let value = Self.value(of: "a=ice-pwd:", in: line) {
                passwords.append(value)
            } else if let value = Self.value(of: "a=setup:", in: line) {
                setups.append(value)
            } else if line.hasPrefix("a=rtpmap:") {
                rtpmap.append(line)
            } else if line.hasPrefix("a=candidate:") {
                candidates += 1
            } else if line.hasPrefix("a=crypto:") {
                cryptos += 1
            }
        }
        guard fingerprints.count == 1, ufrags.count == 1, passwords.count == 1, setups.count == 1
        else {
            return nil
        }
        fingerprint = fingerprints[0]
        iceUfrag = ufrags[0]
        icePwd = passwords[0]
        byteCount = sdp.utf8.count
        setup = setups[0]
        self.rtpmap = rtpmap
        candidateCount = candidates
        cryptoCount = cryptos
    }

    /// The lines of an SDP, exactly as `str::lines()` cuts them on the core
    /// side: split on `\n`, one trailing `\r` dropped.
    ///
    /// The split runs over UTF-8 bytes, not over `Character`s, because Swift
    /// folds a CRLF pair into a single grapheme cluster that is equal to
    /// neither `"\r"` nor `"\n"` — a `String` split on `"\n"` finds no line
    /// break at all in a CRLF document, which is exactly what SDP is.
    public static func lines(of sdp: String) -> [String] {
        Array(sdp.utf8)
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { line in
                let body = line.last == UInt8(ascii: "\r") ? line.dropLast() : line
                return String(decoding: body, as: UTF8.self)
            }
    }

    private static func value(of prefix: String, in line: String) -> String? {
        line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }

    /// `sha-256 AB:CD:…` -> `abcd…`, or `nil` for any other algorithm or
    /// shape. The core compares this exact string with the body's
    /// `fingerprint` member (`voice_v1.rs:126-140`).
    private static func sha256Fingerprint(_ value: String) -> String? {
        guard value.hasPrefix("sha-256 ") else { return nil }
        let bytes = value.dropFirst("sha-256 ".count).split(separator: ":", omittingEmptySubsequences: false)
        guard bytes.count == 32,
              bytes.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isHexDigit } })
        else {
            return nil
        }
        return bytes.joined().lowercased()
    }
}
