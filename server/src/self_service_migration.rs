//! Offline key-granted history mapping. Never assigns a legacy slot to a new key.
use paranoid_key_protocol::Credential;
use sqlx::{Postgres, Transaction};
fn invalid() -> sqlx::Error {
    sqlx::Error::Configuration("ambiguous legacy state".into())
}
pub(crate) async fn check_schema(tx: &mut Transaction<'_, Postgres>) -> Result<(), sqlx::Error> {
    sqlx::raw_sql("CREATE SCHEMA ss_expected; SET LOCAL search_path=ss_expected")
        .execute(&mut **tx)
        .await?;
    sqlx::raw_sql(include_str!("../schema.sql"))
        .execute(&mut **tx)
        .await?;
    sqlx::raw_sql(include_str!("../key-schema.sql"))
        .execute(&mut **tx)
        .await?;
    sqlx::query("SET LOCAL search_path=pg_catalog")
        .execute(&mut **tx)
        .await?;
    let expected: Vec<String> = sqlx::query_scalar(include_str!("../legacy-schema-snapshot.sql"))
        .bind("ss_expected")
        .fetch_all(&mut **tx)
        .await?;
    let actual: Vec<String> = sqlx::query_scalar(include_str!("../legacy-schema-snapshot.sql"))
        .bind("public")
        .fetch_all(&mut **tx)
        .await?;
    let normalize = |v: Vec<String>, schema: &str| -> Vec<String> {
        v.into_iter()
            .map(|s| s.replace(&format!("{schema}."), ""))
            .collect()
    };
    if normalize(expected, "ss_expected") != normalize(actual, "public") {
        return Err(invalid());
    }
    sqlx::raw_sql("DROP SCHEMA ss_expected CASCADE; SET LOCAL search_path=public")
        .execute(&mut **tx)
        .await?;
    Ok(())
}
pub(crate) async fn migrate(
    tx: &mut Transaction<'_, Postgres>,
    realm: &str,
    pin: &str,
) -> Result<(), sqlx::Error> {
    let tables:Vec<String>=sqlx::query_scalar("SELECT table_name::text FROM information_schema.tables WHERE table_schema='public' AND table_name NOT LIKE 'ss_%' ORDER BY table_name").fetch_all(&mut **tx).await?;
    if tables != ["envelopes", "key_grants", "key_meta", "room_state"] {
        return Err(invalid());
    }
    sqlx::query("LOCK TABLE room_state,envelopes,key_grants,key_meta IN ACCESS EXCLUSIVE MODE")
        .execute(&mut **tx)
        .await?;
    let meta: Vec<(i16, i16, String, String)> =
        sqlx::query_as("SELECT id,version,realm,pin FROM key_meta")
            .fetch_all(&mut **tx)
            .await?;
    if meta != vec![(1, 1, realm.to_owned(), pin.to_owned())] {
        return Err(invalid());
    }
    let room: Vec<(i16, i64, i64)> =
        sqlx::query_as("SELECT id,sequence,used_bytes FROM room_state")
            .fetch_all(&mut **tx)
            .await?;
    let (last,used):(i64,i64)=sqlx::query_as("SELECT coalesce(max(sequence),0),coalesce(sum(octet_length(ciphertext)),0)::bigint FROM envelopes").fetch_one(&mut **tx).await?;
    if room != vec![(1, last, used)] {
        return Err(invalid());
    }
    type Grant = (i16, String, String, String, String, String, String, String);
    let grants:Vec<Grant>=sqlx::query_as("SELECT slot,grant_id,credential,fingerprint,account,device,auth,mode FROM key_grants ORDER BY slot").fetch_all(&mut **tx).await?;
    sqlx::query("CREATE TABLE ss_legacy_slots(slot SMALLINT PRIMARY KEY CHECK(slot IN (0,1)),account TEXT NOT NULL UNIQUE REFERENCES ss_accounts(account))").execute(&mut **tx).await?;
    for (slot, grant, raw, fp, account, device, auth, mode) in grants {
        let c: Credential = serde_json::from_str(&raw).map_err(|_| invalid())?;
        c.verify().map_err(|_| invalid())?;
        if !(0..=1).contains(&slot)
            || uuid::Uuid::parse_str(&grant)
                .map(|u| u.to_string() != grant)
                .unwrap_or(true)
            || c.fingerprint() != fp
            || c.account != account
            || c.device != device
            || c.auth != auth
            || c.realm != realm
            || c.pin != pin
        {
            return Err(invalid());
        }
        let mapped = match mode.as_str() {
            "approved" | "pending" => "pending",
            "active" => "active",
            "revoked" => "revoked",
            _ => return Err(invalid()),
        };
        sqlx::query("INSERT INTO ss_accounts VALUES($1,$2,$3)")
            .bind(&account)
            .bind(&c.root)
            .bind(mapped)
            .execute(&mut **tx)
            .await?;
        sqlx::query("INSERT INTO ss_devices VALUES($1,$2,$3,$4,$5)")
            .bind(&account)
            .bind(device)
            .bind(auth)
            .bind(fp)
            .bind(raw)
            .execute(&mut **tx)
            .await?;
        sqlx::query("INSERT INTO ss_legacy_slots VALUES($1,$2)")
            .bind(slot)
            .bind(account)
            .execute(&mut **tx)
            .await?;
    }
    let unbound:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM envelopes e LEFT JOIN ss_legacy_slots s ON e.sender=s.slot LEFT JOIN ss_legacy_slots r ON e.recipient=r.slot WHERE s.account IS NULL OR r.account IS NULL)").fetch_one(&mut **tx).await?;
    if unbound {
        return Err(invalid());
    }
    let ids: Vec<String> = sqlx::query_scalar("SELECT message_id FROM envelopes")
        .fetch_all(&mut **tx)
        .await?;
    if ids.iter().any(|id| {
        uuid::Uuid::parse_str(id)
            .map(|u| u.to_string() != *id)
            .unwrap_or(true)
    }) {
        return Err(invalid());
    }
    sqlx::query("INSERT INTO ss_conversations SELECT DISTINCT least(s.account,r.account),greatest(s.account,r.account) FROM envelopes e JOIN ss_legacy_slots s ON e.sender=s.slot JOIN ss_legacy_slots r ON e.recipient=r.slot").execute(&mut **tx).await?;
    sqlx::query("INSERT INTO ss_messages SELECT e.sequence,s.account,r.account,e.message_id,e.ciphertext,least(s.account,r.account),greatest(s.account,r.account) FROM envelopes e JOIN ss_legacy_slots s ON e.sender=s.slot JOIN ss_legacy_slots r ON e.recipient=r.slot").execute(&mut **tx).await?;
    sqlx::raw_sql("CREATE TABLE ss_legacy_key_meta AS TABLE key_meta; ALTER TABLE key_meta DROP CONSTRAINT key_meta_version_check; ALTER TABLE key_meta ADD CONSTRAINT key_meta_version_check CHECK(version=2) NOT VALID; UPDATE key_meta SET version=2; ALTER TABLE key_meta VALIDATE CONSTRAINT key_meta_version_check").execute(&mut **tx).await?;
    sqlx::query("UPDATE ss_meta SET sequence=$1 WHERE id=1")
        .bind(last)
        .execute(&mut **tx)
        .await?;
    Ok(())
}
