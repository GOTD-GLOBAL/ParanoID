use axum::{
    extract::{
        rejection::{JsonRejection, QueryRejection},
        DefaultBodyLimit, Query, State,
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use std::sync::Arc;
use subtle::ConstantTimeEq;
mod key_http;
mod key_transport;
pub mod registration;

#[derive(Clone)]
struct Store {
    pool: PgPool,
    hashes: [[u8; 32]; 2],
    quota: i64,
}
struct Failure(StatusCode, &'static str);
impl IntoResponse for Failure {
    fn into_response(self) -> Response {
        (self.0, Json(serde_json::json!({"error":self.1}))).into_response()
    }
}
impl From<sqlx::Error> for Failure {
    fn from(_: sqlx::Error) -> Self {
        Self(StatusCode::SERVICE_UNAVAILABLE, "storage_unavailable")
    }
}
fn invalid() -> Failure {
    Failure(StatusCode::BAD_REQUEST, "invalid_envelope")
}
fn authenticate(s: &Store, h: &HeaderMap) -> Result<i16, Failure> {
    let value = h
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|v| v.len() == 64)
        .ok_or(Failure(StatusCode::UNAUTHORIZED, "unauthorized"))?;
    let hash: [u8; 32] = Sha256::digest(value.as_bytes()).into();
    // Always compare both hashes; never log headers or credential material.
    let a = hash.ct_eq(&s.hashes[0]);
    let b = hash.ct_eq(&s.hashes[1]);
    if bool::from(a) {
        Ok(0)
    } else if bool::from(b) {
        Ok(1)
    } else {
        Err(Failure(StatusCode::UNAUTHORIZED, "unauthorized"))
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Submission {
    id: String,
    recipient: String,
    ciphertext: String,
}
#[derive(Serialize)]
struct Accepted {
    id: String,
    sequence: i64,
}

pub async fn stored_app(
    pool: PgPool,
    tokens: [String; 2],
    quota: i64,
) -> Result<Router, sqlx::Error> {
    if tokens[0] == tokens[1]
        || tokens
            .iter()
            .any(|t| t.len() != 64 || !t.bytes().all(|c| c.is_ascii_hexdigit()))
        || quota < 1
    {
        return Err(sqlx::Error::Configuration(
            "invalid development configuration".into(),
        ));
    }
    let mut tx = pool.begin().await?;
    sqlx::raw_sql(include_str!("../schema.sql"))
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    let state = Arc::new(Store {
        pool,
        hashes: tokens.map(|t| Sha256::digest(t.as_bytes()).into()),
        quota,
    });
    Ok(app()
        .merge(
            Router::new()
                .route("/v0/messages", post(send).get(sync))
                .with_state(state),
        )
        .layer(DefaultBodyLimit::max(24576)))
}
pub fn development_database_allowed(options: &sqlx::postgres::PgConnectOptions, ci: bool) -> bool {
    use std::os::unix::fs::MetadataExt;
    if let Some(socket) = options.get_socket() {
        let Some(parent) = socket.parent() else {
            return false;
        };
        if !socket.is_absolute()
            || !parent
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("paranoid-"))
        {
            return false;
        }
        let (Ok(s), Ok(p)) = (
            std::fs::symlink_metadata(socket),
            std::fs::symlink_metadata(parent),
        ) else {
            return false;
        };
        return s.is_dir()
            && p.is_dir()
            && s.mode() & 0o777 == 0o700
            && p.mode() & 0o777 == 0o700
            && s.uid() == p.uid();
    }
    // Explicitly opted-in disposable CI service only; never arbitrary remote URLs.
    ci && options.get_host() == "127.0.0.1"
        && options.get_port() == 5432
        && options.get_database() == Some("paranoid_test")
        && options.get_username() == "paranoid_test"
}

pub fn app() -> Router {
    Router::new().route(
        "/health",
        get(|| async { Json(serde_json::json!({"status":"ok","protocol":"paranoid-dev-v0"})) }),
    )
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Cursor {
    #[serde(default)]
    after: i64,
    limit: Option<i64>,
}
#[derive(Serialize)]
struct Envelope {
    id: String,
    sequence: i64,
    sender: &'static str,
    ciphertext: String,
}
#[derive(Serialize)]
struct Page {
    messages: Vec<Envelope>,
    cursor: i64,
}
async fn sync(
    State(s): State<Arc<Store>>,
    headers: HeaderMap,
    query: Result<Query<Cursor>, QueryRejection>,
) -> Result<Json<Page>, Failure> {
    let recipient = authenticate(&s, &headers)?;
    let Query(query) = query.map_err(|e| Failure(e.status(), "invalid_cursor"))?;
    let limit = query.limit.unwrap_or(50);
    if query.after < 0 || !(1..=100).contains(&limit) {
        return Err(Failure(StatusCode::BAD_REQUEST, "invalid_cursor"));
    }
    let rows: Vec<(String,i64,i16,Vec<u8>)>=sqlx::query_as("SELECT message_id,sequence,sender,ciphertext FROM envelopes WHERE recipient=$1 AND sequence>$2 ORDER BY sequence LIMIT $3")
        .bind(recipient).bind(query.after).bind(limit).fetch_all(&s.pool).await?;
    let messages: Vec<_> = rows
        .into_iter()
        .map(|(id, sequence, sender, bytes)| Envelope {
            id,
            sequence,
            sender: if sender == 0 { "alice" } else { "bob" },
            ciphertext: STANDARD.encode(bytes),
        })
        .collect();
    let cursor = messages.last().map(|m| m.sequence).unwrap_or(query.after);
    Ok(Json(Page { messages, cursor }))
}

async fn send(
    State(s): State<Arc<Store>>,
    headers: HeaderMap,
    input: Result<Json<Submission>, JsonRejection>,
) -> Result<Json<Accepted>, Failure> {
    let sender = authenticate(&s, &headers)?;
    let Json(input) = input.map_err(|e| Failure(e.status(), "invalid_envelope"))?;
    let recipient = match input.recipient.as_str() {
        "alice" => 0,
        "bob" => 1,
        _ => return Err(invalid()),
    };
    if sender == recipient {
        return Err(invalid());
    }
    let id = uuid::Uuid::parse_str(&input.id)
        .map_err(|_| invalid())?
        .to_string();
    let bytes = STANDARD.decode(input.ciphertext).map_err(|_| invalid())?;
    if bytes.is_empty() || bytes.len() > 16384 {
        return Err(invalid());
    }
    let mut tx = s.pool.begin().await?;
    sqlx::query("SET LOCAL synchronous_commit = on")
        .execute(&mut *tx)
        .await?;
    // The fixed room row serializes commit order, not merely sequence allocation.
    let (used, last): (i64, i64) =
        sqlx::query_as("SELECT used_bytes,sequence FROM room_state WHERE id=1 FOR UPDATE")
            .fetch_one(&mut *tx)
            .await?;
    let existing: Option<(i64, i16, Vec<u8>)> = sqlx::query_as(
        "SELECT sequence,recipient,ciphertext FROM envelopes WHERE sender=$1 AND message_id=$2",
    )
    .bind(sender)
    .bind(&id)
    .fetch_optional(&mut *tx)
    .await?;
    if let Some((sequence, old_recipient, old_bytes)) = existing {
        if recipient != old_recipient || bytes != old_bytes {
            return Err(Failure(StatusCode::CONFLICT, "idempotency_conflict"));
        }
        tx.commit().await?;
        return Ok(Json(Accepted { id, sequence }));
    }
    if last >= 100000 || bytes.len() as i64 > s.quota.saturating_sub(used) {
        return Err(Failure(StatusCode::INSUFFICIENT_STORAGE, "quota_exceeded"));
    }
    let sequence: i64=sqlx::query_scalar("UPDATE room_state SET sequence=sequence+1, used_bytes=used_bytes+$1 WHERE id=1 RETURNING sequence")
        .bind(bytes.len() as i64).fetch_one(&mut *tx).await?;
    sqlx::query("INSERT INTO envelopes(sequence,sender,recipient,message_id,ciphertext) VALUES($1,$2,$3,$4,$5)")
        .bind(sequence).bind(sender).bind(recipient).bind(&id).bind(bytes).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(Json(Accepted { id, sequence }))
}
