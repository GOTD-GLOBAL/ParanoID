use base64::{engine::general_purpose::STANDARD, Engine};
use paranoid_client_core::command;
use serde_json::{json, Value};

#[test]
fn malformed_replay_of_accepted_id_never_returns_cursor_progress() {
    let (mut a, mut b) = paired();
    a = call(&a["state"], json!({"op":"send","text":"accepted once"}));
    let original = event(&a["outbox"][0], "alice", 1);
    b = call(&b["state"], json!({"op":"receive","message":original}));
    for (seq, body) in [(3, "AA=="), (3, "not-base64!"), (1, "AA==")] {
        let mut replay = original.clone();
        replay["sequence"] = json!(seq);
        replay["ciphertext"] = json!(body);
        let result = command(
            &b["state"].to_string(),
            &json!({"op":"receive","message":replay}).to_string(),
        );
        assert!(
            matches!(result, Err("conflicting_replay")),
            "known ID must never return a rejection/progress candidate"
        );
    }
    let mut alias = original.clone();
    alias["id"] = json!(format!("{{{}}}", original["id"].as_str().unwrap()));
    alias["sequence"] = json!(3);
    assert!(command(
        &b["state"].to_string(),
        &json!({"op":"receive","message":alias}).to_string()
    )
    .is_err());
    // Exact retries still succeed, and the intervening legitimate event remains visible.
    b = call(&b["state"], json!({"op":"receive","message":original}));
    assert_eq!(b["cursor"], 1);
    a = call(
        &a["state"],
        json!({"op":"send","text":"intervening valid event"}),
    );
    b = call(
        &b["state"],
        json!({"op":"receive","message":event(&a["outbox"][1],"alice",2)}),
    );
    assert_eq!(b["cursor"], 2);
    assert_eq!(b["rejected_count"], 0);
    assert_eq!(b["messages"].as_array().unwrap().len(), 2);
}

#[test]
fn simultaneous_first_sends_and_lost_acceptance_keep_exact_retry_bytes() {
    let (mut a, mut b) = paired();
    a = call(&a["state"], json!({"op":"send","text":"A first"}));
    b = call(&b["state"], json!({"op":"send","text":"B first"}));
    let a_sent = a["outbox"][0].clone();
    let b_sent = b["outbox"][0].clone();
    b = call(
        &b["state"],
        json!({"op":"receive","message":event(&a_sent,"alice",1)}),
    );
    a = call(
        &a["state"],
        json!({"op":"receive","message":event(&b_sent,"bob",2)}),
    );
    let a_receipt = a["outbox"][1].clone();
    let b_receipt = b["outbox"][1].clone();
    b = call(
        &b["state"],
        json!({"op":"receive","message":event(&a_receipt,"alice",3)}),
    );
    a = call(
        &a["state"],
        json!({"op":"receive","message":event(&b_receipt,"bob",4)}),
    );
    assert_eq!(a["messages"][0]["delivered"], true);
    assert_eq!(b["messages"][0]["delivered"], true);
    assert!(a["outbox"][0] == a_sent);
    assert!(b["outbox"][0] == b_sent);
    for entry in a["outbox"].as_array().unwrap().clone() {
        a = call(&a["state"], json!({"op":"accepted","id":entry["id"]}));
    }
    for entry in b["outbox"].as_array().unwrap().clone() {
        b = call(&b["state"], json!({"op":"accepted","id":entry["id"]}));
    }
    b = call(
        &b["state"],
        json!({"op":"receive","message":event(&a_sent,"alice",1)}),
    );
    assert_eq!(b["messages"].as_array().unwrap().len(), 2);
    assert!(b["outbox"].as_array().unwrap().is_empty());
    assert!(a["outbox"].as_array().unwrap().is_empty());
}

