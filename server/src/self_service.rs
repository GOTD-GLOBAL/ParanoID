//! Draft self-service foundation; offline schema changes only.
pub use crate::self_service_http::{app, app_with_turn};
pub use crate::voice_turn::TurnConfig;
use sqlx::PgPool;

async fn initialize(pool: &PgPool, realm: &str, pin: &str) -> Result<(), sqlx::Error> {
    if !realm.starts_with("https://") || realm.len() > 512 || !paranoid_key_protocol::hex32(pin) {
        return Err(sqlx::Error::Configuration("invalid realm".into()));
    }
    let mut tx = pool.begin().await?;
    let existing: i64 = sqlx::query_scalar("SELECT (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public')+(SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public')+(SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' AND t.typrelid=0 AND t.typelem=0)").fetch_one(&mut *tx).await?;

    if existing != 0 {
        crate::self_service_migration::check_schema(&mut tx).await?;
    }
    sqlx::raw_sql(include_str!("../self-service-schema.sql"))
        .execute(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO ss_meta(id,version,realm,pin) VALUES(1,2,$1,$2)")
        .bind(realm)
        .bind(pin)
        .execute(&mut *tx)
        .await?;
    if existing != 0 {
        crate::self_service_migration::migrate(&mut tx, realm, pin).await?;
    } else {
        sqlx::raw_sql("CREATE TABLE room_state(id SMALLINT PRIMARY KEY CHECK(id=1),sequence BIGINT NOT NULL CHECK(sequence>=0),used_bytes BIGINT NOT NULL CHECK(used_bytes>=0)); CREATE FUNCTION refuse_v0_room_initialization() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'self-service schema requires v2 startup'; END; $$; CREATE TRIGGER key_schema_startup_guard BEFORE INSERT ON room_state FOR EACH ROW EXECUTE FUNCTION refuse_v0_room_initialization()").execute(&mut *tx).await?;
    }
    tx.commit().await
}

pub async fn reject_cutover(pool: &PgPool) -> Result<(), sqlx::Error> {
    let exists: bool = sqlx::query_scalar("SELECT to_regclass('public.ss_meta') IS NOT NULL")
        .fetch_one(pool)
        .await?;
    if exists {
        return Err(sqlx::Error::Configuration(
            "self-service database requires v2 runtime".into(),
        ));
    }
    Ok(())
}
pub fn worker_guard(
    options: &sqlx::postgres::PgConnectOptions,
) -> Result<std::fs::File, Box<dyn std::error::Error>> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
    let directory = options.get_socket().ok_or("private socket required")?;
    if directory.canonicalize()? != *directory
        || directory.metadata()?.permissions().mode() & 0o077 != 0
    {
        return Err("private canonical socket directory required".into());
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(0x20000) // Linux O_NOFOLLOW
        .open(directory.join("paranoid-key-worker.lock"))?;
    let meta = file.metadata()?;
    if !meta.is_file()
        || meta.nlink() != 1
        || meta.permissions().mode() & 0o077 != 0
        || meta.uid() != directory.metadata()?.uid()
    {
        return Err("private single-link worker lock required".into());
    }
    file.try_lock()?;
    Ok(file)
}
pub async fn init_cli() -> Result<(), Box<dyn std::error::Error>> {
    let options: sqlx::postgres::PgConnectOptions =
        std::env::var("PARANOID_DATABASE_URL")?.parse()?;
    if options.get_socket().is_none() || !crate::development_database_allowed(&options, false) {
        return Err("private local database required".into());
    }
    let _guard = worker_guard(&options)?;
    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await?;
    initialize(
        &pool,
        &std::env::var("PARANOID_KEY_REALM")?,
        &std::env::var("PARANOID_KEY_PIN")?,
    )
    .await?;
    println!("Self-service schema initialized offline");
    Ok(())
}
