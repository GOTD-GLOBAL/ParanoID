use paranoid_client_core::command;
use serde_json::{json, Value};

fn create() -> Value {
    serde_json::from_str(
        &command(
            "",
            &json!({"op":"create_identity","realm":"https://127.0.0.2:38443","pin":"a".repeat(64)})
                .to_string(),
        )
        .unwrap(),
    )
    .unwrap()
}
fn apply(state: &Value, request: Value) -> Result<Value, &'static str> {
    command(&state.to_string(), &request.to_string()).map(|s| serde_json::from_str(&s).unwrap())
}
fn grant(first: &Value, slot: i16) -> Value {
    let c: paranoid_key_protocol::Credential =
        serde_json::from_value(first["request"]["credential"].clone()).unwrap();
    json!({"type":"paranoid-grant-v1","id":uuid::Uuid::new_v4().to_string(),"credential":c.fingerprint(),"realm":c.realm,"pin":c.pin,"slot":slot,"expires":9999999999i64})
}
#[test]
fn raw_qr_is_parsed_strictly_before_android_can_collapse_duplicate_keys() {
    let first = create();
    let g = grant(&first, 0);
    let good = apply(
        &first["state"],
        json!({"op":"import_grant_text","text":g.to_string()}),
    );
    assert!(
        good.is_ok(),
        "raw descriptor must reach strict native parser"
    );
    let duplicate = g.to_string().replacen('{', "{\"slot\":1,", 1);
    assert!(apply(
        &first["state"],
        json!({"op":"import_grant_text","text":duplicate})
    )
    .is_err());
}

#[test]
fn an_unconfirmed_bad_or_expired_public_grant_does_not_permanently_poison_identity() {
    let first = create();
    let bad = grant(&first, 0);
    let real = grant(&first, 0);
    let candidate = apply(&first["state"], json!({"op":"import_grant","grant":bad})).unwrap();
    let replaced = apply(
        &candidate["state"],
        json!({"op":"import_grant","grant":real}),
    );
    assert!(
        replaced.is_ok(),
        "correct operator descriptor must replace an unconfirmed public candidate"
    );
    assert!(replaced.unwrap()["state"]["identity"] == first["state"]["identity"]);
    let active = activated(0);
    assert!(apply(&active["state"], json!({"op":"import_grant","grant":real})).is_err());
}

#[test]
fn unreadable_legacy_olm_state_is_not_wrapped_in_a_new_root_identity() {
    let old: Value = serde_json::from_str(
        &command(
            "",
            &json!({"op":"init","realm":"https://127.0.0.2:38443","device":"alice"}).to_string(),
        )
        .unwrap(),
    )
    .unwrap();
    let mut corrupted = old["state"].clone();
    corrupted["account"] = json!({});
    assert!(
        apply(
            &corrupted,
            json!({"op":"create_identity","realm":"https://127.0.0.2:38443","pin":"a".repeat(64)})
        )
        .is_err(),
        "invalid retained Olm keys must stop migration before root generation"
    );
}

