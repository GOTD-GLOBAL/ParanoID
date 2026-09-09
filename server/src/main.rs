use sqlx::postgres::PgPoolOptions;
use std::{env, net::SocketAddr, time::Duration};
mod limited_accept;

#[cfg(test)]
mod deployment_tests {
    #[test]
    fn key_external_bind_requires_exact_reviewed_ipv4() {
        let external = "192.0.2.10:38443".parse().unwrap();
        assert!(super::bind_allowed(
            external,
            true,
            true,
            Some("192.0.2.10")
        ));
        assert!(!super::bind_allowed(external, true, true, None));
        assert!(!super::bind_allowed(
            external,
            true,
            true,
            Some("192.0.2.11")
        ));
        assert!(!super::bind_allowed(
            "0.0.0.0:38443".parse().unwrap(),
            true,
            true,
            Some("0.0.0.0")
        ));
        assert!(!super::bind_allowed(
            "192.0.2.10:443".parse().unwrap(),
            true,
            true,
            Some("192.0.2.10")
        ));
        assert!(!super::bind_allowed(
            external,
            false,
            false,
            Some("192.0.2.10")
        ));
        assert!(super::bind_allowed(
            "127.0.0.1:38443".parse().unwrap(),
            true,
            true,
            None
        ));
    }
}

fn bind_allowed(
    address: SocketAddr,
    alpha: bool,
    key_mode: bool,
    reviewed_ip: Option<&str>,
) -> bool {
    if alpha && address.port() != 38443 {
        return false;
    }
    if !alpha {
        return address.ip().is_loopback();
    }
    if !key_mode || address.ip().is_loopback() {
        return true;
    }
    address.is_ipv4()
        && !address.ip().is_unspecified()
        && !address.ip().is_multicast()
        && reviewed_ip == Some(address.ip().to_string().as_str())
}

