use paranoid_key_protocol::identity_v3::{
    base58_decode32, base58_encode, derive_registry, parse_generation, verify_records,
    ChallengeRequestV3, IdentityChallengeV3, ProofRole, Purpose, GENESIS, PROGRAM,
};
use paranoid_key_protocol::Identity;

const REALM: &str = "https://auth-fixture.invalid:38444";

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
        .collect()
}

#[test]
fn generation_is_canonical_bounded_decimal() {
    assert_eq!(parse_generation("0"), Ok(0));
    assert_eq!(parse_generation("1"), Ok(1));
    assert_eq!(parse_generation("9223372036854775807"), Ok(i64::MAX));
    for invalid in [
        "",
        "00",
        "01",
        "+1",
        "-1",
        " 1",
        "1 ",
        "1.0",
        "1e0",
        "１",
        "9223372036854775808",
        "99999999999999999999",
    ] {
        assert!(parse_generation(invalid).is_err(), "accepted {invalid:?}");
    }
}

#[test]
fn transcript_matches_independent_public_vectors() {
    let vectors: serde_json::Value = serde_json::from_str(include_str!(
        "../../docs/protocol/identity-login-v3-vectors.json"
    ))
    .unwrap();
    for case in vectors["cases"].as_array().unwrap() {
        let mut data = case["challenge"].clone();
        data["expires"] = data["expires"]
            .as_str()
            .unwrap()
            .parse::<i64>()
            .unwrap()
            .into();
        let challenge: IdentityChallengeV3 = serde_json::from_value(data).unwrap();
        let role = if case["role"] == "owner" {
            ProofRole::Owner
        } else {
            ProofRole::Device
        };
        let bytes = challenge.transcript(role).unwrap();
        assert_eq!(hex(&bytes), case["transcript_hex"].as_str().unwrap());
        assert_eq!(
            paranoid_key_protocol::digest(&bytes),
            case["sha256"].as_str().unwrap()
        );
        paranoid_key_protocol::verify(
            case["public_key"].as_str().unwrap(),
            &bytes,
            case["signature"].as_str().unwrap(),
        )
        .unwrap();
    }
}

#[test]
fn base58_is_exact_32_byte_canonical() {
    for text in [PROGRAM, GENESIS, "11111111111111111111111111111111"] {
        assert_eq!(base58_encode(&base58_decode32(text).unwrap()), text);
    }
    for bad in [
        "",
        "0",
        "O",
        "I",
        "l",
        "1111111111111111111111111111111",
        "111111111111111111111111111111111",
        "C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas1",
    ] {
        assert!(base58_decode32(bad).is_err(), "accepted {bad:?}");
    }
}

#[test]
fn registry_addresses_match_solana_client_derivation() {
    // Values produced by the pinned solana-address client in blockchain/solana/client.
    for (owner, name, identity, nickname) in [
        (
            "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx",
            "abc",
            "EHQLd5XtddaVkmtK46HQxnJHK8kbEuWnuYtvCU6UShST",
            "AJwLwNTpJUFZHKjNnT9riMzzZQJ58sjsZydcNS3AtjX2",
        ),
        (
            "n2NGZdM6KZFJE1bBghSapYaMqZM1sb6J1x7CLYei5QJ",
            "p28_accept_0922",
            "2x4DynMWpg68PLLmn3cdNXJN6qjgqReMH4MqM9SoGqQj",
            "Di1zRKBCPkt88ZR8bbnDRG5KQVMxB9gJAbkph8Rm7zRE",
        ),
    ] {
        let d = derive_registry(&base58_decode32(owner).unwrap(), name).unwrap();
        assert_eq!(base58_encode(&d.identity), identity);
        assert_eq!(base58_encode(&d.nickname), nickname);
    }
}

// Finalized Devnet readback observed 2026-09-24 for the owner's public test name.
const LIVE_IDENTITY: &str = "504e44494430303101ff0b88ae86382590e4b1e3644efee6f96673d3a937721121837079d262c049aa2fbcce2cf8a8283f5b98b0141f86bc1315c3430dc77a9c7f1ab6c9f44d8ce6f1f10f7032385f6163636570745f303932320000000000000000000000000000000000000000000000000000000000000000000000000000";
const LIVE_NAME: &str = "504e444e414d453101fe0b88ae86382590e4b1e3644efee6f96673d3a937721121837079d262c049aa2f1cf646ccaa7aecfffe67ca47d997566626b99a8403d18a3f78430dba0dd081f80f7032385f6163636570745f303932320000000000000000000000000000000000000000000000000000000000000000000000000000";

