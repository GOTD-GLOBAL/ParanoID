//! Clean-install schema 3. One Account, immutable signed channels, whole-State transactions.
use super::contact_v2::ContactV2;
use super::intro_v2::{canonical_id, channel, frame, Introduction, PROFILE};
use super::voice_v1::CallV1;
use super::*;
use paranoid_key_protocol::digest;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct State {
    version: u32,
    // Sole owner of private Olm Account and identity; never a messaging adapter.
    legacy: Client,
    enrollment: Option<Status>,
    fallback_key: Option<String>,
    conversations: BTreeMap<String, Conversation>,
    cursor: i64,
    events: BTreeMap<String, Event>,
    rejected_events: Vec<Notice>,
    rejected_count: u64,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Conversation {
    contact: ContactV2,
    channel: String,
    trust: Trust,
    blocked: bool,
    active: bool,
    sessions: Vec<Value>,
    outbox: Vec<Outgoing>,
    history: Vec<Entry>,
    commitments: BTreeMap<String, ReceiptTarget>,
}
#[derive(Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum Trust {
    NetworkUnverified,
    OutOfBandVerified,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Status {
    mode: String,
    account: String,
    device: String,
    credential: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Event {
    sender: String,
    id: String,
    sequence: i64,
    channel: String,
    profile: String,
    outer_digest: String,
    inner_digest: String,
    receipt_queued: bool,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Notice {
    sender: String,
    id: String,
    sequence: i64,
    outer_digest: String,
    reason: String,
}
#[derive(Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct ReceiptTarget {
    target_channel: String,
    target_sender: String,
    target_id: String,
    target_inner_digest: String,
}
#[derive(Serialize, Deserialize)]
#[serde(untagged)]
enum Body {
    Text(String),
    Receipt(ReceiptTarget),
    Call(Box<CallV1>),
}
// Explicit fields plus typed body: unknown/duplicate fields remain rejected by serde.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PlainV1 {
    v: u8,
    channel: String,
    realm: String,
    from: String,
    to: String,
    id: String,
    kind: String,
    body: Body,
}
impl PlainV1 {
    fn into_body(self) -> Result<Body> {
        match (self.kind.as_str(), self.body) {
            ("text", body @ Body::Text(_)) | ("receipt", body @ Body::Receipt(_)) => Ok(body),
            ("call", Body::Call(body)) => {
                body.validate()?;
                Ok(Body::Call(body))
            }
            _ => Err("unsupported_message"),
        }
    }
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Operation {
    UpgradeV2,
    PrepareContactV2,
    View,
    SignRequestV2 {
        challenge: Box<paranoid_key_protocol::ChallengeV2>,
        method: String,
        path: String,
        body: String,
    },
    SignSessionV2 {
        session: Box<paranoid_key_protocol::SessionV2>,
        operation: String,
        id: Option<String>,
    },
    ServerStatusV2 {
        status: Status,
    },
    ContactTextV2 {
        text: String,
    },
    PairContactV2 {
        text: String,
        verified: bool,
    },
    SendV2 {
        account: String,
        text: String,
        /// The client's own clock at the instant of the tap, in milliseconds
        /// since the epoch. Absent or zero means the client keeps no time.
        #[serde(default)]
        now_ms: u64,
    },
    SendCallV1 {
        account: String,
        body: Box<CallV1>,
    },
    ReceiveV2 {
        message: Incoming,
        /// The client's own clock at the instant this event was committed.
        #[serde(default)]
        now_ms: u64,
    },
    AcceptedV2 {
        id: String,
    },
    BlockContactV2 {
        account: String,
        blocked: bool,
    },
}
#[derive(Serialize)]
struct CallEvent {
    account: String,
    channel: String,
    body: Box<CallV1>,
}
enum Acceptance {
    Accepted(Option<CallEvent>),
    ExactDuplicate,
    Rejected(&'static str),
}
fn own_id(s: &State) -> Result<&str> {
    Ok(&s
        .legacy
        .identity
        .as_ref()
        .ok_or("invalid_state")?
        .credential
        .account)
}
fn local_contact(s: &State) -> Result<ContactV2> {
    ContactV2::create(
        &s.legacy,
        s.fallback_key.as_deref().ok_or("prepare_contact_first")?,
    )
}
fn clean_identity(s: &Client) -> Result<()> {
    super::self_service::validate(s)?;
    if s.public.device != "unassigned"
        || s.peer.is_some()
        || s.peer_credential.is_some()
        || s.enrollment.is_some()
        || s.grant.is_some()
        || !s.sessions.is_empty()
        || !s.outbox.is_empty()
        || !s.history.is_empty()
        || !s.seen.is_empty()
        || s.cursor != 0
        || s.rejected_count != 0
        || !s.rejected_events.is_empty()
        || s.first_rejected_sequence.is_some()
    {
        return Err("unsupported_state");
    }
    let i = s.identity.as_ref().ok_or("invalid_state")?;
    if vodozemac::Ed25519SecretKey::from_base64(&i.auth_secret)
        .map_err(|_| "invalid_state")?
        .public_key()
        .to_base64()
        != i.credential.auth
        || vodozemac::Ed25519SecretKey::from_base64(&i.root_secret)
            .map_err(|_| "invalid_state")?
            .public_key()
            .to_base64()
            != i.credential.root
    {
        return Err("invalid_state");
    }
    Ok(())
}
fn validate(s: &State) -> Result<()> {
    if s.version != 3 {
        return Err("unsupported_state");
    }
    clean_identity(&s.legacy)?;
    if !(0..=100000).contains(&s.cursor)
        || s.conversations.len() > 64
        || s.rejected_events.len() > 64
        || s.conversations
            .values()
            .filter(|c| c.trust == Trust::NetworkUnverified)
            .count()
            > 16
    {
        return Err("invalid_state");
    }
    let own = s.legacy.identity.as_ref().ok_or("invalid_state")?;
    if s.enrollment.as_ref().is_some_and(|e| {
        e.mode != "active"
            || e.account != own.credential.account
            || e.device != own.credential.device
            || e.credential != own.credential.fingerprint()
    }) {
        return Err("invalid_state");
    }
    if let Some(f) = &s.fallback_key {
        let secret: vodozemac::Curve25519SecretKey = serde_json::from_value(
            s.legacy.account["fallback_keys"]["fallback_key"]["key"].clone(),
        )
        .map_err(|_| "invalid_state")?;
        if Curve25519PublicKey::from(&secret).to_base64() != *f {
            return Err("invalid_state");
        }
    }
    for (id, c) in &s.conversations {
        c.contact.verify(&s.legacy)?;
        if *id != c.contact.credential.account
            || c.channel != channel(&local_contact(s)?, &c.contact)?
            || c.sessions.len() > 8
            || c.outbox.len() > 400
            || c.commitments.len() > 1000
            || s.events.values().filter(|e| e.sender == *id).count() > 1000
        {
            return Err("invalid_state");
        }
        for sess in &c.sessions {
            session(sess)?;
        }
        for (id, t) in &c.commitments {
            if id != &t.target_id
                || !canonical_id(id)
                || t.target_channel != c.channel
                || t.target_sender != own_id(s)?
                || !paranoid_key_protocol::hex32(&t.target_inner_digest)
            {
                return Err("invalid_state");
            }
        }
        let mut ids = std::collections::BTreeSet::new();
        for m in &c.outbox {
            if !canonical_id(&m.id)
                || m.recipient != *id
                || !ids.insert(&m.id)
                || frame(&m.ciphertext)?[0] != 2
            {
                return Err("invalid_state");
            }
        }
    }
    let mut sequences = std::collections::BTreeSet::new();
    for (key, e) in &s.events {
        if *key != format!("{}:{}", e.sender, e.id)
            || !canonical_id(&e.id)
            || !(1..=s.cursor).contains(&e.sequence)
            || !sequences.insert(e.sequence)
            || !s
                .conversations
                .get(&e.sender)
                .is_some_and(|c| c.channel == e.channel)
            || e.profile != PROFILE
            || !paranoid_key_protocol::hex32(&e.outer_digest)
            || !paranoid_key_protocol::hex32(&e.inner_digest)
        {
            return Err("invalid_state");
        }
    }
    Ok(())
}
fn snapshot_size(s: &State) -> Result<()> {
    if serde_json::to_vec(s).map_err(|_| "state_error")?.len() > 8 * 1024 * 1024 {
        Err("local_state_full")
    } else {
        Ok(())
    }
}
fn reply(s: State, acceptance: Option<Acceptance>) -> Result<String> {
    snapshot_size(&s)?;
    let mut outbox = Vec::new();
    let mut dialogs = Vec::new();
    for (id, c) in &s.conversations {
        outbox.extend(c.outbox.iter());
        dialogs.push(json!({"account":id,"fingerprint":c.contact.fingerprint(),"own":own_id(&s)?,"messages":c.history,
            "channel":c.channel,"trust":c.trust,"identity_verified":c.trust==Trust::OutOfBandVerified,"blocked":c.blocked,
            "channel_state":if c.blocked {"blocked"} else if c.active {"active"} else if c.commitments.is_empty(){"absent"}else{"local_pending"}}));
    }
    let contact = s
        .fallback_key
        .as_ref()
        .map(|_| local_contact(&s))
        .transpose()?;
    let identity = s.legacy.identity.as_ref().ok_or("invalid_state")?;
    let mut result = json!({"state":&s,"public":s.legacy.public,"request":{"type":"paranoid-request-v1","credential":identity.credential},
        "contact":contact,"contact_fingerprint":contact.as_ref().map(ContactV2::fingerprint),"enrollment":s.enrollment,
        "outbox":outbox,"dialogs":dialogs,"cursor":s.cursor,"rejected_count":s.rejected_count,"rejected_events":s.rejected_events});
    match acceptance {
        Some(Acceptance::Accepted(event)) => {
            result["acceptance"] = json!("accepted");
            if let Some(event) = event {
                result["call_event"] = json!(event);
            }
        }
        Some(Acceptance::ExactDuplicate) => result["acceptance"] = json!("exact_duplicate"),
        Some(Acceptance::Rejected(reason)) => {
            result["acceptance"] = json!("rejected");
            result["rejection_reason"] = json!(reason);
        }
        None => {}
    }
    Ok(result.to_string())
}
fn add_peer(s: &mut State, contact: ContactV2, trust: Trust) -> Result<()> {
    let id = contact.credential.account.clone();
    if let Some(c) = s.conversations.get_mut(&id) {
        if c.contact != contact {
            return Err("peer_already_pinned");
        }
        if trust == Trust::OutOfBandVerified {
            c.trust = trust;
        }
        return Ok(());
    }
    if s.conversations.len() >= 64 {
        return Err("contact_limit");
    }
    if trust == Trust::NetworkUnverified
        && s.conversations
            .values()
            .filter(|c| c.trust == Trust::NetworkUnverified)
            .count()
            >= 16
    {
        return Err("unverified_contact_limit");
    }
    let chan = channel(&local_contact(s)?, &contact)?;
    s.conversations.insert(
        id,
        Conversation {
            contact,
            channel: chan,
            trust,
            blocked: false,
            active: false,
            sessions: vec![],
            outbox: vec![],
            history: vec![],
            commitments: BTreeMap::new(),
        },
    );
    Ok(())
}
fn enqueue(s: &mut State, id: &str, body: Body, now_ms: u64) -> Result<String> {
    let own = own_id(s)?.to_owned();
    let c = s.conversations.get_mut(id).ok_or("verify_peer_first")?;
    if c.blocked {
        return Err("contact_blocked");
    }
    if c.outbox.len() >= 400 {
        return Err("outbox_full");
    }
    // Bound stale durable controls without reserving schema fields or deleting
    // ciphertext. Ordinary text retains its independent 400-envelope allowance.
    if matches!(body, Body::Call(_)) && c.outbox.len() >= 16 {
        return Err("call_outbox_full");
    }
    // Owner decision 2026-09-17: conversation history has no entry ceiling. Only
    // the bounded receipt-commitment ledger still refuses a text send; the whole
    // sealed snapshot stays bounded by `snapshot_size` (`local_state_full`).
    if matches!(body, Body::Text(_)) && c.commitments.len() >= 1000 {
        return Err("local_history_full");
    }
    if c.sessions.is_empty() {
        let a = account(&s.legacy)?;
        c.sessions.push(encode(
            a.create_outbound_session(
                SessionConfig::version_1(),
                key(&c.contact.bundle.curve)?,
                key(&c.contact.fallback_key)?,
            )
            .map_err(|_| "session_error")?
            .pickle(),
        )?);
    }
    let mid = uuid::Uuid::new_v4().to_string();
    let kind = match &body {
        Body::Text(_) => "text",
        Body::Receipt(_) => "receipt",
        Body::Call(_) => "call",
    };
    let p = PlainV1 {
        v: 1,
        channel: c.channel.clone(),
        realm: s.legacy.public.realm.clone(),
        from: own.clone(),
        to: id.into(),
        id: mid.clone(),
        kind: kind.into(),
        body,
    };
    let index = c.sessions.len() - 1;
    let mut sess = session(&c.sessions[index])?;
    let encrypted = sess
        .encrypt(serde_json::to_vec(&p).map_err(|_| "state_error")?)
        .map_err(|_| "encryption_failed")?;
    let (typ, bytes) = encrypted.to_parts();
    let mut inner = vec![typ as u8];
    inner.extend(bytes);
    let pending = Outgoing {
        id: mid.clone(),
        recipient: id.into(),
        ciphertext: STANDARD.encode(&inner),
    };
    let wrapped = Introduction::create(
        &s.legacy,
        s.fallback_key.as_deref().ok_or("prepare_contact_first")?,
        &c.contact,
        &pending,
        &c.channel,
    )?;
    c.sessions[index] = encode(sess.pickle())?;
    c.outbox.push(wrapped);
    if let Body::Text(text) = p.body {
        c.commitments.insert(
            mid.clone(),
            ReceiptTarget {
                target_channel: c.channel.clone(),
                target_sender: own.clone(),
                target_id: mid.clone(),
                target_inner_digest: digest(&inner),
            },
        );
        c.history.push(Entry {
            id: mid.clone(),
            author: own,
            text,
            accepted: false,
            delivered: false,
            local_ms: now_ms,
        });
    }
    Ok(mid)
}
fn receive_candidate(
    s: &mut State,
    m: &Incoming,
    outer_digest: String,
    now_ms: u64,
) -> Result<Acceptance> {
    if s.conversations.get(&m.sender).is_some_and(|c| c.blocked) {
        return Err("contact_blocked");
    }
    let known_peer = s.conversations.contains_key(&m.sender);
    let intro = Introduction::inspect(
        &s.legacy,
        s.fallback_key.as_deref().ok_or("prepare_contact_first")?,
        m,
    )?;
    let inner = intro.inner()?;
    add_peer(s, intro.contact, Trust::NetworkUnverified)?;
    let c = s.conversations.get_mut(&m.sender).ok_or("invalid_state")?;
    let message =
        OlmMessage::from_parts(inner[0] as usize, &inner[1..]).map_err(|_| "invalid_ciphertext")?;
    let mut plaintext = None;
    for pickle in &mut c.sessions {
        let mut candidate = session(pickle)?;
        if let Ok(bytes) = candidate.decrypt(&message) {
            *pickle = encode(candidate.pickle())?;
            plaintext = Some(bytes);
            break;
        }
    }
    let bytes = if let Some(bytes) = plaintext {
        bytes
    } else {
        if c.sessions.len() >= 8 {
            return Err("session_limit");
        }
        let OlmMessage::PreKey(prekey) = &message else {
            return Err("decryption_failed");
        };
        // Reusable fallback keys can reconstruct a consumed session. Keep the
        // retained ratchet's replay decision authoritative even without an Event
        // row (call controls have none). Sessions are never evicted.
        for pickle in &c.sessions {
            if session(pickle)?.session_id() == prekey.session_id() {
                return Err("decryption_failed");
            }
        }
        let mut a = account(&s.legacy)?;
        let result = a
            .create_inbound_session(
                SessionConfig::version_1(),
                key(&c.contact.bundle.curve)?,
                prekey,
            )
            .map_err(|_| "decryption_failed")?;
        s.legacy.account = encode(a.pickle())?;
        c.sessions.push(encode(result.session.pickle())?);
        result.plaintext
    };
    let p: PlainV1 = serde_json::from_slice(&bytes).map_err(|_| "invalid_plaintext")?;
    if p.v != 1
        || p.channel != c.channel
        || p.realm != s.legacy.public.realm
        || p.from != m.sender
        || p.to != own_id(s)?
        || p.id != m.id
    {
        return Err("context_mismatch");
    }
    let target = ReceiptTarget {
        target_channel: p.channel.clone(),
        target_sender: m.sender.clone(),
        target_id: m.id.clone(),
        target_inner_digest: digest(&inner),
    };
    let accepted_channel = p.channel.clone();
    let body = p.into_body()?;
    if !matches!(body, Body::Call(_))
        && s.events.values().filter(|e| e.sender == m.sender).count() >= 1000
    {
        return Err("invalid_or_full_inbox");
    }
    let mut call_event = None;
    let receipt_queued = match body {
        Body::Text(text) => {
            if text.is_empty() || text.len() > 2048 {
                return Err("invalid_text");
            }
            let c = s.conversations.get_mut(&m.sender).ok_or("invalid_state")?;
            // Owner decision 2026-09-17: no history ceiling. The snapshot bound in
            // `snapshot_size` remains the only capacity refusal for stored text.
            c.history.push(Entry {
                id: m.id.clone(),
                author: m.sender.clone(),
                text,
                accepted: true,
                delivered: true,
                local_ms: now_ms,
            });
            enqueue(s, &m.sender, Body::Receipt(target), 0)?;
            true
        }
        Body::Receipt(target) => {
            let own = own_id(s)?.to_owned();
            let c = s.conversations.get_mut(&m.sender).ok_or("invalid_state")?;
            if c.commitments.get(&target.target_id) != Some(&target) {
                return Err("unknown_receipt");
            }
            let entry = c
                .history
                .iter_mut()
                .find(|h| h.id == target.target_id && h.author == own)
                .ok_or("unknown_receipt")?;
            entry.accepted = true;
            entry.delivered = true;
            false
        }
        Body::Call(body) => {
            if !known_peer {
                return Err("unknown_call_peer");
            }
            call_event = Some(CallEvent {
                account: m.sender.clone(),
                channel: accepted_channel.clone(),
                body,
            });
            false
        }
    };
    s.conversations
        .get_mut(&m.sender)
        .ok_or("invalid_state")?
        .active = true;
    if call_event.is_none() {
        s.events.insert(
            format!("{}:{}", m.sender, m.id),
            Event {
                sender: m.sender.clone(),
                id: m.id.clone(),
                sequence: m.sequence,
                channel: accepted_channel,
                profile: PROFILE.into(),
                outer_digest,
                inner_digest: digest(&inner),
                receipt_queued,
            },
        );
    }
    s.cursor = m.sequence;
    snapshot_size(s)?;
    Ok(Acceptance::Accepted(call_event))
}
fn receive(s: &mut State, m: Incoming, now_ms: u64) -> Result<Acceptance> {
    if !paranoid_key_protocol::hex32(&m.sender)
        || !canonical_id(&m.id)
        || !(1..=100000).contains(&m.sequence)
        || m.sender == own_id(s)?
    {
        return Err("invalid_envelope");
    }
    // Commit exact outer bytes, sender/id and sequence before trying decryption.
    let outer = frame(&m.ciphertext);
    let key = format!("{}:{}", m.sender, m.id);
    if let Some(old) = s.events.get(&key) {
        if old.sequence != m.sequence
            || !outer
                .as_ref()
                .is_ok_and(|bytes| digest(bytes) == old.outer_digest)
        {
            return Err("conflicting_replay");
        }
        return Ok(Acceptance::ExactDuplicate);
    }
    if s.events.values().any(|e| e.sequence == m.sequence) || m.sequence <= s.cursor {
        return Err("conflicting_replay");
    }
    // Deep-copy ALL state, including Account, before transient peer allocation.
    let mut candidate: State = serde_json::from_value(encode(&*s)?).map_err(|_| "invalid_state")?;
    let result =
        outer.and_then(|bytes| receive_candidate(&mut candidate, &m, digest(&bytes), now_ms));
    match result {
        Ok(accepted @ Acceptance::Accepted(_)) => {
            *s = candidate;
            Ok(accepted)
        }
        Ok(_) => Err("invalid_acceptance"),
        Err(reason) => {
            if matches!(
                reason,
                "invalid_state" | "state_error" | "prepare_contact_first"
            ) {
                return Err(reason);
            }
            if s.rejected_events.len() >= 64 {
                s.rejected_events.remove(0);
            }
            s.rejected_events.push(Notice {
                sender: m.sender,
                id: m.id,
                sequence: m.sequence,
                outer_digest: digest(m.ciphertext.as_bytes()),
                reason: reason.into(),
            });
            s.rejected_count = s.rejected_count.saturating_add(1);
            s.cursor = m.sequence;
            Ok(Acceptance::Rejected(reason))
        }
    }
}
// Session requests expose operation/id selectors, never a caller-controlled
// path, cursor, body or nonce. The immutable outbox remains the signing source.
fn sign_session(
    s: &State,
    session: &paranoid_key_protocol::SessionV2,
    operation: &str,
    id: Option<&str>,
) -> Result<String> {
    if s.enrollment.is_none() {
        return Err("registration_required");
    }
    let identity = s.legacy.identity.as_ref().ok_or("invalid_state")?;
    let c = &identity.credential;
    if !canonical_id(&session.id)
        || !canonical_id(&session.epoch)
        || session.expires <= 0
        || session.realm != c.realm
        || session.pin != c.pin
        || session.account != c.account
        || session.device != c.device
        || session.credential != c.fingerprint()
    {
        return Err("session_context_mismatch");
    }
    let (method, path, body) = match (operation, id) {
        ("send", Some(id)) => {
            let envelope = s
                .conversations
                .values()
                .flat_map(|c| &c.outbox)
                .find(|m| m.id == id)
                .ok_or("unknown_outbox")?;
            (
                "POST",
                "/v2/messages".to_owned(),
                serde_json::to_string(envelope).map_err(|_| "state_error")?,
            )
        }
        ("messages" | "events", None) => (
            "GET",
            format!("/v2/{operation}?after={}&limit=20", s.cursor),
            String::new(),
        ),
        ("turn", None) => ("GET", "/v2/voice/turn".to_owned(), String::new()),
        // Push wake registration (RFC-0020): the FCM registration token is an opaque
        // Google-issued string; the server stores it per account/device and never
        // learns anything else. Empty token = unregister.
        ("push", Some(token)) => {
            if token.len() > 4096 || !token.bytes().all(|b| b.is_ascii_graphic()) {
                return Err("invalid_push_token");
            }
            (
                "POST",
                "/v2/push".to_owned(),
                json!({"platform":"fcm","token":token}).to_string(),
            )
        }
        _ => return Err("invalid_session_operation"),
    };
    let nonce = uuid::Uuid::new_v4().to_string();
    let key = vodozemac::Ed25519SecretKey::from_base64(&identity.auth_secret)
        .map_err(|_| "invalid_state")?;
    let signature = key
        .sign(&session.bytes(&nonce, method, &path, &digest(body.as_bytes())))
        .to_base64();
    Ok(json!({"authorization":format!("ParanoidSessionV2 {}.{}.{}",session.id,nonce,signature),"method":method,"path":path,"body":body}).to_string())
}
pub(super) fn command(raw: &str, request: &str) -> Result<String> {
    let op: Operation = serde_json::from_str(request).map_err(|_| "invalid_request")?;
    let version = serde_json::from_str::<Value>(raw).map_err(|_| "invalid_state")?["version"]
        .as_u64()
        .ok_or("invalid_state")?;
    if version == 2 {
        return Err("unsupported_state");
    }
    if let Operation::SignRequestV2 {
        challenge,
        method,
        path,
        body,
    } = &op
    {
        if version == 0 {
            if path == "/v2/session" {
                return Err("registration_required");
            }
            let legacy: Client = serde_json::from_str(raw).map_err(|_| "invalid_state")?;
            clean_identity(&legacy)?;
            return super::self_service::sign(&legacy, challenge, method, path, body);
        }
    }
    let mut s = if version == 0 && matches!(op, Operation::UpgradeV2) {
        let legacy: Client = serde_json::from_str(raw).map_err(|_| "invalid_state")?;
        clean_identity(&legacy)?;
        State {
            version: 3,
            legacy,
            enrollment: None,
            fallback_key: None,
            conversations: BTreeMap::new(),
            cursor: 0,
            events: BTreeMap::new(),
            rejected_events: vec![],
            rejected_count: 0,
        }
    } else {
        if version != 3 {
            return Err("unsupported_state");
        }
        let s: State = serde_json::from_str(raw).map_err(|_| "invalid_state")?;
        validate(&s)?;
        s
    };
    match op {
        Operation::UpgradeV2 | Operation::View => {}
        Operation::SignRequestV2 {
            challenge,
            method,
            path,
            body,
        } => {
            if path == "/v2/session" && s.enrollment.is_none() {
                return Err("registration_required");
            }
            return super::self_service::sign(&s.legacy, &challenge, &method, &path, &body);
        }
        Operation::SignSessionV2 {
            session,
            operation,
            id,
        } => {
            return sign_session(&s, &session, &operation, id.as_deref());
        }
        Operation::ServerStatusV2 { status } => {
            let c = &s
                .legacy
                .identity
                .as_ref()
                .ok_or("invalid_state")?
                .credential;
            if status.mode != "active"
                || status.account != c.account
                || status.device != c.device
                || status.credential != c.fingerprint()
            {
                return Err("status_conflict");
            }
            s.enrollment = Some(status);
        }
        Operation::PrepareContactV2 => {
            if s.enrollment.is_none() {
                return Err("registration_required");
            }
            if s.fallback_key.is_none() {
                let mut a = account(&s.legacy)?;
                a.generate_fallback_key();
                s.fallback_key = Some(
                    a.fallback_key()
                        .values()
                        .next()
                        .ok_or("prekey_error")?
                        .to_base64(),
                );
                a.mark_keys_as_published();
                s.legacy.account = encode(a.pickle())?;
            }
        }
        Operation::ContactTextV2 { text } => {
            if text.len() > 4096 {
                return Err("qr_limit");
            }
            let c: ContactV2 = serde_json::from_str(&text).map_err(|_| "invalid_contact")?;
            c.verify(&s.legacy)?;
            return Ok(
                json!({"fingerprint":c.fingerprint(),"account":c.credential.account}).to_string(),
            );
        }
        Operation::PairContactV2 { text, verified } => {
            if !verified || s.enrollment.is_none() {
                return Err("peer_not_verified");
            }
            if text.len() > 4096 {
                return Err("qr_limit");
            }
            let c: ContactV2 = serde_json::from_str(&text).map_err(|_| "invalid_contact")?;
            c.verify(&s.legacy)?;
            add_peer(&mut s, c, Trust::OutOfBandVerified)?;
        }
        Operation::SendV2 {
            account,
            text,
            now_ms,
        } => {
            if s.enrollment.is_none() {
                return Err("registration_required");
            }
            if text.is_empty() || text.len() > 2048 {
                return Err("invalid_text");
            }
            enqueue(&mut s, &account, Body::Text(text), now_ms)?;
        }
        Operation::SendCallV1 { account, body } => {
            if s.enrollment.is_none() {
                return Err("registration_required");
            }
            body.validate()?;
            enqueue(&mut s, &account, Body::Call(body), 0)?;
        }
        Operation::ReceiveV2 { message, now_ms } => {
            if s.enrollment.is_none() {
                return Err("registration_required");
            }
            let result = receive(&mut s, message, now_ms)?;
            return reply(s, Some(result));
        }
        Operation::AcceptedV2 { id } => {
            let c = s
                .conversations
                .values_mut()
                .find(|c| c.outbox.iter().any(|m| m.id == id))
                .ok_or("unknown_acceptance")?;
            c.outbox.retain(|m| m.id != id);
            if let Some(h) = c.history.iter_mut().find(|h| h.id == id) {
                h.accepted = true;
            }
        }
        Operation::BlockContactV2 { account, blocked } => {
            s.conversations
                .get_mut(&account)
                .ok_or("unknown_contact")?
                .blocked = blocked;
        }
    }
    reply(s, None)
}
