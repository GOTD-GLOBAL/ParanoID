import Foundation

/// Everything a DER read can report. The walker never traps: a truncated or
/// malformed encoding always leaves through one of these cases, so a hostile
/// certificate cannot turn a parse into a crash.
public enum DERError: Error, Equatable, Sendable {
    /// The encoding claims more octets than the buffer holds.
    case truncated
    /// A DER rule is broken: an indefinite or non-minimal length, a multi-byte
    /// tag, a `BOOLEAN` that is not `0x00`/`0xFF`, a `DEFAULT` value written
    /// out, a non-minimal `INTEGER` or `OBJECT IDENTIFIER` arc.
    case malformed(String)
    /// Well-formed DER that is not the structure the grammar asks for here.
    case unexpected(String)
}

/// The identifier octets this walker needs. Every one is a single-byte tag:
/// X.509 uses no tag number above 30, so the multi-byte form is refused
/// outright.
public enum DERTag {
    public static let boolean: UInt8 = 0x01
    public static let integer: UInt8 = 0x02
    public static let bitString: UInt8 = 0x03
    public static let octetString: UInt8 = 0x04
    public static let objectIdentifier: UInt8 = 0x06
    public static let utcTime: UInt8 = 0x17
    public static let generalizedTime: UInt8 = 0x18
    public static let sequence: UInt8 = 0x30
    public static let set: UInt8 = 0x31

    /// The constructed context-specific tag `[number]`, as the X.509 modules
    /// write the explicitly tagged members of a certificate (`[0]` version,
    /// `[3]` extensions).
    public static func context(_ number: UInt8) -> UInt8 { 0xa0 | (number & 0x1f) }
}

/// One tag-length-value triple.
///
/// `encoded` is the element with its header, which is what a signature covers
/// (`tbsCertificate`) and what a key pin digests (`subjectPublicKeyInfo`);
/// `content` is the value octets alone. Both are copies, so an element stays
/// valid independently of the buffer it was read from.
public struct DERElement: Equatable, Sendable {
    public let tag: UInt8
    public let content: [UInt8]
    public let encoded: [UInt8]

    /// True when bit 6 of the identifier octet is set, i.e. the value octets
    /// are themselves a series of elements.
    public var isConstructed: Bool { tag & 0x20 != 0 }

    /// The tag number when the element carries a context-specific tag
    /// (`[2] dNSName`, `[7] iPAddress`, ...), `nil` for every other class.
    public var contextNumber: UInt8? { (tag & 0xc0) == 0x80 ? tag & 0x1f : nil }

    /// The single element encoded by `bytes`. Trailing octets are refused, so
    /// a certificate with anything appended to it does not parse.
    public static func parse(_ bytes: [UInt8]) throws -> DERElement {
        var reader = DERReader(bytes)
        let element = try reader.element()
        guard reader.isAtEnd else { throw DERError.unexpected("trailing octets after the top-level element") }
        return element
    }

    /// The elements inside a constructed value, all of them; a value that does
    /// not divide exactly into elements is rejected.
    public func children() throws -> [DERElement] {
        guard isConstructed else { throw DERError.unexpected("element 0x\(String(tag, radix: 16)) is primitive") }
        var reader = DERReader(content)
        var result: [DERElement] = []
        while !reader.isAtEnd { result.append(try reader.element()) }
        return result
    }

    /// The dotted decimal form of an `OBJECT IDENTIFIER`, with the minimal
    /// base-128 encoding enforced (a leading `0x80` in any arc is a forgery
    /// vector: it would let two encodings name the same OID).
    public func objectIdentifier() throws -> String {
        guard tag == DERTag.objectIdentifier else { throw DERError.unexpected("not an OBJECT IDENTIFIER") }
        var arcs: [UInt64] = []
        var value: UInt64 = 0
        var started = false
        for byte in content {
            if !started, byte == 0x80 { throw DERError.malformed("non-minimal OBJECT IDENTIFIER arc") }
            guard value <= UInt64.max >> 7 else { throw DERError.malformed("OBJECT IDENTIFIER arc out of range") }
            started = true
            value = value << 7 | UInt64(byte & 0x7f)
            if byte & 0x80 == 0 {
                arcs.append(value)
                value = 0
                started = false
            }
        }
        guard !started else { throw DERError.malformed("truncated OBJECT IDENTIFIER arc") }
        guard let first = arcs.first else { throw DERError.malformed("empty OBJECT IDENTIFIER") }
        let root = min(first / 40, 2)
        return ([root, first - root * 40] + arcs.dropFirst()).map { String($0) }.joined(separator: ".")
    }

    /// A `BOOLEAN`; DER allows exactly `0x00` and `0xFF`.
    public func boolean() throws -> Bool {
        guard tag == DERTag.boolean else { throw DERError.unexpected("not a BOOLEAN") }
        guard content.count == 1 else { throw DERError.malformed("BOOLEAN must be one octet") }
        switch content[0] {
        case 0x00: return false
        case 0xff: return true
        default: throw DERError.malformed("BOOLEAN must be 0x00 or 0xFF")
        }
    }

