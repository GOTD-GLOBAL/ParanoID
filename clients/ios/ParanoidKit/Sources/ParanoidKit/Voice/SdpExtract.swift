/// The fields `send_call_v1` carries beside an SDP, read out of that SDP,
/// together with the structure the call-v2 validator measures.
///
/// A `call` control repeats the DTLS fingerprint and the ICE credentials as
/// their own members, and the core cross-checks every one of them against the
/// SDP text before it accepts the control (`voice_v1.rs:167-188`): the
/// fingerprint must be the lowercase colon-free form of the `a=fingerprint`
/// line, and `ice_ufrag` / `ice_pwd` must equal their `a=` lines byte for
/// byte. Android reads the same three values with a line scan before calling
/// `CallController.localDescription` (`TextEngine.java:138-144`); this is the
/// iOS counterpart.
///
/// A call-v2 description is not one media section but two — `m=audio` then
/// `m=video`, bundled on the audio section's transport
/// ([call-v2](../../../../../../docs/protocol/call-v2.md)) — so each transport
/// attribute may appear once at session level **or** once in the audio
/// section, and at most once more in the video section with the identical
/// value (`voice_v1.rs:236-242`). This scan applies that rule: it resolves the
/// one value each attribute has, wherever the description repeats it, and
/// refuses a description that carries two different values or none.
///
/// The scan never rewrites the SDP. libwebrtc's offer is sent exactly as
/// produced (`docs/protocol/voice-v1.md`: the sender does not munge SDP), so
/// anything the core would refuse is fixed through WebRTC configuration
/// instead, never by editing the text.
///
/// The remaining members are the survey the call layer and the spike need,
/// per section where the core counts per section: the payload types of the
/// `m=` line, the `a=rtpmap` mappings, the `a=sendrecv` and `a=rtcp-mux`
/// counts, and the `a=candidate` count; plus the whole-description totals —
/// byte count, line count, and the number of `a=crypto` and of blocked
/// direction attributes. The core tolerates extra audio mappings
/// (RED/CN/telephone-event) as long as every payload type also appears in the
/// `m=` line, accepts only H.264/VP8/rtx/red/ulpfec/flexfec-03 in the video
/// section (`voice_v1.rs:11-18`), and refuses any `a=crypto` line outright.
public struct SdpExtract: Equatable, Sendable {
    /// One `a=rtpmap:` line, split the way the core splits it
    /// (`voice_v1.rs:203-225`).
    public struct Mapping: Equatable, Sendable {
        /// The payload type, verbatim; it must also appear in the `m=` line.
        public let payloadType: String
        /// The encoding name and parameters, lowercased: `opus/48000/2`,
        /// `h264/90000`. The core compares the lowercase form.
        public let codec: String
        /// The whole line, verbatim, for the evidence file.
        public let line: String
    }

    /// One media section: the `m=` line and everything up to the next one.
    public struct Section: Equatable, Sendable {
        /// The media type of the `m=` line, verbatim (`audio`, `video`).
        public let kind: String
        /// The port of the `m=` line, or `nil` when it is not a number. The
        /// core requires a non-zero audio port and allows `0` on a
        /// bundle-only video section (`voice_v1.rs:157-159`).
        public let port: Int?
        /// The transport of the `m=` line, verbatim; the core requires
        /// `UDP/TLS/RTP/SAVPF`.
        public let transport: String
        /// The payload types listed in the `m=` line, in order.
        public let payloadTypes: [String]
        /// Every `a=rtpmap:` line of this section, in order.
        public let mappings: [Mapping]
        /// Number of `a=sendrecv` lines; the core requires exactly one in each
        /// of the two sections and none at session level.
        public let sendrecvCount: Int
        /// Number of `a=rtcp-mux` lines; required once in the audio section,
        /// allowed once in the video section.
        public let rtcpMuxCount: Int
        /// Number of `a=candidate:` lines of this section. Under max-bundle
        /// they all sit in the audio section.
        public let candidateCount: Int

        /// The `a=rtpmap:` lines, verbatim.
        public var rtpmap: [String] { mappings.map(\.line) }
        /// The lowercased codec of every mapping, in order.
        public var codecs: [String] { mappings.map(\.codec) }
        /// Whether every mapped payload type is also declared in the `m=`
        /// line, which the core requires (`voice_v1.rs:250-254`).
        public var declaresEveryMapping: Bool {
            mappings.allSatisfy { payloadTypes.contains($0.payloadType) }
        }
    }

