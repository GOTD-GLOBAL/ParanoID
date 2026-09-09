//! Development-only, peer-pinned Olm state machine. Platform adapters must
//! encrypt and atomically persist returned state BEFORE any network side effect.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use vodozemac::{
    olm::{Account, AccountPickle, OlmMessage, Session, SessionConfig, SessionPickle},
    Curve25519PublicKey,
};

type Result<T> = std::result::Result<T, &'static str>;
mod contact;

// Android/JVM adapter only; core state/network/storage remain separate.
#[no_mangle]
pub extern "system" fn Java_org_paranoid_text_CoreBridge_command(
    mut env: jni::JNIEnv,
    _class: jni::objects::JClass,
    state: jni::objects::JString,
    request: jni::objects::JString,
) -> jni::sys::jstring {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<String> {
        let state: String = env
            .get_string(&state)
            .map_err(|_| "invalid_jni_input")?
            .into();
        let request: String = env
            .get_string(&request)
            .map_err(|_| "invalid_jni_input")?
            .into();
        command(&state, &request)
    }));
    let output = match result {
        Ok(Ok(output)) => output,
        Ok(Err(error)) => json!({"error":error}).to_string(),
        Err(_) => json!({"error":"native_failure"}).to_string(),
    };
    env.new_string(output)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(deny_unknown_fields)]
