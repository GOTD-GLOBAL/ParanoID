import Foundation

/// In-memory RFC-0030 bootstrap proposal, NOT a durable catalogue or login API.
/// Only public metadata: allocation is always unallocated and binding is null.
public struct IdentityCatalogue: Equatable, Sendable {
    /// Complete caller-supplied trust tuple, not a slot ID or live server lookup.
    /// The proposal currently admits ASCII DNS / IPv4 origins only, not IPv6.
    public struct Realm: Equatable, Sendable {
        public let origin: String
        public let pin: String
        public let protocolKind: String

        // Validate the proposal's narrow canonical grammar, never repair a URL.
        private static func isOrigin(_ origin: String) -> Bool {
            guard origin.utf8.count <= 300, origin.hasPrefix("https://") else { return false }
            let parts = origin.dropFirst(8).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts.count == 2 else { return false }
            if parts.count == 2 {
                let port = parts[1]
                guard !port.isEmpty, port.first != "0", port.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = UInt16(port), number > 0, number != 443 else { return false }
            }
            let host = parts[0]
            guard !host.isEmpty, host.utf8.count <= 253 else { return false }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
                return labels.count == 4 && labels.allSatisfy {
                    !$0.isEmpty && ($0.count == 1 || $0.first != "0") && UInt8($0) != nil
                }
            }
            guard let first = labels.last?.utf8.first, (97...122).contains(first) else { return false }
            return labels.allSatisfy { label in
                !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy {
                        (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                    }
            }
        }

        public init(origin: String, pin: String, protocolKind: String) throws {
            guard Self.isOrigin(origin), pin.utf8.count == 64, pin.utf8.allSatisfy(IdentityCatalogue.isHex),
                  protocolKind == "identity-v3" else {
                throw IdentityCatalogueError.invalidSchema
            }
            self.origin = origin
            self.pin = pin
            self.protocolKind = protocolKind
        }
    }

    public struct Realms: Equatable, Sendable {
        public let fi: Realm
        public let ru: Realm

        public init(fi: Realm, ru: Realm) throws {
            guard fi != ru else { throw IdentityCatalogueError.invalidSchema }
            self.fi = fi
            self.ru = ru
        }
    }

    fileprivate static func isUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36 else { return false }
        return value.utf8.enumerated().allSatisfy { index, byte in
            [8, 13, 18, 23].contains(index) ? byte == 45 : isHex(byte)
        }
    }

    fileprivate static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }

    public let installID: String
    public let ownerRef: String
    public let realms: Realms

    public init(installID: String, ownerRef: String, realms: Realms) throws {
        guard Self.isUUID(installID), Self.isUUID(ownerRef) else {
            throw IdentityCatalogueError.invalidSchema
        }
        self.installID = installID
        self.ownerRef = ownerRef
        self.realms = realms
    }
}

/// Fixed categories only: never attach input text, IDs, descriptors or parser excerpts.
/// Admission may stop at the first unsupported/invalid field; it is not an
/// arbitrary-JSON validator and makes no claim about the unvisited remainder.
public enum IdentityCatalogueError: Error, Equatable, Sendable {
    case invalidSchema
    case invalidJSON
    case contextMismatch
    case limitExceeded
    case invalidUTF8
    case unsupportedVersion
    case unsupportedState
}

public enum IdentityCatalogueCodec {
    /// The caller's context must come from its own trusted bootstrap state.
    /// This checks syntax/context, not authenticity, freshness or durable continuity.
    public static func decode(_ data: Data, expectedInstallID: String,
                              expectedRealms: IdentityCatalogue.Realms) throws -> IdentityCatalogue {
        guard data.count <= 65_536 else { throw IdentityCatalogueError.limitExceeded }
        guard String(data: data, encoding: .utf8) != nil else { throw IdentityCatalogueError.invalidUTF8 }
        guard IdentityCatalogue.isUUID(expectedInstallID) else { throw IdentityCatalogueError.invalidSchema }
        var parser = BootstrapParser(bytes: Array(data))
        let value = try parser.catalogue()
        guard value.installID == expectedInstallID, value.realms == expectedRealms else {
            throw IdentityCatalogueError.contextMismatch
        }
        return value
    }

    /// Deterministic fi-then-ru output. Validated immutable fields contain no JSON
    /// metacharacters and their constructor bounds keep output below 64 KiB.
    public static func encode(_ value: IdentityCatalogue) -> Data {
        func realm(_ slot: String, _ realm: IdentityCatalogue.Realm) -> String {
            #"{"slot":"\#(slot)","origin":"\#(realm.origin)","pin":"\#(realm.pin)","protocol":"\#(realm.protocolKind)","allocation":"unallocated"}"#
        }
        let json = #"{"version":5,"minReader":5,"kind":"catalogue","installID":"\#(value.installID)","owner":{"ref":"\#(value.ownerRef)","allocation":"unallocated","binding":null},"realms":[\#(realm("fi", value.realms.fi)),\#(realm("ru", value.realms.ru))]}"#
        return Data(json.utf8)
    }
}

/// Schema-directed, nonrecursive JSON reader. Unknown values are never traversed.
/// Maximum container path: catalogue -> realms array -> realm object.
private struct BootstrapParser {
    let bytes: [UInt8]
    var index = 0

