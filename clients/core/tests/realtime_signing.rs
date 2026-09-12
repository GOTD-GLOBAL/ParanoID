use paranoid_client_core::command;
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};

fn call(state: &Value, request: Value) -> Result<Value, &'static str> {
    command(&state.to_string(), &request.to_string()).map(|s| serde_json::from_str(&s).unwrap())
}
fn ready() -> Value {
    let initial: Value = serde_json::from_str(
        &command(
            "",
            &json!({"op":"create_identity","realm":"https://127.0.0.2:38443","pin":"a".repeat(64)})
                .to_string(),
        )
        .unwrap(),
    )
    .unwrap();
    let a = call(&initial["state"], json!({"op":"upgrade_v2"})).unwrap();
    let c: paranoid_key_protocol::Credential =
        serde_json::from_value(a["request"]["credential"].clone()).unwrap();
    let a = call(&a["state"], json!({"op":"server_status_v2","status":{"mode":"active","account":c.account,"device":c.device,"credential":c.fingerprint()}})).unwrap();
    call(&a["state"], json!({"op":"prepare_contact_v2"})).unwrap()
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}
fn session(a: &Value) -> Value {
    let c: paranoid_key_protocol::Credential =
        serde_json::from_value(a["request"]["credential"].clone()).unwrap();
    json!({"id":uuid::Uuid::new_v4().to_string(),"epoch":uuid::Uuid::new_v4().to_string(),"expires":now()+300,"realm":c.realm,"pin":c.pin,"account":c.account,"device":c.device,"credential":c.fingerprint()})
}
fn sign(
    a: &Value,
    context: &Value,
    operation: &str,
    id: Option<&str>,
) -> Result<Value, &'static str> {
    let mut r = json!({"op":"sign_session_v2","session":context,"operation":operation});
    if let Some(id) = id {
        r["id"] = json!(id);
    }
    call(&a["state"], r)
}
fn lp(fields: &[&str]) -> Vec<u8> {
    let mut out = vec![];
    for f in fields {
        out.extend((f.len() as u32).to_be_bytes());
        out.extend(f.as_bytes());
    }
    out
}
#[test]
fn session_signs_exact_native_cursor_context_with_unique_nonces_without_state_mutation() {
    let a = ready();
    let s = session(&a);
    let before = a["state"].clone();
    let first = sign(&a, &s, "events", None).expect("native signed-session operation required");
    let second = sign(&a, &s, "events", None).unwrap();
    assert_eq!(first["method"], "GET");
    assert_eq!(first["path"], "/v2/events?after=0&limit=20");
    assert_eq!(first["body"], "");
    assert_ne!(first["authorization"], second["authorization"]);
    let auth = first["authorization"].as_str().unwrap();
    let parts: Vec<_> = auth
        .strip_prefix("ParanoidSessionV2 ")
        .unwrap()
        .split('.')
        .collect();
    assert_eq!(parts.len(), 3);
    assert_eq!(parts[0], s["id"]);
    assert_eq!(
        uuid::Uuid::parse_str(parts[1]).unwrap().get_version_num(),
        4
    );
    let expires = s["expires"].to_string();
    let digest = paranoid_key_protocol::digest(b"");
    let bytes = lp(&[
        "paranoid-session-request-v1",
        parts[0],
        s["epoch"].as_str().unwrap(),
        &expires,
        s["realm"].as_str().unwrap(),
        s["pin"].as_str().unwrap(),
        s["account"].as_str().unwrap(),
        s["device"].as_str().unwrap(),
        s["credential"].as_str().unwrap(),
        parts[1],
        "GET",
        "/v2/events?after=0&limit=20",
        &digest,
    ]);
    paranoid_key_protocol::verify(
        a["request"]["credential"]["auth"].as_str().unwrap(),
        &bytes,
        parts[2],
    )
    .unwrap();
    assert_eq!(
        call(&a["state"], json!({"op":"view"})).unwrap()["state"],
        before
    );
}
#[test]
fn session_rejects_cross_identity_trust_invalid_expiry_unknown_routes_and_extra_fields() {
    let a = ready();
    let good = session(&a);
    sign(&a, &good, "messages", None).unwrap();
    for key in [
        "realm",
        "pin",
        "account",
        "device",
        "credential",
        "id",
        "epoch",
    ] {
        let mut bad = good.clone();
        bad[key] = json!("wrong");
        assert!(sign(&a, &bad, "events", None).is_err(), "{key}");
    }
    for expires in [0, u64::MAX] {
        let mut bad = good.clone();
        bad["expires"] = json!(expires);
        assert!(sign(&a, &bad, "events", None).is_err());
    }
    for op in ["register", "session", "/v2/admin", "events?after=9", ""] {
        assert!(sign(&a, &good, op, None).is_err());
    }
    for (key, value) in [
        ("path", json!("/v2/registration/commit")),
        ("body", json!("forged")),
        ("nonce", json!(uuid::Uuid::new_v4().to_string())),
    ] {
        let mut r = json!({"op":"sign_session_v2","session":good,"operation":"events"});
        r[key] = value;
        assert!(call(&a["state"], r).is_err());
    }
    assert!(sign(&a, &good, "events", Some("unexpected")).is_err());
}
#[test]
fn session_open_is_exact_active_device_challenge_only() {
    use base64::Engine;
    let a = ready();
    let s = session(&a);
    let mut challenge = s.clone();
    challenge["nonce"] = json!(base64::engine::general_purpose::STANDARD.encode([42; 32]));
    challenge["expires"] = json!(now() + 60);
    challenge["purpose"] = json!("session");
    challenge["method"] = json!("POST");
    challenge["path"] = json!("/v2/session");
    challenge["body"] = json!(paranoid_key_protocol::digest(b"{}"));
    let request = json!({"op":"sign_request_v2","challenge":challenge,"method":"POST","path":"/v2/session","body":"{}"});
    let signed =
        call(&a["state"], request.clone()).expect("exact session opening intent must be supported");
    assert!(signed["authorization"]
        .as_str()
        .unwrap()
        .starts_with("ParanoidV2 "));
    for key in ["method", "path", "body"] {
        let mut wrong = request.clone();
        wrong[key] = json!("wrong");
        assert!(call(&a["state"], wrong).is_err());
    }
    let mut inactive = a["state"].clone();
    inactive["enrollment"] = Value::Null;
    assert!(call(&inactive, request).is_err());
}
#[test]
fn session_send_only_signs_retained_immutable_outbox_and_rejects_accepted_ids() {
    let a = ready();
    let b = ready();
    let a = call(
        &a["state"],
        json!({"op":"pair_contact_v2","text":b["contact"].to_string(),"verified":true}),
    )
    .unwrap();
    let a=call(&a["state"],json!({"op":"send_v2","account":b["request"]["credential"]["account"],"text":"retained signed bytes"})).unwrap();
    let s = session(&a);
    let id = a["outbox"][0]["id"].as_str().unwrap();
    let signed = sign(&a, &s, "send", Some(id)).unwrap();
    assert_eq!(signed["method"], "POST");
    assert_eq!(signed["path"], "/v2/messages");
    assert_eq!(
        serde_json::from_str::<Value>(signed["body"].as_str().unwrap()).unwrap(),
        a["outbox"][0]
    );
    assert_eq!(
        sign(&a, &s, "send", Some(id)).unwrap()["body"],
        signed["body"]
    );
    assert!(sign(&a, &s, "send", Some(&uuid::Uuid::new_v4().to_string())).is_err());
    let accepted = call(&a["state"], json!({"op":"accepted_v2","id":id})).unwrap();
    assert!(sign(&accepted, &s, "send", Some(id)).is_err());
}

