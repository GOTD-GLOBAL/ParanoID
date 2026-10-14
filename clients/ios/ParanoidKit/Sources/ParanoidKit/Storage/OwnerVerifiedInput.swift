import Foundation

struct OwnerBinding: Equatable {
    let genesis: String
    let program: String
    let identity: String
    let owner: String
    let name: String
}
struct OwnerBindingRequest: Equatable {
    let correlation: UUID
    let material: OwnerEnvelopeV1
}
struct OwnerBindingEvidence {
    let request: OwnerBindingRequest
    let binding: OwnerBinding
    let finalizedHeight: UInt64
}
enum OwnerTerminalDisposition: String { case expiredAbsent, nameTaken }
struct OwnerExpiryRequest: Equatable {
    let correlation: UUID
    let material: OwnerEnvelopeV1   // captured complete ledger is the target
    let proposedName: String
}
struct OwnerExpiryEvidence {
    let request: OwnerExpiryRequest
    let finalizedHeight: UInt64
    let dispositions: [(attemptID: String, disposition: OwnerTerminalDisposition)]
}
/// ISOLATED TRUSTED external verified-input seam. No production conformance.
/// A fixture here is NOT RPC authentication, finality, blockhash-expiry proof,
/// Face ID, or foreground signing authority. No boolean grants those powers.
@MainActor protocol IsolatedTrustedOwnerVerifier {
    func binding(for request: OwnerBindingRequest) async throws -> OwnerBindingEvidence?
    func expiry(for request: OwnerExpiryRequest) async throws -> OwnerExpiryEvidence?
}