fn activated(slot: i16) -> Value {
    let first = create();
    let g = grant(&first, slot);
    let saved = apply(&first["state"], json!({"op":"import_grant","grant":g})).unwrap();
    let status = json!({"mode":"active","slot":slot,"grant":g["id"],"credential":g["credential"]});
    let active = apply(
        &saved["state"],
        json!({"op":"server_status","status":status}),
    );
    assert!(
        active.is_ok(),
        "confirmed server mapping must attach alias without new keys"
    );
    active.unwrap()
}
#[test]
fn typed_verified_contact_enables_e2ee_but_never_replaces_an_existing_pin() {
    let a = activated(0);
    let b = activated(1);
    assert_eq!(a["public"]["device"], "alice");
    let contact = b["contact"].clone();
    assert_eq!(contact["type"], "paranoid-contact-v1");
    assert!(apply(
        &a["state"],
        json!({"op":"pair_contact","contact":contact,"verified":false})
    )
    .is_err());
    let a = apply(
        &a["state"],
        json!({"op":"pair_contact","contact":contact,"verified":true}),
    )
    .unwrap();
    let b = apply(
        &b["state"],
        json!({"op":"pair_contact","contact":a["contact"],"verified":true}),
    )
    .unwrap();
    let mut bad = contact.clone();
    bad["bundle"]["curve"] = a["public"]["curve"].clone();
    assert!(apply(
        &a["state"],
        json!({"op":"pair_contact","contact":bad,"verified":true})
    )
    .is_err());
    let replacement = activated(1);
    assert!(apply(
        &a["state"],
        json!({"op":"pair_contact","contact":replacement["contact"],"verified":true})
    )
    .is_err());
    assert!(apply(
        &a["state"],
        json!({"op":"pair","peer":replacement["public"],"verified":true})
    )
    .is_err());
    let a = apply(&a["state"], json!({"op":"send","text":"registered E2EE"})).unwrap();
    let mut m = a["outbox"][0].clone();
    m.as_object_mut().unwrap().remove("recipient");
    m["sender"] = json!("alice");
    m["sequence"] = json!(1);
    let b = apply(&b["state"], json!({"op":"receive","message":m})).unwrap();
    assert_eq!(b["messages"][0]["text"], "registered E2EE");
}
#[test]
fn grant_candidate_is_persistable_before_signing_exact_bound_proof() {
    let first = create();
    let g = grant(&first, 0);
    let imported = apply(&first["state"], json!({"op":"import_grant","grant":g}));
    assert!(
        imported.is_ok(),
        "grant must be saved without regenerating identity"
    );
    let imported = imported.unwrap();
    assert!(first["state"]["account"] == imported["state"]["account"]);
    assert_eq!(imported["public"]["device"], "unassigned");
    let c = &first["request"]["credential"];
    let ch = json!({"id":uuid::Uuid::new_v4().to_string(),"nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","epoch":uuid::Uuid::new_v4().to_string(),"expires":9999999999i64,
        "realm":c["realm"],"pin":c["pin"],"account":c["account"],"device":c["device"],"credential":g["credential"],"grant":g["id"],"slot":0,"purpose":"enroll","method":"POST","path":"/v1/enrollment/commit","body":paranoid_key_protocol::digest(b"{}")});
    let signed=apply(&imported["state"],json!({"op":"sign_request","challenge":ch,"method":"POST","path":"/v1/enrollment/commit","body":"{}"})).unwrap();
    let proof: paranoid_key_protocol::Challenge = serde_json::from_value(ch.clone()).unwrap();
    let signature = signed["authorization"]
        .as_str()
        .unwrap()
        .split_once('.')
        .unwrap()
        .1;
    assert!(
        paranoid_key_protocol::verify(c["auth"].as_str().unwrap(), &proof.bytes(), signature)
            .is_ok()
    );
    for field in [
        "realm",
        "pin",
        "account",
        "device",
        "credential",
        "grant",
        "body",
        "path",
        "purpose",
    ] {
        let mut bad = ch.clone();
        bad[field] = json!("substituted");
        assert!(apply(&imported["state"],json!({"op":"sign_request","challenge":bad,"method":"POST","path":"/v1/enrollment/commit","body":"{}"})).is_err());
    }
}

#[test]
fn public_request_validates_root_device_olm_binding_not_merely_json() {
    let first: Value = serde_json::from_str(
        &command(
            "",
            &json!({"op":"create_identity","realm":"https://127.0.0.2:38443","pin":"a".repeat(64)})
                .to_string(),
        )
        .unwrap(),
    )
    .unwrap();
    let check = |descriptor: &Value| {
        command(
            "",
            &json!({"op":"validate_request","descriptor":descriptor}).to_string(),
        )
    };
    assert!(
        check(&first["request"]).is_ok(),
        "valid root-signed public request must verify"
    );
    for field in [
        "root",
        "account",
        "device",
        "auth",
        "realm",
        "pin",
        "olm",
        "signature",
    ] {
        let mut bad = first["request"].clone();
        bad["credential"][field] = json!("substituted");
        assert!(check(&bad).is_err(), "substituted field accepted");
    }
    let mut bad = first["request"].clone();
    bad["extra"] = json!(true);
    assert!(check(&bad).is_err());
}

// REG-01 / REQ-ID-005: no transport slot or bearer at identity creation.
#[test]
fn create_identity_is_unassigned_and_duplicate_create_retains_exact_state() {
    let request =
        json!({"op":"create_identity","realm":"https://127.0.0.2:38443","pin":"a".repeat(64)})
            .to_string();
    let result = command("", &request);
    assert!(
        result.is_ok(),
        "Create ID must produce a persistable local identity"
    );
    let first: Value = serde_json::from_str(&result.unwrap()).unwrap();
    assert_eq!(first["public"]["device"], "unassigned");
    assert_ne!(
        first["request"]["credential"]["root"],
        first["request"]["credential"]["auth"]
    );
    assert!(first["request"]["credential"]["root"].is_string());
    let state = first["state"].to_string();
    let again: Value = serde_json::from_str(&command(&state, &request).unwrap()).unwrap();
    assert!(
        first["state"] == again["state"],
        "duplicate create must not regenerate any key"
    );
    assert!(command("corrupt retained state", &request).is_err());
}
