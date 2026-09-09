use paranoid_client_core::command;
use paranoid_key_protocol::{digest, transcript, Credential};
use serde_json::{json, Value};
fn call(s: &Value, r: Value) -> Result<Value, &'static str> {
    command(&s.to_string(), &r.to_string()).map(|v| serde_json::from_str(&v).unwrap())
}
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
// Synthetic original identities without an inferred relationship (RFC-0013).
fn original_unpaired(device: &str) -> Value {
    let a: Value = serde_json::from_str(
        &command(
            "",
            &json!({"op":"init","device":device,"realm":"https://127.0.0.2:38443"}).to_string(),
        )
        .unwrap(),
    )
    .unwrap();
    call(
        &a["state"],
        json!({"op":"create_identity","realm":"https://127.0.0.2:38443","pin":"a".repeat(64)}),
    )
    .unwrap()
}

fn retain_original(a: &Value, b: &Value) -> Value {
    // Represent a previously verified original contact using genuine fixture
    // bundle/credential, not a pairing API bypass in production or recovery.
    let mut a = a.clone();
    a["state"]["peer"] = b["public"].clone();
    a["state"]["peer_credential"] = b["request"]["credential"].clone();
    a
}

#[test]
fn signed_v2_qr_does_not_disclose_retained_peer_profile() {
    let a = migrate_ready(&original_unpaired("alice"));
    let b = migrate_ready(&original_unpaired("bob"));
    let mut retained = a["state"].clone();
    // Two possible synthetic histories sharing exactly the same identity and QR.
    // Never a recovery procedure on installed state.
    let original = json!({"state":retained["legacy"],"public":a["public"]});
    retained["legacy"] = retain_original(&original, &b)["state"].clone();
    let retained = call(&retained, json!({"op":"view"})).unwrap();
    assert_eq!(a["contact"], retained["contact"]);
    assert_eq!(a["request"], retained["request"]);
    let new_receiver = pair(&b, &a);
    let retained_receiver = pair(&b, &retained);
    assert!(new_receiver["state"] == retained_receiver["state"]);
    assert_eq!(
        new_receiver["state"]["conversations"][id(&a)]["state"]["public"]["device"],
        id(&b)
    );
    assert_eq!(
        pair(&a, &b)["state"]["conversations"][id(&b)]["state"]["public"]["device"],
        id(&a)
    );
    assert_eq!(
        pair(&retained, &b)["state"]["legacy"]["public"]["device"],
        "alice"
    );
}

#[test]
fn new_conversations_between_original_labels_keep_account_context_and_strict_rejection() {
    let a = migrate_ready(&original_unpaired("alice"));
    let b = migrate_ready(&original_unpaired("bob"));
    let a = pair(&a, &b);
    let b = pair(&b, &a);
    for (sender, receiver) in [(&a, &b), (&b, &a)] {
        let sent = call(
            &sender["state"],
            json!({"op":"send_v2","account":id(receiver),"text":"new account profile"}),
        )
        .unwrap();
        let mut wrong = sent["outbox"][0].clone();
        wrong.as_object_mut().unwrap().remove("recipient");
        wrong["sender"] = json!(id(sender));
        wrong["sequence"] = json!(1);
        wrong["id"] = json!(uuid::Uuid::new_v4().to_string());
        let rejected = call(
            &receiver["state"],
            json!({"op":"receive_v2","message":wrong}),
        )
        .unwrap();
        let rejected_adapter = &rejected["state"]["conversations"][id(sender)]["state"];
        assert_eq!(
            rejected_adapter["rejected_events"][0]["reason"],
            "context_mismatch"
        );
        assert!(rejected["outbox"].as_array().unwrap().is_empty());
        assert!(rejected["state"]["legacy"]["account"] == receiver["state"]["legacy"]["account"]);
        for field in ["sessions", "history", "outbox", "seen"] {
            assert!(
                rejected_adapter[field]
                    == receiver["state"]["conversations"][id(sender)]["state"][field]
            );
        }
        // Independent valid delivery from the original receiver snapshot: never
        // reset a committed rejection cursor to make a message pass.
        let received = deliver(&sent, receiver, 0, 1);
        assert_eq!(received["rejected_count"], 0);
        assert_eq!(
            received["dialogs"][0]["messages"][0]["text"],
            "new account profile"
        );
        assert_eq!(
            received["state"]["conversations"][id(sender)]["state"]["public"]["device"],
            id(receiver)
        );
        let receipt = deliver(&received, &sent, 0, 2);
        assert_eq!(receipt["rejected_count"], 0);
        assert_eq!(receipt["dialogs"][0]["messages"][0]["delivered"], true);
    }
}

