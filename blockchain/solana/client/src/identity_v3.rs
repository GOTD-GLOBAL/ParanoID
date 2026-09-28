//! RFC-0027 identity-v3 owner signing. Typed only: it rebuilds the owner transcript from
//! a challenge that must echo the caller's retained intent exactly. Never signs arbitrary
//! bytes, never signs `status` (device-only) and returns only the signature.
use paranoid_key_protocol::identity_v3::{
    base58_encode, ChallengeRequestV3, IdentityChallengeV3, ProofRole, Purpose,
};

pub(crate) fn sign_owner(
    owner_seed: &[u8; 32],
    intent: &ChallengeRequestV3,
    challenge: &IdentityChallengeV3,
    realm: &str,
    pin: &str,
    now: i64,
) -> Result<String, &'static str> {
    use base64::{engine::general_purpose::STANDARD_NO_PAD, Engine};
    use solana_signer::Signer;
    if intent.purpose == Purpose::Status || challenge.purpose == Purpose::Status {
        return Err("owner_not_required");
    }
    let key = solana_keypair::Keypair::new_from_array(*owner_seed);
    if intent.owner != base58_encode(key.pubkey().as_ref()) {
        return Err("owner_mismatch");
    }
    if !challenge.matches_request(intent, realm, pin, now) {
        return Err("challenge_mismatch");
    }
    let signature = key.sign_message(&challenge.transcript(ProofRole::Owner)?);
    Ok(STANDARD_NO_PAD.encode(signature.as_ref()))
}