    mutating func catalogue() throws -> IdentityCatalogue {
        var installID = ""
        var ownerRef = ""
        var realms: IdentityCatalogue.Realms?
        try object(fields: ["version", "minReader", "kind", "installID", "owner", "realms"]) { parser, key in
            switch key {
            case "version", "minReader": try parser.version()
            case "kind":
                guard try parser.string() == "catalogue" else { throw IdentityCatalogueError.invalidSchema }
            case "installID": installID = try parser.string()
            case "owner": ownerRef = try parser.owner()
            case "realms": realms = try parser.realms()
            default: throw IdentityCatalogueError.invalidSchema
            }
        }
        whitespace()
        guard index == bytes.count else { throw IdentityCatalogueError.invalidJSON }
        guard let realms else { throw IdentityCatalogueError.invalidSchema }
        return try IdentityCatalogue(installID: installID, ownerRef: ownerRef, realms: realms)
    }

    private mutating func version() throws {
        whitespace()
        let start = index
        while index < bytes.count, ![9, 10, 13, 32, 44, 125].contains(bytes[index]) { index += 1 }
        let token = bytes[start..<index]
        guard !token.isEmpty, token.allSatisfy({ (48...57).contains($0) }),
              token.count == 1 || token.first != 48 else { throw IdentityCatalogueError.invalidSchema }
        guard token.count == 1, token.first == 53 else { throw IdentityCatalogueError.unsupportedVersion }
    }

    private mutating func owner() throws -> String {
        var ref = ""
        try object(fields: ["ref", "allocation", "binding"]) { parser, key in
            switch key {
            case "ref": ref = try parser.string()
            case "allocation": try parser.allocation()
            case "binding":
                parser.whitespace()
                guard parser.index < parser.bytes.count, parser.bytes[parser.index] == 110 else {
                    throw IdentityCatalogueError.unsupportedState
                }
                for byte in "null".utf8 {
                    guard parser.index < parser.bytes.count, parser.bytes[parser.index] == byte else {
                        throw IdentityCatalogueError.invalidJSON
                    }
                    parser.index += 1
                }
            default: throw IdentityCatalogueError.invalidSchema
            }
        }
        return ref
    }

    private mutating func allocation() throws {
        let value = try string()
        if value == "allocated" { throw IdentityCatalogueError.unsupportedState }
        guard value == "unallocated" else { throw IdentityCatalogueError.invalidSchema }
    }

    private mutating func realms() throws -> IdentityCatalogue.Realms {
        try expect(91)
        let first = try realm()
        try expect(44)
        let second = try realm()
        try expect(93)
        guard first.0 != second.0,
              let fi = [first, second].first(where: { $0.0 == "fi" })?.1,
              let ru = [first, second].first(where: { $0.0 == "ru" })?.1 else {
            throw IdentityCatalogueError.invalidSchema
        }
        return try .init(fi: fi, ru: ru)
    }

    private mutating func realm() throws -> (String, IdentityCatalogue.Realm) {
        var slot = ""
        var origin = ""
        var pin = ""
        var kind = ""
        try object(fields: ["slot", "origin", "pin", "protocol", "allocation"]) { parser, key in
            switch key {
            case "slot": slot = try parser.string()
            case "origin": origin = try parser.string()
            case "pin": pin = try parser.string()
            case "protocol": kind = try parser.string()
            case "allocation": try parser.allocation()
            default: throw IdentityCatalogueError.invalidSchema
            }
        }
        return (slot, try .init(origin: origin, pin: pin, protocolKind: kind))
    }

    private mutating func object(fields: Set<String>,
                                 read: (inout Self, String) throws -> Void) throws {
        try expect(123)
        var seen = Set<String>()
        if !consume(125) {
            while true {
                let key = try string()
                guard fields.contains(key), seen.insert(key).inserted else {
                    throw IdentityCatalogueError.invalidSchema
                }
                try expect(58)
                try read(&self, key)
                if consume(125) { break }
                try expect(44)
            }
        }
        guard seen == fields else { throw IdentityCatalogueError.invalidSchema }
    }

    private mutating func string() throws -> String {
        try expect(34)
        var decoded = [UInt8]()
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 34 {
                guard let text = String(bytes: decoded, encoding: .utf8) else {
                    throw IdentityCatalogueError.invalidJSON
                }
                return text
            }
            guard byte >= 32 else { throw IdentityCatalogueError.invalidJSON }
            if byte != 92 {
                decoded.append(byte)
            } else {
                guard index < bytes.count else { throw IdentityCatalogueError.invalidJSON }
                let escape = bytes[index]
                index += 1
                switch escape {
                case 34, 47, 92: decoded.append(escape)
                case 98: decoded.append(8)
                case 102: decoded.append(12)
                case 110: decoded.append(10)
                case 114: decoded.append(13)
                case 116: decoded.append(9)
                case 117:
                    var code = try hexQuad()
                    if (0xD800...0xDBFF).contains(code) {
                        guard index + 1 < bytes.count, bytes[index] == 92, bytes[index + 1] == 117 else {
                            throw IdentityCatalogueError.invalidJSON
                        }
                        index += 2
                        let low = try hexQuad()
                        guard (0xDC00...0xDFFF).contains(low) else { throw IdentityCatalogueError.invalidJSON }
                        code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw IdentityCatalogueError.invalidJSON }
                    decoded.append(contentsOf: String(scalar).utf8)
                default: throw IdentityCatalogueError.invalidJSON
                }
            }
            guard decoded.count <= 300 else { throw IdentityCatalogueError.limitExceeded }
        }
        throw IdentityCatalogueError.invalidJSON
    }

    private mutating func hexQuad() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count else { throw IdentityCatalogueError.invalidJSON }
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case 48...57: digit = byte - 48
            case 65...70: digit = byte - 55
            case 97...102: digit = byte - 87
            default: throw IdentityCatalogueError.invalidJSON
            }
            value = value * 16 + UInt32(digit)
            index += 1
        }
        return value
    }

    private mutating func whitespace() {
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard consume(byte) else { throw IdentityCatalogueError.invalidJSON }
    }
}
