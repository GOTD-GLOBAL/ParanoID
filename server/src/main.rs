use sqlx::postgres::PgPoolOptions;
use std::{env, net::SocketAddr, time::Duration};

#[tokio::main]
async fn main() {
    if run().await.is_err() {
        // Never print connection strings, credentials, request payloads or raw DB errors.
        eprintln!("ParanoID development server could not start or stopped with an error");
        std::process::exit(1);
    }
}
async fn run() -> Result<(), Box<dyn std::error::Error>> {
    if env::var("PARANOID_DEVELOPMENT_ONLY").as_deref() != Ok("1") {
        return Err("development opt-in required".into());
    }
    let address: SocketAddr = env::var("PARANOID_BIND")
        .unwrap_or_else(|_| "127.0.0.1:38300".into())
        .parse()?;
    if !address.ip().is_loopback() {
        return Err("only loopback is supported".into());
    }
    let tokens = [
        env::var("PARANOID_ALICE_TOKEN")?,
        env::var("PARANOID_BOB_TOKEN")?,
    ];
    let quota: i64 = env::var("PARANOID_QUOTA_BYTES")
        .unwrap_or_else(|_| "16777216".into())
        .parse()?;
    let options: sqlx::postgres::PgConnectOptions = env::var("PARANOID_DATABASE_URL")?.parse()?;
    let ci = env::var("PARANOID_CI_TEST_DATABASE").as_deref() == Ok("1");
    if !paranoid_server::development_database_allowed(&options, ci) {
        return Err("private development database required".into());
    }
    let pool = PgPoolOptions::new()
        .max_connections(4)
        .acquire_timeout(Duration::from_secs(5))
        .connect_with(options)
        .await?;
    let app = paranoid_server::stored_app(pool, tokens, quota).await?;
    let listener = tokio::net::TcpListener::bind(address).await?;
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