    /// A small non-negative `INTEGER` (version, path length), minimally
    /// encoded. Negative values and anything wider than 56 bits are refused
    /// rather than wrapped.
    public func integer() throws -> Int {
        guard tag == DERTag.integer else { throw DERError.unexpected("not an INTEGER") }
        guard let first = content.first else { throw DERError.malformed("empty INTEGER") }
        if content.count > 1, first == 0x00, content[1] & 0x80 == 0 {
            throw DERError.malformed("non-minimal INTEGER")
        }
        guard first & 0x80 == 0 else { throw DERError.unexpected("negative INTEGER") }
        let digits = content.drop(while: { $0 == 0x00 })
        guard digits.count <= 7 else { throw DERError.unexpected("INTEGER too large") }
        return digits.reduce(0) { $0 << 8 | Int($1) }
    }

    /// A `BIT STRING` as its unused-bit count and its octets. The count is the
    /// number of ignored bits in the last octet.
    public func bitString() throws -> (unusedBits: Int, bytes: [UInt8]) {
        guard tag == DERTag.bitString else { throw DERError.unexpected("not a BIT STRING") }
        guard let unused = content.first else { throw DERError.malformed("empty BIT STRING") }
        guard unused <= 7 else { throw DERError.malformed("BIT STRING unused-bit count out of range") }
        guard unused == 0 || content.count > 1 else { throw DERError.malformed("empty BIT STRING with unused bits") }
        return (Int(unused), Array(content.dropFirst()))
    }

    /// A `UTCTime` or `GeneralizedTime` in the only form RFC 5280 §4.1.2.5
    /// allows in a certificate: UTC, whole seconds, `Z` suffix. A two-digit
    /// year below 50 is 20xx, otherwise 19xx.
    public func time() throws -> Date {
        let yearDigits: Int
        switch tag {
        case DERTag.utcTime: yearDigits = 2
        case DERTag.generalizedTime: yearDigits = 4
        default: throw DERError.unexpected("not a UTCTime or GeneralizedTime")
        }
        guard content.count == yearDigits + 11, content.last == UInt8(ascii: "Z") else {
            throw DERError.malformed("certificate time must be YYMMDDHHMMSSZ or YYYYMMDDHHMMSSZ")
        }
        func number(_ offset: Int, _ width: Int) throws -> Int {
            try content[offset..<(offset + width)].reduce(0) { total, byte in
                guard (0x30...0x39).contains(byte) else { throw DERError.malformed("non-digit in a certificate time") }
                return total * 10 + Int(byte - 0x30)
            }
        }
        var components = DateComponents()
        let year = try number(0, yearDigits)
        components.year = yearDigits == 4 ? year : year + (year >= 50 ? 1900 : 2000)
        components.month = try number(yearDigits, 2)
        components.day = try number(yearDigits + 2, 2)
        components.hour = try number(yearDigits + 4, 2)
        components.minute = try number(yearDigits + 6, 2)
        components.second = try number(yearDigits + 8, 2)
        guard (1...12).contains(components.month ?? 0), (1...31).contains(components.day ?? 0),
              (0...23).contains(components.hour ?? -1), (0...59).contains(components.minute ?? -1),
              (0...60).contains(components.second ?? -1) else {
            throw DERError.malformed("certificate time out of range")
        }
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw DERError.malformed("no UTC time zone") }
        calendar.timeZone = utc
        guard let date = calendar.date(from: components) else { throw DERError.malformed("invalid certificate time") }
        return date
    }
}

/// A cursor over a series of DER elements.
///
/// It reads the definite-length form only, and only when the length is encoded
/// minimally: an indefinite length (BER, not DER), a length with leading zero
/// octets, a long form below 128 and a multi-byte tag are all rejected. That
/// keeps one certificate to exactly one encoding, which is what makes a
/// digest over `subjectPublicKeyInfo` a meaningful pin.
public struct DERReader {
    private let bytes: [UInt8]
    private var index: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.index = 0
    }

    /// True once every octet has been consumed.
    public var isAtEnd: Bool { index == bytes.count }

    /// The next element, or an error that says why there is not one.
    public mutating func element() throws -> DERElement {
        let start = index
        guard index < bytes.count else { throw DERError.truncated }
        let tag = bytes[index]
        index += 1
        guard tag & 0x1f != 0x1f else { throw DERError.malformed("multi-byte tag") }
        guard index < bytes.count else { throw DERError.truncated }
        let first = bytes[index]
        index += 1
        var length = 0
        if first & 0x80 != 0 {
            let width = Int(first & 0x7f)
            guard width != 0 else { throw DERError.malformed("indefinite length") }
            guard width <= 4 else { throw DERError.malformed("length wider than a certificate can be") }
            guard bytes.count - index >= width else { throw DERError.truncated }
            guard bytes[index] != 0x00 else { throw DERError.malformed("non-minimal length") }
            for _ in 0..<width {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
            guard length >= 0x80 else { throw DERError.malformed("non-minimal length") }
        } else {
            length = Int(first)
        }
        guard bytes.count - index >= length else { throw DERError.truncated }
        let element = DERElement(tag: tag,
                                 content: Array(bytes[index..<(index + length)]),
                                 encoded: Array(bytes[start..<(index + length)]))
        index += length
        return element
    }

    /// The next element, required to carry `tag`.
    public mutating func element(tag: UInt8) throws -> DERElement {
        let element = try element()
        guard element.tag == tag else {
            throw DERError.unexpected("expected tag 0x\(String(tag, radix: 16)), got 0x\(String(element.tag, radix: 16))")
        }
        return element
    }
}
