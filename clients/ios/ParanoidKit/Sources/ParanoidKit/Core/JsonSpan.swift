/// Byte-exact extraction of one top-level member value from a JSON object text.
///
/// The core returns its next snapshot as the top-level `"state"` member of
/// every reply. Android re-serialises that member through `org.json` before
/// comparing and persisting it (`SelfServiceClient.java:73-76`); on iOS the
/// value is sliced out of the reply verbatim and never re-encoded, so the
/// persisted snapshot and the `next == current` comparison use exactly the
/// bytes the core produced. This is sound because the core serialises every
/// snapshot through `serde_json::Value` (sorted `BTreeMap` keys, no
/// insignificant whitespace): the same state is always the same text.
///
/// The scanner reads only as much JSON grammar as the task needs: it walks the
/// members of the outermost object, decodes member names (escapes included)
/// to find the requested key and returns the raw bytes of that member's value
/// (string, number, literal, array or object) unchanged. Any syntax it cannot
/// account for yields `nil`; it never guesses.
public enum JsonSpan {
    /// The verbatim text of the top-level `"state"` member of `text`, or
    /// `nil` when `text` is not a JSON object or carries no such member.
    public static func state(in text: String) -> String? {
        value(of: "state", in: text)
    }

    /// The verbatim text of the value of `key` in the top-level object of
    /// `text`, or `nil` when `text` is not a JSON object or has no such
    /// member. Keys nested inside other values are never matched.
    public static func value(of key: String, in text: String) -> String? {
        var scanner = Scanner(bytes: Array(text.utf8))
        guard let range = scanner.topLevelValue(of: Array(key.utf8)) else {
            return nil
        }
        return String(decoding: scanner.bytes[range], as: UTF8.self)
    }
}

private struct Scanner {
    let bytes: [UInt8]
    private var index = 0

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let leftBrace = UInt8(ascii: "{")
    private static let rightBrace = UInt8(ascii: "}")
    private static let leftBracket = UInt8(ascii: "[")
    private static let rightBracket = UInt8(ascii: "]")
    private static let comma = UInt8(ascii: ",")
    private static let colon = UInt8(ascii: ":")
    private static let simpleEscapes: Set<UInt8> = Set("\"\\/bfnrt".utf8)
    private static let literalStarts: Set<UInt8> = Set("-0123456789tfn".utf8)

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Range of the value of `key` among the members of the outermost object.
    /// The whole text must be one well-formed object (plus surrounding
    /// whitespace); a truncated or trailing-garbage document yields `nil`
    /// even when the member itself was found.
    mutating func topLevelValue(of key: [UInt8]) -> Range<Int>? {
        var found: Range<Int>?
        skipWhitespace()
        guard take(Self.leftBrace) else { return nil }
        skipWhitespace()
        if !take(Self.rightBrace) {
            while true {
                guard let name = scanName() else { return nil }
                skipWhitespace()
                guard take(Self.colon) else { return nil }
                skipWhitespace()
                guard let value = scanValue() else { return nil }
                if found == nil, name == key { found = value }
                skipWhitespace()
                if take(Self.rightBrace) { break }
                guard take(Self.comma) else { return nil }
                skipWhitespace()
            }
        }
        skipWhitespace()
        guard index == bytes.count else { return nil }
        return found
    }

    private var peek: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard peek == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    /// Advances past the string starting at `index`, validating its escapes,
    /// and returns the range of its content (without the quotes).
    private mutating func skipString() -> Range<Int>? {
        guard take(Self.quote) else { return nil }
        let start = index
        while let byte = peek {
            index += 1
            switch byte {
            case Self.quote:
                return start..<(index - 1)
            case Self.backslash:
                guard let escaped = peek else { return nil }
                index += 1
                if escaped == UInt8(ascii: "u") {
                    guard hex4(at: index) != nil else { return nil }
                    index += 4
                } else if !Self.simpleEscapes.contains(escaped) {
                    return nil
                }
            case 0x00..<0x20:
                return nil // raw control characters are not JSON
            default:
                continue
            }
        }
        return nil
    }

    /// Decoded bytes of the member name starting at `index`.
    private mutating func scanName() -> [UInt8]? {
        guard let content = skipString() else { return nil }
        return Self.unescape(bytes[content])
    }

    /// Range of the whole value starting at `index`, quotes and brackets
    /// included, exactly as written.
    private mutating func scanValue() -> Range<Int>? {
        let start = index
        guard let first = peek else { return nil }
        switch first {
        case Self.quote:
            guard skipString() != nil else { return nil }
        case Self.leftBrace, Self.leftBracket:
            var closers: [UInt8] = []
            scanning: while let byte = peek {
                switch byte {
                case Self.quote:
                    guard skipString() != nil else { return nil }
                case Self.leftBrace:
                    closers.append(Self.rightBrace)
                    index += 1
                case Self.leftBracket:
                    closers.append(Self.rightBracket)
                    index += 1
                case Self.rightBrace, Self.rightBracket:
                    guard closers.popLast() == byte else { return nil }
                    index += 1
                    if closers.isEmpty { break scanning }
                case 0x00..<0x20 where byte != 0x09 && byte != 0x0A && byte != 0x0D:
                    return nil
                default:
                    index += 1
                }
            }
            guard closers.isEmpty else { return nil }
        default:
            guard Self.literalStarts.contains(first) else { return nil }
            while let byte = peek, !Self.isDelimiter(byte) {
                index += 1
            }
        }
        return start..<index
    }

    private static func isDelimiter(_ byte: UInt8) -> Bool {
        byte == comma || byte == rightBrace || byte == rightBracket
            || byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private func hex4(at position: Int) -> UInt32? {
        Self.hex4(bytes[...], at: position)
    }

    private static func hex4(_ bytes: ArraySlice<UInt8>, at position: Int) -> UInt32? {
        guard position >= bytes.startIndex, position + 4 <= bytes.endIndex else { return nil }
        var value: UInt32 = 0
        for byte in bytes[position..<(position + 4)] {
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: return nil
            }
            value = value << 4 | digit
        }
        return value
    }

    /// Decodes the escapes of a string content already validated by
    /// `skipString`. A lone surrogate becomes U+FFFD, which no real key
    /// matches.
    private static func unescape(_ raw: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var position = raw.startIndex
        while position < raw.endIndex {
            let byte = raw[position]
            guard byte == backslash else {
                out.append(byte)
                position += 1
                continue
            }
            let escaped = raw[position + 1]
            position += 2
            switch escaped {
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var code = hex4(raw, at: position) ?? 0xFFFD
                position += 4
                if (0xD800...0xDBFF).contains(code),
                   position + 6 <= raw.endIndex,
                   raw[position] == backslash, raw[position + 1] == UInt8(ascii: "u"),
                   let low = hex4(raw, at: position + 2), (0xDC00...0xDFFF).contains(low) {
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    position += 6
                }
                let scalar = Unicode.Scalar(code) ?? Unicode.Scalar(0xFFFD)!
                UTF8.encode(scalar) { out.append($0) }
            default:
                out.append(escaped) // `"`, `\` and `/` stand for themselves
            }
        }
        return out
    }
}