#[tokio::main]
async fn main() {
    if run().await.is_err() {
        // Never print connection strings, credentials, request payloads or raw DB errors.
        eprintln!("ParanoID development server could not start or stopped with an error");
        std::process::exit(1);
    }
}
async fn run() -> Result<(), Box<dyn std::error::Error>> {
    if env::args().nth(1).as_deref() == Some("deployment-capabilities") {
        use sha2::{Digest, Sha256};
        println!(
            "{}",
            serde_json::json!({
                "deployment_api": 1, "runtime": "key-v1-local-lock-close-v1",
                "schema": format!("{:x}", Sha256::digest(include_bytes!("../schema.sql"))),
                "key_schema": format!("{:x}", Sha256::digest(include_bytes!("../key-schema.sql")))
            })
        );
        return Ok(());
    }
    if env::args().nth(1).as_deref() == Some("key-admin-renew") {
        return paranoid_server::registration::renew_cli(env::args().skip(2).collect()).await;
    }
    if env::args().nth(1).as_deref() == Some("key-admin-revoke") {
        return paranoid_server::registration::revoke_cli(env::args().skip(2).collect()).await;
    }
    if env::args().nth(1).as_deref() == Some("key-admin-approve") {
        return paranoid_server::registration::approve_cli(env::args().skip(2).collect()).await;
    }
    if env::args().nth(1).as_deref() == Some("key-admin-init") {
        let options: sqlx::postgres::PgConnectOptions =
            env::var("PARANOID_DATABASE_URL")?.parse()?;
        if options.get_socket().is_none()
            || !paranoid_server::development_database_allowed(&options, false)
        {
            return Err("private local database required".into());
        }
        let pool = PgPoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await?;
        let realm = env::var("PARANOID_KEY_REALM")?;
        let pin = env::var("PARANOID_KEY_PIN")?;
        if !realm.starts_with("https://")
            || realm.len() > 512
            || pin.len() != 64
            || !pin
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err("invalid public realm".into());
        }
        let mut tx = pool.begin().await?;
        sqlx::raw_sql(include_str!("../schema.sql"))
            .execute(&mut *tx)
            .await?;
        sqlx::raw_sql(include_str!("../key-schema.sql"))
            .execute(&mut *tx)
            .await?;
        sqlx::query("INSERT INTO key_meta VALUES(1,1,$1,$2)")
            .bind(realm)
            .bind(pin)
            .execute(&mut *tx)
            .await?;
        tx.commit().await?;
        println!("Local key schema initialized; old startup is blocked");
        return Ok(());
    }
    let key_mode = env::var("PARANOID_MODE").as_deref() == Ok("closed-alpha-key-v1");
    let alpha = key_mode || env::var("PARANOID_MODE").as_deref() == Ok("closed-alpha-v0");
    let tls = if alpha {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let result = async {
            let cert = env::var("PARANOID_TLS_CERT")?;
            let key = env::var("PARANOID_TLS_KEY")?;
            Ok::<_, Box<dyn std::error::Error>>(
                axum_server::tls_rustls::RustlsConfig::from_pem_file(cert, key).await?,
            )
        }
        .await;
        match result {
            Ok(config) => {
                if key_mode {
                    // The key listener serves HTTP/1 only; never negotiate h2.
                    // Preserve the exact certificate, key resolver and TLS policy.
                    let mut inner = (*config.get_inner()).clone();
                    inner.alpn_protocols = vec![b"http/1.1".to_vec()];
                    Some(axum_server::tls_rustls::RustlsConfig::from_config(
                        std::sync::Arc::new(inner),
                    ))
                } else {
                    Some(config)
                }
            }
            Err(_) => {
                eprintln!("invalid TLS configuration");
                return Err("TLS required".into());
            }
        }
    } else {
        None
    };
    if !alpha
        && (env::var("PARANOID_MODE").is_ok()
            || env::var("PARANOID_DEVELOPMENT_ONLY").as_deref() != Ok("1"))
    {
        return Err("development opt-in required".into());
    }
    let address: SocketAddr = env::var("PARANOID_BIND")
        .unwrap_or_else(|_| "127.0.0.1:38300".into())
        .parse()?;
    if !bind_allowed(
        address,
        alpha,
        key_mode,
        env::var("PARANOID_REVIEWED_KEY_IP").ok().as_deref(),
    ) {
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
    if (alpha && (ci || options.get_socket().is_none()))
        || !paranoid_server::development_database_allowed(&options, ci)
    {
        return Err("private development database required".into());
    }
    // Lifetime local lock survives PG backend termination/restart. The advisory
    // lock remains a second guard, but is not the source of process exclusivity.
    let _process_guard = if key_mode {
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
        Some(file)
    } else {
        None
    };
    let pool = PgPoolOptions::new()
        .max_connections(4)
        .acquire_timeout(Duration::from_secs(5))
        .connect_with(options)
        .await?;
    // A single process owns volatile replay state. A second worker must not run.
    let _key_guard = if key_mode {
        let mut connection = pool.acquire().await?;
        let locked: bool = sqlx::query_scalar("SELECT pg_try_advisory_lock(706172616e6::bigint)")
            .fetch_one(&mut *connection)
            .await?;
        if !locked {
            return Err("another key worker exists".into());
        }
        Some(connection)
    } else {
        None
    };
    let app = if key_mode {
        paranoid_server::registration::key_app(pool, tokens, quota).await?
    } else {
        paranoid_server::stored_app(pool, tokens, quota).await?
    };
    if let Some(tls) = tls {
        // Global, bounded ingress state: no unbounded map of attacker-controlled IPs.
        let budget = std::sync::Arc::new(std::sync::Mutex::new((std::time::Instant::now(), 0u32)));
        let app = app.layer(axum::middleware::from_fn(
            move |request, next: axum::middleware::Next| {
                let budget = budget.clone();
                async move {
                    use axum::response::IntoResponse;
                    let allowed = {
                        let mut window = budget.lock().unwrap();
                        if window.0.elapsed() >= Duration::from_secs(1) {
                            *window = (std::time::Instant::now(), 0);
                        }
                        window.1 += 1;
                        window.1 <= 20
                    };
                    if !allowed {
                        return (
                            axum::http::StatusCode::TOO_MANY_REQUESTS,
                            axum::Json(serde_json::json!({"error":"alpha_rate_limit"})),
                        )
                            .into_response();
                    }
                    match tokio::time::timeout(Duration::from_secs(10), next.run(request)).await {
                        Ok(response) => response,
                        Err(_) => (
                            axum::http::StatusCode::REQUEST_TIMEOUT,
                            axum::Json(serde_json::json!({"error":"request_timeout"})),
                        )
                            .into_response(),
                    }
                }
            },
        ));
        if key_mode {
            let mut server = axum_server::bind_rustls(address, tls)
                .map(limited_accept::LimitedAccept::new)
                .http1_only();
            server.http_builder().http1().keep_alive(false);
            server.serve(app.into_make_service()).await?;
            return Ok(());
        }
        axum_server::bind_rustls(address, tls)
            .serve(app.into_make_service())
            .await?;
        return Ok(());
    }
    let listener = tokio::net::TcpListener::bind(address).await?;
    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
