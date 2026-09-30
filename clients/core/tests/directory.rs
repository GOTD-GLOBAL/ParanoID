//! RFC-0028: a phone accepts a server directory entry only when the nickname owner's
//! stored enroll/replace proof binds this server and exactly the returned credential
//! (which commits to the Olm identity and one-time key of the contact card).
use paranoid_client_core::command;
use paranoid_key_protocol::identity_v3::{
    base58_encode, derive_registry, ChallengeRequestV3, DirectoryProof, IdentityChallengeV3,
    ProofRole, Purpose, GENESIS, PROGRAM,
};
use serde_json::{json, Value};

const REALM: &str = "https://127.0.0.2:38443";

fn call(s: &Value, r: Value) -> Result<Value, &'static str> {
    command(&s.to_string(), &r.to_string()).map(|v| serde_json::from_str(&v).unwrap())
}

fn phone(realm: &str) -> Value {
    let a: Value = serde_json::from_str(
        &command(
            "",
            &json!({"op":"create_identity","realm":realm,"pin":"a".repeat(64)}).to_string(),
        )
        .unwrap(),
    )
    .unwrap();
    let a = call(&a["state"], json!({"op":"upgrade_v2"})).unwrap();
    let c: paranoid_key_protocol::Credential =
        serde_json::from_value(a["request"]["credential"].clone()).unwrap();
    let a = call(
        &a["state"],
        json!({"op":"server_status_v2","status":{"mode":"active","account":c.account,"device":c.device,"credential":c.fingerprint()}}),
    )
    .unwrap();
    call(&a["state"], json!({"op":"prepare_contact_v2"})).unwrap()
}

struct Owner {
    key: vodozemac::Ed25519SecretKey,
    name: String,
}
impl Owner {
    fn new(name: &str) -> Self {
        Self {
            key: vodozemac::Ed25519SecretKey::new(),
            name: name.into(),
        }
    }
    fn owner(&self) -> String {
        base58_encode(self.key.public_key().as_bytes())
    }
    fn identity(&self) -> String {
        base58_encode(
            &derive_registry(self.key.public_key().as_bytes(), &self.name)
                .unwrap()
                .identity,
        )
    }
}

/// The proof exactly as the server stores it after a successful enroll commit.
fn proof(o: &Owner, phone: &Value, realm: &str) -> DirectoryProof {
    let r = ChallengeRequestV3 {
        purpose: Purpose::Enroll,
        operation: uuid::Uuid::new_v4().to_string(),
        genesis: GENESIS.into(),
        program: PROGRAM.into(),
        identity: o.identity(),
        owner: o.owner(),
        name: o.name.clone(),
        credential_object: serde_json::from_value(phone["request"]["credential"].clone()).unwrap(),
        expected_generation: "0".into(),
    };
    let pin = "a".repeat(64);
    let checked = r.validate(realm, &pin).unwrap();
    // Issued long ago: expiry must not matter for a historical proof.
    let challenge =
        IdentityChallengeV3::issue(&checked, realm, &pin, &uuid::Uuid::new_v4().to_string(), 10);
    let owner_signature = o
        .key
        .sign(&challenge.transcript(ProofRole::Owner).unwrap())
        .to_base64();
    DirectoryProof {
        challenge,
        owner_signature,
    }
}

fn entry(o: &Owner, phone: &Value, proof: &DirectoryProof) -> Value {
    json!({"name":o.name,"owner":o.owner(),"identity":o.identity(),"contact":phone["contact"],"proof":proof})
}

fn verify(viewer: &Value, entry: &Value) -> Result<Value, &'static str> {
    call(
        &viewer["state"],
        json!({"op":"verify_directory_entry_v1","entry":entry}),
    )
}

