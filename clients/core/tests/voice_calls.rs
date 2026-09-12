//! REQ-CALL-002/003: actual Olm/frame2 authentication and transient call events.
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
fn send(a: &Value, b: &Value, body: Value) -> Value {
    call(
        &a["state"],
        json!({"op":"send_call_v1","account":id(b),"body":body}),
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
fn assert_only_notice(before: &Value, after: &Value) {
    assert_eq!(after["acceptance"], "rejected");
    assert!(after.get("call_event").is_none());
    let mut actual = after["state"].clone();
    for f in ["rejected_events", "rejected_count", "cursor"] {
        actual[f] = before["state"][f].clone();
    }
    assert!(actual==before["state"],"rejected candidate changed private Account, pins, sessions, history, outbox, commitments or replay state");
}

fn audio_sdp(answer: bool) -> String {
    // call-v2 bundled audio + video (H.264 preferred, VP8 mandatory fallback).
    format!(
        "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0 1\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=mid:0\r\na=ice-ufrag:abcd1234\r\na=ice-pwd:abcdefghijklmnopqrstuvwx\r\na=fingerprint:sha-256 {}\r\na=setup:{}\r\na=sendrecv\r\na=rtcp-mux\r\na=rtpmap:111 opus/48000/2\r\na=candidate:1 1 udp 2122260223 127.0.0.1 40000 typ host\r\na=end-of-candidates\r\nm=video 9 UDP/TLS/RTP/SAVPF 96 97 98\r\nc=IN IP4 0.0.0.0\r\na=mid:1\r\na=sendrecv\r\na=rtcp-mux\r\na=rtpmap:96 H264/90000\r\na=rtpmap:97 VP8/90000\r\na=rtpmap:98 rtx/90000\r\na=fmtp:98 apt=97\r\n",
        std::iter::repeat_n("AB", 32).collect::<Vec<_>>().join(":"),
        if answer { "active" } else { "actpass" }
    )
}

fn body(kind: &str) -> Value {
    let media = matches!(kind, "offer" | "answer");
    let offer = audio_sdp(false);
    json!({"v":2,"kind":kind,"call_id":uuid::Uuid::new_v4().to_string(),
        "video":matches!(kind,"knock"|"ready"|"offer"|"answer"|"media"),
        "caller_nonce":"1".repeat(64),"callee_nonce":if kind=="knock" {String::new()} else {"2".repeat(64)},
        "seq":if matches!(kind,"knock"|"ready"){0}else if media{1}else{2},
        "sent_ms":1_789_000_000_000u64,"expires_ms":1_789_000_045_000u64,
        "sdp":if media {audio_sdp(kind=="answer")}else{String::new()},
        "fingerprint":if media{"ab".repeat(32)}else{String::new()},
        "ice_ufrag":if media{"abcd1234"}else{""},"ice_pwd":if media{"abcdefghijklmnopqrstuvwx"}else{""},
        "offer_digest":if matches!(kind,"knock"|"ready"){String::new()}else{paranoid_key_protocol::digest(offer.as_bytes())},
        "reason":if kind=="end"{"hangup"}else{""}})
}

fn known() -> (Value, Value) {
    let a = ready();
    let b = ready();
    (pair(&a, &b), pair(&b, &a))
}

fn event(a: &Value, b: &Value, value: &Value) -> Value {
    let mid = uuid::Uuid::new_v4().to_string();
    forge(
        a,
        b,
        &mid,
        &plain(a, b, &mid, "call", value.clone()).to_string(),
        1,
    )
}

#[test]
fn established_call_controls_are_encrypted_signed_transient_and_never_messages_or_receipts() {
    for kind in ["knock", "ready", "offer", "answer", "heartbeat", "end"] {
        let (a, b) = known();
        let control = body(kind);
        let sent = send(&a, &b, control.clone());
        assert_eq!(sent["outbox"].as_array().unwrap().len(), 1);
        assert!(sent.get("call_event").is_none());
        let received = receive(&b, incoming(&sent, 0, 1));
        assert_eq!(received["acceptance"], "accepted", "{kind}");
        assert_eq!(
            received["call_event"],
            json!({"account":id(&a),"channel":channel(&a,&b),"body":control})
        );
        assert!(received["outbox"].as_array().unwrap().is_empty());
        for state in [&sent, &received] {
            let peer = if id(state) == id(&a) { id(&b) } else { id(&a) };
            assert!(state["state"]["conversations"][peer]["history"]
                .as_array()
                .unwrap()
                .is_empty());
            assert!(state["state"]["conversations"][peer]["commitments"]
                .as_object()
                .unwrap()
                .is_empty());
            assert_eq!(state["dialogs"][0]["trust"], "out_of_band_verified");
        }
    }
}

#[test]
fn exact_control_replay_and_reopen_never_emit_another_call_event() {
    let (a, b) = known();
    let sent = send(&a, &b, body("knock"));
    let envelope = incoming(&sent, 0, 1);
    let received = receive(&b, envelope.clone());
    assert!(received.get("call_event").is_some());
    let reopened = reopen(&received);
    assert!(reopened.get("call_event").is_none());
    // Calls deliberately use persisted cursor/ratchet replay rejection; only
    // text and receipts retain the historical exact-duplicate Event ledger.
    assert!(call(
        &reopened["state"],
        json!({"op":"receive_v2","message":envelope})
    )
    .is_err());
    let mut changed = envelope;
    changed["sequence"] = json!(2);
    assert_only_notice(&received, &receive(&received, changed));
}

#[test]
fn prior_authenticated_text_contact_can_receive_call_without_identity_trust_upgrade() {
    let a = ready();
    let b = ready();
    let a = pair(&a, &b);
    let text = call(
        &a["state"],
        json!({"op":"send_v2","account":id(&b),"text":"Establish a real unverified conversation"}),
    )
    .unwrap();
    let b = receive(&b, incoming(&text, 0, 1));
    assert_eq!(b["dialogs"][0]["trust"], "network_unverified");
    let call = send(&text, &b, body("knock"));
    let received = receive(&b, incoming(&call, 1, 2));
    assert_eq!(received["acceptance"], "accepted");
    assert!(received.get("call_event").is_some());
    assert_eq!(received["dialogs"][0]["trust"], "network_unverified");
    assert_eq!(
        received["dialogs"][0]["messages"],
        b["dialogs"][0]["messages"]
    );
    assert_eq!(received["outbox"], b["outbox"]);
}

#[test]
fn unknown_and_blocked_call_controls_cannot_allocate_or_mutate_crypto_state() {
    let a = ready();
    let b = ready();
    let a = pair(&a, &b);
    let sent = send(&a, &b, body("knock"));
    let rejected = receive(&b, incoming(&sent, 0, 1));
    assert_only_notice(&b, &rejected);
    assert!(rejected["dialogs"].as_array().unwrap().is_empty());

    let b = pair(&b, &a);
    let blocked = call(
        &b["state"],
        json!({"op":"block_contact_v2","account":id(&a),"blocked":true}),
    )
    .unwrap();
    assert_only_notice(&blocked, &receive(&blocked, incoming(&sent, 0, 1)));
    assert!(call(
        &blocked["state"],
        json!({"op":"send_call_v1","account":id(&a),"body":body("knock")})
    )
    .is_err());
    let unpaired = ready();
    assert!(call(
        &unpaired["state"],
        json!({"op":"send_call_v1","account":id(&a),"body":body("knock")})
    )
    .is_err());
}

#[test]
fn call_control_preserves_v8_snapshot_shape_and_exact_retry_bytes() {
    let (a, b) = known();
    let sent = send(&a, &b, body("knock"));
    let keys = |value: &Value| {
        value
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>()
    };
    assert_eq!(keys(&a["state"]), keys(&sent["state"]));
    assert_eq!(
        keys(&a["state"]["conversations"][id(&b)]),
        keys(&sent["state"]["conversations"][id(&b)])
    );
    assert_eq!(sent["state"]["version"], 3);
    assert!(
        sent["state"]["legacy"] == a["state"]["legacy"],
        "call changed retained identity"
    );
    let reopened = reopen(&sent);
    assert_eq!(reopened["outbox"], sent["outbox"]);
    assert!(
        reopened["state"] == sent["state"],
        "reopen changed private state"
    );
    let accepted = call(
        &sent["state"],
        json!({"op":"accepted_v2","id":sent["outbox"][0]["id"]}),
    )
    .unwrap();
    assert!(accepted["outbox"].as_array().unwrap().is_empty());
    assert!(accepted.get("call_event").is_none());
    assert!(accepted["dialogs"][0]["messages"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn flat_call_shape_limits_and_kind_sequences_are_strict_on_send_and_receive() {
    let (a, b) = known();
    let cases = [
        ("v", json!(1)),
        ("v", json!(1.5)),
        ("video", json!("true")),
        ("video", json!(1)),
        ("kind", json!("candidate")),
        ("call_id", json!("00000000-0000-0000-0000-000000000000")),
        ("caller_nonce", json!("A".repeat(64))),
        ("caller_nonce", json!("1".repeat(63))),
        ("callee_nonce", json!("2".repeat(64))),
        ("seq", json!(1)),
        ("seq", json!(-1)),
        ("sent_ms", json!(0)),
        ("expires_ms", json!(1_789_000_000_000u64)),
        ("expires_ms", json!(1_789_000_045_001u64)),
        ("sdp", json!("v=0\r\n")),
        ("fingerprint", json!("ab".repeat(32))),
        ("ice_ufrag", json!("abcd")),
        ("ice_pwd", json!("abcdefghijklmnopqrstuvwx")),
        ("offer_digest", json!("1".repeat(64))),
        ("reason", json!("hangup")),
        ("unrecognized", json!(true)),
    ];
    for (field, value) in cases {
        let mut malformed = body("knock");
        malformed[field] = value;
        assert!(
            call(
                &a["state"],
                json!({"op":"send_call_v1","account":id(&b),"body":malformed})
            )
            .is_err(),
            "{field}"
        );
        assert_only_notice(&b, &receive(&b, event(&a, &b, &malformed)));
    }
    for kind in ["heartbeat", "end"] {
        let mut malformed = body(kind);
        malformed["video"] = json!(true);
        assert!(call(
            &a["state"],
            json!({"op":"send_call_v1","account":id(&b),"body":malformed})
        )
        .is_err());
    }
    for kind in ["ready", "offer", "answer", "heartbeat", "media", "end"] {
        let mut malformed = body(kind);
        malformed["seq"] = if kind == "ready" { json!(1) } else { json!(0) };
        assert!(call(
            &a["state"],
            json!({"op":"send_call_v1","account":id(&b),"body":malformed})
        )
        .is_err());
    }
}

#[test]
fn duplicate_body_keys_are_rejected_without_json_value_normalization() {
    let (a, b) = known();
    let valid = body("knock").to_string();
    for key in ["v", "kind", "call_id", "caller_nonce", "seq", "sdp"] {
        let value = body("knock")[key].clone();
        let raw = format!("{{\"{key}\":{value},{}", &valid[1..]);
        let request = format!(
            "{{\"op\":\"send_call_v1\",\"account\":\"{}\",\"body\":{raw}}}",
            id(&b)
        );
        assert!(command(&a["state"].to_string(), &request).is_err());
        let mid = uuid::Uuid::new_v4().to_string();
        let placeholder = plain(&a, &b, &mid, "call", json!("RAW_BODY")).to_string();
        let encrypted = forge(&a, &b, &mid, &placeholder.replace("\"RAW_BODY\"", &raw), 1);
        assert_only_notice(&b, &receive(&b, encrypted));
    }
}

#[test]
fn sdp_exact_fingerprint_ice_offer_digest_and_audio_only_contract_are_enforced() {
    let (a, b) = known();
    for (field, value) in [
        ("fingerprint", json!("cd".repeat(32))),
        ("ice_ufrag", json!("efgh5678")),
        ("ice_pwd", json!("zyxwvutsrqponmlkjihgfedc")),
        ("offer_digest", json!("3".repeat(64))),
    ] {
        let mut malformed = body("offer");
        malformed[field] = value;
        assert!(
            call(
                &a["state"],
                json!({"op":"send_call_v1","account":id(&b),"body":malformed})
            )
            .is_err(),
            "{field}"
        );
        assert_only_notice(&b, &receive(&b, event(&a, &b, &malformed)));
    }
    let sdp = audio_sdp(false);
    // Lines inserted into the audio section (before the bundled video section).
    let in_audio = |line: &str| sdp.replacen("m=video", &format!("{line}\r\nm=video"), 1);
    let invalid = [
        sdp.replace("m=audio", "m=video"),
        format!("{sdp}m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"),
        sdp[..sdp.find("m=video").unwrap()].to_string(),
        format!("{sdp}m=video 9 UDP/TLS/RTP/SAVPF 96\r\na=mid:2\r\na=sendrecv\r\na=rtcp-mux\r\na=rtpmap:96 VP8/90000\r\n"),
        sdp.replace("a=rtpmap:96 H264/90000\r\na=rtpmap:97 VP8/90000\r\n", "a=rtpmap:96 VP9/90000\r\na=rtpmap:97 AV1/90000\r\n"),
        sdp.replace("a=mid:1\r\na=sendrecv", "a=mid:1\r\na=recvonly"),
        format!("{sdp}a=fingerprint:sha-256 {}\r\n", std::iter::repeat_n("CD", 32).collect::<Vec<_>>().join(":")),
        format!("{sdp}a=ice-ufrag:efgh5678\r\n"),
        format!("{sdp}a=setup:actpass\r\na=setup:actpass\r\n"),
        in_audio(&format!(
            "a=fingerprint:sha-256 {}",
            std::iter::repeat_n("AB", 32).collect::<Vec<_>>().join(":")
        )),
        in_audio("a=ice-ufrag:abcd1234"),
        in_audio("a=rtcp-mux"),
        sdp.replace("UDP/TLS/RTP/SAVPF", "RTP/AVP"),
        sdp.replace("sha-256", "sha-1"),
        sdp.replace("a=rtcp-mux\r\n", ""),
        sdp.replace("opus/48000/2", "PCMU/8000"),
        in_audio("a=rtpmap:111 PCMU/8000"),
        format!("{sdp}a=rtpmap:96 VP8/90000\r\n"),
        sdp.replace("a=sendrecv", "a=inactive"),
        format!(
            "{sdp}{}",
            "a=candidate:2 1 udp 2122260223 127.0.0.1 40001 typ host\r\n".repeat(16)
        ),
        in_audio("a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:abc"),
        format!("{sdp}{}", "a=rtcp-mux\r\n".repeat(256)),
        format!("{sdp}{}", "a=x:y\r\n".repeat(600)),
        format!("{sdp}a=candidate:{}\r\n", "a".repeat(513)),
        format!("{sdp}a=x:{}\r\n", "é".repeat(3072)),
        format!("{sdp}a=x:{}\r\n", "x".repeat(12288)),
    ];
    for (index, sdp) in invalid.into_iter().enumerate() {
        let mut malformed = body("offer");
        malformed["sdp"] = json!(sdp);
        malformed["offer_digest"] = json!(paranoid_key_protocol::digest(sdp.as_bytes()));
        assert!(
            call(
                &a["state"],
                json!({"op":"send_call_v1","account":id(&b),"body":malformed})
            )
            .is_err(),
            "invalid sdp case {index}"
        );
        assert_only_notice(&b, &receive(&b, event(&a, &b, &malformed)));
    }
    {
        let answer = audio_sdp(true);
        let mixed = format!("{answer}a=setup:passive\r\n");
        let mut malformed = body("answer");
        malformed["sdp"] = json!(mixed);
        assert!(
            call(
                &a["state"],
                json!({"op":"send_call_v1","account":id(&b),"body":malformed})
            )
            .is_err(),
            "answer setup active+passive across sections"
        );
        let same = format!("{answer}a=setup:active\r\n");
        let mut accepted = body("answer");
        accepted["sdp"] = json!(same);
        assert!(
            call(
                &a["state"],
                json!({"op":"send_call_v1","account":id(&b),"body":accepted})
            )
            .is_ok(),
            "answer repeated identical setup"
        );
    }
    let valid = [
        format!(
            "{sdp}a=ice-ufrag:abcd1234\r\na=ice-pwd:abcdefghijklmnopqrstuvwx\r\na=fingerprint:sha-256 {}\r\na=setup:actpass\r\n",
            std::iter::repeat_n("AB", 32).collect::<Vec<_>>().join(":")
        ),
        sdp.replace("a=rtpmap:96 H264/90000\r\n", ""),
        sdp.replace("m=video 9", "m=video 0"),
    ];
    for (index, sdp) in valid.into_iter().enumerate() {
        let mut accepted = body("offer");
        accepted["sdp"] = json!(sdp);
        accepted["offer_digest"] = json!(paranoid_key_protocol::digest(sdp.as_bytes()));
        assert!(
            call(
                &a["state"],
                json!({"op":"send_call_v1","account":id(&b),"body":accepted})
            )
            .is_ok(),
            "valid sdp case {index}"
        );
    }
}

#[test]
fn authenticated_call_wrong_inner_or_outer_context_and_ciphertext_tamper_roll_back() {
    let (a, b) = known();
    let good = body("knock");
    for field in ["channel", "realm", "from", "to", "id", "kind"] {
        let mid = uuid::Uuid::new_v4().to_string();
        let mut p = plain(&a, &b, &mid, "call", good.clone());
        p[field] = json!("wrong");
        assert_only_notice(&b, &receive(&b, forge(&a, &b, &mid, &p.to_string(), 1)));
    }
    let sent = send(&a, &b, good);
    let m = incoming(&sent, 0, 1);
    let bytes = STANDARD.decode(m["ciphertext"].as_str().unwrap()).unwrap();
    let intro: Value = serde_json::from_slice(&bytes[1..]).unwrap();
    for field in [
        "recipient_account",
        "recipient_device",
        "recipient_credential",
        "recipient_contact",
        "channel",
        "signature",
    ] {
        let mut changed = intro.clone();
        changed[field] = json!("0".repeat(64));
        let mut bad = m.clone();
        bad["ciphertext"] = json!(wrap(&changed));
        assert_only_notice(&b, &receive(&b, bad));
    }
    let mut altered = intro;
    let mut inner = STANDARD
        .decode(altered["ciphertext"].as_str().unwrap())
        .unwrap();
    let last = inner.len() - 1;
    inner[last] ^= 1;
    altered["ciphertext"] = json!(STANDARD.encode(inner));
    resign(&a, &mut altered);
    let mut bad = m;
    bad["ciphertext"] = json!(wrap(&altered));
    assert_only_notice(&b, &receive(&b, bad));
}

#[test]
fn early_end_has_explicit_empty_context_without_promoting_it_to_media_authority() {
    let (a, b) = known();
    let mut end = body("end");
    end["callee_nonce"] = json!("");
    end["offer_digest"] = json!("");
    end["reason"] = json!("cancel");
    let sent = send(&a, &b, end.clone());
    assert_eq!(
        receive(&b, incoming(&sent, 0, 1))["call_event"]["body"],
        end
    );
    end["offer_digest"] = json!("1".repeat(64));
    assert!(call(
        &a["state"],
        json!({"op":"send_call_v1","account":id(&b),"body":end})
    )
    .is_err());
}

#[test]
fn higher_sequence_replay_of_consumed_call_prekey_never_recreates_a_fallback_session() {
    let (a, b) = known();
    let sent = send(&a, &b, body("knock"));
    let original = incoming(&sent, 0, 1);
    let received = receive(&b, original.clone());
    assert_eq!(received["acceptance"], "accepted");
    assert!(received["state"]["events"].as_object().unwrap().is_empty());
    let reopened = reopen(&received);
    for seq in 2..=10 {
        let mut replay = original.clone();
        replay["sequence"] = json!(seq);
        let rejected = receive(&reopened, replay);
        assert_only_notice(&reopened, &rejected);
        assert_eq!(
            rejected["state"]["conversations"][id(&a)]["sessions"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
}

#[test]
fn retained_session_id_identifies_consumed_reusable_fallback_prekey() {
    // Pin actual vodozemac behavior: consumed ratchets reject replay, but a
    // reusable fallback Account can recreate it. Native must check retained ID.
    let a = ready();
    let b = ready();
    let mid = uuid::Uuid::new_v4().to_string();
    let envelope = forge(&a, &b, &mid, "synthetic primitive proof", 1);
    let outer = STANDARD
        .decode(envelope["ciphertext"].as_str().unwrap())
        .unwrap();
    let intro: Value = serde_json::from_slice(&outer[1..]).unwrap();
    let inner = STANDARD
        .decode(intro["ciphertext"].as_str().unwrap())
        .unwrap();
    let message = vodozemac::olm::OlmMessage::from_parts(inner[0] as usize, &inner[1..]).unwrap();
    let vodozemac::olm::OlmMessage::PreKey(prekey) = &message else {
        panic!("expected real prekey");
    };
    let mut account = vodozemac::olm::Account::from_pickle(
        serde_json::from_value(b["state"]["legacy"]["account"].clone()).unwrap(),
    );
    let peer = vodozemac::Curve25519PublicKey::from_base64(
        a["contact"]["bundle"]["curve"].as_str().unwrap(),
    )
    .unwrap();
    let first = account
        .create_inbound_session(vodozemac::olm::SessionConfig::version_1(), peer, prekey)
        .unwrap();
    let mut retained = first.session;
    assert_eq!(retained.session_id(), prekey.session_id());
    assert!(retained.decrypt(&message).is_err());
    let recreated = account
        .create_inbound_session(vodozemac::olm::SessionConfig::version_1(), peer, prekey)
        .unwrap();
    assert_eq!(recreated.session.session_id(), retained.session_id());
    assert_eq!(recreated.plaintext, first.plaintext);
}

#[test]
fn call_admission_preserves_normal_text_outbox_capacity_and_numeric_bounds() {
    let (mut a, b) = known();
    for _ in 0..16 {
        a = send(&a, &b, body("knock"));
    }
    assert_eq!(a["outbox"].as_array().unwrap().len(), 16);
    assert_eq!(
        call(
            &a["state"],
            json!({"op":"send_call_v1","account":id(&b),"body":body("knock")})
        )
        .err(),
        Some("call_outbox_full")
    );
    let text = call(
        &a["state"],
        json!({"op":"send_v2","account":id(&b),"text":"Text still queues with16 pending controls"}),
    )
    .unwrap();
    assert_eq!(text["outbox"].as_array().unwrap().len(), 17);
    assert_eq!(
        text["dialogs"][0]["messages"][0]["text"],
        "Text still queues with16 pending controls"
    );
    let (a, b) = known();
    for (field, value) in [
        ("seq", json!(2147483648u64)),
        ("sent_ms", json!(u64::MAX)),
        ("expires_ms", json!(i64::MAX as u64 + 1)),
    ] {
        let mut invalid = body("heartbeat");
        invalid[field] = value;
        assert!(call(
            &a["state"],
            json!({"op":"send_call_v1","account":id(&b),"body":invalid})
        )
        .is_err());
        assert_only_notice(&b, &receive(&b, event(&a, &b, &invalid)));
    }
}

fn transfer_control(a: &mut Value, b: &mut Value, value: Value, sequence: &mut i64) {
    *a = send(a, b, value.clone());
    *sequence += 1;
    *b = receive(b, incoming(a, 0, *sequence));
    assert_eq!(b["acceptance"], "accepted");
    assert_eq!(b["call_event"]["body"], value);
    assert!(
        b["state"]["events"].as_object().unwrap().is_empty(),
        "voice consumed durable text event budget"
    );
    *a = call(
        &a["state"],
        json!({"op":"accepted_v2","id":a["outbox"][0]["id"]}),
    )
    .unwrap();
}

#[test]
fn twenty_maximum_duration_calls_preserve_text_replay_history_and_receipt_budgets() {
    let (mut a, mut b) = known();
    let initial_a = a["state"]["legacy"].clone();
    let initial_b = b["state"]["legacy"].clone();
    let mut sequence = 0;
    for _ in 0..20 {
        let call_id = uuid::Uuid::new_v4().to_string();
        let control = |kind: &str, seq: u32| {
            let mut value = body(kind);
            value["call_id"] = json!(call_id);
            value["seq"] = json!(seq);
            value
        };
        transfer_control(&mut a, &mut b, control("knock", 0), &mut sequence);
        transfer_control(&mut b, &mut a, control("ready", 0), &mut sequence);
        transfer_control(&mut a, &mut b, control("offer", 1), &mut sequence);
        transfer_control(&mut b, &mut a, control("answer", 1), &mut sequence);
        // Actual core encryption/transport/decryption for 15min at10s heartbeat,
        // with simulated time (this test does not sleep for five hours).
        for heartbeat in 0..90 {
            transfer_control(
                &mut a,
                &mut b,
                control("heartbeat", heartbeat + 2),
                &mut sequence,
            );
            transfer_control(
                &mut b,
                &mut a,
                control("heartbeat", heartbeat + 2),
                &mut sequence,
            );
        }
        transfer_control(&mut a, &mut b, control("end", 92), &mut sequence);
        a = reopen(&a);
        b = reopen(&b);
    }
    assert!(
        a["state"]["legacy"] == initial_a,
        "calls replaced caller identity"
    );
    assert!(
        b["state"]["legacy"] == initial_b,
        "calls replaced callee identity"
    );
    for peer in [&a, &b] {
        assert!(peer["dialogs"][0]["messages"]
            .as_array()
            .unwrap()
            .is_empty());
        assert!(peer["state"]["events"].as_object().unwrap().is_empty());
    }
    a = call(
        &a["state"],
        json!({"op":"send_v2","account":id(&b),"text":"Text remains usable after20 maximum calls"}),
    )
    .unwrap();
    sequence += 1;
    b = receive(&b, incoming(&a, 0, sequence));
    assert_eq!(b["acceptance"], "accepted");
    assert_eq!(
        b["dialogs"][0]["messages"][0]["text"],
        "Text remains usable after20 maximum calls"
    );
    sequence += 1;
    a = receive(&a, incoming(&b, 0, sequence));
    assert_eq!(a["dialogs"][0]["messages"][0]["delivered"], true);
}