#[test]
fn rejection_log_is_bounded_and_old_snapshots_load_without_key_reset() {
    let (mut a, mut b) = paired();
    let original = b["state"].clone();
    for seq in 1..=70 {
        b = call(
            &b["state"],
            json!({"op":"receive","message":{"id":uuid::Uuid::new_v4().to_string(),"sender":"alice","sequence":seq,"ciphertext":"AA=="}}),
        );
    }
    assert_eq!(b["rejected_count"], 70);
    assert_eq!(b["first_rejected_sequence"], 1);
    assert_eq!(b["state"]["rejected_events"].as_array().unwrap().len(), 64);
    assert_eq!(b["state"]["rejected_events"][0]["sequence"], 70 - 64 + 1);
    assert!(b["state"]["account"] == original["account"]);
    assert!(b["state"]["sessions"] == original["sessions"]);
    a = call(
        &a["state"],
        json!({"op":"send","text":"after bounded notices"}),
    );
    b = call(
        &b["state"],
        json!({"op":"receive","message":event(&a["outbox"][0],"alice",71)}),
    );
    assert_eq!(b["messages"][0]["text"], "after bounded notices");
    let mut legacy = original.clone();
    for field in [
        "rejected_events",
        "rejected_count",
        "first_rejected_sequence",
    ] {
        legacy.as_object_mut().unwrap().remove(field);
    }
    let restored = call(&legacy, json!({"op":"view"}));
    assert_eq!(restored["rejected_count"], 0);
    assert!(restored["state"]["account"] == original["account"]);
    let mut corrupt = original.clone();
    corrupt["account"] = json!({});
    assert!(command(
        &corrupt.to_string(),
        &json!({"op":"receive","message":event(&a["outbox"][0],"alice",1)}).to_string()
    )
    .is_err());
}

#[test]
fn unknown_receipt_is_rejected_without_advancing_the_failed_ratchet() {
    use vodozemac::olm::{Session, SessionPickle};
    let (mut a, mut b) = paired();
    a = call(
        &a["state"],
        json!({"op":"send","text":"fixture session setup"}),
    );
    // A malicious authenticated peer, using the real library and existing keys,
    // can send an unknown receipt. Preserve its actual counter for the next send.
    let pickle: SessionPickle = serde_json::from_value(a["state"]["sessions"][0].clone()).unwrap();
    let mut session = Session::from_pickle(pickle);
    let id = uuid::Uuid::new_v4().to_string();
    let plain = json!({"v":0,"realm":"https://test.invalid","from":"alice","to":"bob","id":id,"kind":"receipt","body":uuid::Uuid::new_v4().to_string()});
    let encrypted = session.encrypt(plain.to_string()).unwrap();
    let (kind, bytes) = encrypted.to_parts();
    let mut frame = vec![kind as u8];
    frame.extend(bytes);
    a["state"]["sessions"][0] = serde_json::to_value(session.pickle()).unwrap();
    let before = b["state"].clone();
    b = call(
        &before,
        json!({"op":"receive","message":{"id":id,"sender":"alice","sequence":1,"ciphertext":STANDARD.encode(frame)}}),
    );
    assert_eq!(
        b["state"]["rejected_events"][0]["reason"],
        "unknown_receipt"
    );
    assert!(b["outbox"].as_array().unwrap().is_empty());
    assert!(b["messages"].as_array().unwrap().is_empty());
    assert!(b["state"]["account"] == before["account"]);
    assert!(b["state"]["sessions"] == before["sessions"]);
    a = call(
        &a["state"],
        json!({"op":"send","text":"after unknown receipt"}),
    );
    b = call(
        &b["state"],
        json!({"op":"receive","message":event(&a["outbox"][1],"alice",2)}),
    );
    assert_eq!(b["messages"][0]["text"], "after unknown receipt");
}

fn call(state: &Value, request: Value) -> Value {
    serde_json::from_str(&command(&state.to_string(), &request.to_string()).unwrap()).unwrap()
}
fn paired() -> (Value, Value) {
    let init = |device| -> Value {
        serde_json::from_str(
            &command(
                "",
                &json!({"op":"init","device":device,"realm":"https://test.invalid"}).to_string(),
            )
            .unwrap(),
        )
        .unwrap()
    };
    let mut a = init("alice");
    let mut b = init("bob");
    a = call(
        &a["state"],
        json!({"op":"pair","peer":b["public"],"verified":true}),
    );
    b = call(
        &b["state"],
        json!({"op":"pair","peer":a["public"],"verified":true}),
    );
    (a, b)
}
fn event(outgoing: &Value, sender: &str, sequence: i64) -> Value {
    json!({"id":outgoing["id"],"ciphertext":outgoing["ciphertext"],"sender":sender,"sequence":sequence})
}