#[test]
fn genuine_entry_is_accepted_and_pairs_as_network_unverified() {
    let (viewer, bob) = (phone(REALM), phone(REALM));
    let o = Owner::new("bob_found");
    let e = entry(&o, &bob, &proof(&o, &bob, REALM));
    let v = verify(&viewer, &e).unwrap();
    assert_eq!(v["name"], "bob_found");
    assert_eq!(v["account"], bob["request"]["credential"]["account"]);
    assert_eq!(v["fingerprint"], bob["contact_fingerprint"]);
    let paired = call(
        &viewer["state"],
        json!({"op":"pair_directory_entry_v1","entry":e}),
    )
    .unwrap();
    let dialog = &paired["dialogs"][0];
    assert_eq!(dialog["account"], bob["request"]["credential"]["account"]);
    assert_eq!(dialog["trust"], "network_unverified");
    assert_eq!(dialog["identity_verified"], false);
    // A first message can be sent to the found contact.
    let sent = call(
        &paired["state"],
        json!({"op":"send_v2","account":dialog["account"],"text":"привет"}),
    )
    .unwrap();
    assert_eq!(sent["outbox"].as_array().unwrap().len(), 1);
}

#[test]
fn server_substituting_the_one_time_key_is_rejected() {
    let (viewer, bob) = (phone(REALM), phone(REALM));
    let o = Owner::new("bob_otk");
    let p = proof(&o, &bob, REALM);
    let other = phone(REALM);
    let mut e = entry(&o, &bob, &p);
    e["contact"]["bundle"]["one_time_key"] = other["contact"]["bundle"]["one_time_key"].clone();
    assert!(verify(&viewer, &e).is_err());
    let mut e = entry(&o, &bob, &p);
    e["contact"]["bundle"]["curve"] = other["contact"]["bundle"]["curve"].clone();
    assert!(verify(&viewer, &e).is_err());
    // Even a server-held credential whose Olm digest matches its own keys is refused: the
    // owner never signed that credential.
    let mut e = entry(&o, &bob, &p);
    e["contact"] = other["contact"].clone();
    assert_eq!(verify(&viewer, &e), Err("proof_credential_mismatch"));
    assert!(call(
        &viewer["state"],
        json!({"op":"pair_directory_entry_v1","entry":e})
    )
    .is_err());
}

#[test]
fn whole_credential_substitution_with_a_fresh_owner_proof_for_another_owner_is_rejected() {
    let (viewer, mallory_phone) = (phone(REALM), phone(REALM));
    let o = Owner::new("bob_whole");
    // The server runs its own phone and signs a proof with ITS OWN owner key for bob's name.
    let fake = Owner {
        key: vodozemac::Ed25519SecretKey::new(),
        name: "bob_whole".into(),
    };
    let p = proof(&fake, &mallory_phone, REALM);
    // Presented under bob's real owner/identity: owner mismatch.
    let e = json!({"name":"bob_whole","owner":o.owner(),"identity":o.identity(),"contact":mallory_phone["contact"],"proof":p});
    assert_eq!(verify(&viewer, &e), Err("proof_identity_mismatch"));
    // Presented consistently under the fake owner: the core accepts the signature, so the
    // finalized Solana registry check (name -> owner) done by the caller is what rejects
    // it. This test pins that division of responsibility.
    let e = entry(&fake, &mallory_phone, &p);
    assert!(verify(&viewer, &e).is_ok());
}

