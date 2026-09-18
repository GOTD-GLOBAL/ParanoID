use base64::{engine::general_purpose::STANDARD, Engine};
use paranoid_client_core::command;
use serde_json::{json, Value};

fn call(s: &Value, r: Value) -> Result<Value, &'static str> {
    command(&s.to_string(), &r.to_string()).map(|v| serde_json::from_str(&v).unwrap())
}
fn ready() -> Value {
    let a: Value = serde_json::from_str(
        &command(
            "",
            &json!({"op":"create_identity","realm":"https://127.0.0.2:38443","pin":"a".repeat(64)})
                .to_string(),
        )
        .unwrap(),
    )
    .unwrap();
    let a = call(&a["state"], json!({"op":"upgrade_v2"})).unwrap();
    let c = &a["request"]["credential"];
    let a = call(&a["state"], json!({"op":"server_status_v2","status":{"mode":"active","account":c["account"],"device":c["device"],"credential":paranoid_key_protocol::digest(&credential_bytes(c))}})).unwrap();
    call(&a["state"], json!({"op":"prepare_contact_v2"})).unwrap()
}
fn credential_bytes(c: &Value) -> Vec<u8> {
    let c: paranoid_key_protocol::Credential = serde_json::from_value(c.clone()).unwrap();
    c.bytes()
}
fn id(a: &Value) -> &str {
    a["request"]["credential"]["account"].as_str().unwrap()
}
fn pair(a: &Value, b: &Value) -> Value {
    call(
        &a["state"],
        json!({"op":"pair_contact_v2","text":b["contact"].to_string(),"verified":true}),
    )
    .unwrap()
}
fn send(a: &Value, b: &Value, text: &str) -> Value {
    call(
        &a["state"],
        json!({"op":"send_v2","account":id(b),"text":text}),
    )
    .unwrap()
}
fn incoming(a: &Value, n: usize, seq: i64) -> Value {
    let mut m = a["outbox"][n].clone();
    m.as_object_mut().unwrap().remove("recipient");
    m["sender"] = json!(id(a));
    m["sequence"] = json!(seq);
    m
}
fn receive(b: &Value, m: Value) -> Value {
    call(&b["state"], json!({"op":"receive_v2","message":m})).unwrap()
}
fn send_at(a: &Value, b: &Value, text: &str, now_ms: u64) -> Value {
    call(
        &a["state"],
        json!({"op":"send_v2","account":id(b),"text":text,"now_ms":now_ms}),
    )
    .unwrap()
}
fn receive_at(b: &Value, m: Value, now_ms: u64) -> Value {
    call(
        &b["state"],
        json!({"op":"receive_v2","message":m,"now_ms":now_ms}),
    )
    .unwrap()
}
fn messages<'a>(view: &'a Value, account: &str) -> &'a Vec<Value> {
    view["dialogs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["account"] == json!(account))
        .unwrap()["messages"]
        .as_array()
        .unwrap()
}
fn reopen(a: &Value) -> Value {
    call(&a["state"], json!({"op":"view"})).unwrap()
}
// Independent LP encoding: the contract checks must not reuse the production
// transcript encoder to construct expected signed channel/envelope bytes.
fn lp(fields: &[&str]) -> Vec<u8> {
    let mut bytes = Vec::new();
    for field in fields {
        bytes.extend((field.len() as u32).to_be_bytes());
        bytes.extend(field.as_bytes());
    }
    bytes
}

