//! RFC-0027: the Android-facing owner signer is typed, intent-bound and never signs status.
use paranoid_devnet_client::command;
use paranoid_key_protocol::identity_v3::{
    derive_registry, ChallengeRequestV3, IdentityChallengeV3, ProofRole, Purpose, GENESIS, PROGRAM,
};
use paranoid_key_protocol::Identity;
use serde_json::{json, Value};

const REALM: &str = "https://auth-fixture.invalid:38444";
const ENTROPY: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
// Public vector: owner of the all-zero entropy fixture (see standard_public_recovery_vector).
const OWNER: &str = "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx";

fn pin() -> String {
    "a".repeat(64)
}

fn intent(device: &Identity, purpose: Purpose, generation: &str) -> ChallengeRequestV3 {
    let owner = paranoid_key_protocol::identity_v3::base58_decode32(OWNER).unwrap();
    ChallengeRequestV3 {
        purpose,
        operation: uuid::Uuid::new_v4().to_string(),
        genesis: GENESIS.into(),
        program: PROGRAM.into(),
        identity: paranoid_key_protocol::identity_v3::base58_encode(
            &derive_registry(&owner, "alice_test").unwrap().identity,
        ),
        owner: OWNER.into(),
        name: "alice_test".into(),
        credential_object: device.credential.clone(),
        expected_generation: generation.into(),
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

fn issue(i: &ChallengeRequestV3) -> IdentityChallengeV3 {
    let checked = i.validate(REALM, &pin()).unwrap();
    IdentityChallengeV3::issue(
        &checked,
        REALM,
        &pin(),
        &uuid::Uuid::new_v4().to_string(),
        now() + 60,
    )
}

fn sign(i: &ChallengeRequestV3, ch: &IdentityChallengeV3, entropy: &str) -> Value {
    serde_json::from_str(&command(
        &json!({"op":"identity_owner_proof_v3","entropy":entropy,"intent":i,"challenge":ch,
            "realm":REALM,"pin":pin(),"now":now()})
        .to_string(),
    ))
    .unwrap()
}

#[test]
fn owner_proof_verifies_against_the_server_validator() {
    let device = Identity::create(REALM, &pin(), "curve", "prekey").unwrap();
    for (purpose, generation) in [
        (Purpose::Enroll, "0"),
        (Purpose::Replace, "3"),
        (Purpose::Inspect, "0"),
    ] {
        let i = intent(&device, purpose, generation);
        let ch = issue(&i);
        let out = sign(&i, &ch, ENTROPY);
        let signature = out["owner_signature"].as_str().expect("owner proof");
        paranoid_key_protocol::verify(
            &base64_key(OWNER),
            &ch.transcript(ProofRole::Owner).unwrap(),
            signature,
        )
        .unwrap();
        let device_sig = vodozemac::Ed25519SecretKey::from_base64(&device.auth_secret)
            .unwrap()
            .sign(&ch.transcript(ProofRole::Device).unwrap())
            .to_base64();
        ch.verify_proofs(
            &i.validate(REALM, &pin()).unwrap(),
            Some(signature),
            &device_sig,
        )
        .unwrap();
        assert_eq!(
            out.as_object().unwrap().len(),
            1,
            "no key material returned"
        );
    }
}

#[test]
fn owner_signer_refuses_status_mismatch_and_foreign_keys() {
    let device = Identity::create(REALM, &pin(), "curve", "prekey").unwrap();
    let status = intent(&device, Purpose::Status, "0");
    assert_eq!(
        sign(&status, &issue(&status), ENTROPY)["error"],
        "owner_not_required"
    );
    let i = intent(&device, Purpose::Enroll, "0");
    let ch = issue(&i);
    let mut swapped = ch.clone();
    swapped.name = "mallory_x".into();
    assert_eq!(sign(&i, &swapped, ENTROPY)["error"], "challenge_mismatch");
    let mut stale = ch.clone();
    stale.expires = now() - 1;
    assert_eq!(sign(&i, &stale, ENTROPY)["error"], "challenge_mismatch");
    let mut other_server = ch.clone();
    other_server.realm = "https://evil.invalid".into();
    assert_eq!(
        sign(&i, &other_server, ENTROPY)["error"],
        "challenge_mismatch"
    );
    let other = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=";
    assert_eq!(sign(&i, &ch, other)["error"], "owner_mismatch");
    let raw = command(
        &json!({"op":"identity_owner_proof_v3","entropy":ENTROPY,"intent":i,
        "challenge":ch,"realm":REALM,"pin":pin(),"now":now(),"bytes":"AAAA"})
        .to_string(),
    );
    assert!(raw.contains("invalid_request"), "unknown fields rejected");
}

fn base64_key(base58: &str) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD_NO_PAD
        .encode(paranoid_key_protocol::identity_v3::base58_decode32(base58).unwrap())
}
