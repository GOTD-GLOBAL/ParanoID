//! RFC-0028 server member directory (identity-v3 mode only).
//!
//! Every route here is reached ONLY through the signed v2 session path
//! (`self_service_http::session_query`), after the session proof, the `ss_meta FOR UPDATE`
//! lock and the exact active-binding check. This module additionally requires that the
//! caller's transport account is the CURRENT account of an ACTIVE identity membership, so a
//! retired (replaced) or banned member is refused even if some session survived.
//!
//! Rate limits are fixed windows persisted in PostgreSQL and updated under the same
//! `ss_meta` lock: 60 requests per member per 3600 s (`id_memberships.directory_*`) and
//! 600 per server per 3600 s (`id_meta.directory_*`). A wall-clock rollback denies.
//! A refused request (either budget) consumes nothing; an accepted-then-invalid request
//! still counts.
use crate::Failure;
use axum::http::StatusCode;
use paranoid_key_protocol::{digest, olm_digest, transcript, verify, Credential};
use serde_json::{json, Value};
use sqlx::PgConnection;

pub(crate) const PAGE: i64 = 50;
const WINDOW: i64 = 3600;
pub(crate) const MEMBER_BUDGET: i64 = 60;
pub(crate) const SERVER_BUDGET: i64 = 600;
const CARD_LIMIT: usize = 4096;

fn denied() -> Failure {
    Failure(StatusCode::UNAUTHORIZED, "unauthorized")
}

/// Directory query grammar: empty, or a prefix of an RFC-0026 canonical name.
fn valid_prefix(query: &str) -> bool {
    query.len() <= 24
        && query
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
        && query.bytes().next().is_none_or(|c| c.is_ascii_lowercase())
}

/// Minimal server-side mirror of the client `ContactV2` wire object (clients/core
/// `contact_v2.rs`). The server checks the binding and signature only; the phone that adds
/// the contact re-verifies everything, including Curve25519 key canonicity.
#[derive(serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
struct Card {
    #[serde(rename = "type")]
    kind: String,
    credential: Credential,
    bundle: Bundle,
    fallback_key: String,
    signature: String,
}
#[derive(serde::Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
struct Bundle {
    device: String,
    realm: String,
    curve: String,
    one_time_key: String,
}

fn check_card(card: &Card, active: &Credential, realm: &str) -> Result<(), Failure> {
    let bad = || crate::invalid();
    let b = &card.bundle;
    if card.kind != "paranoid-contact-v2"
        || card.credential != *active
        || b.realm != realm
        || card.credential.olm != olm_digest(&b.curve, &b.one_time_key)
        || !["unassigned", "alice", "bob"].contains(&b.device.as_str())
        || [&b.curve, &b.one_time_key, &card.fallback_key]
            .iter()
            .any(|k| k.is_empty() || k.len() > 64)
    {
        return Err(Failure(StatusCode::CONFLICT, "card_mismatch"));
    }
    let bytes = transcript(&[
        "paranoid-contact-v2",
        &card.credential.fingerprint(),
        &b.device,
        &b.realm,
        &b.curve,
        &b.one_time_key,
        &card.fallback_key,
    ]);
    verify(&card.credential.auth, &bytes, &card.signature).map_err(|_| bad())?;
    Ok(())
}

/// Consume one request from the member window and, for searches, the server window;
/// refuse without consuming. Visibility and card publication never touch the server
/// window, so other members cannot stop anyone from hiding or being listed (review P2-1).
async fn take_budget(
    conn: &mut PgConnection,
    membership: &str,
    search: bool,
) -> Result<(), Failure> {
    let busy = || Failure(StatusCode::TOO_MANY_REQUESTS, "directory_rate");
    if search {
        take_server_budget(conn).await?;
    }
    let member: Option<i64> = sqlx::query_scalar("UPDATE id_memberships SET directory_count=CASE WHEN t.n-directory_window>=$2 THEN 1 ELSE directory_count+1 END, directory_window=CASE WHEN t.n-directory_window>=$2 THEN t.n ELSE directory_window END FROM (SELECT floor(extract(epoch FROM clock_timestamp()))::bigint AS n) t WHERE membership=$1 AND t.n>=directory_window AND (directory_count<$3 OR t.n-directory_window>=$2) RETURNING directory_count")
        .bind(membership)
        .bind(WINDOW)
        .bind(MEMBER_BUDGET)
        .fetch_optional(&mut *conn)
        .await?;
    if member.is_none() {
        return Err(busy());
    }
    Ok(())
}

