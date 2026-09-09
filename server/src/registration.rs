//! Operator-local exact-key admission. No public approval endpoint.
use paranoid_key_protocol::{Grant, PublicRequest};
use sqlx::{postgres::PgPoolOptions, PgPool};
use std::{
    io::{Read, Write},
    os::unix::fs::OpenOptionsExt,
};

pub use crate::key_http::key_app;

pub async fn renew_cli(args: Vec<String>) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() != 3 {
        return Err(
            "explicit slot, verified fingerprint and new public output file required".into(),
        );
    }
    let slot: i16 = args[0].parse()?;
    if !(0..=1).contains(&slot) {
        return Err("invalid slot".into());
    }
    let pool = local_pool().await?;
    let mut tx = pool.begin().await?;
    sqlx::query("SELECT id FROM room_state WHERE id=1 FOR UPDATE")
        .execute(&mut *tx)
        .await?;
    let raw:Option<String>=sqlx::query_scalar("SELECT credential FROM key_grants WHERE slot=$1 AND fingerprint=$2 AND mode='approved' AND expires<=floor(extract(epoch FROM clock_timestamp()))::bigint")
        .bind(slot).bind(&args[1]).fetch_optional(&mut *tx).await?;
    let credential: paranoid_key_protocol::Credential =
        serde_json::from_str(&raw.ok_or("only expired unconsumed approvals can be renewed")?)?;
    credential.verify()?;
    let expires: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint+900")
            .fetch_one(&mut *tx)
            .await?;
    let grant = Grant {
        kind: "paranoid-grant-v1".into(),
        id: uuid::Uuid::new_v4().to_string(),
        credential: credential.fingerprint(),
        realm: credential.realm,
        pin: credential.pin,
        slot,
        expires,
    };
    sqlx::query("UPDATE key_grants SET grant_id=$1,expires=$2 WHERE slot=$3")
        .bind(&grant.id)
        .bind(expires)
        .bind(slot)
        .execute(&mut *tx)
        .await?;
    let mut output = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&args[2])?;
    output.write_all(serde_json::to_string(&grant)?.as_bytes())?;
    output.sync_all()?;
    tx.commit().await?;
    println!("Expired exact-key grant renewed; no slot or credential changed");
    Ok(())
}

pub async fn revoke_cli(args: Vec<String>) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() != 2 {
        return Err("explicit slot and verified credential fingerprint required".into());
    }
    let slot: i16 = args[0].parse()?;
    if !(0..=1).contains(&slot) || !paranoid_key_protocol::hex32(&args[1]) {
        return Err("invalid binding".into());
    }
    let pool = local_pool().await?;
    let mut tx = pool.begin().await?;
    sqlx::query("SELECT id FROM room_state WHERE id=1 FOR UPDATE")
        .execute(&mut *tx)
        .await?;
    let result=sqlx::query("UPDATE key_grants SET mode='revoked' WHERE slot=$1 AND fingerprint=$2 AND mode IN ('approved','pending','revoked')")
        .bind(slot).bind(&args[1]).execute(&mut *tx).await?;
    if result.rows_affected() != 1 {
        return Err("binding absent or already active; key-only rollback required".into());
    }
    tx.commit().await?;
    println!("Pending grant retired; history and active key-only accounts unchanged");
    Ok(())
}

pub async fn local_pool() -> Result<PgPool, Box<dyn std::error::Error>> {
    let options: sqlx::postgres::PgConnectOptions =
        std::env::var("PARANOID_DATABASE_URL")?.parse()?;
    if options.get_socket().is_none() || !crate::development_database_allowed(&options, false) {
        return Err("private local database required".into());
    }
    Ok(PgPoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await?)
}
pub async fn approve_cli(args: Vec<String>) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() != 5 {
        return Err("expected explicit slot, verified credential fingerprint, verified Olm digest, public request file, new public grant file".into());
    }
    let slot: i16 = args[0].parse()?;
    if !(0..=1).contains(&slot) {
        return Err("invalid slot".into());
    }
    let file = std::fs::File::open(&args[3])?;
    let mut bytes = Vec::new();
    file.take(8193).read_to_end(&mut bytes)?;
    if bytes.len() > 8192 {
        return Err("request limit".into());
    }
    let request: PublicRequest = serde_json::from_slice(&bytes)?;
    request.verify()?;
    let c = &request.credential;
    if c.fingerprint() != args[1] || c.olm != args[2] {
        return Err("verified binding mismatch".into());
    }
    let pool = local_pool().await?;
    let mut tx = pool.begin().await?;
    sqlx::query("SELECT id FROM room_state WHERE id=1 FOR UPDATE")
        .execute(&mut *tx)
        .await?;
    let (realm, pin): (String, String) =
        sqlx::query_as("SELECT realm,pin FROM key_meta WHERE id=1 AND version=1")
            .fetch_one(&mut *tx)
            .await?;
    if realm != c.realm || pin != c.pin {
        return Err("realm mismatch".into());
    }
    let expires: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::bigint + 900")
            .fetch_one(&mut *tx)
            .await?;
    let grant = Grant {
        kind: "paranoid-grant-v1".into(),
        id: uuid::Uuid::new_v4().to_string(),
        credential: c.fingerprint(),
        realm,
        pin,
        slot,
        expires,
    };
    sqlx::query("INSERT INTO key_grants(slot,grant_id,credential,fingerprint,account,device,auth,expires,mode) VALUES($1,$2,$3,$4,$5,$6,$7,$8,'approved')")
        .bind(slot).bind(&grant.id).bind(serde_json::to_string(c)?).bind(&grant.credential).bind(&c.account).bind(&c.device).bind(&c.auth).bind(expires).execute(&mut *tx).await?;
    // Output is public, created exclusively; failure rolls back the grant transaction.
    let mut output = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&args[4])?;
    output.write_all(serde_json::to_string(&grant)?.as_bytes())?;
    output.sync_all()?;
    tx.commit().await?;
    println!("Exact-key grant saved to the requested public descriptor file");
    Ok(())
}