#[test]
fn live_registry_records_verify_and_every_byte_mutation_fails() {
    let owner = base58_decode32("n2NGZdM6KZFJE1bBghSapYaMqZM1sb6J1x7CLYei5QJ").unwrap();
    let (id, name) = (unhex(LIVE_IDENTITY), unhex(LIVE_NAME));
    verify_records(&owner, "p28_accept_0922", &id, &name).unwrap();
    assert!(verify_records(&owner, "p28_accept_0923", &id, &name).is_err());
    assert!(verify_records(&owner, "p28_accept_0922", &name, &id).is_err());
    for i in 0..128 {
        for (which, data) in [(0, &id), (1, &name)] {
            let mut bad = data.clone();
            bad[i] ^= 1;
            let result = if which == 0 {
                verify_records(&owner, "p28_accept_0922", &bad, &name)
            } else {
                verify_records(&owner, "p28_accept_0922", &id, &bad)
            };
            assert!(result.is_err(), "mutation {which}/{i} accepted");
        }
    }
    assert!(verify_records(&owner, "p28_accept_0922", &id[..127], &name).is_err());
}

struct Fixture {
    owner: vodozemac::Ed25519SecretKey,
    device: Identity,
}

fn fixture() -> Fixture {
    let owner = vodozemac::Ed25519SecretKey::new();
    let device = Identity::create(REALM, &"a".repeat(64), "curve", "prekey").unwrap();
    Fixture { owner, device }
}

fn request(f: &Fixture, purpose: Purpose, generation: &str) -> ChallengeRequestV3 {
    let owner = base58_encode(f.owner.public_key().as_bytes());
    let derived = derive_registry(f.owner.public_key().as_bytes(), "alice_test").unwrap();
    ChallengeRequestV3 {
        purpose,
        operation: uuid::Uuid::new_v4().to_string(),
        genesis: GENESIS.into(),
        program: PROGRAM.into(),
        identity: base58_encode(&derived.identity),
        owner,
        name: "alice_test".into(),
        credential_object: f.device.credential.clone(),
        expected_generation: generation.into(),
    }
}

#[test]
fn request_validation_is_strict_and_context_bound() {
    let f = fixture();
    let pin = "a".repeat(64);
    for (purpose, generation) in [
        (Purpose::Inspect, "0"),
        (Purpose::Status, "0"),
        (Purpose::Enroll, "0"),
        (Purpose::Replace, "1"),
        (Purpose::Replace, "9223372036854775806"),
    ] {
        request(&f, purpose, generation)
            .validate(REALM, &pin)
            .unwrap();
    }
    for (purpose, generation) in [
        (Purpose::Inspect, "1"),
        (Purpose::Status, "2"),
        (Purpose::Enroll, "1"),
        (Purpose::Replace, "0"),
        (Purpose::Replace, "9223372036854775807"),
        (Purpose::Replace, "01"),
    ] {
        assert!(request(&f, purpose, generation)
            .validate(REALM, &pin)
            .is_err());
    }
    type Mutation = fn(&mut ChallengeRequestV3);
    let mutations: [Mutation; 11] = [
        |r| r.genesis = PROGRAM.into(),
        |r| r.program = GENESIS.into(),
        |r| r.identity = PROGRAM.into(),
        |r| r.name = "Alice_test".into(),
        |r| r.name = "ab".into(),
        |r| r.name = "alice test".into(),
        |r| r.operation = r.operation.to_uppercase(),
        |r| r.operation = "00000000-0000-0000-0000-000000000000".into(),
        |r| r.credential_object.realm = "https://other.invalid".into(),
        |r| r.credential_object.signature = r.credential_object.signature.replace('A', "B"),
        |r| r.owner = "11111111111111111111111111111111".into(),
    ];
    for (index, mutate) in mutations.iter().enumerate() {
        let mut r = request(&f, Purpose::Enroll, "0");
        mutate(&mut r);
        assert!(
            r.validate(REALM, &pin).is_err(),
            "mutation {index} accepted"
        );
    }
    assert!(request(&f, Purpose::Enroll, "0")
        .validate(REALM, &"b".repeat(64))
        .is_err());
    // The identity PDA depends only on the owner: another canonical name is
    // syntactically valid here and is rejected only by finalized registry readback.
    let mut other_name = request(&f, Purpose::Enroll, "0");
    other_name.name = "alice_tesu".into();
    assert!(other_name.validate(REALM, &pin).is_ok());
    let mut same_key = request(&f, Purpose::Enroll, "0");
    let root = base64_32(&f.device.credential.root);
    same_key.owner = base58_encode(&root);
    assert!(same_key.validate(REALM, &pin).is_err());
}