// Owner decision 2026-09-17: the local history has no ceiling, so a conversation
// far past the retired 200-entry cap keeps accepting text and still applies a
// later delivery receipt to an older own message.
#[test]
fn history_past_the_retired_cap_accepts_text_and_a_later_delivery_receipt() {
    let (mut a, mut b) = paired();
    b = call(&b["state"], json!({"op":"send","text":"needs receipt"}));
    let own_id = b["outbox"][0]["id"].clone();
    a = call(
        &a["state"],
        json!({"op":"send","text":"text past the retired cap"}),
    );
    a = call(
        &a["state"],
        json!({"op":"receive","message":event(&b["outbox"][0],"bob",1)}),
    );
    let history = b["state"]["history"].as_array_mut().unwrap();
    while history.len() < 250 {
        history.push(json!({"id":uuid::Uuid::new_v4().to_string(),"author":"bob","text":"old test entry","accepted":true,"delivered":false}));
    }
    let before = b["state"].clone();
    b = call(
        &before,
        json!({"op":"receive","message":event(&a["outbox"][0],"alice",2)}),
    );
    assert_eq!(b["cursor"], 2);
    assert_eq!(b["rejected_count"], 0);
    assert!(b["state"]["rejected_events"].as_array().unwrap().is_empty());
    assert_eq!(b["messages"].as_array().unwrap().len(), 251);
    // The candidate is committed now, so the Olm account and session state are
    // expected to move; only the refusal path leaves them byte-identical.
    b = call(
        &b["state"],
        json!({"op":"receive","message":event(&a["outbox"][1],"alice",3)}),
    );
    assert_eq!(b["cursor"], 3);
    let original = b["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["id"] == own_id)
        .unwrap();
    assert_eq!(original["delivered"], true);
    assert_eq!(b["messages"].as_array().unwrap().len(), 251);
}

#[test]
fn bad_event_is_recorded_without_crypto_commit_and_next_message_arrives() {
    let (mut a, mut b) = paired();
    a = call(
        &a["state"],
        json!({"op":"send","text":"corrupt this test event"}),
    );
    let mut bad = event(&a["outbox"][0], "alice", 1);
    let mut bytes = STANDARD
        .decode(bad["ciphertext"].as_str().unwrap())
        .unwrap();
    let last = bytes.len() - 1;
    bytes[last] ^= 1;
    bad["ciphertext"] = json!(STANDARD.encode(bytes));
    let before = b["state"].clone();
    b = call(&before, json!({"op":"receive","message":bad}));
    assert_eq!(b["cursor"], 1);
    assert_eq!(b["rejected_count"], 1);
    assert!(b["state"]["account"] == before["account"]);
    assert!(b["state"]["sessions"] == before["sessions"]);
    assert!(b["messages"].as_array().unwrap().is_empty());
    assert!(b["outbox"].as_array().unwrap().is_empty());
    // Serialize/reload the actual snapshot before subsequent sync.
    b = call(&b["state"], json!({"op":"view"}));
    assert_eq!(b["cursor"], 1);
    a = call(
        &a["state"],
        json!({"op":"send","text":"valid message after poison"}),
    );
    b = call(
        &b["state"],
        json!({"op":"receive","message":event(&a["outbox"][1],"alice",2)}),
    );
    assert_eq!(b["messages"].as_array().unwrap().len(), 1);
    assert_eq!(b["messages"][0]["text"], "valid message after poison");
    assert_eq!(b["outbox"].as_array().unwrap().len(), 1);
    assert_eq!(b["cursor"], 2);
}