// Intentionally RED until RFC-0013 resolves the missing authenticated per-pair signal.
// Not ignored: this is an acceptance gate, not a claim of delivered compatibility.
#[test]
fn asymmetric_retained_pair_requires_bidirectional_text_and_receipts() {
    let old_a = original_unpaired("alice");
    let old_b = original_unpaired("bob");
    let a = migrate_ready(&retain_original(&old_a, &old_b));
    let b = migrate_ready(&old_b);
    let a = pair(&a, &b);
    let paired_b = pair(&b, &a);
    let mut failures = Vec::new();
    for (sender, receiver, deferred) in [
        (&a, &b, true),
        (&a, &paired_b, false),
        (&paired_b, &a, false),
    ] {
        let sent = call(
            &sender["state"],
            json!({"op":"send_v2","account":id(receiver),"text":"retained compatibility"}),
        )
        .unwrap();
        let received = deliver(&sent, receiver, 0, 1);
        let received = if deferred {
            assert_eq!(received["rejected_count"], 1);
            assert!(received["dialogs"].as_array().unwrap().is_empty());
            assert!(received["outbox"].as_array().unwrap().is_empty());
            assert_eq!(
                received["state"]["legacy"]["rejected_events"][0]["reason"],
                "unverified_contact"
            );
            let verified = pair(&received, &sent);
            assert_eq!(verified["cursor"], 0);
            deliver(&sent, &verified, 0, 1)
        } else {
            received
        };
        if received["rejected_count"] != 0 {
            let adapter = if received["state"]["conversations"][id(&sent)].is_null() {
                &received["state"]["legacy"]
            } else {
                &received["state"]["conversations"][id(&sent)]["state"]
            };
            failures.push((deferred, adapter["rejected_events"][0]["reason"].clone()));
            continue;
        }
        assert_eq!(
            received["dialogs"][0]["messages"][0]["text"],
            "retained compatibility"
        );
        let receipted = deliver(&received, &sent, 0, 2);
        assert_eq!(receipted["dialogs"][0]["messages"][0]["delivered"], true);
        assert_eq!(receipted["rejected_count"], 0);
        assert!(deliver(&sent, &received, 0, 1)["state"] == received["state"]);
    }
    assert!(
        failures.is_empty(),
        "asymmetric text/receipt acceptance blocked: {failures:?}"
    );
}

