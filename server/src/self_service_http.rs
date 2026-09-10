use crate::Failure;
use axum::{
    body::Bytes,
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, Method, StatusCode, Uri},
    routing::post,
    Json, Router,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use paranoid_key_protocol::{
    digest, session_nonce_valid, verify, ChallengeV2, Credential, SessionV2,
};
use rand::RngCore;
use sqlx::PgPool;
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

struct Service {
    pool: PgPool,
    realm: String,
    pin: String,
    epoch: String,
    devices: Mutex<HashMap<String, (Instant, u8)>>,
    pending: Mutex<HashMap<String, (ChallengeV2, Credential, Instant)>>,
    sessions: Mutex<HashMap<String, Session>>,
    waiters: Mutex<HashSet<String>>,
    changed: tokio::sync::Notify,
    turn: Option<crate::voice_turn::Issuer>,
}
struct Session {
    context: SessionV2,
    credential: Credential,
    issued: Instant,
    nonces: HashSet<String>,
}
impl Session {
    fn alive(&self) -> bool {
        self.issued.elapsed() < Duration::from_secs(300) && self.context.expires > now()
    }
}
fn denied() -> Failure {
    Failure(StatusCode::UNAUTHORIZED, "unauthorized")
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Register {
    credential: Credential,
    purpose: String,
    method: String,
    path: String,
    body: String,
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Auth {
    account: String,
    device: String,
    credential: String,
    purpose: String,
    method: String,
    path: String,
    body: String,
}

pub async fn app(pool: PgPool) -> Result<Router, sqlx::Error> {
    app_with_turn(pool, None).await
}

pub async fn app_with_turn(
    pool: PgPool,
    turn: Option<crate::voice_turn::TurnConfig>,
) -> Result<Router, sqlx::Error> {
    let (realm, pin): (String, String) =
        sqlx::query_as("SELECT realm,pin FROM ss_meta WHERE id=1 AND version=2")
            .fetch_one(&pool)
            .await?;
    let turn = turn.map(|config| config.issuer(&realm)).transpose()?;
    let budget = Arc::new(Mutex::new((Instant::now(), 0u32, 0u32)));
    let s = Arc::new(Service {
        pool,
        realm,
        pin,
        epoch: uuid::Uuid::new_v4().to_string(),
        pending: Mutex::new(HashMap::new()),
        devices: Mutex::new(HashMap::new()),
        sessions: Mutex::new(HashMap::new()),
        waiters: Mutex::new(HashSet::new()),
        changed: tokio::sync::Notify::new(),
        turn,
    });
    Ok(Router::new()
        .route(
            "/health",
            axum::routing::get(|| async {
                Json(serde_json::json!({"status":"ok","protocol":"paranoid-self-service-v2","realtime":"signed-long-poll-v1"}))
            }),
        )
        .route("/v2/registration/challenge", post(challenge))
        .route("/v2/registration/commit", post(operation))
        .route("/v2/auth/challenge", post(challenge))
        .route("/v2/auth/verify", post(operation))
        .route("/v2/session", post(operation))
        .route("/v2/events", axum::routing::get(session_operation))
        .route(
            "/v2/voice/turn",
            axum::routing::get(session_operation).layer(axum::middleware::from_fn(
                |request: axum::extract::Request, next: axum::middleware::Next| async move {
                    let mut response = next.run(request).await;
                    response.headers_mut().insert(
                        axum::http::header::CACHE_CONTROL,
                        axum::http::HeaderValue::from_static("no-store"),
                    );
                    response
                },
            )),
        )
        .route(
            "/v2/messages",
            post(operation)
                .get(operation)
                .layer(DefaultBodyLimit::max(24576)),
        )
        .with_state(s)
        .merge(crate::android_updates::router(
            std::env::var_os("PARANOID_ANDROID_UPDATE_ROOT").map(std::path::PathBuf::from),
        ))
        .layer(DefaultBodyLimit::max(8192))
        .layer(axum::middleware::from_fn(
            move |request: axum::extract::Request, next: axum::middleware::Next| {
                let budget = budget.clone();
                async move {
                    use axum::response::IntoResponse;
                    let allowed = {
                        let mut w = budget.lock().unwrap();
                        if w.0.elapsed() >= Duration::from_secs(1) {
                            *w = (Instant::now(), 0, 0);
                        }
                        w.1 = w.1.saturating_add(1);
                        if request.uri().path().starts_with("/v2/auth/")
                            || request.uri().path().starts_with("/v2/registration/")
                            || request.uri().path() == "/v2/session"
                        {
                            w.2 = w.2.saturating_add(1);
                        }
                        w.1 <= 20 && w.2 <= 8
                    };
                    if !allowed {
                        return Failure(StatusCode::TOO_MANY_REQUESTS, "ingress_limit")
                            .into_response();
                    }
                    let seconds = if request.method() == Method::GET && request.uri().path() == "/v2/events" { 25 } else { 10 };
                    match tokio::time::timeout(Duration::from_secs(seconds), next.run(request)).await {
                        Ok(r) => r,
                        Err(_) => {
                            Failure(StatusCode::REQUEST_TIMEOUT, "request_timeout").into_response()
                        }
                    }
                }
            },
        )))
}
fn valid_intent(i: &Register) -> bool {
    if i.path.len() > 512 || !paranoid_key_protocol::hex32(&i.body) {
        return false;
    }
    match (i.purpose.as_str(), i.method.as_str(), i.path.as_str()) {
        ("register", "POST", "/v2/registration/commit")
        | ("status", "POST", "/v2/auth/verify")
        | ("session", "POST", "/v2/session") => i.body == digest(b"{}"),
        ("message", "POST", "/v2/messages") => true,
        ("message", "GET", p) if p == "/v2/messages" || p.starts_with("/v2/messages?") => {
            i.body == digest(b"")
        }
        _ => false,
    }
}
async fn challenge(
    State(s): State<Arc<Service>>,
    uri: Uri,
    bytes: Bytes,
) -> Result<Json<ChallengeV2>, Failure> {
    let i: Register = if uri.path() == "/v2/registration/challenge" {
        serde_json::from_slice(&bytes).map_err(|_| denied())?
    } else {
        let a: Auth = serde_json::from_slice(&bytes).map_err(|_| denied())?;
        let raw:Option<String>=sqlx::query_scalar("SELECT credential FROM ss_devices JOIN ss_accounts USING(account) WHERE account=$1 AND device=$2 AND fingerprint=$3 AND mode='active'").bind(&a.account).bind(&a.device).bind(&a.credential).fetch_optional(&s.pool).await?;
        Register {
            credential: serde_json::from_str(&raw.ok_or_else(denied)?).map_err(|_| denied())?,
            purpose: a.purpose,
            method: a.method,
            path: a.path,
            body: a.body,
        }
    };
    if uri.query().is_some()
        || !valid_intent(&i)
        || (uri.path() == "/v2/registration/challenge") != (i.purpose == "register")
    {
        return Err(denied());
    }
    i.credential.verify().map_err(|_| denied())?;
    if i.credential.realm != s.realm || i.credential.pin != s.pin {
        return Err(denied());
    }
    let mut nonce = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    let c = &i.credential;
    let ch = ChallengeV2 {
        id: uuid::Uuid::new_v4().to_string(),
        nonce: STANDARD.encode(nonce),
        epoch: s.epoch.clone(),
        expires: now() + 60,
        realm: s.realm.clone(),
        pin: s.pin.clone(),
        account: c.account.clone(),
        device: c.device.clone(),
        credential: c.fingerprint(),
        purpose: i.purpose,
        method: i.method,
        path: i.path,
        body: i.body,
    };
    let mut pending = s.pending.lock().unwrap();
    pending.retain(|_, (_, _, t)| t.elapsed() < Duration::from_secs(60));
    if pending.len() >= 16
        || pending
            .values()
            .filter(|(ch, _, _)| ch.account == c.account)
            .count()
            >= 4
    {
        return Err(Failure(StatusCode::TOO_MANY_REQUESTS, "challenge_capacity"));
    }
    let mut devices = s.devices.lock().unwrap();
    devices.retain(|_, (t, _)| t.elapsed() < Duration::from_secs(1));
    let w = devices
        .entry(c.account.clone())
        .or_insert((Instant::now(), 0));
    if w.1 >= 2 {
        return Err(Failure(StatusCode::TOO_MANY_REQUESTS, "device_rate"));
    }
    w.1 += 1;
    pending.insert(ch.id.clone(), (ch.clone(), i.credential, Instant::now()));
    Ok(Json(ch))
}
async fn operation(
    State(s): State<Arc<Service>>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Json<serde_json::Value>, Failure> {
    if headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|h| h.starts_with("ParanoidSessionV2 "))
    {
        return session_operation(State(s), method, uri, headers, bytes).await;
    }
    let h = headers
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("ParanoidV2 "))
        .ok_or_else(denied)?;
    let (id, sig) = h.split_once('.').ok_or_else(denied)?;
    let (ch, c) = {
        let pending = s.pending.lock().unwrap();
        let (ch, c, t) = pending.get(id).ok_or_else(denied)?;
        if t.elapsed() >= Duration::from_secs(60)
            || ch.expires <= now()
            || ch.method != method.as_str()
            || ch.path
                != uri
                    .path_and_query()
                    .map(|x| x.as_str())
                    .unwrap_or(uri.path())
            || ch.body != digest(&bytes)
        {
            return Err(denied());
        }
        verify(&c.auth, &ch.bytes(), sig).map_err(|_| denied())?;
        (ch.clone(), c.clone())
    };
    if s.pending.lock().unwrap().remove(id).is_none() {
        return Err(denied());
    }
    let mut tx = s.pool.begin().await?;
    sqlx::query("SET LOCAL synchronous_commit=on")
        .execute(&mut *tx)
        .await?;
    sqlx::query("SELECT id FROM ss_meta WHERE id=1 FOR UPDATE")
        .execute(&mut *tx)
        .await?;
    let old:Option<(String,String,String,String,String,String)>=sqlx::query_as("SELECT d.fingerprint,a.mode,d.device,d.auth,d.credential,a.root FROM ss_devices d JOIN ss_accounts a USING(account) WHERE account=$1").bind(&c.account).fetch_optional(&mut *tx).await?;
    if let Some((fp, mode, device, auth, raw, root)) = old {
        if fp != c.fingerprint()
            || device != c.device
            || auth != c.auth
            || root != c.root
            || serde_json::from_str::<Credential>(&raw).ok().as_ref() != Some(&c)
            || mode == "revoked"
            || (mode != "active" && ch.purpose != "register")
        {
            return Err(Failure(StatusCode::CONFLICT, "binding_conflict"));
        }
        if mode == "pending" {
            sqlx::query("UPDATE ss_accounts SET mode='active' WHERE account=$1")
                .bind(&c.account)
                .execute(&mut *tx)
                .await?;
        }
    } else {
        if ch.purpose != "register" {
            return Err(denied());
        }
        let conflict: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM ss_devices WHERE device=$1 OR auth=$2 OR fingerprint=$3)",
        )
        .bind(&c.device)
        .bind(&c.auth)
        .bind(c.fingerprint())
        .fetch_one(&mut *tx)
        .await?;
        if conflict {
            return Err(Failure(StatusCode::CONFLICT, "binding_conflict"));
        }
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM ss_accounts")
            .fetch_one(&mut *tx)
            .await?;
        if count >= 1024 {
            return Err(Failure(StatusCode::TOO_MANY_REQUESTS, "account_capacity"));
        }
        let issued:Option<i64>=sqlx::query_scalar("UPDATE ss_meta SET registrations=CASE WHEN floor(extract(epoch FROM clock_timestamp()))::bigint-registration_window>=60 THEN 1 ELSE registrations+1 END, registration_window=CASE WHEN floor(extract(epoch FROM clock_timestamp()))::bigint-registration_window>=60 THEN floor(extract(epoch FROM clock_timestamp()))::bigint ELSE registration_window END WHERE id=1 AND (registrations<8 OR floor(extract(epoch FROM clock_timestamp()))::bigint-registration_window>=60) RETURNING registrations").fetch_optional(&mut *tx).await?;
        if issued.is_none() {
            return Err(Failure(StatusCode::TOO_MANY_REQUESTS, "registration_rate"));
        }
        sqlx::query("INSERT INTO ss_accounts VALUES($1,$2,'active')")
            .bind(&c.account)
            .bind(&c.root)
            .execute(&mut *tx)
            .await?;
        sqlx::query("INSERT INTO ss_devices VALUES($1,$2,$3,$4,$5)")
            .bind(&c.account)
            .bind(&c.device)
            .bind(&c.auth)
            .bind(c.fingerprint())
            .bind(serde_json::to_string(&c).map_err(|_| denied())?)
            .execute(&mut *tx)
            .await?;
    }
    if ch.purpose == "message" {
        let result = crate::self_service_messages::messages(
            &mut tx,
            &ch.account,
            method.as_str(),
            &uri,
            &bytes,
        )
        .await?;
        tx.commit().await?;
        if method == Method::POST {
            s.changed.notify_waiters();
        }
        return Ok(Json(result));
    }
    tx.commit().await?;
    if ch.purpose == "session" {
        let mut sessions = s.sessions.lock().unwrap();
        sessions.retain(|_, session| session.alive());
        if sessions.len() >= 64
            || sessions
                .values()
                .filter(|session| session.context.account == c.account)
                .count()
                >= 2
        {
            return Err(Failure(StatusCode::TOO_MANY_REQUESTS, "session_capacity"));
        }
        let context = SessionV2 {
            id: uuid::Uuid::new_v4().to_string(),
            epoch: s.epoch.clone(),
            expires: now() + 300,
            realm: s.realm.clone(),
            pin: s.pin.clone(),
            account: c.account.clone(),
            device: c.device.clone(),
            credential: c.fingerprint(),
        };
        sessions.insert(
            context.id.clone(),
            Session {
                context: context.clone(),
                credential: c,
                issued: Instant::now(),
                nonces: HashSet::new(),
            },
        );
        return Ok(Json(serde_json::to_value(context).map_err(|_| denied())?));
    }
    Ok(Json(
        serde_json::json!({"mode":"active","account":ch.account,"device":ch.device,"credential":ch.credential}),
    ))
}

