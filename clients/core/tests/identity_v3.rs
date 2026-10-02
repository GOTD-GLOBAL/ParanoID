//! RFC-0027: the messenger core signs the identity-v3 DEVICE proof with its own
//! transport auth key, only for a challenge that echoes its own credential.
use paranoid_client_core::command;
use paranoid_key_protocol::identity_v3::{
    base58_encode, derive_registry, ChallengeRequestV3, IdentityChallengeV3, ProofRole, Purpose,
    GENESIS, PROGRAM,
};
use serde_json::{json, Value};

const REALM: &str = "https://127.0.0.2:38443";

fn call(s: &Value, r: Value) -> Result<Value, &'static str> {
    command(&s.to_string(), &r.to_string()).map(|v| serde_json::from_str(&v).unwrap())
}

fn fresh() -> Value {
    let a: Value = serde_json::from_str(
        &command(
            "",
            &json!({"op":"create_identity","realm":REALM,"pin":"a".repeat(64)}).to_string(),
        )
        .unwrap(),
    )
    .unwrap();
    call(&a["state"], json!({"op":"upgrade_v2"})).unwrap()
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

fn intent(state: &Value, purpose: Purpose) -> ChallengeRequestV3 {
    let owner = vodozemac::Ed25519SecretKey::new().public_key();
    let credential = serde_json::from_value(state["request"]["credential"].clone()).unwrap();
    ChallengeRequestV3 {
        purpose,
        operation: uuid::Uuid::new_v4().to_string(),
        genesis: GENESIS.into(),
        program: PROGRAM.into(),
        identity: base58_encode(
            &derive_registry(owner.as_bytes(), "alice_core")
                .unwrap()
                .identity,
        ),
        owner: base58_encode(owner.as_bytes()),
        name: "alice_core".into(),
        credential_object: credential,
        expected_generation: if purpose == Purpose::Replace {
            "1"
        } else {
            "0"
        }
        .into(),
    }
}

fn issue(i: &ChallengeRequestV3) -> IdentityChallengeV3 {
    let checked = i.validate(REALM, &"a".repeat(64)).unwrap();
    IdentityChallengeV3::issue(
        &checked,
        REALM,
        &"a".repeat(64),
        &uuid::Uuid::new_v4().to_string(),
        now() + 60,
    )
}

fn sign(
    state: &Value,
    i: &ChallengeRequestV3,
    c: &IdentityChallengeV3,
) -> Result<Value, &'static str> {
    call(
        &state["state"],
        json!({"op":"identity_device_proof_v3","intent":i,"challenge":c,"now":now()}),
    )
}

#[test]
fn identity_credential_view_returns_public_credential_and_fingerprint_only() {
    let a = fresh();
    let out = call(&a["state"], json!({"op":"identity_credential_v3"})).unwrap();
    let c: paranoid_key_protocol::Credential =
        serde_json::from_value(out["credential"].clone()).unwrap();
    assert_eq!(out["fingerprint"], c.fingerprint());
    assert_eq!(out["credential"], a["request"]["credential"]);
    assert_eq!(out.as_object().unwrap().len(), 2, "{out}");
    assert!(!out.to_string().contains("secret"));
}

#[test]
fn device_proof_verifies_for_every_purpose_and_returns_only_a_signature() {
    let a = fresh();
    for purpose in [
        Purpose::Enroll,
        Purpose::Replace,
        Purpose::Inspect,
        Purpose::Status,
    ] {
        let i = intent(&a, purpose);
        let c = issue(&i);
        let out = sign(&a, &i, &c).unwrap();
        assert_eq!(out.as_object().unwrap().len(), 1, "{out}");
        let signature = out["device_signature"].as_str().unwrap();
        paranoid_key_protocol::verify(
            &i.credential_object.auth,
            &c.transcript(ProofRole::Device).unwrap(),
            signature,
        )
        .unwrap();
    }
}

#[test]
fn device_signer_refuses_foreign_credentials_servers_and_stale_challenges() {
    let (a, b) = (fresh(), fresh());
    let foreign = intent(&b, Purpose::Enroll);
    assert_eq!(
        sign(&a, &foreign, &issue(&foreign)),
        Err("credential_mismatch")
    );
    let i = intent(&a, Purpose::Enroll);
    let c = issue(&i);
    let mut stale = c.clone();
    // Expired by more than the tolerated clock skew (RFC-0027 client check).
    stale.expires = now() - paranoid_key_protocol::identity_v3::CLOCK_SKEW_SECONDS - 1;
    assert_eq!(sign(&a, &i, &stale), Err("challenge_mismatch"));
    let mut far = c.clone();
    far.expires = now()
        + paranoid_key_protocol::identity_v3::CHALLENGE_SECONDS
        + paranoid_key_protocol::identity_v3::CLOCK_SKEW_SECONDS
        + 5;
    assert_eq!(sign(&a, &i, &far), Err("challenge_mismatch"));
    // A phone a few seconds behind the server still signs.
    let mut skewed = c.clone();
    skewed.expires = now() + paranoid_key_protocol::identity_v3::CHALLENGE_SECONDS + 7;
    assert!(sign(&a, &i, &skewed).is_ok());
    let mut renamed = c.clone();
    renamed.name = "mallory_x".into();
    assert_eq!(sign(&a, &i, &renamed), Err("challenge_mismatch"));
    // Same credential but a different server realm is refused by request validation.
    let mut elsewhere = i.clone();
    elsewhere.credential_object.realm = "https://evil.invalid".into();
    assert!(sign(&a, &elsewhere, &c).is_err());
    // The state is never changed by signing.
    let raw = command(
        &a["state"].to_string(),
        &json!({"op":"identity_device_proof_v3","intent":i,"challenge":c,"now":now()}).to_string(),
    )
    .unwrap();
    assert!(!raw.contains("\"state\""));
}
