//! General account-pair conversations, serialized by the caller's ss_meta lock.
use crate::{invalid, Cursor, Failure, Submission};
use axum::{
    extract::Query,
    http::{StatusCode, Uri},
};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use sqlx::{Postgres, Transaction};
pub(crate) async fn messages(
    tx: &mut Transaction<'_, Postgres>,
    sender: &str,
    method: &str,
    uri: &Uri,
    body: &[u8],
) -> Result<Value, Failure> {
    if method == "GET" {
        let Query(c) = Query::<Cursor>::try_from_uri(uri).map_err(|_| invalid())?;
        let limit = c.limit.unwrap_or(50);
        if c.after < 0 || !(1..=100).contains(&limit) || !body.is_empty() {
            return Err(invalid());
        }
        let rows:Vec<(String,i64,String,Vec<u8>)>=sqlx::query_as("SELECT message_id,sequence,sender,ciphertext FROM ss_messages WHERE recipient=$1 AND sequence>$2 ORDER BY sequence LIMIT $3").bind(sender).bind(c.after).bind(limit).fetch_all(&mut **tx).await?;
        let cursor = rows.last().map(|x| x.1).unwrap_or(c.after);
        let messages:Vec<Value>=rows.into_iter().map(|(id,sequence,sender,bytes)|json!({"id":id,"sequence":sequence,"sender":sender,"ciphertext":STANDARD.encode(bytes)})).collect();
        return Ok(json!({"messages":messages,"cursor":cursor}));
    }
    if method != "POST" || uri.query().is_some() {
        return Err(invalid());
    }
    let i: Submission = serde_json::from_slice(body).map_err(|_| invalid())?;
    if !paranoid_key_protocol::hex32(&i.recipient)
        || i.recipient == sender
        || uuid::Uuid::parse_str(&i.id)
            .map(|u| u.to_string() != i.id)
            .unwrap_or(true)
    {
        return Err(invalid());
    }
    let bytes = STANDARD.decode(&i.ciphertext).map_err(|_| invalid())?;
    if bytes.is_empty() || bytes.len() > 16384 || STANDARD.encode(&bytes) != i.ciphertext {
        return Err(invalid());
    }
    let old: Option<(i64, String, Vec<u8>)> = sqlx::query_as(
        "SELECT sequence,recipient,ciphertext FROM ss_messages WHERE sender=$1 AND message_id=$2",
    )
    .bind(sender)
    .bind(&i.id)
    .fetch_optional(&mut **tx)
    .await?;
    if let Some((sequence, recipient, old_bytes)) = old {
        if recipient != i.recipient || bytes != old_bytes {
            return Err(Failure(StatusCode::CONFLICT, "idempotency_conflict"));
        }
        return Ok(json!({"id":i.id,"sequence":sequence}));
    }
    let (rows,used,sent_rows,sent_bytes):(i64,i64,i64,i64)=sqlx::query_as("SELECT count(*),coalesce(sum(octet_length(ciphertext)),0)::bigint,count(*) FILTER(WHERE sender=$1),coalesce(sum(octet_length(ciphertext)) FILTER(WHERE sender=$1),0)::bigint FROM ss_messages").bind(sender).fetch_one(&mut **tx).await?;
    if rows >= 100000
        || sent_rows >= 10000
        || bytes.len() as i64 > 16777216i64.saturating_sub(sent_bytes)
        || bytes.len() as i64 > 268435456i64.saturating_sub(used)
    {
        return Err(Failure(StatusCode::INSUFFICIENT_STORAGE, "quota_exceeded"));
    }
    let exists: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM ss_accounts WHERE account=$1 AND mode='active')",
    )
    .bind(&i.recipient)
    .fetch_one(&mut **tx)
    .await?;
    if !exists {
        return Err(invalid());
    }
    let (a, b) = if sender < i.recipient.as_str() {
        (sender, i.recipient.as_str())
    } else {
        (i.recipient.as_str(), sender)
    };
    sqlx::query("INSERT INTO ss_conversations VALUES($1,$2) ON CONFLICT DO NOTHING")
        .bind(a)
        .bind(b)
        .execute(&mut **tx)
        .await?;
    let sequence: i64 =
        sqlx::query_scalar("UPDATE ss_meta SET sequence=sequence+1 WHERE id=1 RETURNING sequence")
            .fetch_one(&mut **tx)
            .await?;
    sqlx::query("INSERT INTO ss_messages VALUES($1,$2,$3,$4,$5,$6,$7)")
        .bind(sequence)
        .bind(sender)
        .bind(&i.recipient)
        .bind(&i.id)
        .bind(bytes)
        .bind(a)
        .bind(b)
        .execute(&mut **tx)
        .await?;
    Ok(json!({"id":i.id,"sequence":sequence}))
}