type Binding = (String, String, String, String, String, String);

fn binding_matches(old: Option<Binding>, c: &Credential) -> bool {
    old.is_some_and(|(fingerprint, mode, device, auth, raw, root)| {
        mode == "active"
            && fingerprint == c.fingerprint()
            && device == c.device
            && auth == c.auth
            && root == c.root
            && serde_json::from_str::<Credential>(&raw).ok().as_ref() == Some(c)
    })
}

fn still_live(s: &Service, context: &SessionV2) -> Result<(), Failure> {
    let mut sessions = s.sessions.lock().unwrap();
    if sessions
        .get(&context.id)
        .is_some_and(|session| session.alive() && session.context == *context)
    {
        Ok(())
    } else {
        sessions.remove(&context.id);
        Err(denied())
    }
}

fn session_proof(
    s: &Service,
    method: &Method,
    uri: &Uri,
    headers: &HeaderMap,
    body: &[u8],
) -> Result<(SessionV2, Credential), Failure> {
    let route = uri.path();
    if headers.get_all("authorization").iter().count() != 1
        || !matches!(
            (method.as_str(), route),
            ("GET", "/v2/messages" | "/v2/events" | "/v2/voice/turn") | ("POST", "/v2/messages")
        )
        || (method == Method::POST && uri.query().is_some())
        || (route == "/v2/voice/turn" && (uri.query().is_some() || !body.is_empty()))
    {
        return Err(denied());
    }
    let h = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|h| h.strip_prefix("ParanoidSessionV2 "))
        .ok_or_else(denied)?;
    let mut fields = h.split('.');
    let id = fields.next().ok_or_else(denied)?;
    let nonce = fields.next().ok_or_else(denied)?;
    let signature = fields.next().ok_or_else(denied)?;
    if fields.next().is_some() || !session_nonce_valid(nonce) {
        return Err(denied());
    }
    let mut sessions = s.sessions.lock().unwrap();
    let session = sessions.get_mut(id).ok_or_else(denied)?;
    if !session.alive() {
        sessions.remove(id);
        return Err(denied());
    }
    let path = uri.path_and_query().map(|v| v.as_str()).unwrap_or(route);
    verify(
        &session.credential.auth,
        &session
            .context
            .bytes(nonce, method.as_str(), path, &digest(body)),
        signature,
    )
    .map_err(|_| denied())?;
    if session.nonces.contains(nonce) {
        return Err(denied());
    }
    if session.nonces.len() >= 2048 {
        return Err(Failure(StatusCode::TOO_MANY_REQUESTS, "session_exhausted"));
    }
    session.nonces.insert(nonce.to_owned());
    Ok((session.context.clone(), session.credential.clone()))
}

