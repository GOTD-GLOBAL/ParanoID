use paranoid_client_core::command;
use serde_json::{json, Value};

#[test]
fn tampering_context_replacement_and_retries_are_fail_closed() {
    let mut a = initialize("alice");
    let mut b = initialize("bob");
    a = call(
        &a["state"].to_string(),
        json!({"op":"pair","peer":b["public"],"verified":true}),
    );
    b = call(
        &b["state"].to_string(),
        json!({"op":"pair","peer":a["public"],"verified":true}),
    );
    let stranger = initialize("bob");
    assert!(command(
        &a["state"].to_string(),
        &json!({"op":"pair","peer":stranger["public"],"verified":true}).to_string()
    )
    .is_err());
    a = call(
        &a["state"].to_string(),
        json!({"op":"send","text":"persist these bytes"}),
    );
    let view = call(&a["state"].to_string(), json!({"op":"view"}));
    assert_eq!(a["outbox"], view["outbox"]);
    let out = &a["outbox"][0];
    let incoming =
        json!({"id":out["id"],"sender":"alice","ciphertext":out["ciphertext"],"sequence":1});
    let mut wrong = incoming.clone();
    wrong["id"] = json!(uuid::Uuid::new_v4().to_string());
    assert!(command(
        &b["state"].to_string(),
        &json!({"op":"receive","message":wrong}).to_string()
    )
    .is_err());
    let mut wrong = incoming.clone();
    wrong["sender"] = json!("bob");
    assert!(command(
        &b["state"].to_string(),
        &json!({"op":"receive","message":wrong}).to_string()
    )
    .is_err());
    let mut wrong = incoming.clone();
    wrong["ciphertext"] = json!("AQID");
    assert!(command(
        &b["state"].to_string(),
        &json!({"op":"receive","message":wrong}).to_string()
    )
    .is_err());
    b = call(
        &b["state"].to_string(),
        json!({"op":"receive","message":incoming}),
    );
    assert_eq!(b["messages"].as_array().unwrap().len(), 1);
    let mut replay = incoming.clone();
    replay["sequence"] = json!(2);
    assert!(command(
        &b["state"].to_string(),
        &json!({"op":"receive","message":replay}).to_string()
    )
    .is_err());
    assert!(command("broken-state", &json!({"op":"view"}).to_string()).is_err());
    assert!(command(
        &b["state"].to_string(),
        &json!({"op":"init","device":"bob","realm":"https://test.invalid"}).to_string()
    )
    .is_err());
}

#[test]
fn pinned_peers_exchange_text_and_authenticated_delivery_receipt_after_reload() {
    let mut a = initialize("alice");
    let mut b = initialize("bob");
    assert!(command(
        &a["state"].to_string(),
        &json!({"op":"pair","peer":b["public"],"verified":false}).to_string()
    )
    .is_err());
    a = call(
        &a["state"].to_string(),
        json!({"op":"pair","peer":b["public"],"verified":true}),
    );
    b = call(
        &b["state"].to_string(),
        json!({"op":"pair","peer":a["public"],"verified":true}),
    );
    a = call(
        &a["state"].to_string(),
        json!({"op":"send","text":"hello phone B"}),
    );
    let outgoing = a["outbox"][0].clone();
    assert!(!outgoing["ciphertext"]
        .as_str()
        .unwrap()
        .contains("hello phone B"));
    let incoming = json!({"id":outgoing["id"],"ciphertext":outgoing["ciphertext"],"sender":"alice","sequence":1});
    b = call(
        &b["state"].to_string(),
        json!({"op":"receive","message":incoming}),
    );
    assert_eq!(b["messages"][0]["text"], "hello phone B");
    assert_eq!(b["cursor"], 1);
    let duplicate = call(
        &b["state"].to_string(),
        json!({"op":"receive","message":incoming}),
    );
    assert_eq!(duplicate["messages"].as_array().unwrap().len(), 1);
    assert_eq!(duplicate["outbox"].as_array().unwrap().len(), 1);
    let receipt = b["outbox"][0].clone();
    a = call(
        &a["state"].to_string(),
        json!({"op":"accepted","id":outgoing["id"]}),
    );
    assert_eq!(a["messages"][0]["accepted"], true);
    assert_eq!(a["messages"][0]["delivered"], false);
    a = call(
        &a["state"].to_string(),
        json!({"op":"receive","message":{"id":receipt["id"],"ciphertext":receipt["ciphertext"],"sender":"bob","sequence":2}}),
    );
    assert_eq!(a["messages"][0]["delivered"], true);
    assert!(a["outbox"].as_array().unwrap().is_empty());
}

fn call(state: &str, request: Value) -> Value {
    serde_json::from_str(&command(state, &request.to_string()).unwrap()).unwrap()
}
fn initialize(device: &str) -> Value {
    call(
        "",
        json!({"op":"init","device":device,"realm":"https://test.invalid"}),
    )
}
#[test]
fn fresh_client_exports_only_public_pairing_data() {
    let a = initialize("alice");
    let b = initialize("alice");
    assert_ne!(a["public"]["curve"], b["public"]["curve"]);
    assert_eq!(a["public"].as_object().unwrap().len(), 4);
    assert!(a["public"]["one_time_key"].is_string());
    assert!(a["state"]["account"].is_object());
    assert!(command(
        &a["state"].to_string(),
        &json!({"op":"send","text":"hello"}).to_string()
    )
    .is_err());
}