    /// `a=fingerprint:sha-256 …`, lowercase and without the colons, the form
    /// the `fingerprint` member of a `call` body must carry.
    public let fingerprint: String
    /// The one value the `a=ice-ufrag:` lines agree on.
    public let iceUfrag: String
    /// The one value the `a=ice-pwd:` lines agree on.
    public let icePwd: String
    /// UTF-8 length of the whole SDP. The core's own limit is 12288 bytes
    /// (`voice_v1.rs:10`), but the control frame cannot carry that much; see
    /// ``maxSdpBytes``.
    public let byteCount: Int
    /// Number of lines after `v=0`; the core refuses more than 512
    /// (`voice_v1.rs:133`).
    public let lineCount: Int
    /// The one value the `a=setup:` lines agree on (`actpass` in an offer,
    /// `active` or `passive` in an answer).
    public let setup: String
    /// The media sections, in the order their `m=` lines appear.
    public let sections: [Section]
    /// Every `a=rtpmap:` line of the description, in order, verbatim.
    public let rtpmap: [String]
    /// Number of `a=candidate:` lines; the core refuses more than 16.
    public let candidateCount: Int
    /// Number of `a=crypto:` lines; the core refuses any.
    public let cryptoCount: Int
    /// Number of `a=sendonly` / `a=recvonly` / `a=inactive` lines; the core
    /// refuses any (`voice_v1.rs:193-194`), because camera on and off is a
    /// track flag plus a `media` control, never a renegotiation.
    public let blockedDirectionCount: Int

    /// The media types of the sections, in order: call-v2 requires exactly
    /// `["audio", "video"]`.
    public var mediaKinds: [String] { sections.map(\.kind) }

    /// Largest description this client hands to the core.
    ///
    /// `MAX_SDP` in the core is 12288 bytes, but a `call` control travels
    /// inside one frame2 envelope and the measured ceiling of that path is
    /// 10040 bytes, so the description is capped below it with room to spare
    /// rather than at the core's limit. A description above this cap is a
    /// configuration bug on this side and is never sent.
    public static let maxSdpBytes = 9000

    /// Whether the description fits ``maxSdpBytes``; checked before the SDP is
    /// handed to the core.
    public var fitsFrameBudget: Bool { byteCount <= Self.maxSdpBytes }

