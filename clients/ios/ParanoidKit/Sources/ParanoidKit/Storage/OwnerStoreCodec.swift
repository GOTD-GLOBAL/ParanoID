import Foundation

// Schema-directed bounded scanner; never constructs an arbitrary JSON tree.
struct OwnerJSON {
    let bytes: [UInt8]
    var i = 0
    init(_ data: Data) throws {
        guard data.count <= 65_536 else { throw OwnerStoreError.limitExceeded }
        guard String(data: data, encoding: .utf8) != nil else { throw OwnerStoreError.invalidFormat }
        bytes = Array(data)
    }
    mutating func whitespace() { while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
    mutating func take(_ byte: UInt8) -> Bool { whitespace(); guard i < bytes.count, bytes[i] == byte else { return false }; i += 1; return true }
    mutating func expect(_ byte: UInt8) throws { guard take(byte) else { throw OwnerStoreError.invalidFormat } }
    mutating func literal(_ s: String) throws {
        whitespace()
        for b in s.utf8 { guard i < bytes.count, bytes[i] == b else { throw OwnerStoreError.invalidFormat }; i += 1 }
    }
    mutating func end() throws { whitespace(); guard i == bytes.count else { throw OwnerStoreError.invalidFormat } }
    mutating func object(_ fields: Set<String>, _ read: (inout Self, String) throws -> Void) throws {
        try expect(123); var seen = Set<String>()
        if !take(125) {
            while true {
                let key = try string(32)
                guard fields.contains(key), seen.insert(key).inserted else { throw OwnerStoreError.invalidFormat }
                try expect(58); try read(&self, key)
                if take(125) { break }; try expect(44)
            }
        }
        guard seen == fields else { throw OwnerStoreError.invalidFormat }
    }
    mutating func string(_ cap: Int) throws -> String {
        try expect(34); var out = [UInt8]()
        while i < bytes.count {
            var b = bytes[i]; i += 1
            if b == 34 { return String(decoding: out, as: UTF8.self) }
            if b == 92 {
                guard i < bytes.count else { throw OwnerStoreError.invalidFormat }
                b = bytes[i]; i += 1
                switch b {
                case 34, 47, 92: break
                case 98: b = 8
                case 102: b = 12
                case 110: b = 10
                case 114: b = 13
                case 116: b = 9
                case 117:
                    var code = 0
                    for _ in 0..<4 {
                        guard i < bytes.count else { throw OwnerStoreError.invalidFormat }
                        let c = bytes[i]; i += 1
                        let v: Int
                        switch c { case 48...57: v = Int(c - 48); case 65...70: v = Int(c - 55); case 97...102: v = Int(c - 87); default: throw OwnerStoreError.invalidFormat }
                        code = code * 16 + v
                    }
                    // Every admitted value/key is ASCII; no Unicode scalar can
                    // make a non-ASCII escape valid for this schema.
                    guard code < 128 else { throw OwnerStoreError.invalidFormat }; b = UInt8(code)
                default: throw OwnerStoreError.invalidFormat
                }
            } else if b < 32 { throw OwnerStoreError.invalidFormat }
            guard b < 128 else { throw OwnerStoreError.invalidFormat }
            guard out.count < cap else { throw OwnerStoreError.limitExceeded }; out.append(b)
        }
        throw OwnerStoreError.invalidFormat
    }
    mutating func u64() throws -> UInt64 {
        whitespace(); let start = i; var value: UInt64 = 0
        while i < bytes.count, (48...57).contains(bytes[i]) {
            let (m, overflow) = value.multipliedReportingOverflow(by: 10)
            let (n, overflow2) = m.addingReportingOverflow(UInt64(bytes[i] - 48))
            guard !overflow, !overflow2, i - start < 20 else { throw OwnerStoreError.invalidFormat }
            value = n; i += 1
        }
        guard i > start, i - start == 1 || bytes[start] != 48,
              i == bytes.count || [9, 10, 13, 32, 44, 93, 125].contains(bytes[i]) else { throw OwnerStoreError.invalidFormat }
        return value
    }
    mutating func version(_ v: UInt64) throws { guard try u64() == v else { throw OwnerStoreError.unsupportedVersion } }
    mutating func bool() throws -> Bool {
        whitespace(); if i < bytes.count, bytes[i] == 116 { try literal("true"); return true }
        try literal("false"); return false
    }
}

struct AllocatedCatalogueState: Equatable {
    let context: IdentityCatalogue
    var allocated: Bool
    var binding: OwnerBinding? = nil
}
enum AllocatedCatalogueCodec {
    static func encode(_ value: AllocatedCatalogueState) throws -> Data {
        guard value.allocated || value.binding == nil else { throw OwnerStoreError.invalidFormat }
        try value.binding?.validate()
        let bootstrap = String(decoding: IdentityCatalogueCodec.encode(value.context), as: UTF8.self)
        // Only the first allocation belongs to the owner; both realms remain unallocated.
        guard value.allocated, let range = bootstrap.range(of: #""allocation":"unallocated""#) else { return Data(bootstrap.utf8) }
        let allocated = bootstrap.replacingCharacters(in: range, with: #""allocation":"allocated""#)
        return Data(allocated.replacingOccurrences(of: #""binding":null"#, with: #""binding":\#(value.binding?.json ?? "null")"#).utf8)
    }
    static func decode(_ data: Data, context: IdentityCatalogue) throws -> AllocatedCatalogueState {
        var p = try OwnerJSON(data); var install = ""; var ref = ""; var allocation = ""
        var fi: IdentityCatalogue.Realm?; var ru: IdentityCatalogue.Realm?; var binding: OwnerBinding?
        try p.object(["version", "minReader", "kind", "installID", "owner", "realms"]) { p, key in
            switch key {
            case "version", "minReader": try p.version(5)
            case "kind": guard try p.string(9) == "catalogue" else { throw OwnerStoreError.invalidFormat }
            case "installID": install = try p.string(36)
            case "owner":
                try p.object(["ref", "allocation", "binding"]) { p, k in
                    switch k { case "ref": ref = try p.string(36); case "allocation": allocation = try p.string(11); default: binding = try p.binding() }
                }
            default:
                try p.expect(91)
                for index in 0..<2 {
                    if index != 0 { try p.expect(44) }
                    var slot = ""; var origin = ""; var pin = ""; var proto = ""
                    try p.object(["slot", "origin", "pin", "protocol", "allocation"]) { p, k in
                        switch k {
                        case "slot": slot = try p.string(2)
                        case "origin": origin = try p.string(300)
                        case "pin": pin = try p.string(64)
                        case "protocol": proto = try p.string(11)
                        default: guard try p.string(11) == "unallocated" else { throw OwnerStoreError.invalidTransition }
                        }
                    }
                    let realm: IdentityCatalogue.Realm
                    do { realm = try .init(origin: origin, pin: pin, protocolKind: proto) } catch { throw OwnerStoreError.invalidFormat }
                    if slot == "fi", fi == nil { fi = realm }
                    else if slot == "ru", ru == nil { ru = realm }
                    else { throw OwnerStoreError.invalidFormat }
                }
                try p.expect(93)
            }
        }
        try p.end()
        guard ["allocated", "unallocated"].contains(allocation) else { throw OwnerStoreError.invalidFormat }
        guard install == context.installID, ref == context.ownerRef, fi == context.realms.fi, ru == context.realms.ru else { throw OwnerStoreError.contextMismatch }
        guard allocation == "allocated" || binding == nil else { throw OwnerStoreError.invalidFormat }
        return .init(context: context, allocated: allocation == "allocated", binding: binding)
    }
}

struct OwnerEnvelopeV1: Equatable {
    let context: IdentityCatalogue
    let entropy: String
    let owner: String
    let identity: String
    let genesis: String
    let program: String
    var phase = "unregistered"
    var wordsBackupConfirmed = false
    var attempts: [OwnerAttempt] = []
    var binding: OwnerBinding? = nil
}

/// Calls the real existing non-signing Rust commands only. This observer is
/// instrumentation, not an injectable identity-success or cryptographic double.
struct OwnerMaterialCore {
    func validate(_ binding: OwnerBinding, material: OwnerEnvelopeV1) throws {
        try binding.validate()
        guard binding.owner == material.owner, binding.identity == material.identity,
              binding.genesis == material.genesis, binding.program == material.program else { throw OwnerStoreError.bindingMismatch }
        observed("lookup")
        do {
            let r = try DevnetBridge.command(request: #"{"op":"lookup","owner":"\#(binding.owner)","name":"\#(binding.name)"}"#).object
            guard r["identity"] as? String == binding.identity else { throw OwnerStoreError.bindingMismatch }
        } catch { throw OwnerStoreError.bindingMismatch }
    }
    var observed: (String) -> Void = { _ in }
    func identity(entropy: String, context: IdentityCatalogue) throws -> OwnerEnvelopeV1 {
        guard [24, 44].contains(entropy.utf8.count), let raw = Data(base64Encoded: entropy),
              [16, 32].contains(raw.count), raw.base64EncodedString() == entropy else { throw OwnerStoreError.invalidFormat }
        observed("identity")
        do {
            let r = try DevnetBridge.command(request: #"{"op":"identity","entropy":"\#(entropy)"}"#).object
            guard let owner = r["owner"] as? String, let identity = r["identity"] as? String,
                  let genesis = r["genesis"] as? String, let program = r["program"] as? String else { throw OwnerStoreError.invalidFormat }
            return .init(context: context, entropy: entropy, owner: owner, identity: identity, genesis: genesis, program: program)
        } catch { throw OwnerStoreError.invalidFormat }
    }
}
enum OwnerEnvelopeCodec {
    static func encode(_ v: OwnerEnvelopeV1, core: OwnerMaterialCore) throws -> Data {
        // Bound and validate scalars BEFORE interpolation/map/join. The round-trip
        // below still enforces full phase/ledger/material semantics using Rust.
        guard v.attempts.count <= 8, v.phase.utf8.count <= 44, v.entropy.utf8.count <= 44 else { throw OwnerStoreError.limitExceeded }
        guard ["unregistered", "registrationPending", "registryConfirmed"].contains(v.phase),
              let entropy = Data(base64Encoded: v.entropy), [16, 32].contains(entropy.count),
              entropy.base64EncodedString() == v.entropy else { throw OwnerStoreError.invalidFormat }
        for field in [v.owner, v.identity, v.genesis, v.program] { _ = try OwnerScalars.base58(field, count: 32) }
        try v.binding?.validate()
        for attempt in v.attempts {
            try attempt.intent.validate(context: v.context, owner: v.owner)
            guard attempt.stage.utf8.count <= 11, attempt.resolution.utf8.count <= 13 else { throw OwnerStoreError.limitExceeded }
            guard ["ownerSigned", "assembled"].contains(attempt.stage),
                  ["unresolved", "expiredAbsent", "nameTaken", "ownerBound"].contains(attempt.resolution) else { throw OwnerStoreError.invalidFormat }
            _ = try OwnerScalars.wire(attempt.message)
            _ = try OwnerScalars.base58(attempt.ownerSignature, count: 64)
            if let transaction = attempt.transaction { _ = try OwnerScalars.wire(transaction) }
            if let signature = attempt.signature { _ = try OwnerScalars.base58(signature, count: 64) }
        }
        let data = Data(#"{"version":1,"kind":"owner","installID":"\#(v.context.installID)","ownerRef":"\#(v.context.ownerRef)","entropy":"\#(v.entropy)","owner":"\#(v.owner)","identity":"\#(v.identity)","genesis":"\#(v.genesis)","program":"\#(v.program)","phase":"\#(v.phase)","binding":\#(v.binding?.json ?? "null"),"wordsBackupConfirmed":\#(v.wordsBackupConfirmed),"attempts":[\#(v.attempts.map(\.json).joined(separator: ","))]}"#.utf8)
        guard try decode(data, context: v.context, core: core) == v else { throw OwnerStoreError.invalidFormat }
        return data
    }
    static func decode(_ data: Data, context: IdentityCatalogue, core: OwnerMaterialCore) throws -> OwnerEnvelopeV1 {
        var p = try OwnerJSON(data); var values: [String: String] = [:]; var backup = false; var binding: OwnerBinding?; var attempts: [OwnerAttempt] = []
        try p.object(["version", "kind", "installID", "ownerRef", "entropy", "owner", "identity", "genesis", "program", "phase", "binding", "wordsBackupConfirmed", "attempts"]) { p, key in
            switch key {
            case "version": try p.version(1)
            case "binding": binding = try p.binding()
            case "wordsBackupConfirmed": backup = try p.bool()
            case "attempts": attempts = try p.attempts()
            default: values[key] = try p.string(44)
            }
        }
        try p.end()
        guard values["kind"] == "owner", ["unregistered", "registrationPending", "registryConfirmed"].contains(values["phase"] ?? ""),
              OwnerScalars.uuid(values["installID"] ?? ""), OwnerScalars.uuid(values["ownerRef"] ?? "") else { throw OwnerStoreError.invalidFormat }
        guard values["installID"] == context.installID, values["ownerRef"] == context.ownerRef else { throw OwnerStoreError.contextMismatch }
        for field in ["owner", "identity", "genesis", "program"] { _ = try OwnerScalars.base58(values[field] ?? "", count: 32) }
        var result = try core.identity(entropy: values["entropy"] ?? "", context: context)
        guard values["owner"] == result.owner, values["identity"] == result.identity,
              values["genesis"] == result.genesis, values["program"] == result.program else { throw OwnerStoreError.bindingMismatch }
        result.wordsBackupConfirmed = backup
        result.phase = values["phase"]!
        guard (result.phase == "registryConfirmed") == (binding != nil) else { throw OwnerStoreError.invalidFormat }
        if let binding { try core.validate(binding, material: result) }
        result.binding = binding
        result.attempts = attempts
        guard attempts.isEmpty || backup else { throw OwnerStoreError.invalidFormat }
        guard result.phase != "unregistered" || attempts.isEmpty,
              result.phase != "registrationPending" || !attempts.isEmpty else { throw OwnerStoreError.invalidFormat }
        var ids = Set<String>(); var expiryMaximum: UInt64 = 0
        for (index, attempt) in attempts.enumerated() {
            try attempt.intent.validate(context: context, owner: result.owner)
            guard ids.insert(attempt.intent.attemptID).inserted, attempt.sends <= 3 else { throw OwnerStoreError.invalidFormat }
            expiryMaximum = max(expiryMaximum, attempt.intent.lastValidHeight)
            switch attempt.resolution {
            case "unresolved":
                // Only the last entry may be unresolved, and never once confirmed.
                guard attempt.finalizedHeight == nil, index == attempts.count - 1, result.phase != "registryConfirmed" else { throw OwnerStoreError.invalidFormat }
            case "expiredAbsent", "nameTaken":
                guard let height = attempt.finalizedHeight, height > expiryMaximum else { throw OwnerStoreError.invalidFormat }
            case "ownerBound":
                guard attempt.finalizedHeight != nil, result.phase == "registryConfirmed" else { throw OwnerStoreError.invalidFormat }
            default: throw OwnerStoreError.invalidFormat
            }
            let message = try OwnerScalars.wire(attempt.message)
            let ownerSignature = try OwnerScalars.base58(attempt.ownerSignature, count: 64)
            switch attempt.stage {
            case "ownerSigned": guard attempt.transaction == nil, attempt.signature == nil, attempt.sends == 0 else { throw OwnerStoreError.invalidFormat }
            case "assembled":
                guard let transaction = attempt.transaction, let signature = attempt.signature else { throw OwnerStoreError.invalidFormat }
                let wire = try OwnerScalars.wire(transaction)
                let payerSignature = try OwnerScalars.base58(signature, count: 64)
                guard wire == Data([2]) + payerSignature + ownerSignature + message else { throw OwnerStoreError.invalidFormat }
            default: throw OwnerStoreError.invalidFormat
            }
        }
        return result
    }
}