fn contact_fingerprint(c: &Value) -> String {
    let credential: paranoid_key_protocol::Credential =
        serde_json::from_value(c["credential"].clone()).unwrap();
    paranoid_key_protocol::digest(&lp(&[
        "paranoid-contact-v2",
        &credential.fingerprint(),
        c["bundle"]["device"].as_str().unwrap(),
        c["bundle"]["realm"].as_str().unwrap(),
        c["bundle"]["curve"].as_str().unwrap(),
        c["bundle"]["one_time_key"].as_str().unwrap(),
        c["fallback_key"].as_str().unwrap(),
    ]))
}
fn channel(a: &Value, b: &Value) -> String {
    let (lo, hi) = if id(a) < id(b) { (a, b) } else { (b, a) };
    let lc: paranoid_key_protocol::Credential =
        serde_json::from_value(lo["contact"]["credential"].clone()).unwrap();
    let hc: paranoid_key_protocol::Credential =
        serde_json::from_value(hi["contact"]["credential"].clone()).unwrap();
    paranoid_key_protocol::digest(&lp(&[
        "paranoid-first-contact-channel-v1",
        &lc.account,
        &lc.device,
        &lc.fingerprint(),
        &contact_fingerprint(&lo["contact"]),
        &hc.account,
        &hc.device,
        &hc.fingerprint(),
        &contact_fingerprint(&hi["contact"]),
        &lc.realm,
        &lc.pin,
        "account-id-intro-v1",
    ]))
}
fn plain(a: &Value, b: &Value, id: &str, kind: &str, body: Value) -> Value {
    json!({"v":1,"channel":channel(a,b),"realm":a["public"]["realm"],"from":self::id(a),"to":self::id(b),"id":id,"kind":kind,"body":body})
}
fn resign(a: &Value, intro: &mut Value) {
    let inner = STANDARD
        .decode(intro["ciphertext"].as_str().unwrap())
        .unwrap();
    let t = lp(&[
        "paranoid-sender-intro-v2",
        &contact_fingerprint(&intro["contact"]),
        intro["recipient_account"].as_str().unwrap(),
        intro["recipient_device"].as_str().unwrap(),
        intro["recipient_credential"].as_str().unwrap(),
        intro["recipient_contact"].as_str().unwrap(),
        intro["id"].as_str().unwrap(),
        intro["profile"].as_str().unwrap(),
        intro["channel"].as_str().unwrap(),
        &paranoid_key_protocol::digest(&inner),
    ]);
    let auth = vodozemac::Ed25519SecretKey::from_base64(
        a["state"]["legacy"]["identity"]["auth_secret"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    intro["signature"] = json!(auth.sign(&t).to_base64());
}
fn wrap(intro: &Value) -> String {
    let mut bytes = vec![2];
    bytes.extend(intro.to_string().as_bytes());
    STANDARD.encode(bytes)
}
fn forge(a: &Value, b: &Value, mid: &str, raw_plain: &str, seq: i64) -> Value {
    let account = vodozemac::olm::Account::from_pickle(
        serde_json::from_value(a["state"]["legacy"]["account"].clone()).unwrap(),
    );
    let mut session = account
        .create_outbound_session(
            vodozemac::olm::SessionConfig::version_1(),
            vodozemac::Curve25519PublicKey::from_base64(
                b["contact"]["bundle"]["curve"].as_str().unwrap(),
            )
            .unwrap(),
            vodozemac::Curve25519PublicKey::from_base64(
                b["contact"]["fallback_key"].as_str().unwrap(),
            )
            .unwrap(),
        )
        .unwrap();
    let (kind, bytes) = session.encrypt(raw_plain.as_bytes()).unwrap().to_parts();
    let mut inner = vec![kind as u8];
    inner.extend(bytes);
    let bc: paranoid_key_protocol::Credential =
        serde_json::from_value(b["contact"]["credential"].clone()).unwrap();
    let mut intro = json!({"type":"paranoid-sender-intro-v2","contact":a["contact"],"recipient_account":id(b),"recipient_device":bc.device,
        "recipient_credential":bc.fingerprint(),"recipient_contact":contact_fingerprint(&b["contact"]),"id":mid,"profile":"account-id-intro-v1",
        "channel":channel(a,b),"ciphertext":STANDARD.encode(inner),"signature":""});
    resign(a, &mut intro);
    json!({"sender":id(a),"id":mid,"sequence":seq,"ciphertext":wrap(&intro)})
}
fn assert_only_notice(before: &Value, after: &Value, reason: &str) {
    assert_eq!(after["acceptance"], "rejected");
    assert_eq!(after["rejection_reason"], reason);
    let mut actual = after["state"].clone();
    for f in ["rejected_events", "rejected_count", "cursor"] {
        actual[f] = before["state"][f].clone();
    }
    assert!(actual==before["state"],"rejected candidate changed private Account, pins, sessions, history, outbox, commitments or replay state");
}

#[test]
fn duplicate_nested_receipt_fields_are_not_collapsed_before_validation() {
    let a = ready();
    let b = ready();
    let a = send(&pair(&a, &b), &b, "target");
    let target = a["state"]["conversations"][id(&b)]["commitments"]
        [a["outbox"][0]["id"].as_str().unwrap()]
    .clone();
    let mid = uuid::Uuid::new_v4().to_string();
    let p = plain(&b, &a, &mid, "receipt", target.clone());
    let raw = p.to_string().replace(
        "\"target_id\":",
        &format!("\"target_id\":{},\"target_id\":", target["target_id"]),
    );
    let rejected = receive(&a, forge(&b, &a, &mid, &raw, 1));
    assert_only_notice(&a, &rejected, "invalid_plaintext");
}

#[test]
fn server_acceptance_preserves_local_pending_channel_and_exact_commitment() {
    let a = ready();
    let b = ready();
    let a = send(&pair(&a, &b), &b, "pending");
    let accepted = call(
        &a["state"],
        json!({"op":"accepted_v2","id":a["outbox"][0]["id"]}),
    )
    .unwrap();
    assert_eq!(accepted["dialogs"][0]["channel_state"], "local_pending");
    assert_eq!(
        accepted["state"]["conversations"][id(&b)]["commitments"],
        a["state"]["conversations"][id(&b)]["commitments"]
    );
    assert_eq!(accepted["dialogs"][0]["messages"][0]["delivered"], false);
}

#[test]
fn independently_derived_channel_crossing_texts_and_receipts_share_two_sessions() {
    let a = ready();
    let b = ready();
    let a = pair(&a, &b);
    let b = pair(&b, &a);
    assert_eq!(a["dialogs"][0]["channel"], channel(&a, &b));
    assert_eq!(b["dialogs"][0]["channel"], channel(&b, &a));
    let a = send(&a, &b, "cross A");
    let b = send(&b, &a, "cross B");
    let a_received = receive(&a, incoming(&b, 0, 1));
    let b_received = receive(&b, incoming(&a, 0, 2));
    let a = receive(&a_received, incoming(&b_received, 1, 3));
    let b = receive(&b_received, incoming(&a_received, 1, 4));
    assert_eq!(a["dialogs"][0]["messages"][0]["delivered"], true);
    assert_eq!(b["dialogs"][0]["messages"][0]["delivered"], true);
    assert_eq!(a["dialogs"][0]["messages"][1]["text"], "cross B");
    assert_eq!(b["dialogs"][0]["messages"][1]["text"], "cross A");
    assert_eq!(
        a["state"]["conversations"][id(&b)]["sessions"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        b["state"]["conversations"][id(&a)]["sessions"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert!(reopen(&a)["state"] == a["state"]);
    for actor in [&a, &b] {
        assert!(actor["state"]["legacy"]["account"].is_object());
        for conv in actor["state"]["conversations"]
            .as_object()
            .unwrap()
            .values()
        {
            assert!(conv.get("account").is_none());
            assert!(conv.get("identity").is_none());
        }
    }
}

#[test]
fn signed_wrong_inner_context_and_strict_json_roll_back_entire_state() {
    let a = ready();
    let b = ready();
    let mid = uuid::Uuid::new_v4().to_string();
    let valid = plain(&a, &b, &mid, "text", json!("must not appear"));
    for (field, bad) in [
        ("v", json!(0)),
        ("v", json!(2)),
        ("channel", json!("f".repeat(64))),
        ("realm", json!("https://elsewhere")),
        ("from", json!(id(&b))),
        ("to", json!(id(&a))),
        ("id", json!(uuid::Uuid::new_v4().to_string())),
    ] {
        let mut p = valid.clone();
        p[field] = bad;
        for receiver in [&b, &pair(&b, &a)] {
            assert_only_notice(
                receiver,
                &receive(receiver, forge(&a, &b, &mid, &p.to_string(), 1)),
                "context_mismatch",
            );
        }
    }
    for raw in [
        valid.to_string().replace("\"v\":1", "\"v\":1,\"v\":1"),
        valid.to_string().replace("\"v\":1", "\"extra\":0,\"v\":1"),
    ] {
        assert_only_notice(
            &b,
            &receive(&b, forge(&a, &b, &mid, &raw, 1)),
            "invalid_plaintext",
        );
    }
    for p in [
        plain(&a, &b, &mid, "text", json!("")),
        plain(&a, &b, &mid, "text", json!("x".repeat(2049))),
    ] {
        assert_only_notice(
            &b,
            &receive(&b, forge(&a, &b, &mid, &p.to_string(), 1)),
            "invalid_text",
        );
    }
    assert_eq!(
        receive(&b, forge(&a, &b, &mid, &valid.to_string(), 1))["acceptance"],
        "accepted"
    );
}

#[test]
fn wrong_signatures_stripping_and_recursive_outer_fields_never_allocate_peer() {
    let a = ready();
    let b = ready();
    let a = send(&pair(&a, &b), &b, "authenticated");
    let base = incoming(&a, 0, 1);
    let raw = STANDARD
        .decode(base["ciphertext"].as_str().unwrap())
        .unwrap();
    let intro: Value = serde_json::from_slice(&raw[1..]).unwrap();
    let mut variants = Vec::new();
    let mut stripped = base.clone();
    stripped["ciphertext"] = intro["ciphertext"].clone();
    variants.push(stripped);
    for field in [
        "signature",
        "recipient_account",
        "recipient_device",
        "recipient_credential",
        "recipient_contact",
        "id",
        "profile",
        "channel",
    ] {
        let mut i = intro.clone();
        i[field] = json!("bad");
        let mut m = base.clone();
        m["ciphertext"] = json!(wrap(&i));
        variants.push(m);
    }
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
        let mut i = intro.clone();
        i["contact"]["credential"][field] = json!("bad");
        let mut m = base.clone();
        m["ciphertext"] = json!(wrap(&i));
        variants.push(m);
    }
    for raw in [
        intro
            .to_string()
            .replace("\"profile\":", "\"unknown\":0,\"profile\":"),
        intro.to_string().replace(
            "\"profile\":",
            "\"profile\":\"account-id-intro-v1\",\"profile\":",
        ),
        intro.to_string().replace(
            "\"fallback_key\":",
            "\"fallback_key\":\"duplicate\",\"fallback_key\":",
        ),
    ] {
        let mut bytes = vec![2];
        bytes.extend(raw.as_bytes());
        let mut m = base.clone();
        m["ciphertext"] = json!(STANDARD.encode(bytes));
        variants.push(m);
    }
    for malformed in ["%".into(), STANDARD.encode(vec![2; 16385])] {
        let mut m = base.clone();
        m["ciphertext"] = json!(malformed);
        variants.push(m);
    }
    for m in variants {
        let rejected = receive(&b, m);
        let reason = rejected["rejection_reason"].as_str().unwrap();
        assert_only_notice(&b, &rejected, reason);
    }
    let mut nested = intro.clone();
    nested["ciphertext"] = base["ciphertext"].clone();
    resign(&a, &mut nested);
    let mut m = base;
    m["ciphertext"] = json!(wrap(&nested));
    assert_only_notice(&b, &receive(&b, m), "invalid_introduction");
}

#[test]
fn unknown_receipt_and_every_wrong_commitment_target_roll_back() {
    let a = ready();
    let b = ready();
    let mid = uuid::Uuid::new_v4().to_string();
    let target = json!({"target_channel":channel(&a,&b),"target_sender":id(&b),"target_id":uuid::Uuid::new_v4().to_string(),"target_inner_digest":"a".repeat(64)});
    assert_only_notice(
        &b,
        &receive(
            &b,
            forge(
                &a,
                &b,
                &mid,
                &plain(&a, &b, &mid, "receipt", target).to_string(),
                1,
            ),
        ),
        "unknown_receipt",
    );
    let a = send(&pair(&a, &b), &b, "known target");
    let target = a["state"]["conversations"][id(&b)]["commitments"]
        [a["outbox"][0]["id"].as_str().unwrap()]
    .clone();
    for field in [
        "target_channel",
        "target_sender",
        "target_id",
        "target_inner_digest",
    ] {
        let mut wrong = target.clone();
        wrong[field] = json!("f".repeat(64));
        assert_only_notice(
            &a,
            &receive(
                &a,
                forge(
                    &b,
                    &a,
                    &mid,
                    &plain(&b, &a, &mid, "receipt", wrong).to_string(),
                    1,
                ),
            ),
            "unknown_receipt",
        );
    }
}

#[test]
fn replay_ledger_binds_sender_uuid_sequence_exact_outer_and_survives_reload() {
    let a = ready();
    let b = ready();
    let c = ready();
    let mid = uuid::Uuid::new_v4().to_string();
    let m = forge(
        &a,
        &b,
        &mid,
        &plain(&a, &b, &mid, "text", json!("one")).to_string(),
        1,
    );
    let received = reopen(&receive(&b, m.clone()));
    assert!(receive(&received, m.clone())["state"] == received["state"]);
    for (field, value) in [("sequence", json!(2)), ("ciphertext", json!("malformed"))] {
        let mut changed = m.clone();
        changed[field] = value;
        assert_eq!(
            call(
                &received["state"],
                json!({"op":"receive_v2","message":changed})
            )
            .err(),
            Some("conflicting_replay")
        );
    }
    let bytes = STANDARD.decode(m["ciphertext"].as_str().unwrap()).unwrap();
    let mut i: Value = serde_json::from_slice(&bytes[1..]).unwrap();
    i["profile"] = json!("wrong");
    resign(&a, &mut i);
    let mut changed = m.clone();
    changed["ciphertext"] = json!(wrap(&i));
    assert_eq!(
        call(
            &received["state"],
            json!({"op":"receive_v2","message":changed})
        )
        .err(),
        Some("conflicting_replay")
    );
    let same_id_other = forge(
        &c,
        &b,
        &mid,
        &plain(&c, &b, &mid, "text", json!("different sender")).to_string(),
        2,
    );
    let two = receive(&received, same_id_other.clone());
    assert_eq!(two["dialogs"].as_array().unwrap().len(), 2);
    assert_eq!(two["state"]["events"].as_object().unwrap().len(), 2);
    let mut sequence_conflict = same_id_other;
    sequence_conflict["sequence"] = json!(1);
    assert_eq!(
        call(
            &received["state"],
            json!({"op":"receive_v2","message":sequence_conflict})
        )
        .err(),
        Some("conflicting_replay")
    );
}

#[test]
fn genuine_changed_same_root_fallback_and_stale_signature_are_rejected() {
    let a = ready();
    let b = ready();
    let pinned = pair(&b, &a);
    let mut changed = a.clone();
    changed["contact"]["fallback_key"] = json!(vodozemac::Curve25519PublicKey::from(
        &vodozemac::Curve25519SecretKey::new()
    )
    .to_base64());
    let c = &changed["contact"];
    let credential: paranoid_key_protocol::Credential =
        serde_json::from_value(c["credential"].clone()).unwrap();
    let t = lp(&[
        "paranoid-contact-v2",
        &credential.fingerprint(),
        c["bundle"]["device"].as_str().unwrap(),
        c["bundle"]["realm"].as_str().unwrap(),
        c["bundle"]["curve"].as_str().unwrap(),
        c["bundle"]["one_time_key"].as_str().unwrap(),
        c["fallback_key"].as_str().unwrap(),
    ]);
    let auth = vodozemac::Ed25519SecretKey::from_base64(
        a["state"]["legacy"]["identity"]["auth_secret"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    changed["contact"]["signature"] = json!(auth.sign(&t).to_base64());
    let mid = uuid::Uuid::new_v4().to_string();
    assert_only_notice(
        &pinned,
        &receive(
            &pinned,
            forge(
                &changed,
                &b,
                &mid,
                &plain(&changed, &b, &mid, "text", json!("no repin")).to_string(),
                1,
            ),
        ),
        "peer_already_pinned",
    );
    assert_eq!(
        call(
            &pinned["state"],
            json!({"op":"pair_contact_v2","text":changed["contact"].to_string(),"verified":true})
        )
        .err(),
        Some("peer_already_pinned")
    );
    let one = forge(
        &a,
        &b,
        &mid,
        &plain(&a, &b, &mid, "text", json!("one")).to_string(),
        1,
    );
    let two = forge(
        &a,
        &b,
        &mid,
        &plain(&a, &b, &mid, "text", json!("two")).to_string(),
        1,
    );
    let mut first: Value = serde_json::from_slice(
        &STANDARD
            .decode(one["ciphertext"].as_str().unwrap())
            .unwrap()[1..],
    )
    .unwrap();
    let second: Value = serde_json::from_slice(
        &STANDARD
            .decode(two["ciphertext"].as_str().unwrap())
            .unwrap()[1..],
    )
    .unwrap();
    first["ciphertext"] = second["ciphertext"].clone();
    let mut forged = one;
    forged["ciphertext"] = json!(wrap(&first));
    let rejected = receive(&b, forged);
    assert_only_notice(
        &b,
        &rejected,
        rejected["rejection_reason"].as_str().unwrap(),
    );
}

#[test]
fn budgets_bound_unverified_and_total_peers_without_eviction_and_block_preserves_keys() {
    let mut b = ready();
    let mut first = None;
    let mut last = None;
    for n in 1..=17 {
        let a = ready();
        let a = send(&pair(&a, &b), &b, "bounded stranger");
        let received = receive(&b, incoming(&a, 0, n));
        if n <= 16 {
            assert_eq!(received["acceptance"], "accepted");
            if n == 1 {
                first = Some(a.clone());
            }
            b = received;
        } else {
            assert_only_notice(&b, &received, "unverified_contact_limit");
            last = Some(a);
            b = received;
        }
    }
    assert_eq!(b["dialogs"].as_array().unwrap().len(), 16);
    let first = first.unwrap();
    let last = last.unwrap();
    b = pair(&b, &first);
    let after_capacity_freed = send(&last, &b, "new event after capacity freed");
    b = receive(&b, incoming(&after_capacity_freed, 1, 18));
    assert_eq!(b["dialogs"].as_array().unwrap().len(), 17);
    let blocked = call(
        &b["state"],
        json!({"op":"block_contact_v2","account":id(&first),"blocked":true}),
    )
    .unwrap();
    assert_eq!(
        call(
            &blocked["state"],
            json!({"op":"send_v2","account":id(&first),"text":"blocked"})
        )
        .err(),
        Some("contact_blocked")
    );
    let later = send(&first, &b, "blocked inbound");
    let rejected = receive(&blocked, incoming(&later, 1, 19));
    assert_only_notice(&blocked, &rejected, "contact_blocked");
    let unblocked = call(
        &rejected["state"],
        json!({"op":"block_contact_v2","account":id(&first),"blocked":false}),
    )
    .unwrap();
    assert_eq!(
        unblocked["state"]["conversations"][id(&first)]["contact"],
        b["state"]["conversations"][id(&first)]["contact"]
    );
    let newest = send(&later, &b, "after unblock");
    b = receive(&unblocked, incoming(&newest, 2, 20));
    assert_eq!(b["acceptance"], "accepted");
    for _ in 17..64 {
        b = pair(&b, &ready());
    }
    assert_eq!(b["dialogs"].as_array().unwrap().len(), 64);
    let extra = ready();
    assert_eq!(
        call(
            &b["state"],
            json!({"op":"pair_contact_v2","text":extra["contact"].to_string(),"verified":true})
        )
        .err(),
        Some("contact_limit")
    );
    let extra = send(&pair(&extra, &b), &b, "65th");
    assert_only_notice(&b, &receive(&b, incoming(&extra, 0, 21)), "contact_limit");
}

// Synthetic local quota prefill exercises defensive boundaries without thousands
// of network fixture writes. Incoming bytes and Olm decrypt/signatures are real.
#[test]
fn post_decrypt_receipt_outbox_capacity_discards_account_and_ratchets() {
    let a = ready();
    let b = ready();
    let a = send(&pair(&a, &b), &b, "real first");
    let received = receive(&b, incoming(&a, 0, 1));
    let mut full = received.clone();
    let c = &mut full["state"]["conversations"][id(&a)];
    let base = c["outbox"][0].clone();
    let rows = c["outbox"].as_array_mut().unwrap();
    while rows.len() < 400 {
        let mut row = base.clone();
        row["id"] = json!(uuid::Uuid::new_v4().to_string());
        rows.push(row);
    }
    let full = reopen(&full);
    let next = send(&a, &b, "decrypted before quota");
    assert_only_notice(&full, &receive(&full, incoming(&next, 1, 2)), "outbox_full");
}

// Owner decision 2026-09-17: conversation history has no ceiling. A snapshot far
// past the retired 200-entry cap still loads, and real decrypted text is still
// committed and visible instead of becoming a capacity notice.
#[test]
fn history_past_the_retired_cap_loads_and_still_accepts_decrypted_text() {
    let a = ready();
    let b = ready();
    let a = send(&pair(&a, &b), &b, "real first");
    let received = receive(&b, incoming(&a, 0, 1));
    let mut full = received.clone();
    let c = &mut full["state"]["conversations"][id(&a)];
    let base = c["history"][0].clone();
    let rows = c["history"].as_array_mut().unwrap();
    while rows.len() < 250 {
        let mut row = base.clone();
        row["id"] = json!(uuid::Uuid::new_v4().to_string());
        rows.push(row);
    }
    let full = reopen(&full);
    let next = send(&a, &b, "past the retired cap");
    let after = receive(&full, incoming(&next, 1, 2));
    assert_eq!(after["acceptance"], "accepted");
    let dialog = after["dialogs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|d| d["account"] == json!(id(&a)))
        .unwrap();
    let messages = dialog["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 251);
    assert_eq!(messages.last().unwrap()["text"], "past the retired cap");
}

#[test]
fn eight_real_inbound_sessions_are_retained_and_ninth_is_rejected_transactionally() {
    let a = ready();
    let mut b = ready();
    for n in 1..=9 {
        let mid = uuid::Uuid::new_v4().to_string();
        let m = forge(
            &a,
            &b,
            &mid,
            &plain(&a, &b, &mid, "text", json!("new session")).to_string(),
            n,
        );
        let result = receive(&b, m);
        if n <= 8 {
            assert_eq!(result["acceptance"], "accepted");
            b = result;
        } else {
            assert_only_notice(&b, &result, "session_limit");
        }
    }
    assert_eq!(
        b["state"]["conversations"][id(&a)]["sessions"]
            .as_array()
            .unwrap()
            .len(),
        8
    );
}

#[test]
fn whole_snapshot_limit_after_unknown_decryption_and_receipt_construction_rolls_back() {
    let a = ready();
    let mut b = ready();
    for _ in 0..21 {
        b = pair(&b, &ready());
    }
    let target = 8 * 1024 * 1024 - 1024;
    let mut length = b["state"].to_string().len();
    let ids: Vec<String> = b["state"]["conversations"]
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    for peer in ids {
        for _ in 0..200 {
            if length >= target {
                break;
            }
            let row = json!({"id":uuid::Uuid::new_v4().to_string(),"author":peer,"text":"x".repeat(2048.min(target-length)),"accepted":true,"delivered":true});
            length += row.to_string().len() + 1;
            b["state"]["conversations"][&peer]["history"]
                .as_array_mut()
                .unwrap()
                .push(row);
        }
        if length >= target {
            break;
        }
    }
    assert!(b["state"].to_string().len() < 8 * 1024 * 1024);
    let b = reopen(&b);
    let a = send(&pair(&a, &b), &b, &"y".repeat(2048));
    assert_only_notice(&b, &receive(&b, incoming(&a, 0, 1)), "local_state_full");
}

#[test]
fn old_snapshots_refuse_without_reset_and_pristine_registration_identity_reopens() {
    let a = ready();
    let mut old = a["state"].clone();
    old["version"] = json!(2);
    assert_eq!(
        call(&old, json!({"op":"view"})).err(),
        Some("unsupported_state")
    );
    let mut legacy = a["state"]["legacy"].clone();
    legacy["public"]["device"] = json!("alice");
    assert_eq!(
        call(&legacy, json!({"op":"upgrade_v2"})).err(),
        Some("unsupported_state")
    );
    assert_eq!(reopen(&a)["request"], a["request"]);
    let upgraded = call(&a["state"]["legacy"], json!({"op":"upgrade_v2"})).unwrap();
    assert_eq!(upgraded["request"], a["request"]);
    assert_eq!(upgraded["state"]["version"], 3);
}

#[test]
fn valid_outer_signature_with_corrupt_olm_and_full_inbox_never_commit_crypto_state() {
    let a = ready();
    let b = ready();
    let a = send(&pair(&a, &b), &b, "authenticated frame");
    let mut m = incoming(&a, 0, 1);
    let raw = STANDARD.decode(m["ciphertext"].as_str().unwrap()).unwrap();
    let mut intro: Value = serde_json::from_slice(&raw[1..]).unwrap();
    let mut inner = STANDARD
        .decode(intro["ciphertext"].as_str().unwrap())
        .unwrap();
    *inner.last_mut().unwrap() ^= 1;
    intro["ciphertext"] = json!(STANDARD.encode(inner));
    resign(&a, &mut intro);
    m["ciphertext"] = json!(wrap(&intro));
    assert_only_notice(&b, &receive(&b, m), "decryption_failed");

    let mut full = receive(&b, incoming(&a, 0, 1));
    let original = full["state"]["events"]
        .as_object()
        .unwrap()
        .values()
        .next()
        .unwrap()
        .clone();
    for sequence in 2..=1000 {
        let mut event = original.clone();
        let mid = uuid::Uuid::new_v4().to_string();
        event["id"] = json!(mid);
        event["sequence"] = json!(sequence);
        full["state"]["events"][format!("{}:{}", id(&a), mid)] = event;
    }
    full["state"]["cursor"] = json!(1000);
    let full = reopen(&full);
    let next = send(&a, &b, "over replay budget");
    assert_only_notice(
        &full,
        &receive(&full, incoming(&next, 1, 1001)),
        "invalid_or_full_inbox",
    );
}

#[test]
fn stripped_v1_is_also_rejected_by_the_unchanged_historical_v0_decoder() {
    let a = ready();
    let b = ready();
    let a = send(&pair(&a, &b), &b, "new strict context");
    let mut message = incoming(&a, 0, 1);
    let bytes = STANDARD
        .decode(message["ciphertext"].as_str().unwrap())
        .unwrap();
    let intro: Value = serde_json::from_slice(&bytes[1..]).unwrap();
    message["ciphertext"] = intro["ciphertext"].clone();
    // Synthetic old account-ID-v0 adapter with the matching shared Account.
    // Nothing migrates/rewrites a phone snapshot or changes the old decoder.
    let mut old = b["state"]["legacy"].clone();
    old["public"]["device"] = json!(id(&b));
    old["peer"] = a["contact"]["bundle"].clone();
    old["peer"]["device"] = json!(id(&a));
    let rejected = call(&old, json!({"op":"receive","message":message})).unwrap();
    assert_eq!(
        rejected["state"]["rejected_events"][0]["reason"],
        "invalid_plaintext"
    );
    for field in ["account", "sessions", "history", "outbox", "seen"] {
        assert_eq!(rejected["state"][field], old[field]);
    }
}

#[test]
fn exact_wire_limit_and_equivalent_json_reencoding_have_distinct_replay_commitments() {
    let a = ready();
    let b = ready();
    let a = send(&pair(&a, &b), &b, "exact wire limit");
    let original = incoming(&a, 0, 1);
    let mut frame = STANDARD
        .decode(original["ciphertext"].as_str().unwrap())
        .unwrap();
    assert!(frame.len() < 16384);
    frame.resize(16384, b' ');
    let mut maximum = original.clone();
    maximum["ciphertext"] = json!(STANDARD.encode(&frame));
    let received = receive(&b, maximum.clone());
    assert_eq!(received["acceptance"], "accepted");
    assert!(receive(&reopen(&received), maximum)["state"] == received["state"]);
    assert_eq!(
        call(
            &received["state"],
            json!({"op":"receive_v2","message":original})
        )
        .err(),
        Some("conflicting_replay")
    );
    frame.push(b' ');
    let mut over = incoming(&a, 0, 1);
    over["ciphertext"] = json!(STANDARD.encode(frame));
    assert_only_notice(&b, &receive(&b, over), "invalid_introduction");
}

// REQ-MSG-005 / REQ-MSG-003: real native crypto, no recipient pairing.
#[test]
fn zero_contact_plaintext_reply_receipts_and_clean_reopen() {
    let a = ready();
    let b = ready();
    assert_eq!(b["dialogs"], json!([]));
    let a = send(&pair(&a, &b), &b, "Привет без подтверждения");
    let original = a["outbox"][0].clone();
    let raw = STANDARD
        .decode(original["ciphertext"].as_str().unwrap())
        .unwrap();
    assert_eq!(
        raw[0], 2,
        "all new text must be durably wrapped before network"
    );
    let m = incoming(&a, 0, 1);
    let b = receive(&b, m.clone());
    assert_eq!(b["acceptance"], "accepted");
    assert_eq!(
        b["dialogs"][0]["messages"][0]["text"],
        "Привет без подтверждения"
    );
    assert_eq!(b["dialogs"][0]["trust"], "network_unverified");
    assert_eq!(b["dialogs"][0]["identity_verified"], false);
    let b = reopen(&b);
    let duplicate = receive(&b, m);
    assert_eq!(duplicate["acceptance"], "exact_duplicate");
    assert!(duplicate["state"] == b["state"]);
    let a = call(&a["state"], json!({"op":"accepted_v2","id":original["id"]})).unwrap();
    let a = receive(&reopen(&a), incoming(&b, 0, 2));
    assert_eq!(a["dialogs"][0]["messages"][0]["delivered"], true);
    let b = send(&b, &a, "Ответ сразу");
    let a = receive(&a, incoming(&b, 1, 3));
    assert_eq!(a["dialogs"][0]["messages"][1]["text"], "Ответ сразу");
    let b = receive(&b, incoming(&a, 0, 4));
    assert_eq!(b["dialogs"][0]["messages"][1]["delivered"], true);
    let upgraded = pair(&b, &a);
    assert_eq!(upgraded["dialogs"][0]["trust"], "out_of_band_verified");
    assert_eq!(upgraded["cursor"], b["cursor"]);
    assert_eq!(
        upgraded["dialogs"][0]["messages"],
        b["dialogs"][0]["messages"]
    );
    assert_eq!(upgraded["state"]["version"], 3);
}

// Owner decision 2026-09-17: a message carries the time of the device that wrote
// or received it. The core reads no clock of its own — the client passes the
// instant with the operation, exactly as it already does for a call control —
// and nothing about it crosses the wire.
#[test]
fn message_time_is_the_clock_the_client_passed_and_never_reaches_the_wire() {
    let a = ready();
    let b = ready();
    let sent_at = 1_700_000_000_000u64;
    let received_at = 1_700_000_005_000u64;
    let a = send_at(&pair(&a, &b), &b, "first", sent_at);
    assert_eq!(messages(&a, id(&b))[0]["local_ms"], json!(sent_at));

    // The envelope is unchanged: three members and not one more.
    let envelope = a["outbox"][0].as_object().unwrap();
    let mut members: Vec<&str> = envelope.keys().map(String::as_str).collect();
    members.sort_unstable();
    assert_eq!(members, ["ciphertext", "id", "recipient"]);

    // The receiver stamps with its own clock, not the sender's.
    let b = receive_at(&b, incoming(&a, 0, 1), received_at);
    assert_eq!(messages(&b, id(&a))[0]["local_ms"], json!(received_at));

    // It survives a reopen, which is what a relaunch does.
    assert_eq!(
        messages(&reopen(&b), id(&a))[0]["local_ms"],
        json!(received_at)
    );
}

#[test]
fn message_time_survives_acceptance_receipts_and_duplicate_replay() {
    let a = ready();
    let b = ready();
    let sent_at = 1_700_000_000_000;
    let received_at = sent_at + 5_000;
    let a = send_at(&pair(&a, &b), &b, "timed", sent_at);
    let original = incoming(&a, 0, 1);
    let b = receive_at(&b, original.clone(), received_at);
    let before = reopen(&b);
    let replay = receive_at(&before, original, received_at + 90_000);
    assert_eq!(
        replay["state"], before["state"],
        "replay cannot restamp history"
    );
    let a = call(
        &a["state"],
        json!({"op":"accepted_v2","id":a["outbox"][0]["id"]}),
    )
    .unwrap();
    assert_eq!(messages(&a, id(&b))[0]["local_ms"], json!(sent_at));
    let a = receive_at(&a, incoming(&b, 0, 1), received_at + 10_000);
    let rows = messages(&a, id(&b));
    assert_eq!(rows.len(), 1, "receipt is not a timed text row");
    assert_eq!(rows[0]["local_ms"], json!(sent_at));
    assert_eq!(rows[0]["delivered"], true);
    assert_eq!(messages(&reopen(&a), id(&b))[0]["local_ms"], json!(sent_at));
}

#[test]
fn backwards_local_clock_does_not_reorder_or_reject_messages() {
    let a = ready();
    let b = ready();
    let a = send_at(&pair(&a, &b), &b, "first", 2_000);
    let a = send_at(&a, &b, "second", 1_000);
    let b = receive_at(&b, incoming(&a, 0, 1), 4_000);
    let b = receive_at(&b, incoming(&a, 1, 2), 3_000);
    let rows = messages(&b, id(&a));
    assert_eq!(rows[0]["text"], "first");
    assert_eq!(rows[0]["local_ms"], 4_000);
    assert_eq!(rows[1]["text"], "second");
    assert_eq!(rows[1]["local_ms"], 3_000);
    assert_eq!(b["state"]["cursor"], 2);
}

// A conversation written by a build that kept no time still opens, and every
// entry of it is simply without one: nothing is invented for it (REQ-CLIENT-004).
#[test]
fn a_history_written_without_a_time_opens_and_stays_untimed() {
    let a = ready();
    let b = ready();
    let a = send_at(&pair(&a, &b), &b, "first", 1_700_000_000_000);
    let mut older = a.clone();
    for entry in older["state"]["conversations"][id(&b)]["history"]
        .as_array_mut()
        .unwrap()
    {
        entry.as_object_mut().unwrap().remove("local_ms");
    }
    let older = reopen(&older);
    assert!(messages(&older, id(&b))[0].get("local_ms").is_none());

    // And a message sent after that still gets its own.
    let next = send_at(&older, &b, "second", 1_700_000_009_000);
    let rows = messages(&next, id(&b));
    assert!(rows[0].get("local_ms").is_none());
    assert_eq!(rows[1]["local_ms"], json!(1_700_000_009_000u64));
}