struct Bundle {
    device: String,
    realm: String,
    curve: String,
    one_time_key: String,
}
#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
struct Outgoing {
    id: String,
    recipient: String,
    ciphertext: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    id: String,
    author: String,
    text: String,
    accepted: bool,
    delivered: bool,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RejectedEvent {
    id: String,
    sequence: i64,
    reason: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Client {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    enrollment: Option<contact::Status>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    peer_credential: Option<paranoid_key_protocol::Credential>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    grant: Option<paranoid_key_protocol::Grant>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    identity: Option<paranoid_key_protocol::Identity>,
    version: u32,
    public: Bundle,
    account: Value,
    peer: Option<Bundle>,
    sessions: Vec<Value>,
    cursor: i64,
    outbox: Vec<Outgoing>,
    history: Vec<Entry>,
    seen: BTreeMap<String, (String, i64)>,
    #[serde(default)]
    rejected_events: Vec<RejectedEvent>,
    #[serde(default)]
    rejected_count: u64,
    #[serde(default)]
    first_rejected_sequence: Option<i64>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Incoming {
    id: String,
    sender: String,
    sequence: i64,
    ciphertext: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Plain {
    v: u8,
    realm: String,
    from: String,
    to: String,
    id: String,
    kind: String,
    body: String,
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    ImportGrantText {
        text: String,
    },
    ContactText {
        text: String,
        verified: Option<bool>,
    },
    ServerStatus {
        status: contact::Status,
    },
    PairContact {
        contact: contact::Contact,
        verified: bool,
    },
    PreviewContact {
        contact: contact::Contact,
    },
    ImportGrant {
        grant: paranoid_key_protocol::Grant,
    },
    #[serde(rename = "sign_request")]
    Sign {
        challenge: paranoid_key_protocol::Challenge,
        method: String,
        path: String,
        body: String,
    },
    #[serde(rename = "validate_request")]
    Validate {
        descriptor: paranoid_key_protocol::PublicRequest,
    },
    CreateIdentity {
        realm: String,
        pin: String,
    },
    Init {
        device: String,
        realm: String,
    },
    Pair {
        peer: Bundle,
        verified: bool,
    },
    Send {
        text: String,
    },
    Receive {
        message: Incoming,
    },
    Accepted {
        id: String,
    },
    View,
}
fn encode<T: Serialize>(value: T) -> Result<Value> {
    serde_json::to_value(value).map_err(|_| "state_error")
}
fn account(s: &Client) -> Result<Account> {
    let p: AccountPickle =
        serde_json::from_value(s.account.clone()).map_err(|_| "invalid_state")?;
    Ok(Account::from_pickle(p))
}
fn session(value: &Value) -> Result<Session> {
    let p: SessionPickle = serde_json::from_value(value.clone()).map_err(|_| "invalid_state")?;
    Ok(Session::from_pickle(p))
}
fn key(s: &str) -> Result<Curve25519PublicKey> {
    Curve25519PublicKey::from_base64(s).map_err(|_| "invalid_peer_key")
}
fn validate_peer(s: &Client, peer: &Bundle, verified: bool) -> Result<()> {
    if !verified
        || peer.realm != s.public.realm
        || peer.device == s.public.device
        || !["alice", "bob"].contains(&peer.device.as_str())
        || peer.curve == s.public.curve
    {
        return Err("peer_not_verified");
    }
    key(&peer.curve)?;
    key(&peer.one_time_key)?;
    if s.peer.as_ref().is_some_and(|old| *old != *peer) {
        return Err("peer_already_pinned");
    }
    Ok(())
}
fn reply(s: Client) -> Result<String> {
    let request = s
        .identity
        .as_ref()
        .map(|i| json!({"type":"paranoid-request-v1","credential":i.credential}));
    let contact = contact::contact(&s)?;
    let fingerprint = contact.as_ref().map(|c| c.fingerprint());
    serde_json::to_string(&json!({"state":&s,"public":&s.public,"request":request,"contact":contact,"contact_fingerprint":fingerprint,"enrollment":s.enrollment,"grant":s.grant,"outbox":&s.outbox,"messages":&s.history,"cursor":s.cursor,"rejected_count":s.rejected_count,"first_rejected_sequence":s.first_rejected_sequence})).map_err(|_|"state_error")
}
fn init(device: String, realm: String) -> Result<Client> {
    if !["alice", "bob", "unassigned"].contains(&device.as_str())
        || !realm.starts_with("https://")
        || realm.len() > 512
    {
        return Err("invalid_configuration");
    }
    let mut a = Account::new();
    a.generate_one_time_keys(1);
    let public = Bundle {
        device,
        realm,
        curve: a.identity_keys().curve25519.to_base64(),
        one_time_key: a
            .one_time_keys()
            .values()
            .next()
            .ok_or("prekey_error")?
            .to_base64(),
    };
    a.mark_keys_as_published();
    Ok(Client {
        enrollment: None,
        peer_credential: None,
        grant: None,
        identity: None,
        version: 0,
        public,
        account: encode(a.pickle())?,
        peer: None,
        sessions: vec![],
        cursor: 0,
        outbox: vec![],
        history: vec![],
        seen: BTreeMap::new(),
        rejected_events: vec![],
        rejected_count: 0,
        first_rejected_sequence: None,
    })
}
fn encrypt(s: &mut Client, kind: &str, body: String) -> Result<String> {
    if s.outbox.len() >= 400 {
        return Err("outbox_full");
    }
    let peer = s.peer.clone().ok_or("verify_peer_first")?;
    if s.sessions.is_empty() {
        let a = account(s)?;
        let session = a
            .create_outbound_session(
                SessionConfig::version_1(),
                key(&peer.curve)?,
                key(&peer.one_time_key)?,
            )
            .map_err(|_| "session_error")?;
        s.sessions.push(encode(session.pickle())?);
    }
    let id = uuid::Uuid::new_v4().to_string();
    let p = Plain {
        v: 0,
        realm: s.public.realm.clone(),
        from: s.public.device.clone(),
        to: peer.device.clone(),
        id: id.clone(),
        kind: kind.into(),
        body,
    };
    let index = s.sessions.len() - 1;
    let mut sess = session(&s.sessions[index])?;
    let encrypted = sess
        .encrypt(serde_json::to_vec(&p).map_err(|_| "state_error")?)
        .map_err(|_| "encryption_failed")?;
    let (kind, bytes) = encrypted.to_parts();
    let mut frame = vec![kind as u8];
    frame.extend(bytes);
    s.sessions[index] = encode(sess.pickle())?;
    s.outbox.push(Outgoing {
        id: id.clone(),
        recipient: peer.device,
        ciphertext: STANDARD.encode(frame),
    });
    Ok(id)
}
fn receive(s: &mut Client, m: Incoming) -> Result<()> {
    let peer = s.peer.clone().ok_or("verify_peer_first")?;
    if m.sender != peer.device
        || m.sequence < 1
        || uuid::Uuid::parse_str(&m.id)
            .map(|id| id.to_string() != m.id)
            .unwrap_or(true)
    {
        return Err("invalid_envelope");
    }
    // Accepted IDs are immutable. Classify conflicts before malformed payloads
    // can enter the recoverable-new-event path.
    let known = s.seen.get(&m.id);
    if known.is_some_and(|(_, sequence)| *sequence != m.sequence) {
        return Err("conflicting_replay");
    }
    let malformed = if known.is_some() {
        "conflicting_replay"
    } else {
        "invalid_ciphertext"
    };
    let frame = STANDARD.decode(&m.ciphertext).map_err(|_| malformed)?;
    if frame.len() < 2 || frame.len() > 16384 || frame[0] > 1 {
        return Err(malformed);
    }
    let hash = STANDARD.encode(Sha256::digest(&frame));
    if let Some((old, seq)) = s.seen.get(&m.id) {
        if *old != hash || *seq != m.sequence {
            return Err("conflicting_replay");
        }
        return Ok(());
    }
    if m.sequence <= s.cursor || s.seen.len() >= 1000 {
        return Err("invalid_or_full_inbox");
    }
    let message =
        OlmMessage::from_parts(frame[0] as usize, &frame[1..]).map_err(|_| "invalid_ciphertext")?;
    let mut plaintext = None;
    for i in 0..s.sessions.len() {
        let mut candidate = session(&s.sessions[i])?;
        if let Ok(bytes) = candidate.decrypt(&message) {
            s.sessions[i] = encode(candidate.pickle())?;
            plaintext = Some(bytes);
            break;
        }
    }
    let bytes = if let Some(bytes) = plaintext {
        bytes
    } else {
        if s.sessions.len() >= 8 {
            return Err("session_limit");
        }
        let OlmMessage::PreKey(prekey) = &message else {
            return Err("decryption_failed");
        };
        let mut a = account(s)?;
        let result = a
            .create_inbound_session(SessionConfig::version_1(), key(&peer.curve)?, prekey)
            .map_err(|_| "decryption_failed")?;
        s.account = encode(a.pickle())?;
        s.sessions.push(encode(result.session.pickle())?);
        result.plaintext
    };
    let p: Plain = serde_json::from_slice(&bytes).map_err(|_| "invalid_plaintext")?;
    if p.v != 0
        || p.realm != s.public.realm
        || p.from != peer.device
        || p.to != s.public.device
        || p.id != m.id
    {
        return Err("context_mismatch");
    }
    match p.kind.as_str() {
        "text" => {
            if p.body.is_empty() || p.body.len() > 2048 {
                return Err("invalid_text");
            }
            if s.history.len() >= 200 {
                return Err("local_history_full");
            }
            s.history.push(Entry {
                id: p.id.clone(),
                author: peer.device,
                text: p.body,
                accepted: true,
                delivered: true,
            });
            // This receipt is queued inside the SAME candidate snapshot. The platform
            // must persist that snapshot before transmitting any outbox entry.
            encrypt(s, "receipt", p.id)?;
        }
        "receipt" => {
            let own = s.public.device.clone();
            let item = s
                .history
                .iter_mut()
                .find(|e| e.id == p.body && e.author == own)
                .ok_or("unknown_receipt")?;
            item.accepted = true;
            item.delivered = true;
        }
        _ => return Err("unsupported_message"),
    }
    s.seen.insert(m.id, (hash, m.sequence));
    s.cursor = m.sequence;
    Ok(())
}
pub fn command(state: &str, request: &str) -> Result<String> {
    if state.len() > 8 * 1024 * 1024 || request.len() > 65536 {
        return Err("input_limit");
    }
    let request: Request = serde_json::from_str(request).map_err(|_| "invalid_request")?;
    if let Request::Validate { descriptor } = request {
        descriptor.verify()?;
        return Ok(json!({"fingerprint":descriptor.credential.fingerprint()}).to_string());
    }
    if let Request::CreateIdentity { realm, pin } = request {
        let mut s = if state.is_empty() {
            init("unassigned".into(), realm.clone())?
        } else {
            serde_json::from_str::<Client>(state).map_err(|_| "invalid_state")?
        };
        if s.version != 0 || s.public.realm != realm {
            return Err("identity_change_refused");
        }
        // Do not mint auth keys over unreadable or substituted legacy crypto state.
        let retained = account(&s)?;
        if retained.identity_keys().curve25519.to_base64() != s.public.curve {
            return Err("invalid_state");
        }
        key(&s.public.one_time_key)?;
        for old in &s.sessions {
            session(old)?;
        }
        if let Some(i) = &s.identity {
            if i.credential.pin != pin {
                return Err("identity_change_refused");
            }
        } else {
            s.identity = Some(paranoid_key_protocol::Identity::create(
                &realm,
                &pin,
                &s.public.curve,
                &s.public.one_time_key,
            )?);
        }
        return reply(s);
    }
    if let Request::Init { device, realm } = request {
        if !state.is_empty() {
            return Err("already_initialized");
        }
        return reply(init(device, realm)?);
    }
    let mut s: Client = serde_json::from_str(state).map_err(|_| "invalid_state")?;
    if s.version != 0 {
        return Err("unsupported_state");
    }
    match request {
        Request::ImportGrantText { text } => {
            if text.len() > 4096 {
                return Err("qr_limit");
            }
            let grant: paranoid_key_protocol::Grant =
                serde_json::from_str(&text).map_err(|_| "invalid_grant")?;
            return command(
                state,
                &json!({"op":"import_grant","grant":grant}).to_string(),
            );
        }
        Request::ContactText { text, verified } => {
            if text.len() > 4096 {
                return Err("qr_limit");
            }
            let contact: contact::Contact =
                serde_json::from_str(&text).map_err(|_| "invalid_contact")?;
            let request = if let Some(verified) = verified {
                json!({"op":"pair_contact","contact":contact,"verified":verified})
            } else {
                json!({"op":"preview_contact","contact":contact})
            };
            return command(state, &request.to_string());
        }
        Request::ServerStatus { status } => {
            let g = s.grant.as_ref().ok_or("grant_required")?;
            if status.grant != g.id
                || status.credential != g.credential
                || status.slot != g.slot
                || !["pending", "active"].contains(&status.mode.as_str())
                || s.enrollment
                    .as_ref()
                    .is_some_and(|e| e.mode == "active" && status.mode != "active")
            {
                return Err("status_conflict");
            }
            let alias = if status.slot == 0 { "alice" } else { "bob" };
            if s.public.device != "unassigned" && s.public.device != alias {
                return Err("legacy_slot_conflict");
            }
            s.public.device = alias.into();
            s.enrollment = Some(status);
        }
        Request::PreviewContact { contact } => {
            contact.verify(&s)?;
            return Ok(
                json!({"fingerprint":contact.fingerprint(),"account":contact.credential.account})
                    .to_string(),
            );
        }
        Request::PairContact { contact, verified } => {
            if !verified || s.enrollment.as_ref().map(|e| e.mode.as_str()) != Some("active") {
                return Err("peer_not_verified");
            }
            contact.verify(&s)?;
            s.peer = Some(contact.bundle);
            s.peer_credential = Some(contact.credential);
        }
        Request::ImportGrant { grant } => {
            let i = s.identity.as_ref().ok_or("create_identity_first")?;
            if grant.kind != "paranoid-grant-v1"
                || grant.realm != i.credential.realm
                || grant.pin != i.credential.pin
                || grant.credential != i.credential.fingerprint()
                || !(0..=1).contains(&grant.slot)
                || uuid::Uuid::parse_str(&grant.id)
                    .map(|u| u.to_string() != grant.id)
                    .unwrap_or(true)
                || grant.expires < 1
                || (s.enrollment.is_some() && s.grant.as_ref().is_some_and(|old| *old != grant))
            {
                return Err("grant_conflict");
            }
            let alias = if grant.slot == 0 { "alice" } else { "bob" };
            if s.public.device != "unassigned" && s.public.device != alias {
                return Err("legacy_slot_conflict");
            }
            s.grant = Some(grant);
        }
        Request::Sign {
            challenge: c,
            method,
            path,
            body,
        } => {
            let i = s.identity.as_ref().ok_or("create_identity_first")?;
            let g = s.grant.as_ref().ok_or("grant_required")?;
            let purpose = match (method.as_str(), path.as_str()) {
                ("POST", "/v1/enrollment/commit") => "enroll",
                ("POST", "/v1/auth/verify") => "status",
                ("POST", "/v1/enrollment/activate") => "activate",
                ("POST", "/v1/messages") => "message",
                ("GET", p) if p == "/v1/messages" || p.starts_with("/v1/messages?") => "message",
                _ => return Err("invalid_proof_purpose"),
            };
            if c.method != method
                || c.path != path
                || c.body != paranoid_key_protocol::digest(body.as_bytes())
                || c.purpose != purpose
                || c.account != i.credential.account
                || c.device != i.credential.device
                || c.credential != g.credential
                || c.realm != g.realm
                || c.pin != g.pin
                || c.grant != g.id
                || c.slot != g.slot
                || c.expires < 1
                || uuid::Uuid::parse_str(&c.id).is_err()
                || uuid::Uuid::parse_str(&c.epoch).is_err()
                || STANDARD
                    .decode(&c.nonce)
                    .map(|n| n.len() != 32)
                    .unwrap_or(true)
            {
                return Err("proof_context_mismatch");
            }
            let key = vodozemac::Ed25519SecretKey::from_base64(&i.auth_secret)
                .map_err(|_| "invalid_state")?;
            if key.public_key().to_base64() != i.credential.auth {
                return Err("invalid_state");
            }
            return Ok(json!({"authorization":format!("Paranoid {}.{}",c.id,key.sign(&c.bytes()).to_base64())}).to_string());
        }
        Request::Pair { peer, verified } => {
            if s.identity.is_some() {
                return Err("use_verified_contact");
            }
            validate_peer(&s, &peer, verified)?;
            s.peer = Some(peer);
        }
        Request::Send { text } => {
            if text.is_empty() || text.len() > 2048 || s.history.len() >= 200 {
                return Err("invalid_text_or_full_history");
            }
            let id = encrypt(&mut s, "text", text.clone())?;
            s.history.push(Entry {
                id,
                author: s.public.device.clone(),
                text,
                accepted: false,
                delivered: false,
            });
        }
        Request::Receive { message } => {
            let sequence = message.sequence;
            let id = message.id.clone();
            if let Err(reason) = receive(&mut s, message) {
                let skippable = matches!(
                    reason,
                    "invalid_ciphertext"
                        | "decryption_failed"
                        | "invalid_plaintext"
                        | "context_mismatch"
                        | "unsupported_message"
                        | "unknown_receipt"
                        | "invalid_text_or_full_history"
                        | "invalid_text"
                        | "local_history_full"
                        | "outbox_full"
                        | "session_limit"
                        | "invalid_or_full_inbox"
                );
                // Restore BEFORE recording progress: a failed candidate may have
                // consumed a prekey, ratchet or appended history before failing.
                s = serde_json::from_str(state).map_err(|_| "invalid_state")?;
                if s.seen.contains_key(&id) {
                    return Err("conflicting_replay");
                }
                if !skippable
                    || sequence <= s.cursor
                    || sequence > 100000
                    || uuid::Uuid::parse_str(&id).is_err()
                {
                    return Err(reason);
                }
                if s.rejected_events.len() >= 64 {
                    s.rejected_events.remove(0);
                }
                s.rejected_events.push(RejectedEvent {
                    id,
                    sequence,
                    reason: reason.into(),
                });
                s.rejected_count = s.rejected_count.saturating_add(1);
                if s.first_rejected_sequence.is_none() {
                    s.first_rejected_sequence = Some(sequence);
                }
                s.cursor = sequence;
            }
        }
        Request::Accepted { id } => {
            if !s.outbox.iter().any(|m| m.id == id) {
                return Err("unknown_acceptance");
            }
            s.outbox.retain(|m| m.id != id);
            if let Some(e) = s.history.iter_mut().find(|m| m.id == id) {
                e.accepted = true
            }
        }
        Request::View => {}
        Request::Init { .. } | Request::CreateIdentity { .. } | Request::Validate { .. } => {
            return Err("already_initialized")
        }
    }
    reply(s)
}