#[test]
fn voice_turn_selector_signs_only_exact_empty_get_and_retained_device_context() {
    let a = ready();
    let context = session(&a);
    let before = a["state"].clone();
    let request =
        sign(&a, &context, "turn", None).expect("fixed TURN credential selector required");
    assert_eq!(request["method"], "GET");
    assert_eq!(request["path"], "/v2/voice/turn");
    assert_eq!(request["body"], "");
    let authorization = request["authorization"].as_str().unwrap();
    let fields: Vec<_> = authorization
        .strip_prefix("ParanoidSessionV2 ")
        .unwrap()
        .split('.')
        .collect();
    let expires = context["expires"].to_string();
    let digest = paranoid_key_protocol::digest(b"");
    let bytes = lp(&[
        "paranoid-session-request-v1",
        fields[0],
        context["epoch"].as_str().unwrap(),
        &expires,
        context["realm"].as_str().unwrap(),
        context["pin"].as_str().unwrap(),
        context["account"].as_str().unwrap(),
        context["device"].as_str().unwrap(),
        context["credential"].as_str().unwrap(),
        fields[1],
        "GET",
        "/v2/voice/turn",
        &digest,
    ]);
    paranoid_key_protocol::verify(
        a["request"]["credential"]["auth"].as_str().unwrap(),
        &bytes,
        fields[2],
    )
    .unwrap();
    let another = sign(&a, &context, "turn", None).unwrap();
    assert_ne!(request["authorization"], another["authorization"]);
    for key in [
        "realm",
        "pin",
        "account",
        "device",
        "credential",
        "epoch",
        "id",
    ] {
        let mut wrong = context.clone();
        wrong[key] = json!("wrong");
        assert!(sign(&a, &wrong, "turn", None).is_err(), "{key}");
    }
    assert!(sign(&a, &context, "turn", Some("injected")).is_err());
    for selector in ["turn?x=1", "/v2/voice/turn", "turn/post", "TURN"] {
        assert!(sign(&a, &context, selector, None).is_err());
    }
    for (key, value) in [("path", "/v2/admin"), ("body", "{}"), ("nonce", "fixed")] {
        let mut attempted = json!({"op":"sign_session_v2", "session":context, "operation":"turn"});
        attempted[key] = json!(value);
        assert!(call(&a["state"], attempted).is_err());
    }
    assert_eq!(
        call(&a["state"], json!({"op":"view"})).unwrap()["state"],
        before
    );
}

#[test]
fn push_selector_signs_exact_fcm_registration_and_rejects_bad_tokens() {
    let a = ready();
    let context = session(&a);
    let before = a["state"].clone();
    let request = sign(&a, &context, "push", Some("fcm-token_ABC:123")).unwrap();
    assert_eq!(request["method"], "POST");
    assert_eq!(request["path"], "/v2/push");
    assert_eq!(
        request["body"],
        json!({"platform":"fcm","token":"fcm-token_ABC:123"}).to_string()
    );
    let unregister = sign(&a, &context, "push", Some("")).unwrap();
    assert_eq!(
        unregister["body"],
        json!({"platform":"fcm","token":""}).to_string()
    );
    assert!(
        sign(&a, &context, "push", None).is_err(),
        "token is required"
    );
    for bad in ["with space", "tab\there", "\u{e9}", &"x".repeat(4097)] {
        assert!(sign(&a, &context, "push", Some(bad)).is_err(), "{bad:?}");
    }
    assert_eq!(
        call(&a["state"], json!({"op":"view"})).unwrap()["state"],
        before,
        "signing a push registration mutates no state"
    );
}