fn base64_32(text: &str) -> [u8; 32] {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD_NO_PAD
        .decode(text)
        .unwrap()
        .try_into()
        .unwrap()
}

#[test]
fn issued_challenge_proofs_are_role_purpose_and_request_bound() {
    let f = fixture();
    let pin = "a".repeat(64);
    let r = request(&f, Purpose::Enroll, "0");
    let checked = r.validate(REALM, &pin).unwrap();
    let challenge = IdentityChallengeV3::issue(&checked, REALM, &pin, &epoch(), 100);
    assert!(challenge.matches_request(&r, REALM, &pin, 90));
    assert!(!challenge.matches_request(&r, REALM, &pin, 100));
    let mut other = r.clone();
    other.name = "alice_tesu".into();
    assert!(!challenge.matches_request(&other, REALM, &pin, 90));
    let owner_sig = f
        .owner
        .sign(&challenge.transcript(ProofRole::Owner).unwrap())
        .to_base64();
    let device = vodozemac::Ed25519SecretKey::from_base64(&f.device.auth_secret).unwrap();
    let device_sig = device
        .sign(&challenge.transcript(ProofRole::Device).unwrap())
        .to_base64();
    challenge
        .verify_proofs(&checked, Some(&owner_sig), &device_sig)
        .unwrap();
    assert!(challenge
        .verify_proofs(&checked, Some(&device_sig), &owner_sig)
        .is_err());
    assert!(challenge
        .verify_proofs(&checked, None, &device_sig)
        .is_err());
    let mut replay = challenge.clone();
    replay.purpose = Purpose::Replace;
    replay.expected_generation = "1".into();
    assert!(replay
        .verify_proofs(&checked, Some(&owner_sig), &device_sig)
        .is_err());
    let status = request(&f, Purpose::Status, "0");
    let checked_status = status.validate(REALM, &pin).unwrap();
    let status_challenge = IdentityChallengeV3::issue(&checked_status, REALM, &pin, &epoch(), 100);
    let status_sig = device
        .sign(&status_challenge.transcript(ProofRole::Device).unwrap())
        .to_base64();
    status_challenge
        .verify_proofs(&checked_status, None, &status_sig)
        .unwrap();
    assert!(status_challenge
        .verify_proofs(&checked_status, Some(&owner_sig), &status_sig)
        .is_err());
    assert!(status_challenge
        .verify_proofs(&checked_status, None, &device_sig)
        .is_err());
}

#[test]
fn intent_digest_binds_intent_and_excludes_ephemeral_challenge() {
    let f = fixture();
    let pin = "a".repeat(64);
    let r = request(&f, Purpose::Replace, "3");
    let checked = r.validate(REALM, &pin).unwrap();
    let a = IdentityChallengeV3::issue(&checked, REALM, &pin, &epoch(), 100);
    let b = IdentityChallengeV3::issue(&checked, REALM, &pin, &epoch(), 200);
    assert_ne!(a.id, b.id);
    assert_eq!(a.intent_digest(), b.intent_digest());
    assert_eq!(a.intent_digest(), checked.intent_digest());
    let mut changed = r.clone();
    changed.expected_generation = "4".into();
    assert_ne!(
        changed.validate(REALM, &pin).unwrap().intent_digest(),
        a.intent_digest()
    );
}

fn epoch() -> String {
    uuid::Uuid::new_v4().to_string()
}