async fn session_query(
    s: &Service,
    context: &SessionV2,
    credential: &Credential,
    method: &Method,
    uri: &Uri,
    body: &[u8],
) -> Result<serde_json::Value, Failure> {
    let mut tx = s.pool.begin().await?;
    sqlx::query("SET LOCAL synchronous_commit=on")
        .execute(&mut *tx)
        .await?;
    let turn_request = uri.path() == "/v2/voice/turn";
    if turn_request {
        let meta: Option<(i16, String, String)> =
            sqlx::query_as("SELECT version,realm,pin FROM ss_meta WHERE id=1 FOR UPDATE")
                .fetch_optional(&mut *tx)
                .await?;
        if !meta
            .is_some_and(|(version, realm, pin)| version == 2 && realm == s.realm && pin == s.pin)
        {
            s.sessions.lock().unwrap().remove(&context.id);
            return Err(denied());
        }
    } else {
        sqlx::query("SELECT id FROM ss_meta WHERE id=1 FOR UPDATE")
            .execute(&mut *tx)
            .await?;
    }
    still_live(s, context)?;
    let old: Option<Binding> = sqlx::query_as("SELECT d.fingerprint,a.mode,d.device,d.auth,d.credential,a.root FROM ss_devices d JOIN ss_accounts a USING(account) WHERE account=$1")
        .bind(&credential.account).fetch_optional(&mut *tx).await?;
    if !binding_matches(old, credential) {
        s.sessions.lock().unwrap().remove(&context.id);
        return Err(denied());
    }
    if turn_request {
        let Some(issuer) = &s.turn else {
            tx.commit().await?;
            return Err(Failure(StatusCode::NOT_FOUND, "turn_disabled"));
        };
        let result = issuer.issue(&credential.account, &credential.device)?;
        tx.commit().await?;
        return Ok(result);
    }
    let result = crate::self_service_messages::messages(
        &mut tx,
        &credential.account,
        method.as_str(),
        uri,
        body,
    )
    .await?;
    tx.commit().await?;
    if method == Method::POST {
        s.changed.notify_waiters();
    }
    Ok(result)
}

