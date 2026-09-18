//! Versioned client adapter; legacy state remains intact until explicit operations.
use super::contact_v2::ContactV2;
use super::*;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct State {
    version: u32,
    legacy: Client,
    enrollment: Option<Status>,
    fallback_key: Option<String>,
    legacy_contact: Option<ContactV2>,
    #[serde(default)]
    first_unverified_sequence: Option<i64>,
    conversations: BTreeMap<String, Conversation>,
    cursor: i64,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Conversation {
    contact: ContactV2,
    // This adapter has NO Account/private prekeys; legacy.account is the only owner.
    state: Client,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Status {
    mode: String,
    account: String,
    device: String,
    credential: String,
}
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Operation {
    UpgradeV2,
    AcceptedV2 {
        id: String,
    },
    SignRequestV2 {
        challenge: Box<paranoid_key_protocol::ChallengeV2>,
        method: String,
        path: String,
        body: String,
    },
    PrepareContactV2,
    // RFC-0014 offline inspection only: no state or transport mutation.
    PrepareSenderIntroV2 {
        id: String,
    },
    InspectSenderIntroV2 {
        message: Incoming,
    },
    PairContactV2 {
        text: String,
        verified: bool,
    },
    SendV2 {
        account: String,
        text: String,
        /// The client's own clock at the instant of the tap, in milliseconds
        /// since the epoch; absent or zero means the client keeps no time.
        #[serde(default)]
        now_ms: u64,
    },
    ReceiveV2 {
        message: Incoming,
        /// The client's own clock at the instant this event was committed.
        #[serde(default)]
        now_ms: u64,
    },
    ContactTextV2 {
        text: String,
    },
    ServerStatusV2 {
        status: Status,
    },
    View,
}
pub(super) fn validate(s: &Client) -> Result<()> {
    if s.version != 0 {
        return Err("unsupported_state");
    }
    let a = account(s)?;
    if a.curve25519_key().to_base64() != s.public.curve {
        return Err("invalid_state");
    }
    key(&s.public.one_time_key)?;
    for p in &s.sessions {
        session(p)?;
    }
    let i = s.identity.as_ref().ok_or("create_identity_first")?;
    i.credential.verify()?;
    if i.credential.olm
        != paranoid_key_protocol::olm_digest(&s.public.curve, &s.public.one_time_key)
        || i.credential.realm != s.public.realm
    {
        return Err("invalid_state");
    }
    if let Some(c) = &s.peer_credential {
        c.verify()?;
        let p = s.peer.as_ref().ok_or("invalid_state")?;
        if c.account == i.credential.account
            || c.realm != i.credential.realm
            || c.pin != i.credential.pin
            || c.olm != paranoid_key_protocol::olm_digest(&p.curve, &p.one_time_key)
        {
            return Err("invalid_state");
        }
    }
    for (secret, public) in [
        (&i.root_secret, &i.credential.root),
        (&i.auth_secret, &i.credential.auth),
    ] {
        if vodozemac::Ed25519SecretKey::from_base64(secret)
            .map_err(|_| "invalid_state")?
            .public_key()
            .to_base64()
            != *public
        {
            return Err("invalid_state");
        }
    }
    Ok(())
}
fn validate_state(s: &State) -> Result<()> {
    if s.version != 2
        || s.cursor < 0
        || s.conversations.len() > 64
        || s.first_unverified_sequence
            .is_some_and(|n| !(1..=100000).contains(&n))
    {
        return Err("invalid_state");
    }
    validate(&s.legacy)?;
    if let Some(fallback) = &s.fallback_key {
        // Pinned vodozemac AccountPickle format, already parsed by account().
        let secret: vodozemac::Curve25519SecretKey = serde_json::from_value(
            s.legacy.account["fallback_keys"]["fallback_key"]["key"].clone(),
        )
        .map_err(|_| "invalid_state")?;
        if Curve25519PublicKey::from(&secret).to_base64() != *fallback {
            return Err("invalid_state");
        }
    }
    let own = &s
        .legacy
        .identity
        .as_ref()
        .ok_or("invalid_state")?
        .credential;
    if let Some(status) = &s.enrollment {
        if status.mode != "active"
            || status.account != own.account
            || status.device != own.device
            || status.credential != own.fingerprint()
        {
            return Err("invalid_state");
        }
    }
    if let Some(c) = &s.legacy_contact {
        c.verify(&s.legacy)?;
        if s.legacy.peer.as_ref() != Some(&c.bundle)
            || s.legacy
                .peer_credential
                .as_ref()
                .is_some_and(|p| *p != c.credential)
        {
            return Err("invalid_state");
        }
    }
    for (id, c) in &s.conversations {
        c.contact.verify(&s.legacy)?;
        let mut public = s.legacy.public.clone();
        public.device = own.account.clone();
        let mut peer = c.contact.bundle.clone();
        peer.device = id.clone();
        peer.one_time_key = c.contact.fallback_key.clone();
        if *id != c.contact.credential.account
            || !c.state.account.is_null()
            || c.state.identity.is_some()
            || c.state.version != 0
            || c.state.public != public
            || c.state.peer.as_ref() != Some(&peer)
            || c.state.cursor < 0
            || legacy_credential(s).is_some_and(|p| p.account == *id)
        {
            return Err("invalid_state");
        }
        for pickle in &c.state.sessions {
            session(pickle)?;
        }
    }
    Ok(())
}
fn legacy_credential(s: &State) -> Option<&paranoid_key_protocol::Credential> {
    s.legacy_contact
        .as_ref()
        .map(|c| &c.credential)
        .or(s.legacy.peer_credential.as_ref())
}
fn reply(s: State) -> Result<String> {
    if serde_json::to_vec(&s).map_err(|_| "state_error")?.len() > 8 * 1024 * 1024 {
        return Err("local_state_full");
    }
    let mut result: Value = serde_json::from_str(&super::reply(
        serde_json::from_value(encode(&s.legacy)?).map_err(|_| "invalid_state")?,
    )?)
    .map_err(|_| "state_error")?;
    result["enrollment"] = encode(&s.enrollment)?;
    let contact = s
        .fallback_key
        .as_ref()
        .map(|f| ContactV2::create(&s.legacy, f))
        .transpose()?;
    result["contact_fingerprint"] = encode(contact.as_ref().map(ContactV2::fingerprint))?;
    result["contact"] = encode(contact)?;
    let mut outbox = Vec::new();
    let mut dialogs = Vec::new();
    for (id, c) in &s.conversations {
        outbox.extend(c.state.outbox.iter().cloned());
        dialogs.push(
            json!({"account":id,"fingerprint":c.contact.fingerprint(),"own":c.state.public.device,"messages":c.state.history}),
        );
    }
    if let Some(c) = legacy_credential(&s) {
        let id = &c.account;
        for old in &s.legacy.outbox {
            let mut wire = old.clone();
            wire.recipient = id.clone();
            outbox.push(wire);
        }
        dialogs.push(json!({"account":id,"fingerprint":c.fingerprint(),"own":s.legacy.public.device,"messages":s.legacy.history}));
    }
    if legacy_credential(&s).is_none() && s.legacy.peer.is_some() {
        dialogs.push(json!({"account":"legacy-unverified","requires_verification":true,"own":s.legacy.public.device,"messages":s.legacy.history}));
    }
    result["outbox"] = encode(outbox)?;
    result["dialogs"] = encode(dialogs)?;
    result["cursor"] = json!(s.cursor);
    result["rejected_count"] = json!(s
        .conversations
        .values()
        .fold(s.legacy.rejected_count, |sum, c| sum
            .saturating_add(c.state.rejected_count)));
    result["state"] = encode(s)?;
    Ok(result.to_string())
}
pub(super) fn sign(
    s: &Client,
    c: &paranoid_key_protocol::ChallengeV2,
    method: &str,
    path: &str,
    body: &str,
) -> Result<String> {
    let i = s.identity.as_ref().ok_or("create_identity_first")?;
    let purpose = match (method, path) {
        ("POST", "/v2/registration/commit") if body == "{}" => "register",
        ("POST", "/v2/auth/verify") if body == "{}" => "status",
        ("POST", "/v2/session") if body == "{}" => "session",
        ("POST", "/v2/messages") => "message",
        ("GET", p)
            if body.is_empty() && (p == "/v2/messages" || p.starts_with("/v2/messages?")) =>
        {
            "message"
        }
        _ => return Err("invalid_proof_purpose"),
    };
    let canonical_uuid = |raw: &str| {
        uuid::Uuid::parse_str(raw).is_ok_and(|u| u.to_string() == raw && u.get_version_num() == 4)
    };
    let nonce_ok = STANDARD
        .decode(&c.nonce)
        .is_ok_and(|n| n.len() == 32 && STANDARD.encode(n) == c.nonce);
    if c.method != method
        || c.path != path
        || c.body != paranoid_key_protocol::digest(body.as_bytes())
        || c.purpose != purpose
        || c.account != i.credential.account
        || c.device != i.credential.device
        || c.credential != i.credential.fingerprint()
        || c.realm != i.credential.realm
        || c.pin != i.credential.pin
        || c.expires < 1
        || !canonical_uuid(&c.id)
        || !canonical_uuid(&c.epoch)
        || !nonce_ok
    {
        return Err("proof_context_mismatch");
    }
    let key =
        vodozemac::Ed25519SecretKey::from_base64(&i.auth_secret).map_err(|_| "invalid_state")?;
    Ok(
        json!({"authorization":format!("ParanoidV2 {}.{}",c.id,key.sign(&c.bytes()).to_base64())})
            .to_string(),
    )
}
fn apply_conversation(s: &mut State, id: &str, mut request: Value) -> Result<()> {
    if legacy_credential(s).is_some_and(|c| c.account == id) {
        if request["op"] == "receive" {
            request["message"]["sender"] =
                json!(s.legacy.peer.as_ref().ok_or("invalid_state")?.device);
            if !s.legacy.seen.contains_key(
                request["message"]["id"]
                    .as_str()
                    .ok_or("invalid_envelope")?,
            ) {
                s.legacy.cursor = s.cursor;
            }
        }
        let result = super::command(&encode(&s.legacy)?.to_string(), &request.to_string())?;
        let value: Value = serde_json::from_str(&result).map_err(|_| "state_error")?;
        s.legacy = serde_json::from_value(value["state"].clone()).map_err(|_| "invalid_state")?;
        if request["op"] == "receive" {
            s.cursor = s.cursor.max(
                request["message"]["sequence"]
                    .as_i64()
                    .ok_or("invalid_envelope")?,
            );
        }
        return Ok(());
    }
    let conversation = s.conversations.get_mut(id).ok_or("verify_peer_first")?;
    // Move the one shared Account into a transient adapter; never duplicate it per peer.
    conversation.state.account = std::mem::take(&mut s.legacy.account);
    if request["op"] == "receive"
        && !conversation.state.seen.contains_key(
            request["message"]["id"]
                .as_str()
                .ok_or("invalid_envelope")?,
        )
    {
        conversation.state.cursor = s.cursor;
    }
    let result = super::command(
        &encode(&conversation.state)?.to_string(),
        &request.to_string(),
    )?;
    let value: Value = serde_json::from_str(&result).map_err(|_| "state_error")?;
    conversation.state =
        serde_json::from_value(value["state"].clone()).map_err(|_| "invalid_state")?;
    s.legacy.account = std::mem::take(&mut conversation.state.account);
    if request["op"] == "receive" {
        s.cursor = s.cursor.max(
            request["message"]["sequence"]
                .as_i64()
                .ok_or("invalid_envelope")?,
        );
    }
    Ok(())
}
pub(super) fn command(state: &str, request: &str) -> Result<String> {
    let op: Operation = serde_json::from_str(request).map_err(|_| "invalid_request")?;
    let raw: Value = serde_json::from_str(state).map_err(|_| "invalid_state")?;
    if let Operation::SignRequestV2 {
        challenge,
        method,
        path,
        body,
    } = &op
    {
        if raw["version"] == 2 {
            let s: State = serde_json::from_str(state).map_err(|_| "invalid_state")?;
            validate_state(&s)?;
            return sign(&s.legacy, challenge, method, path, body);
        }
        let legacy: Client = serde_json::from_str(state).map_err(|_| "invalid_state")?;
        validate(&legacy)?;
        return sign(&legacy, challenge, method, path, body);
    }
    let mut s = if raw["version"] == 0 && matches!(op, Operation::UpgradeV2) {
        let legacy: Client = serde_json::from_str(state).map_err(|_| "invalid_state")?;
        validate(&legacy)?;
        State {
            version: 2,
            cursor: legacy.cursor,
            legacy,
            conversations: BTreeMap::new(),
            enrollment: None,
            fallback_key: None,
            legacy_contact: None,
            first_unverified_sequence: None,
        }
    } else {
        let s: State = serde_json::from_str(state).map_err(|_| "invalid_state")?;
        if s.version != 2 {
            return Err("unsupported_state");
        }
        validate_state(&s)?;
        s
    };
    if let Operation::PrepareSenderIntroV2 { id } = &op {
        if s.enrollment.is_none() {
            return Err("registration_required");
        }
        // Deliberately exclude retained legacy profiles and arbitrary caller bytes.
        let (conversation, pending) = s
            .conversations
            .values()
            .find_map(|c| c.state.outbox.iter().find(|m| m.id == *id).map(|m| (c, m)))
            .ok_or("unknown_pending_account_profile")?;
        let envelope = super::sender_intro::Introduction::create(
            &s.legacy,
            s.fallback_key.as_deref().ok_or("prepare_contact_first")?,
            &conversation.contact,
            pending,
        )?;
        return Ok(json!({"envelope":envelope}).to_string());
    }
    if let Operation::InspectSenderIntroV2 { message } = &op {
        let intro = super::sender_intro::Introduction::inspect(
            &s.legacy,
            s.fallback_key.as_deref().ok_or("prepare_contact_first")?,
            message,
        )?;
        if legacy_credential(&s).is_some_and(|c| c.account == message.sender)
            || s.legacy
                .peer
                .as_ref()
                .is_some_and(|p| p.curve == intro.contact.bundle.curve)
        {
            return Err("introduction_profile_conflict");
        }
        if s.conversations
            .get(&message.sender)
            .is_some_and(|old| old.contact != intro.contact)
        {
            return Err("peer_already_pinned");
        }
        return intro.report();
    }
    if matches!(op, Operation::PrepareContactV2) {
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
    if let Operation::ContactTextV2 { ref text } = op {
        if text.len() > 4096 {
            return Err("qr_limit");
        }
        let contact: ContactV2 = serde_json::from_str(text).map_err(|_| "invalid_contact")?;
        contact.verify(&s.legacy)?;
        return Ok(
            json!({"fingerprint":contact.fingerprint(),"account":contact.credential.account})
                .to_string(),
        );
    }
    match &op {
        Operation::AcceptedV2 { id } => {
            let legacy = legacy_credential(&s)
                .filter(|_| s.legacy.outbox.iter().any(|m| m.id == *id))
                .map(|c| c.account.clone());
            let account = legacy
                .or_else(|| {
                    s.conversations
                        .iter()
                        .find(|(_, c)| c.state.outbox.iter().any(|m| m.id == *id))
                        .map(|(a, _)| a.clone())
                })
                .ok_or("unknown_acceptance")?;
            apply_conversation(&mut s, &account, json!({"op":"accepted","id":id}))?;
        }
        Operation::PairContactV2 { text, verified } => {
            if !verified || s.enrollment.is_none() {
                return Err("peer_not_verified");
            }
            if text.len() > 4096 {
                return Err("qr_limit");
            }
            let contact: ContactV2 = serde_json::from_str(text).map_err(|_| "invalid_contact")?;
            contact.verify(&s.legacy)?;
            let id = contact.credential.account.clone();
            if s.legacy
                .peer
                .as_ref()
                .is_some_and(|p| p.curve == contact.bundle.curve)
                || legacy_credential(&s).is_some_and(|c| c.account == id)
            {
                if s.legacy.peer.as_ref() != Some(&contact.bundle)
                    || s.legacy
                        .peer_credential
                        .as_ref()
                        .is_some_and(|c| *c != contact.credential)
                    || s.legacy_contact.as_ref().is_some_and(|c| *c != contact)
                {
                    return Err("peer_already_pinned");
                }
                if s.legacy_contact.is_none() {
                    if let Some(first) = s.first_unverified_sequence {
                        s.cursor = s.cursor.min(first - 1);
                    }
                }
                s.legacy_contact = Some(contact);
                return reply(s);
            }
            if let Some(old) = s.conversations.get(&id) {
                if old.contact != contact {
                    return Err("peer_already_pinned");
                }
            } else {
                if s.conversations.len() >= 64 {
                    return Err("contact_limit");
                }
                let mut public = s.legacy.public.clone();
                public.device = s
                    .legacy
                    .identity
                    .as_ref()
                    .ok_or("invalid_state")?
                    .credential
                    .account
                    .clone();
                let mut peer = contact.bundle.clone();
                peer.device = id.clone();
                peer.one_time_key = contact.fallback_key.clone();
                let state = Client {
                    enrollment: None,
                    peer_credential: None,
                    grant: None,
                    identity: None,
                    version: 0,
                    public,
                    account: Value::Null,
                    peer: Some(peer),
                    sessions: vec![],
                    cursor: 0,
                    outbox: vec![],
                    history: vec![],
                    seen: BTreeMap::new(),
                    rejected_events: vec![],
                    rejected_count: 0,
                    first_rejected_sequence: None,
                };
                s.conversations.insert(id, Conversation { contact, state });
                if let Some(first) = s.first_unverified_sequence {
                    s.cursor = s.cursor.min(first - 1);
                }
            }
        }
        Operation::SendV2 {
            account,
            text,
            now_ms,
        } => {
            if s.enrollment.is_none() {
                return Err("registration_required");
            }
            apply_conversation(
                &mut s,
                account,
                json!({"op":"send","text":text,"now_ms":now_ms}),
            )?;
        }
        Operation::ReceiveV2 { message, now_ms } => {
            let sender = message.sender.clone();
            if !s.conversations.contains_key(&sender)
                && !legacy_credential(&s).is_some_and(|c| c.account == sender)
            {
                if !paranoid_key_protocol::hex32(&sender)
                    || message.sequence <= s.cursor
                    || message.sequence > 100000
                    || !uuid::Uuid::parse_str(&message.id)
                        .is_ok_and(|id| id.to_string() == message.id)
                {
                    return Err("invalid_envelope");
                }
                if s.first_unverified_sequence.is_none() {
                    s.first_unverified_sequence = Some(message.sequence);
                }
                if s.legacy.rejected_events.iter().any(|e| {
                    e.id == message.id
                        && e.sequence == message.sequence
                        && e.reason == "unverified_contact"
                }) {
                    s.cursor = message.sequence;
                    return reply(s);
                }
                // Never decrypt, auto-pin or acknowledge an unknown contact. Retain
                // ciphertext on the server and a bounded visible deferred-event notice.
                if s.legacy.rejected_events.len() >= 64 {
                    s.legacy.rejected_events.remove(0);
                }
                s.legacy.rejected_events.push(RejectedEvent {
                    id: message.id.clone(),
                    sequence: message.sequence,
                    reason: "unverified_contact".into(),
                });
                s.legacy.rejected_count = s.legacy.rejected_count.saturating_add(1);
                if s.legacy.first_rejected_sequence.is_none() {
                    s.legacy.first_rejected_sequence = Some(message.sequence);
                }
                s.cursor = message.sequence;
                return reply(s);
            }
            let m = json!({"id":message.id,"sender":message.sender,"sequence":message.sequence,"ciphertext":message.ciphertext});
            apply_conversation(
                &mut s,
                &sender,
                json!({"op":"receive","message":m,"now_ms":now_ms}),
            )?;
            let verified = if legacy_credential(&s).is_some_and(|c| c.account == sender) {
                s.legacy.seen.contains_key(&message.id)
            } else {
                s.conversations
                    .get(&sender)
                    .is_some_and(|c| c.state.seen.contains_key(&message.id))
            };
            if verified {
                let before = s.legacy.rejected_events.len();
                s.legacy.rejected_events.retain(|e| {
                    !(e.id == message.id
                        && e.sequence == message.sequence
                        && e.reason == "unverified_contact")
                });
                s.legacy.rejected_count = s
                    .legacy
                    .rejected_count
                    .saturating_sub((before - s.legacy.rejected_events.len()) as u64);
            }
        }
        _ => {}
    }
    if let Operation::ServerStatusV2 { status } = op {
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
    reply(s)
}