async fn take_server_budget(conn: &mut PgConnection) -> Result<(), Failure> {
    let busy = || Failure(StatusCode::TOO_MANY_REQUESTS, "directory_rate");
    let server: Option<i64> = sqlx::query_scalar("UPDATE id_meta SET directory_count=CASE WHEN t.n-directory_window>=$1 THEN 1 ELSE directory_count+1 END, directory_window=CASE WHEN t.n-directory_window>=$1 THEN t.n ELSE directory_window END FROM (SELECT floor(extract(epoch FROM clock_timestamp()))::bigint AS n) t WHERE id=1 AND t.n>=directory_window AND (directory_count<$2 OR t.n-directory_window>=$1) RETURNING directory_count")
        .bind(WINDOW)
        .bind(SERVER_BUDGET)
        .fetch_optional(&mut *conn)
        .await?;
    if server.is_none() {
        return Err(busy());
    }
    Ok(())
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Search {
    query: String,
    after: Option<String>,
}
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Visibility {
    visible: bool,
}

type Entry = (String, String, String, String, String);

/// Runs inside the caller's locked transaction. An outer `Err` rolls back (nothing was
/// charged). An inner result is returned only after the budget was taken: the caller
/// commits the transaction for both inner `Ok` and inner `Err`, so a well-formed but
/// rejected request (for example a card that does not match) still counts.
pub(crate) async fn handle(
    conn: &mut PgConnection,
    realm: &str,
    credential: &Credential,
    route: &str,
    body: &[u8],
) -> Result<Result<Value, Failure>, Failure> {
    let caller: Option<(String, String, bool, Option<String>)> = sqlx::query_as("SELECT m.membership,m.name,m.visible,m.card FROM id_memberships m JOIN id_bindings b ON b.account=m.account AND b.membership=m.membership WHERE m.account=$1 AND m.state='active' AND NOT b.retired")
        .bind(&credential.account)
        .fetch_optional(&mut *conn)
        .await?;
    let Some((membership, own_name, visible, card)) = caller else {
        return Err(denied());
    };
    // Parse before charging: malformed bodies never reach the database.
    enum Request {
        Search(Search),
        Visibility(bool),
        Card(Box<Card>),
    }
    let request = match route {
        "/v3/directory/search" => {
            let s: Search = serde_json::from_slice(body).map_err(|_| crate::invalid())?;
            if !valid_prefix(&s.query)
                || s.after
                    .as_deref()
                    .is_some_and(|a| paranoid_key_protocol::identity_v3::canonical_name(a).is_err())
            {
                return Err(crate::invalid());
            }
            Request::Search(s)
        }
        "/v3/directory/visibility" => Request::Visibility(
            serde_json::from_slice::<Visibility>(body)
                .map_err(|_| crate::invalid())?
                .visible,
        ),
        "/v3/directory/card" => {
            if body.len() > CARD_LIMIT {
                return Err(crate::invalid());
            }
            Request::Card(Box::new(
                serde_json::from_slice(body).map_err(|_| crate::invalid())?,
            ))
        }
        _ => return Err(denied()),
    };
    take_budget(conn, &membership, matches!(request, Request::Search(_))).await?;
    let result = match request {
        Request::Search(s) => {
            let rows: Vec<Entry> = sqlx::query_as("SELECT m.name,m.owner,m.identity,m.card,m.proof FROM id_memberships m JOIN ss_accounts a ON a.account=m.account JOIN id_bindings b ON b.account=m.account AND b.membership=m.membership WHERE m.state='active' AND a.mode='active' AND NOT b.retired AND m.visible AND m.card IS NOT NULL AND m.membership<>$1 AND starts_with(m.name,$2) AND ($3::text IS NULL OR m.name COLLATE \"C\" > $3::text COLLATE \"C\") ORDER BY m.name COLLATE \"C\" LIMIT $4")
                .bind(&membership)
                .bind(&s.query)
                .bind(&s.after)
                .bind(PAGE + 1)
                .fetch_all(&mut *conn)
                .await?;
            let more = rows.len() as i64 > PAGE;
            let mut members = Vec::new();
            for (name, owner, identity, card, proof) in rows.into_iter().take(PAGE as usize) {
                let contact: Value = serde_json::from_str(&card).map_err(|_| crate::invalid())?;
                let proof: Value = serde_json::from_str(&proof).map_err(|_| crate::invalid())?;
                members.push(json!({"name":name,"owner":owner,"identity":identity,"contact":contact,"proof":proof}));
            }
            let next = if more {
                members.last().map(|m| m["name"].clone())
            } else {
                None
            };
            Ok(
                json!({"members":members,"next":next,"me":{"name":own_name,"visible":visible,"card":card.is_some()}}),
            )
        }
        Request::Visibility(v) => {
            sqlx::query("UPDATE id_memberships SET visible=$2 WHERE membership=$1")
                .bind(&membership)
                .bind(v)
                .execute(&mut *conn)
                .await?;
            Ok(json!({"name":own_name,"visible":v}))
        }
        Request::Card(c) => match check_card(&c, credential, realm) {
            Err(e) => Err(e),
            Ok(()) => {
                let canonical = serde_json::to_string(&c).map_err(|_| crate::invalid())?;
                sqlx::query("UPDATE id_memberships SET card=$2 WHERE membership=$1")
                    .bind(&membership)
                    .bind(&canonical)
                    .execute(&mut *conn)
                    .await?;
                Ok(json!({"published":true,"name":own_name,"card":digest(canonical.as_bytes())}))
            }
        },
    };
    Ok(result)
}

#[cfg(test)]
mod tests {
    #[test]
    fn prefix_grammar() {
        for ok in ["", "a", "bob", "bob_1", "a23456789012345678901234"] {
            assert!(super::valid_prefix(ok), "{ok}");
        }
        for bad in [
            "_",
            "1",
            "B",
            "bo b",
            "%",
            "a%",
            "a\\",
            "a2345678901234567890123456",
        ] {
            assert!(!super::valid_prefix(bad), "{bad}");
        }
    }
}