fn legacy_pair() -> (Value, Value) {
    let init = |device| {
        serde_json::from_str::<Value>(
            &command(
                "",
                &json!({"op":"init","device":device,"realm":"https://127.0.0.2:38443"}).to_string(),
            )
            .unwrap(),
        )
        .unwrap()
    };
    let a = init("alice");
    let b = init("bob");
    let a = call(
        &a["state"],
        json!({"op":"pair","peer":b["public"],"verified":true}),
    )
    .unwrap();
    let b = call(
        &b["state"],
        json!({"op":"pair","peer":a["public"],"verified":true}),
    )
    .unwrap();
    let b = call(&b["state"], json!({"op":"send","text":"Старая история"})).unwrap();
    let mut message = b["outbox"][0].clone();
    message.as_object_mut().unwrap().remove("recipient");
    message["sender"] = json!("bob");
    message["sequence"] = json!(1);
    let a = call(&a["state"], json!({"op":"receive","message":message})).unwrap();
    let bind = |a: &Value| {
        call(
            &a["state"],
            json!({"op":"create_identity","realm":"https://127.0.0.2:38443","pin":"a".repeat(64)}),
        )
        .unwrap()
    };
    (bind(&a), bind(&b))
}
fn migrate_ready(a: &Value) -> Value {
    let a = upgrade(a);
    let a = call(
        &a["state"],
        json!({"op":"server_status_v2","status":status(&a)}),
    )
    .unwrap();
    call(&a["state"], json!({"op":"prepare_contact_v2"})).unwrap()
}
#[test]
fn consumed_original_prekey_legacy_ratchets_and_exact_outbox_survive_two_new_contacts() {
    let (old_a, old_b) = legacy_pair();
    assert!(old_a["state"]["account"]["one_time_keys"]["private_keys"]
        .as_object()
        .unwrap()
        .is_empty());
    let a = migrate_ready(&old_a);
    let b = migrate_ready(&old_b);
    let a = pair(&a, &b);
    let b = pair(&b, &a);
    assert_eq!(
        a["dialogs"][0]["messages"][0]["text"], "Старая история",
        "legacy history must remain a real dialog"
    );
    assert!(a["state"]["legacy"]["sessions"] == old_a["state"]["sessions"]);
    assert!(a["state"]["legacy"]["outbox"] == old_a["state"]["outbox"]);
    assert_eq!(
        a["outbox"][0]["ciphertext"],
        old_a["outbox"][0]["ciphertext"]
    );
    assert_eq!(a["outbox"][0]["recipient"], id(&b));
    let b = deliver(&a, &b, 0, 2);
    assert_eq!(b["dialogs"][0]["messages"][0]["delivered"], true);
    let mut a = a;
    for text in ["Новый контакт один", "Новый контакт два"] {
        let c = ready();
        a = pair(&a, &c);
        let c = pair(&c, &a);
        let c = call(
            &c["state"],
            json!({"op":"send_v2","account":id(&a),"text":text}),
        )
        .unwrap();
        let seq = a["cursor"].as_i64().unwrap() + 1;
        a = deliver(&c, &a, 0, seq);
        let dialog = a["dialogs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["account"] == id(&c))
            .unwrap();
        assert_eq!(dialog["messages"][0]["text"], text);
    }
    assert!(
        a["state"]["legacy"]["account"]["one_time_keys"]["private_keys"]
            .as_object()
            .unwrap()
            .is_empty()
    );
    assert!(a["state"]["legacy"]["identity"] == old_a["state"]["identity"]);
}
#[test]
fn acceptance_drains_only_exact_queued_id_and_never_claims_peer_delivery() {
    let a = ready();
    let b = ready();
    let a = pair(&a, &b);
    let a = call(
        &a["state"],
        json!({"op":"send_v2","account":id(&b),"text":"offline queue"}),
    )
    .unwrap();
    let message = a["outbox"][0]["id"].clone();
    let accepted = call(&a["state"], json!({"op":"accepted_v2","id":message}));
    assert!(
        accepted.is_ok(),
        "v2 acceptance must update the owning conversation: {accepted:?}"
    );
    let accepted = accepted.unwrap();
    assert_eq!(accepted["outbox"].as_array().unwrap().len(), 0);
    assert_eq!(accepted["dialogs"][0]["messages"][0]["accepted"], true);
    assert_eq!(accepted["dialogs"][0]["messages"][0]["delivered"], false);
    assert!(call(
        &a["state"],
        json!({"op":"accepted_v2","id":uuid::Uuid::new_v4().to_string()})
    )
    .is_err());
}
#[test]
fn installed_verified_peer_routes_and_history_survive_without_readding_contact() {
    let (mut a, b) = legacy_pair();
    a["state"]["peer_credential"] = b["request"]["credential"].clone();
    let a = migrate_ready(&a);
    assert_eq!(
        a["dialogs"].as_array().unwrap().len(),
        1,
        "retained verified contact must not disappear"
    );
    assert_eq!(a["dialogs"][0]["account"], id(&b));
    assert_eq!(a["outbox"][0]["recipient"], id(&b));
    assert_eq!(a["dialogs"][0]["messages"][0]["text"], "Старая история");
}
#[test]
fn damaged_conversation_or_missing_fallback_secret_cannot_reopen_as_healthy_state() {
    let a = ready();
    let b = ready();
    let a = pair(&a, &b);
    let mut bad = a["state"].clone();
    bad["first_unverified_sequence"] = json!(-1);
    assert!(
        call(&bad, json!({"op":"view"})).is_err(),
        "invalid replay cursor must fail closed"
    );
    let mut bad = a["state"].clone();
    bad["conversations"][id(&b)]["state"]["sessions"] = json!([{}]);
    assert!(
        call(&bad, json!({"op":"view"})).is_err(),
        "unreadable retained ratchets must freeze before network use"
    );
    let mut bad = a["state"].clone();
    bad["legacy"]["account"]["fallback_keys"]["fallback_key"] = Value::Null;
    assert!(
        call(&bad, json!({"op":"view"})).is_err(),
        "missing retained fallback secret must not mint replacement"
    );
    let mut bad = a["state"].clone();
    bad["conversations"][id(&b)]["state"]["peer"]["curve"] = a["public"]["curve"].clone();
    assert!(
        call(&bad, json!({"op":"view"})).is_err(),
        "contact pin and crypto adapter must agree"
    );
}
#[test]
fn unverified_sender_is_not_decrypted_or_receipted_and_does_not_block_verified_dialogs() {
    let a = ready();
    let b = ready();
    let a = pair(&a, &b);
    let b = pair(&b, &a);
    let stranger = pair(&ready(), &a);
    let stranger = call(
        &stranger["state"],
        json!({"op":"send_v2","account":id(&a),"text":"Unverified"}),
    )
    .unwrap();
    let mut m = stranger["outbox"][0].clone();
    m.as_object_mut().unwrap().remove("recipient");
    m["sender"] = json!(id(&stranger));
    m["sequence"] = json!(1);
    let skipped = call(&a["state"], json!({"op":"receive_v2","message":m}));
    assert!(
        skipped.is_ok(),
        "unverified sender must become an explicit deferred event, not block every dialog"
    );
    let a = skipped.unwrap();
    assert_eq!(a["rejected_count"], 1);
    assert_eq!(a["outbox"].as_array().unwrap().len(), 0);
    let b = call(
        &b["state"],
        json!({"op":"send_v2","account":id(&a),"text":"Verified"}),
    )
    .unwrap();
    let a = deliver(&b, &a, 0, 2);
    assert_eq!(a["dialogs"][0]["messages"][0]["text"], "Verified");
}
#[test]
fn adding_contact_retries_previously_unverified_ciphertext_without_duplicate_history() {
    let a = ready();
    let b = pair(&ready(), &a);
    let b = call(
        &b["state"],
        json!({"op":"send_v2","account":id(&a),"text":"Sent before reciprocal scan"}),
    )
    .unwrap();
    let a = deliver(&b, &a, 0, 1);
    assert_eq!(a["rejected_count"], 1);
    let a = pair(&a, &b);
    assert_eq!(a["cursor"],0,"explicitly verified new contact must replay retained ciphertext from the first deferred event");
    let a = deliver(&b, &a, 0, 1);
    assert_eq!(
        a["dialogs"][0]["messages"][0]["text"],
        "Sent before reciprocal scan"
    );
    assert_eq!(
        a["rejected_count"], 0,
        "recovered deferred event must no longer be reported as rejected"
    );
    let repeat = deliver(&b, &a, 0, 1);
    assert!(a["state"] == repeat["state"]);
}
#[test]
fn snapshot_growth_is_refused_before_emitting_state_that_cannot_be_reopened() {
    let a = ready();
    let b = ready();
    let a = pair(&a, &b);
    let mut state = a["state"].clone();
    // Synthetic near-budget retained history isolates the serialization boundary.
    let entry = json!({"id":uuid::Uuid::new_v4().to_string(),"author":"alice","text":"x","accepted":true,"delivered":true});
    state["legacy"]["history"] = json!([entry]);
    let padding = 8 * 1024 * 1024 - state.to_string().len() - 1500;
    state["legacy"]["history"][0]["text"] = json!("x".repeat(padding));
    assert!(state.to_string().len() < 8 * 1024 * 1024);
    let result = call(
        &state,
        json!({"op":"send_v2","account":id(&b),"text":"x".repeat(2048)}),
    );
    assert!(result.is_err(),"must refuse a candidate larger than the next-open state limit, not persist an unreadable snapshot");
}
#[test]
fn unbound_legacy_history_stays_visible_but_cannot_be_routed_to_an_unverified_account() {
    let (a, _) = legacy_pair();
    let a = migrate_ready(&a);
    assert_eq!(
        a["dialogs"].as_array().unwrap().len(),
        1,
        "retain the visible old dialog even before the peer root is linked"
    );
    assert_eq!(a["dialogs"][0]["requires_verification"], true);
    assert_eq!(a["dialogs"][0]["messages"][0]["text"], "Старая история");
    assert!(call(
        &a["state"],
        json!({"op":"send_v2","account":a["dialogs"][0]["account"],"text":"must not route"})
    )
    .is_err());
}
// Characterizes the inherited crossing-session algorithm through the new shared Account router.
#[test]
fn simultaneous_first_sends_to_two_contacts_preserve_crossing_ratchets_after_reload() {
    let a = ready();
    let b = ready();
    let c = ready();
    let mut a = pair(&pair(&a, &b), &c);
    let mut peers = vec![pair(&b, &a), pair(&c, &a)];
    for peer in &mut peers {
        a = call(
            &a["state"],
            json!({"op":"send_v2","account":id(peer),"text":"initial outbound"}),
        )
        .unwrap();
        *peer = call(
            &peer["state"],
            json!({"op":"send_v2","account":id(&a),"text":"crossing outbound"}),
        )
        .unwrap();
    }
    let mut seq = 1;
    for peer in &peers {
        a = deliver(peer, &a, 0, seq);
        seq += 1;
    }
    a = call(&a["state"], json!({"op":"view"})).unwrap();
    for peer in &mut peers {
        let queued = a["outbox"].as_array().unwrap().clone();
        for (n, envelope) in queued.iter().enumerate() {
            if envelope["recipient"] == id(peer) {
                *peer = deliver(&a, peer, n, seq);
                seq += 1;
            }
        }
        let receipt = peer["outbox"].as_array().unwrap().len() - 1;
        a = deliver(peer, &a, receipt, seq);
        seq += 1;
    }
    for dialog in a["dialogs"].as_array().unwrap() {
        assert_eq!(dialog["messages"].as_array().unwrap().len(), 2);
        assert!(dialog["messages"]
            .as_array()
            .unwrap()
            .iter()
            .all(|m| m["delivered"] == true));
    }
}
// RFC-0014 bounded prototype: no send/receive/trust-state integration is implied.
#[test]
fn sender_intro_authenticates_exact_pending_bytes_without_installing_contact() {
    let receiver = ready();
    let sender = pair(&ready(), &receiver);
    let sent = call(
        &sender["state"],
        json!({"op":"send_v2","account":id(&receiver),"text":"synthetic intro"}),
    )
    .unwrap();
    let before = sent["state"].clone();
    let prepared = call(
        &before,
        json!({"op":"prepare_sender_intro_v2","id":sent["outbox"][0]["id"]}),
    );
    assert!(
        prepared.is_ok(),
        "signed sender introduction is missing: {:?}",
        prepared.err()
    );
    let prepared = prepared.unwrap();
    assert!(
        prepared.get("state").is_none(),
        "prototype must not rewrite pending bytes"
    );
    let mut message = prepared["envelope"].clone();
    message.as_object_mut().unwrap().remove("recipient");
    message["sender"] = json!(id(&sent));
    message["sequence"] = json!(1);
    let result = call(
        &receiver["state"],
        json!({"op":"inspect_sender_intro_v2","message":message}),
    )
    .unwrap();
    assert_eq!(result["account"], id(&sent));
    assert_eq!(result["identity_verified"], false);
    assert_eq!(result["profile"], "account-id-v2");
    assert_eq!(result["contact_fingerprint"], sent["contact_fingerprint"]);
    assert!(
        result.get("state").is_none(),
        "inspection is not contact acceptance"
    );
    assert!(call(&before, json!({"op":"view"})).unwrap()["state"] == before);
    assert!(
        call(&receiver["state"], json!({"op":"view"})).unwrap()["dialogs"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

#[test]
fn sender_intro_rejects_genuinely_signed_replacement_of_pinned_fallback() {
    let receiver = ready();
    let sender = pair(&ready(), &receiver);
    let pinned = pair(&receiver, &sender);
    let sent = call(
        &sender["state"],
        json!({"op":"send_v2","account":id(&receiver),"text":"pin continuity"}),
    )
    .unwrap();
    // Synthetic adversarial new signed contact under the SAME root/auth keys.
    // Never a phone-state edit or proposed production key-rotation operation.
    let mut changed = sent["state"].clone();
    let pickle: vodozemac::olm::AccountPickle =
        serde_json::from_value(changed["legacy"]["account"].clone()).unwrap();
    let mut account = vodozemac::olm::Account::from_pickle(pickle);
    account.generate_fallback_key();
    changed["fallback_key"] = json!(account.fallback_key().values().next().unwrap().to_base64());
    account.mark_keys_as_published();
    changed["legacy"]["account"] = serde_json::to_value(account.pickle()).unwrap();
    let prepared = call(
        &changed,
        json!({"op":"prepare_sender_intro_v2","id":sent["outbox"][0]["id"]}),
    )
    .unwrap();
    let mut message = prepared["envelope"].clone();
    message.as_object_mut().unwrap().remove("recipient");
    message["sender"] = json!(id(&sent));
    message["sequence"] = json!(1);
    assert!(
        call(
            &receiver["state"],
            json!({"op":"inspect_sender_intro_v2","message":message})
        )
        .is_ok(),
        "control: the replacement intro is genuinely signed, not a malformed fixture"
    );
    assert_eq!(
        call(
            &pinned["state"],
            json!({"op":"inspect_sender_intro_v2","message":message})
        )
        .unwrap_err(),
        "peer_already_pinned"
    );
    assert!(call(&pinned["state"], json!({"op":"view"})).unwrap()["state"] == pinned["state"]);
}

#[test]
fn sender_intro_does_not_change_a_retained_legacy_profile() {
    let old_a = original_unpaired("alice");
    let old_b = original_unpaired("bob");
    let receiver = migrate_ready(&retain_original(&old_a, &old_b));
    let sender = pair(&migrate_ready(&old_b), &receiver);
    let sent = call(
        &sender["state"],
        json!({"op":"send_v2","account":id(&receiver),"text":"not legacy negotiation"}),
    )
    .unwrap();
    let prepared = call(
        &sent["state"],
        json!({"op":"prepare_sender_intro_v2","id":sent["outbox"][0]["id"]}),
    )
    .unwrap();
    let mut message = prepared["envelope"].clone();
    message.as_object_mut().unwrap().remove("recipient");
    message["sender"] = json!(id(&sent));
    message["sequence"] = json!(1);
    let result = call(
        &receiver["state"],
        json!({"op":"inspect_sender_intro_v2","message":message}),
    );
    assert!(
        matches!(result, Err("introduction_profile_conflict")),
        "a signed introduction cannot select a new profile for a retained adapter"
    );
    assert!(call(&receiver["state"], json!({"op":"view"})).unwrap()["state"] == receiver["state"]);
}

fn intro_fixture() -> (Value, Value, Value, Value) {
    use base64::Engine;
    let receiver = ready();
    let sender = pair(&ready(), &receiver);
    let sent = call(
        &sender["state"],
        json!({"op":"send_v2","account":id(&receiver),"text":"real Olm inner ciphertext"}),
    )
    .unwrap();
    let prepared = call(
        &sent["state"],
        json!({"op":"prepare_sender_intro_v2","id":sent["outbox"][0]["id"]}),
    )
    .unwrap();
    let mut message = prepared["envelope"].clone();
    message.as_object_mut().unwrap().remove("recipient");
    message["sender"] = json!(id(&sent));
    message["sequence"] = json!(1);
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(message["ciphertext"].as_str().unwrap())
        .unwrap();
    let intro = serde_json::from_slice(&bytes[1..]).unwrap();
    (sent, receiver, message, intro)
}
fn intro_with_json(message: &Value, raw: &str) -> Value {
    use base64::Engine;
    let mut changed = message.clone();
    let mut bytes = vec![2];
    bytes.extend(raw.as_bytes());
    changed["ciphertext"] = json!(base64::engine::general_purpose::STANDARD.encode(bytes));
    changed
}
// Independent test-side transcript assembly from RFC-0014, not production bytes().
fn resign_intro(intro: &mut Value, sender: &Value) {
    use base64::Engine;
    let inner = base64::engine::general_purpose::STANDARD
        .decode(intro["ciphertext"].as_str().unwrap())
        .unwrap();
    let fields = [
        "recipient_account",
        "recipient_device",
        "recipient_credential",
        "recipient_contact",
        "id",
        "profile",
    ];
    let mut values = vec![
        "paranoid-sender-intro-v1".to_string(),
        sender["contact_fingerprint"].as_str().unwrap().to_string(),
    ];
    values.extend(fields.map(|f| intro[f].as_str().unwrap().to_string()));
    values.push(digest(&inner));
    let refs: Vec<&str> = values.iter().map(String::as_str).collect();
    let auth = vodozemac::Ed25519SecretKey::from_base64(
        sender["state"]["legacy"]["identity"]["auth_secret"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    intro["signature"] = json!(auth.sign(&transcript(&refs)).to_base64());
}
#[test]
fn sender_intro_signed_wrong_recipient_or_profile_is_not_route_authority() {
    let (sent, receiver, message, intro) = intro_fixture();
    // Positive control proves the separately assembled transcript is compatible.
    let mut resigned = intro.clone();
    resign_intro(&mut resigned, &sent);
    assert!(call(&receiver["state"], json!({"op":"inspect_sender_intro_v2","message":intro_with_json(&message, &resigned.to_string())})).is_ok());
    // Every bad context is genuinely signed; signature rejection alone is insufficient.
    for field in [
        "recipient_account",
        "recipient_device",
        "recipient_credential",
        "recipient_contact",
        "id",
        "profile",
    ] {
        let mut bad = intro.clone();
        bad[field] = json!(if field == "profile" {
            "legacy-alice-bob".to_string()
        } else if field == "id" || field == "recipient_device" {
            uuid::Uuid::new_v4().to_string()
        } else {
            "0".repeat(64)
        });
        resign_intro(&mut bad, &sent);
        let m = intro_with_json(&message, &bad.to_string());
        let result = call(
            &receiver["state"],
            json!({"op":"inspect_sender_intro_v2","message":m}),
        );
        assert!(
            matches!(result, Err("introduction_context_mismatch")),
            "signed {field} substitution must fail"
        );
    }
    let other = ready();
    assert!(call(
        &other["state"],
        json!({"op":"inspect_sender_intro_v2","message":message})
    )
    .is_err());
    for (field, value) in [
        ("sender", json!(id(&other))),
        ("id", json!(uuid::Uuid::new_v4().to_string())),
        ("sequence", json!(0)),
        ("sequence", json!(100001)),
    ] {
        let mut m = message.clone();
        m[field] = value;
        assert!(
            call(
                &receiver["state"],
                json!({"op":"inspect_sender_intro_v2","message":m})
            )
            .is_err(),
            "outer {field}"
        );
    }
    assert!(call(&receiver["state"], json!({"op":"view"})).unwrap()["state"] == receiver["state"]);
}
#[test]
fn sender_intro_rejects_forged_nested_bindings_and_malformed_frames() {
    use base64::Engine;
    let (sent, receiver, message, intro) = intro_fixture();
    let other = ready();
    for path in [
        "/signature",
        "/contact/signature",
        "/contact/credential/signature",
        "/contact/credential/root",
        "/contact/credential/account",
        "/contact/credential/device",
        "/contact/credential/auth",
        "/contact/credential/olm",
        "/contact/credential/realm",
        "/contact/credential/pin",
        "/contact/fallback_key",
        "/contact/bundle/curve",
        "/contact/bundle/one_time_key",
        "/contact/bundle/device",
        "/contact/bundle/realm",
    ] {
        let mut bad = intro.clone();
        *bad.pointer_mut(path).unwrap() = json!("forged");
        let m = intro_with_json(&message, &bad.to_string());
        assert!(
            call(
                &receiver["state"],
                json!({"op":"inspect_sender_intro_v2","message":m})
            )
            .is_err(),
            "nested {path}"
        );
    }
    let mut bad = intro.clone();
    bad["signature"] = other["contact"]["signature"].clone();
    assert!(call(&receiver["state"], json!({"op":"inspect_sender_intro_v2","message":intro_with_json(&message, &bad.to_string())})).is_err());
    // Even correctly re-signed malformed inner framing is not an Olm message.
    bad = intro.clone();
    bad["ciphertext"] = json!(base64::engine::general_purpose::STANDARD.encode([0, 0]));
    resign_intro(&mut bad, &sent);
    assert!(call(&receiver["state"], json!({"op":"inspect_sender_intro_v2","message":intro_with_json(&message, &bad.to_string())})).is_err());
    // A different VALID Olm frame with the original signature must fail by signature,
    // not only because the parser rejects malformed framing.
    let later = call(
        &sent["state"],
        json!({"op":"send_v2","account":id(&receiver),"text":"different ciphertext"}),
    )
    .unwrap();
    let mut replaced = intro.clone();
    replaced["ciphertext"] = later["outbox"][1]["ciphertext"].clone();
    assert!(matches!(
        call(
            &receiver["state"],
            json!({"op":"inspect_sender_intro_v2","message":intro_with_json(&message, &replaced.to_string())})
        ),
        Err("invalid_signature")
    ));
    // Inspecting a correctly re-signed frame is NOT decryption/context acceptance:
    // the ordinary receiver must still compare the encrypted message ID later.
    resign_intro(&mut replaced, &sent);
    assert!(call(&receiver["state"], json!({"op":"inspect_sender_intro_v2","message":intro_with_json(&message, &replaced.to_string())})).is_ok());
    let raw = intro.to_string();
    let duplicate = raw.replacen('{', "{\"type\":\"paranoid-sender-intro-v1\",", 1);
    let unknown = raw.replacen('{', "{\"surprise\":true,", 1);
    let nested_duplicate = raw.replacen(
        "\"credential\":{",
        "\"credential\":{\"account\":\"duplicate\",",
        1,
    );
    for raw in [
        duplicate,
        unknown,
        nested_duplicate,
        "{".into(),
        "x".repeat(16384),
    ] {
        assert!(call(
            &receiver["state"],
            json!({"op":"inspect_sender_intro_v2","message":intro_with_json(&message, &raw)})
        )
        .is_err());
    }
    for ciphertext in [
        "!".into(),
        "A".repeat(24000),
        base64::engine::general_purpose::STANDARD.encode([2]),
        sent["outbox"][0]["ciphertext"].as_str().unwrap().into(),
    ] {
        let mut m = message.clone();
        m["ciphertext"] = json!(ciphertext);
        assert!(call(
            &receiver["state"],
            json!({"op":"inspect_sender_intro_v2","message":m})
        )
        .is_err());
    }
    assert!(call(&receiver["state"], json!({"op":"view"})).unwrap()["state"] == receiver["state"]);
}
#[test]
fn sender_intro_preparation_is_exact_read_only_and_refuses_missing_pending_id() {
    let (sent, receiver, message, _) = intro_fixture();
    let op = json!({"op":"prepare_sender_intro_v2","id":sent["outbox"][0]["id"]});
    let first = call(&sent["state"], op.clone()).unwrap();
    let reopened = call(&sent["state"], json!({"op":"view"})).unwrap();
    assert!(call(&reopened["state"], op.clone()).unwrap() == first);
    let validated = call(
        &receiver["state"],
        json!({"op":"inspect_sender_intro_v2","message":message}),
    )
    .unwrap();
    assert_eq!(validated["identity_verified"], false);
    // A second inspection cannot install a pin, consume a prekey or queue receipt.
    assert!(
        call(
            &receiver["state"],
            json!({"op":"inspect_sender_intro_v2","message":message})
        )
        .unwrap()
            == validated
    );
    let accepted = call(
        &sent["state"],
        json!({"op":"accepted_v2","id":sent["outbox"][0]["id"]}),
    )
    .unwrap();
    assert!(call(&accepted["state"], op).is_err());
    assert!(call(
        &sent["state"],
        json!({"op":"prepare_sender_intro_v2","id":uuid::Uuid::new_v4().to_string()})
    )
    .is_err());
    let (a, b) = legacy_pair();
    let a = pair(&migrate_ready(&a), &migrate_ready(&b));
    assert!(!a["outbox"].as_array().unwrap().is_empty());
    assert!(
        call(
            &a["state"],
            json!({"op":"prepare_sender_intro_v2","id":a["outbox"][0]["id"]})
        )
        .is_err(),
        "retained outbox cannot be reframed as account-ID context"
    );
}

// REQ-MSG-005 / RFC-0014: active product acceptance, never ignore/xfail.
#[test]
fn first_contact_plaintext_is_visible_without_recipient_pairing() {
    let recipient = ready();
    let sender = pair(&ready(), &recipient);
    assert!(recipient["dialogs"].as_array().unwrap().is_empty());
    let sent = call(
        &sender["state"],
        json!({"op":"send_v2","account":id(&recipient),"text":"Первое сообщение без встречного QR"}),
    ).unwrap();
    let received = deliver(&sent, &recipient, 0, 1);
    assert_eq!(
        received["dialogs"].as_array().unwrap().len(),
        1,
        "REQ-MSG-005: zero-contact recipient must see first plaintext without any approval"
    );
    assert_eq!(
        received["dialogs"][0]["messages"][0]["text"],
        "Первое сообщение без встречного QR"
    );
    assert_eq!(received["dialogs"][0]["identity_verified"], false);
    assert_eq!(received["rejected_count"], 0);
    let reloaded = call(&received["state"], json!({"op":"view"})).unwrap();
    assert!(deliver(&sent, &reloaded, 0, 1)["state"] == reloaded["state"]);
    let receipted = deliver(&received, &sent, 0, 2);
    assert_eq!(receipted["dialogs"][0]["messages"][0]["delivered"], true);
    let response = call(
        &received["state"],
        json!({"op":"send_v2","account":id(&sent),"text":"Ответ без проверки личности"}),
    )
    .unwrap();
    let reply = deliver(&response, &receipted, 1, 3);
    assert_eq!(
        reply["dialogs"][0]["messages"][1]["text"],
        "Ответ без проверки личности"
    );
    let verified = pair(&response, &sent);
    assert_eq!(verified["dialogs"][0]["identity_verified"], true);
    assert!(verified["dialogs"][0]["messages"] == response["dialogs"][0]["messages"]);
    assert!(verified["state"]["legacy"]["identity"] == recipient["state"]["legacy"]["identity"]);
}

fn ready() -> Value {
    let a = active();
    call(&a["state"], json!({"op":"prepare_contact_v2"})).unwrap()
}
fn id(a: &Value) -> String {
    a["request"]["credential"]["account"]
        .as_str()
        .unwrap()
        .into()
}
fn pair(a: &Value, b: &Value) -> Value {
    call(
        &a["state"],
        json!({"op":"pair_contact_v2","text":b["contact"].to_string(),"verified":true}),
    )
    .unwrap()
}
fn deliver(from: &Value, to: &Value, n: usize, sequence: i64) -> Value {
    let mut m = from["outbox"][n].clone();
    m.as_object_mut().unwrap().remove("recipient");
    m["sender"] = json!(id(from));
    m["sequence"] = json!(sequence);
    call(&to["state"], json!({"op":"receive_v2","message":m})).unwrap()
}
#[test]
fn three_users_exchange_independent_e2ee_conversations_and_authenticated_receipts_after_reload() {
    let a = ready();
    let b = ready();
    let c = ready();
    let attempt = call(
        &a["state"],
        json!({"op":"pair_contact_v2","text":b["contact"].to_string(),"verified":true}),
    );
    assert!(
        attempt.is_ok(),
        "verified v2 contacts must enable independent dialogs: {attempt:?}"
    );
    let a = pair(&attempt.unwrap(), &c);
    let b = pair(&b, &a);
    let c = pair(&c, &a);
    assert_eq!(a["dialogs"].as_array().unwrap().len(), 2);
    let b = call(
        &b["state"],
        json!({"op":"send_v2","account":id(&a),"text":"Борис → Анна"}),
    )
    .unwrap();
    let c = call(
        &c["state"],
        json!({"op":"send_v2","account":id(&a),"text":"Света → Анна"}),
    )
    .unwrap();
    assert_eq!(b["outbox"][0]["recipient"], id(&a));
    let a = deliver(&b, &a, 0, 1);
    let a = deliver(&c, &a, 0, 2);
    assert_eq!(a["cursor"], 2);
    let a = call(&a["state"], json!({"op":"view"})).unwrap();
    for (peer, text) in [(&b, "Борис → Анна"), (&c, "Света → Анна")] {
        let dialog = a["dialogs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["account"] == id(peer))
            .unwrap();
        assert_eq!(dialog["messages"][0]["text"], text);
        let index = a["outbox"]
            .as_array()
            .unwrap()
            .iter()
            .position(|m| m["recipient"] == id(peer))
            .unwrap();
        let delivered = deliver(&a, peer, index, 3);
        assert_eq!(delivered["dialogs"][0]["messages"][0]["delivered"], true);
    }
    let replay = deliver(&b, &a, 0, 1);
    assert_eq!(
        replay["state"], a["state"],
        "exact retry must not duplicate or ratchet"
    );
    assert!(call(
        &a["state"],
        json!({"op":"pair_contact_v2","text":b["contact"].to_string(),"verified":false})
    )
    .is_err());
}
fn active() -> Value {
    let a = upgrade(&create());
    call(
        &a["state"],
        json!({"op":"server_status_v2","status":status(&a)}),
    )
    .unwrap()
}
#[test]
fn reusable_contact_extension_is_signed_persisted_and_keeps_the_original_binding() {
    let a = active();
    let prepared = call(&a["state"], json!({"op":"prepare_contact_v2"}));
    assert!(
        prepared.is_ok(),
        "v2 contact requires a real fallback key: {prepared:?}"
    );
    let prepared = prepared.unwrap();
    let qr = &prepared["contact"];
    assert_eq!(qr["type"], "paranoid-contact-v2");
    assert_eq!(qr["credential"], a["request"]["credential"]);
    assert_eq!(qr["bundle"], a["public"]);
    assert_ne!(qr["fallback_key"], qr["bundle"]["one_time_key"]);
    assert_eq!(
        prepared["state"]["legacy"]["identity"],
        a["state"]["legacy"]["identity"]
    );
    let again = call(&prepared["state"], json!({"op":"prepare_contact_v2"})).unwrap();
    assert_eq!(prepared["state"], again["state"]);
    let b = active();
    let preview = |q: &Value| {
        call(
            &b["state"],
            json!({"op":"contact_text_v2","text":q.to_string()}),
        )
    };
    assert_eq!(
        preview(qr).unwrap()["fingerprint"],
        prepared["contact_fingerprint"]
    );
    for field in ["signature", "fallback_key"] {
        let mut bad = qr.clone();
        bad[field] = json!("bad");
        assert!(preview(&bad).is_err());
    }
    let duplicate = qr
        .to_string()
        .replacen('{', "{\"fallback_key\":\"bad\",", 1);
    assert!(call(
        &b["state"],
        json!({"op":"contact_text_v2","text":duplicate})
    )
    .is_err());
}
fn upgrade(a: &Value) -> Value {
    call(&a["state"], json!({"op":"upgrade_v2"})).unwrap()
}
fn status(a: &Value) -> Value {
    let c: Credential = serde_json::from_value(a["request"]["credential"].clone()).unwrap();
    json!({"mode":"active","account":c.account,"device":c.device,"credential":c.fingerprint()})
}
#[test]
fn v2_status_activates_only_the_exact_saved_credential_without_legacy_alias_changes() {
    let a = upgrade(&create());
    let good = status(&a);
    let active = call(&a["state"], json!({"op":"server_status_v2","status":good}));
    assert!(
        active.is_ok(),
        "v2 status must not require a grant: {active:?}"
    );
    let active = active.unwrap();
    assert_eq!(active["enrollment"], good);
    assert_eq!(active["state"]["legacy"], a["state"]["legacy"]);
    for field in ["mode", "account", "device", "credential"] {
        let mut bad = good.clone();
        bad[field] = json!("changed");
        assert!(call(&a["state"], json!({"op":"server_status_v2","status":bad})).is_err());
    }
}
#[test]
fn migration_retains_installed_identity_and_every_legacy_field() {
    let a = create();
    let upgraded = call(&a["state"], json!({"op":"upgrade_v2"}));
    assert!(
        upgraded.is_ok(),
        "v2 must wrap, not reset the installed client: {upgraded:?}"
    );
    let upgraded = upgraded.unwrap();
    assert_eq!(upgraded["state"]["legacy"], a["state"]);
    assert_eq!(upgraded["request"], a["request"]);
    let again = call(&upgraded["state"], json!({"op":"upgrade_v2"})).unwrap();
    assert_eq!(again["state"], upgraded["state"]);
    let mut bad = a["state"].clone();
    bad["account"] = json!({});
    assert!(call(&bad, json!({"op":"upgrade_v2"})).is_err());
}
#[test]
fn v2_proof_uses_retained_identity_without_grant_and_rejects_context_substitution() {
    let a = create();
    let c: Credential = serde_json::from_value(a["request"]["credential"].clone()).unwrap();
    let ch = json!({"id":uuid::Uuid::new_v4().to_string(),"nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","epoch":uuid::Uuid::new_v4().to_string(),"expires":9999999999i64,"realm":c.realm,"pin":c.pin,"account":c.account,"device":c.device,"credential":c.fingerprint(),"purpose":"register","method":"POST","path":"/v2/registration/commit","body":digest(b"{}")});
    let request = |ch: &Value| json!({"op":"sign_request_v2","challenge":ch,"method":"POST","path":"/v2/registration/commit","body":"{}"});
    let result = call(&a["state"], request(&ch));
    assert!(
        result.is_ok(),
        "saved ID must sign v2 without a grant: {result:?}"
    );
    let result = result.unwrap();
    let auth = result["authorization"].as_str().unwrap();
    assert!(auth.starts_with("ParanoidV2 "));
    let fields = [
        "id",
        "nonce",
        "epoch",
        "expires",
        "realm",
        "pin",
        "account",
        "device",
        "credential",
        "purpose",
        "method",
        "path",
        "body",
    ];
    let strings: Vec<String> = fields
        .iter()
        .map(|f| {
            if *f == "expires" {
                ch[f].to_string()
            } else {
                ch[f].as_str().unwrap().to_owned()
            }
        })
        .collect();
    let mut fields = vec!["paranoid-proof-v2"];
    fields.extend(strings.iter().map(String::as_str));
    paranoid_key_protocol::verify(
        &c.auth,
        &transcript(&fields),
        auth.split_once('.').unwrap().1,
    )
    .unwrap();
    for field in [
        "realm",
        "pin",
        "account",
        "device",
        "credential",
        "purpose",
        "path",
        "body",
    ] {
        let mut bad = ch.clone();
        bad[field] = json!("substituted");
        assert!(
            call(&a["state"], request(&bad)).is_err(),
            "accepted substituted {field}"
        );
    }
}