    /// Reads the fields out of one session description.
    ///
    /// Returns `nil` unless the text begins with `v=0` and each of
    /// `a=fingerprint:`, `a=ice-ufrag:`, `a=ice-pwd:` and `a=setup:` resolves
    /// to exactly one value under the call-v2 placement rule: once at session
    /// level or once in the first media section, at most once more in each
    /// later section, and every occurrence carrying the same value. The
    /// fingerprint must additionally be an `sha-256` value of 32
    /// colon-separated hexadecimal bytes. That is what the core accepts
    /// (`voice_v1.rs:236-242`); a description that fails it is not worth
    /// sending. A misplaced `a=sendrecv`, `a=rtcp-mux` or `a=rtpmap:` line —
    /// one at session level, outside any media section — is refused the same
    /// way, because the core refuses it too.
    public init?(sdp: String) {
        let lines = Self.lines(of: sdp)
        guard lines.first == "v=0" else { return nil }
        // Attribute occurrences carry the index of the section they were read
        // in; `session` is the run of lines before the first `m=` line.
        var fingerprints = Placement()
        var ufrags = Placement()
        var passwords = Placement()
        var setups = Placement()
        var sections: [Section] = []
        var kinds: [String] = []
        var ports: [Int?] = []
        var transports: [String] = []
        var payloadTypes: [[String]] = []
        var mappings: [[Mapping]] = []
        var sendrecv: [Int] = []
        var mux: [Int] = []
        var sectionCandidates: [Int] = []
        var candidates = 0
        var cryptos = 0
        var blocked = 0

        for line in lines.dropFirst() {
            if let value = Self.value(of: "m=", in: line) {
                let fields = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 4 else { return nil }
                kinds.append(fields[0])
                ports.append(Int(fields[1]))
                transports.append(fields[2])
                payloadTypes.append(Array(fields[3...]))
                mappings.append([])
                sendrecv.append(0)
                mux.append(0)
                sectionCandidates.append(0)
            } else if let value = Self.value(of: "a=fingerprint:", in: line) {
                guard let hex = Self.sha256Fingerprint(value) else { return nil }
                fingerprints.add(hex, section: kinds.count)
            } else if let value = Self.value(of: "a=ice-ufrag:", in: line) {
                ufrags.add(value, section: kinds.count)
            } else if let value = Self.value(of: "a=ice-pwd:", in: line) {
                passwords.add(value, section: kinds.count)
            } else if let value = Self.value(of: "a=setup:", in: line) {
                setups.add(value, section: kinds.count)
            } else if line == "a=sendrecv" {
                guard !sendrecv.isEmpty else { return nil }
                sendrecv[sendrecv.count - 1] += 1
            } else if line == "a=sendonly" || line == "a=recvonly" || line == "a=inactive" {
                blocked += 1
            } else if line == "a=rtcp-mux" {
                guard !mux.isEmpty else { return nil }
                mux[mux.count - 1] += 1
            } else if let value = Self.value(of: "a=rtpmap:", in: line) {
                guard !mappings.isEmpty, let space = value.firstIndex(of: " ") else { return nil }
                mappings[mappings.count - 1].append(Mapping(
                    payloadType: String(value[value.startIndex..<space]),
                    codec: String(value[value.index(after: space)...]).lowercased(),
                    line: line))
            } else if line.hasPrefix("a=candidate:") {
                candidates += 1
                if !sectionCandidates.isEmpty { sectionCandidates[sectionCandidates.count - 1] += 1 }
            } else if line.hasPrefix("a=crypto:") {
                cryptos += 1
            }
        }

        guard let fingerprint = fingerprints.resolve(sections: kinds.count),
              let iceUfrag = ufrags.resolve(sections: kinds.count),
              let icePwd = passwords.resolve(sections: kinds.count),
              let setup = setups.resolve(sections: kinds.count)
        else {
            return nil
        }
        for index in kinds.indices {
            sections.append(Section(
                kind: kinds[index], port: ports[index], transport: transports[index],
                payloadTypes: payloadTypes[index], mappings: mappings[index],
                sendrecvCount: sendrecv[index], rtcpMuxCount: mux[index],
                candidateCount: sectionCandidates[index]))
        }
        self.fingerprint = fingerprint
        self.iceUfrag = iceUfrag
        self.icePwd = icePwd
        byteCount = sdp.utf8.count
        // `str::lines()` on the core side yields no empty line for the final
        // `\r\n`, so neither does this count.
        lineCount = (lines.last?.isEmpty == true ? lines.count - 1 : lines.count) - 1
        self.setup = setup
        self.sections = sections
        rtpmap = sections.flatMap(\.rtpmap)
        candidateCount = candidates
        cryptoCount = cryptos
        blockedDirectionCount = blocked
    }

    /// Where one attribute was found and what it said.
    ///
    /// The core allows the attribute once at session level or once in the
    /// first section, and at most once more in each later section, all
    /// occurrences carrying the same value (`voice_v1.rs:236-242`).
    private struct Placement {
        /// Section index of each occurrence; `sections.count` at the time of
        /// the read, so an occurrence before any `m=` line lands on `0` only
        /// if there is no section at all — session level is tracked apart.
        private var counts: [Int: Int] = [:]
        private var value: String?
        private var conflicting = false
        /// `section` is the number of `m=` lines seen so far: `0` means the
        /// line sits at session level, `n > 0` means it sits in section
        /// `n - 1`.
        mutating func add(_ value: String, section: Int) {
            counts[section, default: 0] += 1
            if let stored = self.value, stored != value { conflicting = true }
            self.value = value
        }

        func resolve(sections: Int) -> String? {
            guard !conflicting, let value else { return nil }
            let sessionLevel = counts[0, default: 0]
            // The first section shares one slot with session level; every
            // later section may repeat the same value once.
            guard sessionLevel + counts[1, default: 0] == 1 else { return nil }
            for section in 2...max(2, sections) where sessionLevel + counts[section, default: 0] > 1 {
                return nil
            }
            return value
        }
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
    /// `fingerprint` member (`voice_v1.rs:167-178`).
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