// Unlocked hints only. A true result always leads to the locked authorization
// and inbox query above before any response; idle waiters never lock ss_meta.
async fn wait_needs_query(
    s: &Service,
    context: &SessionV2,
    credential: &Credential,
    after: i64,
) -> Result<bool, Failure> {
    still_live(s, context)?;
    let old: Option<Binding> = sqlx::query_as("SELECT d.fingerprint,a.mode,d.device,d.auth,d.credential,a.root FROM ss_devices d JOIN ss_accounts a USING(account) WHERE account=$1")
        .bind(&credential.account).fetch_optional(&s.pool).await?;
    if !binding_matches(old, credential) {
        return Ok(true);
    }
    let available: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM ss_messages WHERE recipient=$1 AND sequence>$2)",
    )
    .bind(&credential.account)
    .bind(after)
    .fetch_one(&s.pool)
    .await?;
    Ok(available)
}

struct WaitGuard(Arc<Service>, String);
impl Drop for WaitGuard {
    fn drop(&mut self) {
        self.0.waiters.lock().unwrap().remove(&self.1);
    }
}

async fn session_operation(
    State(s): State<Arc<Service>>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<serde_json::Value>, Failure> {
    let (context, credential) = session_proof(&s, &method, &uri, &headers, &body)?;
    if uri.path() != "/v2/events" {
        return session_query(&s, &context, &credential, &method, &uri, &body)
            .await
            .map(Json);
    }
    let axum::extract::Query(cursor) =
        axum::extract::Query::<crate::Cursor>::try_from_uri(&uri).map_err(|_| crate::invalid())?;
    if cursor.after < 0 || !(1..=100).contains(&cursor.limit.unwrap_or(50)) || !body.is_empty() {
        return Err(crate::invalid());
    }
    {
        let mut waiters = s.waiters.lock().unwrap();
        if waiters.len() >= 8 || !waiters.insert(credential.account.clone()) {
            return Err(Failure(StatusCode::TOO_MANY_REQUESTS, "waiter_busy"));
        }
    }
    let _guard = WaitGuard(s.clone(), credential.account.clone());
    let lifetime = {
        let sessions = s.sessions.lock().unwrap();
        let session = sessions.get(&context.id).ok_or_else(denied)?;
        Duration::from_secs(300)
            .saturating_sub(session.issued.elapsed())
            .min(Duration::from_secs(
                context.expires.saturating_sub(now()).max(0) as u64,
            ))
            .min(Duration::from_secs(20))
    };
    let deadline = tokio::time::Instant::now() + lifetime;
    let mut initial = true;
    loop {
        // Arm before every snapshot/probe, so a commit during either cannot be
        // lost. The durable inbox plus one-second unlocked tick covers a missed
        // notify when the sender future is cancelled after committing.
        let notification = s.changed.notified();
        tokio::pin!(notification);
        notification.as_mut().enable();
        if initial
            || tokio::time::Instant::now() >= deadline
            || wait_needs_query(&s, &context, &credential, cursor.after).await?
        {
            let result = session_query(&s, &context, &credential, &method, &uri, &body).await?;
            if !result["messages"].as_array().is_some_and(Vec::is_empty)
                || tokio::time::Instant::now() >= deadline
            {
                return Ok(Json(result));
            }
        }
        initial = false;
        tokio::select! {
            _ = &mut notification => {},
            _ = tokio::time::sleep_until(deadline) => {},
            _ = tokio::time::sleep(Duration::from_secs(1)) => {},
        }
    }
}