#[test]
fn wrong_owner_wrong_name_other_server_and_tampered_signature_are_rejected() {
    let (viewer, bob) = (phone(REALM), phone(REALM));
    let o = Owner::new("bob_bad");
    let p = proof(&o, &bob, REALM);
    let mut e = entry(&o, &bob, &p);
    e["owner"] = json!(Owner::new("bob_bad").owner());
    assert!(verify(&viewer, &e).is_err(), "wrong owner");
    let mut e = entry(&o, &bob, &p);
    e["name"] = json!("carol_bad");
    assert!(verify(&viewer, &e).is_err(), "wrong name");
    let mut e = entry(&o, &bob, &p);
    e["name"] = json!("Bad Name");
    assert!(verify(&viewer, &e).is_err(), "non-canonical name");
    let mut e = entry(&o, &bob, &p);
    e["identity"] = json!(Owner::new("xyz_other").identity());
    assert!(verify(&viewer, &e).is_err(), "wrong identity");
    // Proof issued for another realm/pin (a different server).
    let other_realm = "https://127.0.0.9:38443";
    let elsewhere = phone(other_realm);
    let foreign = proof(&o, &elsewhere, other_realm);
    let e = entry(&o, &bob, &foreign);
    assert_eq!(verify(&viewer, &e), Err("proof_wrong_server"));
    let mut forged = p.clone();
    forged.challenge.realm = REALM.into();
    forged.challenge.pin = "b".repeat(64);
    assert!(
        verify(&viewer, &entry(&o, &bob, &forged)).is_err(),
        "other pin"
    );
    // Tampered owner signature.
    let mut t = p.clone();
    t.owner_signature = o.key.sign(b"not the transcript").to_base64();
    assert_eq!(
        verify(&viewer, &entry(&o, &bob, &t)),
        Err("invalid_owner_signature")
    );
    let mut t = p.clone();
    t.challenge.nonce = t.challenge.nonce.replace('A', "B");
    t.challenge.expected_generation = "0".into();
    t.challenge.operation = uuid::Uuid::new_v4().to_string();
    assert!(
        verify(&viewer, &entry(&o, &bob, &t)).is_err(),
        "tampered challenge"
    );
    // Unknown fields are refused.
    let mut e = entry(&o, &bob, &p);
    e["extra"] = json!(1);
    assert!(verify(&viewer, &e).is_err());
    // The phone's own entry is not a contact.
    let own = entry(&o, &viewer, &proof(&o, &viewer, REALM));
    assert!(verify(&viewer, &own).is_err());
}

#[test]
fn directory_session_requests_are_strict() {
    let viewer = phone(REALM);
    let c = &viewer["request"]["credential"];
    let session = json!({"id":uuid::Uuid::new_v4().to_string(),"epoch":uuid::Uuid::new_v4().to_string(),
        "expires":4_000_000_000i64,"realm":REALM,"pin":"a".repeat(64),"account":c["account"],"device":c["device"],
        "credential":paranoid_key_protocol::digest(&serde_json::from_value::<paranoid_key_protocol::Credential>(c.clone()).unwrap().bytes())});
    let sign = |operation: &str, id: Option<&str>| {
        call(
            &viewer["state"],
            json!({"op":"sign_session_v2","session":session,"operation":operation,"id":id}),
        )
    };
    let s = sign("directory_search", Some(r#"{"query":"bo","after":null}"#)).unwrap();
    assert_eq!(s["path"], "/v3/directory/search");
    assert_eq!(s["method"], "POST");
    assert_eq!(s["body"], r#"{"after":null,"query":"bo"}"#);
    let s = sign("directory_search", Some(r#"{"query":"","after":"bob_x"}"#)).unwrap();
    assert_eq!(s["body"], r#"{"after":"bob_x","query":""}"#);
    for bad in [
        r#"{"query":"B","after":null}"#,
        r#"{"query":"%","after":null}"#,
        r#"{"query":"","after":"x"}"#,
        r#"{"query":"","after":null,"x":1}"#,
        "not json",
    ] {
        assert!(sign("directory_search", Some(bad)).is_err(), "{bad}");
    }
    assert!(sign("directory_search", None).is_err());
    let s = sign("directory_visibility", Some("false")).unwrap();
    assert_eq!(
        (s["path"].as_str(), s["body"].as_str()),
        (
            Some("/v3/directory/visibility"),
            Some(r#"{"visible":false}"#)
        )
    );
    assert!(sign("directory_visibility", Some("maybe")).is_err());
    let s = sign("directory_card", None).unwrap();
    assert_eq!(s["path"], "/v3/directory/card");
    let body: Value = serde_json::from_str(s["body"].as_str().unwrap()).unwrap();
    assert_eq!(body, viewer["contact"]);
    assert!(sign("directory_card", Some("x")).is_err());
}
