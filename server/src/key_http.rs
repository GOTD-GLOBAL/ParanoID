use crate::Failure;
use axum::{
    body::Bytes,
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, Method, StatusCode, Uri},
    routing::post,
    Json, Router,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use paranoid_key_protocol::{digest, verify, Challenge, Credential};
use rand::RngCore;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

struct Keys {
    store: crate::Store,
    pool: PgPool,
    realm: String,
    pin: String,
    epoch: String,
    challenges: Mutex<HashMap<String, (Challenge, Instant)>>,
    devices: Mutex<[(Instant, u8); 2]>,
}
fn denied() -> Failure {
    Failure(StatusCode::UNAUTHORIZED, "unauthorized")
}
pub async fn key_app(pool: PgPool, tokens: [String; 2], quota: i64) -> Result<Router, sqlx::Error> {
    crate::self_service::reject_cutover(&pool).await?;
    if tokens[0] == tokens[1]
        || tokens
            .iter()
            .any(|t| t.len() != 64 || !t.bytes().all(|c| c.is_ascii_hexdigit()))
        || quota < 1
    {
        return Err(sqlx::Error::Configuration("invalid configuration".into()));
    }
    let (realm, pin): (String, String) =
        sqlx::query_as("SELECT realm,pin FROM key_meta WHERE id=1 AND version=1")
            .fetch_one(&pool)
            .await?;
    let store = crate::Store {
        pool: pool.clone(),
        hashes: tokens.map(|t| Sha256::digest(t.as_bytes()).into()),
        quota,
    };
    let s = Arc::new(Keys {
        store,
        pool,
        realm,
        pin,
        epoch: uuid::Uuid::new_v4().to_string(),
        challenges: Mutex::new(HashMap::new()),
        devices: Mutex::new([(Instant::now(), 0); 2]),
    });
    let budget = Arc::new(Mutex::new((Instant::now(), 0u32, 0u32)));
    Ok(crate::app()
        .merge(
            Router::new()
                .route("/v1/enrollment/challenge", post(challenge))
                .route("/v1/auth/challenge", post(challenge))
                .route("/v1/enrollment/commit", post(operation))
                .route("/v1/auth/verify", post(operation))
                .route("/v1/enrollment/activate", post(operation))
                .route(
                    "/v1/messages",
                    post(operation)
                        .get(operation)
                        .layer(DefaultBodyLimit::max(24576)),
                )
                .route(
                    "/v0/messages",
                    post(operation)
                        .get(operation)
                        .layer(DefaultBodyLimit::max(24576)),
                )
                .with_state(s),
        )
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
                        if request.uri().path().starts_with("/v1/auth/")
                            || request.uri().path().starts_with("/v1/enrollment/")
                        {
                            w.2 = w.2.saturating_add(1);
                        }
                        w.1 <= 20 && w.2 <= 8
                    };
                    if !allowed {
                        return Failure(StatusCode::TOO_MANY_REQUESTS, "ingress_limit")
                            .into_response();
                    }
                    match tokio::time::timeout(Duration::from_secs(10), next.run(request)).await {
                        Ok(r) => r,
                        Err(_) => {
                            Failure(StatusCode::REQUEST_TIMEOUT, "request_timeout").into_response()
                        }
                    }
                }
            },
        )))
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Intent {
    grant: String,
    credential: String,
    purpose: String,
    method: String,
    path: String,
    body: String,
}
type Record = (i16, String, String, i64, String);
async fn record(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    grant: &str,
) -> Result<Record, Failure> {
    sqlx::query_as(
        "SELECT slot,credential,fingerprint,expires,mode FROM key_grants WHERE grant_id=$1",
    )
    .bind(grant)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or_else(denied)
}
async fn clock(tx: &mut sqlx::Transaction<'_, sqlx::Postgres>) -> Result<i64, Failure> {
    Ok(
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint")
            .fetch_one(&mut **tx)
            .await?,
    )
}
fn allowed(mode: &str, purpose: &str, expires: i64, now: i64) -> bool {
    match purpose {
        "enroll" => mode == "approved" && expires > now,
        "status" => mode == "pending" || mode == "active",
        "activate" => mode == "pending" || mode == "active",
        "message" => mode == "active",
        _ => false,
    }
}
fn purpose(method: &str, path: &str) -> Option<&'static str> {
    match (method, path) {
        ("POST", "/v1/enrollment/commit") => Some("enroll"),
        ("POST", "/v1/auth/verify") => Some("status"),
        ("POST", "/v1/enrollment/activate") => Some("activate"),
        ("POST", "/v1/messages") => Some("message"),
        ("GET", p) if p == "/v1/messages" || p.starts_with("/v1/messages?") => Some("message"),
        _ => None,
    }
}
async fn challenge(
    State(s): State<Arc<Keys>>,
    uri: Uri,
    bytes: Bytes,
) -> Result<Json<Challenge>, Failure> {
    let i: Intent = serde_json::from_slice(&bytes).map_err(|_| denied())?;
    if purpose(&i.method, &i.path) != Some(i.purpose.as_str())
        || (i.purpose != "message" && i.body != digest(b"{}"))
        || (i.method == "GET" && i.body != digest(b""))
        || i.path.len() > 512
        || uri.query().is_some()
        || !paranoid_key_protocol::hex32(&i.body)
        || (uri.path() == "/v1/enrollment/challenge") != (i.purpose == "enroll")
    {
        return Err(denied());
    }
    let mut tx = s.pool.begin().await?;
    let (slot, raw, fingerprint, expires, mode) = record(&mut tx, &i.grant).await?;
    let now = clock(&mut tx).await?;
    if fingerprint != i.credential || !allowed(&mode, &i.purpose, expires, now) {
        return Err(denied());
    }
    let c: Credential = serde_json::from_str(&raw).map_err(|_| denied())?;
    c.verify().map_err(|_| denied())?;
    {
        let mut devices = s.devices.lock().unwrap();
        let w = &mut devices[slot as usize];
        if w.0.elapsed() >= Duration::from_secs(1) {
            *w = (Instant::now(), 0);
        }
        if w.1 >= 2 {
            return Err(Failure(StatusCode::TOO_MANY_REQUESTS, "device_limit"));
        }
        w.1 += 1;
    }
    if c.realm != s.realm || c.pin != s.pin {
        return Err(denied());
    }
    let mut nonce = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut nonce);
    let ch = Challenge {
        id: uuid::Uuid::new_v4().to_string(),
        nonce: STANDARD.encode(nonce),
        epoch: s.epoch.clone(),
        expires: now + 60,
        realm: s.realm.clone(),
        pin: s.pin.clone(),
        account: c.account,
        device: c.device,
        credential: fingerprint,
        grant: i.grant,
        slot,
        purpose: i.purpose,
        method: i.method,
        path: i.path,
        body: i.body,
    };
    tx.commit().await?;
    let mut pending = s.challenges.lock().unwrap();
    pending.retain(|_, (_, t)| t.elapsed() < Duration::from_secs(60));
    if pending.len() >= 16 || pending.values().filter(|(c, _)| c.slot == slot).count() >= 4 {
        return Err(Failure(StatusCode::TOO_MANY_REQUESTS, "challenge_limit"));
    }
    pending.insert(ch.id.clone(), (ch.clone(), Instant::now()));
    Ok(Json(ch))
}
async fn operation(
    State(s): State<Arc<Keys>>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<Json<serde_json::Value>, Failure> {
    let mut tx = s.pool.begin().await?;
    sqlx::query("SET LOCAL synchronous_commit = on")
        .execute(&mut *tx)
        .await?;
    // Same durable room lock orders mode changes and message writes.
    sqlx::query("SELECT id FROM room_state WHERE id=1 FOR UPDATE")
        .execute(&mut *tx)
        .await?;
    if uri.path() == "/v0/messages" {
        let slot = crate::authenticate(&s.store, &headers)?;
        let mode: Option<String> = sqlx::query_scalar("SELECT mode FROM key_grants WHERE slot=$1")
            .bind(slot)
            .fetch_optional(&mut *tx)
            .await?;
        if mode.as_deref() == Some("active") {
            return Err(denied());
        }
        let result =
            crate::key_transport::messages(&s.store, &mut tx, slot, method.as_str(), &uri, &bytes)
                .await?;
        tx.commit().await?;
        return Ok(Json(result));
    }
    let header = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Paranoid "))
        .ok_or_else(denied)?;
    let (id, sig) = header.split_once('.').ok_or_else(denied)?;
    let ch = {
        let pending = s.challenges.lock().unwrap();
        let (ch, t) = pending.get(id).ok_or_else(denied)?;
        if t.elapsed() >= Duration::from_secs(60) {
            return Err(denied());
        }
        ch.clone()
    };
    let (slot, raw, fingerprint, expires, mode) = record(&mut tx, &ch.grant).await?;
    let now = clock(&mut tx).await?;
    let path = uri
        .path_and_query()
        .map(|p| p.as_str())
        .unwrap_or(uri.path());
    if ch.epoch != s.epoch
        || ch.expires <= now
        || ch.method != method.as_str()
        || ch.path != path
        || ch.body != digest(&bytes)
        || ch.credential != fingerprint
        || ch.slot != slot
        || !allowed(&mode, &ch.purpose, expires, now)
    {
        return Err(denied());
    }
    let c: Credential = serde_json::from_str(&raw).map_err(|_| denied())?;
    verify(&c.auth, &ch.bytes(), sig).map_err(|_| denied())?;
    if s.challenges.lock().unwrap().remove(id).is_none() {
        return Err(denied());
    }
    if ch.purpose == "message" {
        let result =
            crate::key_transport::messages(&s.store, &mut tx, slot, method.as_str(), &uri, &bytes)
                .await?;
        tx.commit().await?;
        return Ok(Json(result));
    }
    let mode = if ch.purpose == "enroll" {
        sqlx::query("UPDATE key_grants SET mode='pending' WHERE slot=$1")
            .bind(slot)
            .execute(&mut *tx)
            .await?;
        "pending"
    } else if ch.purpose == "activate" {
        sqlx::query("UPDATE key_grants SET mode='active' WHERE slot=$1")
            .bind(slot)
            .execute(&mut *tx)
            .await?;
        "active"
    } else {
        mode.as_str()
    };
    tx.commit().await?;
    Ok(Json(
        serde_json::json!({"mode":mode,"slot":slot,"grant":ch.grant,"credential":fingerprint}),
    ))
}
