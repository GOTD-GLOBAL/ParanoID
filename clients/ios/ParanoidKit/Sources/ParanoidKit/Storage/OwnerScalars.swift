import Foundation

enum OwnerScalars {
    static func name(_ s: String) -> Bool {
        let b = Array(s.utf8)
        return (3...24).contains(b.count) && (97...122).contains(b[0]) && b.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
    static func wire(_ s: String) throws -> Data {
        guard s.utf8.count <= 1_644, let bytes = Data(base64Encoded: s), (1...1_232).contains(bytes.count), bytes.base64EncodedString() == s else { throw OwnerStoreError.invalidFormat }
        return bytes
    }
    static func uuid(_ s: String) -> Bool {
        s.utf8.count == 36 && s.utf8.enumerated().allSatisfy { i, b in
            [8, 13, 18, 23].contains(i) ? b == 45 : ((48...57).contains(b) || (97...102).contains(b))
        }
    }
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)
    // Bounded base conversion only; NOT a cryptographic implementation.
    static func base58(_ s: String, count: Int) throws -> Data {
        guard s.utf8.count <= (count == 32 ? 44 : 88), !s.isEmpty else { throw OwnerStoreError.invalidFormat }
        let input = Array(s.utf8); var bytes = [UInt8]()
        for c in input {
            guard let digit = alphabet.firstIndex(of: c) else { throw OwnerStoreError.invalidFormat }
            var carry = digit
            for j in bytes.indices { carry += Int(bytes[j]) * 58; bytes[j] = UInt8(carry & 255); carry >>= 8 }
            while carry > 0 { bytes.append(UInt8(carry & 255)); carry >>= 8 }
            guard bytes.count <= count else { throw OwnerStoreError.invalidFormat }
        }
        let zeroes = input.prefix(while: { $0 == 49 }).count
        let result = Data(repeating: 0, count: zeroes) + Data(bytes.reversed())
        guard result.count == count, base58Encode(result) == s else { throw OwnerStoreError.invalidFormat }
        return result
    }
    static func base58Encode(_ data: Data) -> String {
        var digits = [UInt8]()
        for b in data {
            var carry = Int(b)
            for j in digits.indices { carry += Int(digits[j]) * 256; digits[j] = UInt8(carry % 58); carry /= 58 }
            while carry > 0 { digits.append(UInt8(carry % 58)); carry /= 58 }
        }
        return String(decoding: Array(repeating: UInt8(49), count: data.prefix(while: { $0 == 0 }).count) + digits.reversed().map { alphabet[Int($0)] }, as: UTF8.self)
    }
}
extension OwnerBinding {
    func validate() throws {
        guard OwnerScalars.name(name) else { throw OwnerStoreError.invalidFormat }
        for s in [genesis, program, identity, owner] { _ = try OwnerScalars.base58(s, count: 32) }
    }
    var json: String { #"{"genesis":"\#(genesis)","program":"\#(program)","identity":"\#(identity)","owner":"\#(owner)","name":"\#(name)"}"# }
}
extension OwnerJSON {
    mutating func binding() throws -> OwnerBinding? {
        whitespace()
        if i < bytes.count, bytes[i] == 110 { try literal("null"); return nil }
        var v: [String: String] = [:]
        try object(["genesis", "program", "identity", "owner", "name"]) { p, k in v[k] = try p.string(k == "name" ? 24 : 44) }
        let result = OwnerBinding(genesis: v["genesis"]!, program: v["program"]!, identity: v["identity"]!, owner: v["owner"]!, name: v["name"]!)
        try result.validate(); return result
    }
}
