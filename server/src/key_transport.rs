//! Existing v0 envelope semantics inside the key-auth mode/room transaction.
use crate::{invalid, Cursor, Failure, Store, Submission};
use axum::{
    extract::Query,
    http::{StatusCode, Uri},
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use sqlx::{Postgres, Transaction};
pub(crate) async fn messages(
    s: &Store,
    tx: &mut Transaction<'_, Postgres>,
    slot: i16,
    method: &str,
    uri: &Uri,
    body: &[u8],
) -> Result<Value, Failure> {
    if method == "GET" {
        if !body.is_empty() {
            return Err(invalid());
        }
        let Query(c) = Query::<Cursor>::try_from_uri(uri)
            .map_err(|_| Failure(StatusCode::BAD_REQUEST, "invalid_cursor"))?;
        let limit = c.limit.unwrap_or(50);
        if c.after < 0 || !(1..=100).contains(&limit) {
            return Err(Failure(StatusCode::BAD_REQUEST, "invalid_cursor"));
        }
        let rows:Vec<(String,i64,i16,Vec<u8>)>=sqlx::query_as("SELECT message_id,sequence,sender,ciphertext FROM envelopes WHERE recipient=$1 AND sequence>$2 ORDER BY sequence LIMIT $3")
            .bind(slot).bind(c.after).bind(limit).fetch_all(&mut **tx).await?;
        let cursor = rows.last().map(|r| r.1).unwrap_or(c.after);
        let messages:Vec<Value>=rows.into_iter().map(|(id,sequence,sender,bytes)|json!({"id":id,"sequence":sequence,"sender":if sender==0 {"alice"}else{"bob"},"ciphertext":STANDARD.encode(bytes)})).collect();
        return Ok(json!({"messages":messages,"cursor":cursor}));
    }
    if method != "POST" || uri.query().is_some() {
        return Err(invalid());
    }
    let input: Submission = serde_json::from_slice(body).map_err(|_| invalid())?;
    let recipient = match input.recipient.as_str() {
        "alice" => 0,
        "bob" => 1,
        _ => return Err(invalid()),
    };
    if slot == recipient {
        return Err(invalid());
    }
    let id = uuid::Uuid::parse_str(&input.id)
        .map_err(|_| invalid())?
        .to_string();
    let bytes = STANDARD.decode(input.ciphertext).map_err(|_| invalid())?;
    if bytes.is_empty() || bytes.len() > 16384 {
        return Err(invalid());
    }
    let (used, last): (i64, i64) =
        sqlx::query_as("SELECT used_bytes,sequence FROM room_state WHERE id=1 FOR UPDATE")
            .fetch_one(&mut **tx)
            .await?;
    let existing: Option<(i64, i16, Vec<u8>)> = sqlx::query_as(
        "SELECT sequence,recipient,ciphertext FROM envelopes WHERE sender=$1 AND message_id=$2",
    )
    .bind(slot)
    .bind(&id)
    .fetch_optional(&mut **tx)
    .await?;
    if let Some((sequence, old_recipient, old_bytes)) = existing {
        if recipient != old_recipient || bytes != old_bytes {
            return Err(Failure(StatusCode::CONFLICT, "idempotency_conflict"));
        }
        return Ok(json!({"id":id,"sequence":sequence}));
    }
    if last >= 100000 || bytes.len() as i64 > s.quota.saturating_sub(used) {
        return Err(Failure(StatusCode::INSUFFICIENT_STORAGE, "quota_exceeded"));
    }
    let sequence:i64=sqlx::query_scalar("UPDATE room_state SET sequence=sequence+1,used_bytes=used_bytes+$1 WHERE id=1 RETURNING sequence").bind(bytes.len() as i64).fetch_one(&mut **tx).await?;
    sqlx::query("INSERT INTO envelopes(sequence,sender,recipient,message_id,ciphertext) VALUES($1,$2,$3,$4,$5)").bind(sequence).bind(slot).bind(recipient).bind(&id).bind(bytes).execute(&mut **tx).await?;
    Ok(json!({"id":id,"sequence":sequence}))
}
