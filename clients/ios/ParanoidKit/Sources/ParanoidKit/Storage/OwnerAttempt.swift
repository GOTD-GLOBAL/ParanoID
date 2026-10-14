import Foundation

struct OwnerAttemptIntent: Equatable {
    let attemptID: String
    let name: String
    let sponsorRealmKey: IdentityCatalogue.Realm
    let payer: String
    let blockhash: String
    let lastValidHeight: UInt64
}
struct OwnerAttempt: Equatable {
    let intent: OwnerAttemptIntent
    var stage = "ownerSigned"
    let message: String
    let ownerSignature: String
    var transaction: String? = nil
    var signature: String? = nil
    var sends: UInt64 = 0
    var resolution = "unresolved"
    var finalizedHeight: UInt64? = nil
}
extension OwnerAttemptIntent {
    func validate(context: IdentityCatalogue, owner: String) throws {
        guard OwnerScalars.uuid(attemptID), OwnerScalars.name(name), payer != owner,
              [context.realms.fi, context.realms.ru].contains(sponsorRealmKey) else { throw OwnerStoreError.invalidFormat }
        _ = try OwnerScalars.base58(payer, count: 32); _ = try OwnerScalars.base58(blockhash, count: 32)
    }
}
extension OwnerAttempt {
    var json: String {
        let t = intent; let r = t.sponsorRealmKey
        let realm = #"{"origin":"\#(r.origin)","pin":"\#(r.pin)","protocol":"\#(r.protocolKind)"}"#
        func quoted(_ s: String?) -> String { s.map { "\"" + $0 + "\"" } ?? "null" }
        return #"{"attemptID":"\#(t.attemptID)","stage":"\#(stage)","name":"\#(t.name)","sponsorRealmKey":\#(realm),"payer":"\#(t.payer)","blockhash":"\#(t.blockhash)","last_valid_height":\#(t.lastValidHeight),"message":"\#(message)","owner_signature":"\#(ownerSignature)","transaction":\#(quoted(transaction)),"signature":\#(quoted(signature)),"sends":\#(sends),"resolution":"\#(resolution)","finalized_height":\#(finalizedHeight.map(String.init) ?? "null")}"#
    }
}
extension OwnerJSON {
    mutating func optionalString(_ cap: Int) throws -> String? {
        whitespace(); if i < bytes.count, bytes[i] == 110 { try literal("null"); return nil }
        return try string(cap)
    }
    mutating func attempts() throws -> [OwnerAttempt] {
        try expect(91); var result: [OwnerAttempt] = []
        if take(93) { return result }
        while true {
            guard result.count < 8 else { throw OwnerStoreError.limitExceeded }
            result.append(try attempt())
            if take(93) { return result }; try expect(44)
        }
    }
    private mutating func attempt() throws -> OwnerAttempt {
        var strings: [String: String] = [:]; var height: UInt64 = 0; var sends: UInt64 = 0; var finalized: UInt64?
        var realm: IdentityCatalogue.Realm?
        try object(["attemptID", "stage", "name", "sponsorRealmKey", "payer", "blockhash", "last_valid_height", "message", "owner_signature", "transaction", "signature", "sends", "resolution", "finalized_height"]) { p, k in
            switch k {
            case "sponsorRealmKey":
                var r: [String: String] = [:]
                try p.object(["origin", "pin", "protocol"]) { p, k in r[k] = try p.string(k == "origin" ? 300 : (k == "pin" ? 64 : 11)) }
                do { realm = try .init(origin: r["origin"]!, pin: r["pin"]!, protocolKind: r["protocol"]!) } catch { throw OwnerStoreError.invalidFormat }
            case "last_valid_height": height = try p.u64()
            case "sends": sends = try p.u64()
            case "finalized_height":
                p.whitespace(); if p.i < p.bytes.count, p.bytes[p.i] == 110 { try p.literal("null") } else { finalized = try p.u64() }
            case "transaction", "signature": strings[k] = try p.optionalString(k == "transaction" ? 1_644 : 88)
            default:
                let caps = ["attemptID": 36, "stage": 11, "name": 24, "payer": 44, "blockhash": 44, "message": 1_644, "owner_signature": 88, "resolution": 13]
                guard let cap = caps[k] else { throw OwnerStoreError.invalidFormat }; strings[k] = try p.string(cap)
            }
        }
        guard let realm else { throw OwnerStoreError.invalidFormat }
        let t = OwnerAttemptIntent(attemptID: strings["attemptID"]!, name: strings["name"]!, sponsorRealmKey: realm, payer: strings["payer"]!, blockhash: strings["blockhash"]!, lastValidHeight: height)
        return .init(intent: t, stage: strings["stage"]!, message: strings["message"]!, ownerSignature: strings["owner_signature"]!, transaction: strings["transaction"], signature: strings["signature"], sends: sends, resolution: strings["resolution"]!, finalizedHeight: finalized)
    }
}
struct OwnerSigningRequest: Equatable {
    let correlation: UUID
    let material: OwnerEnvelopeV1
    let intent: OwnerAttemptIntent
}
struct OwnerAssemblyRequest: Equatable {
    let correlation: UUID
    let material: OwnerEnvelopeV1
    let attempt: OwnerAttempt
}
struct OwnerAssemblyEvidence {
    let request: OwnerAssemblyRequest
    let transaction: String
    let signature: String
}
@MainActor protocol IsolatedTrustedOwnerAssembler {
    /// Must check actual Rust request/result name, owner, identity/nickname,
    /// payer and message under fresh foreground authority. No production impl.
    func assembled(for request: OwnerAssemblyRequest) throws -> OwnerAssemblyEvidence
}
struct OwnerSignedEvidence {
    let request: OwnerSigningRequest
    let message: String
    let ownerSignature: String
}
/// Explicit trusted signing/foreground-authority boundary, with no production
/// conformance. Test fixtures are not UI authentication or permission to sign.
@MainActor protocol IsolatedTrustedOwnerSigner {
    func ownerSigned(for request: OwnerSigningRequest) throws -> OwnerSignedEvidence
}
