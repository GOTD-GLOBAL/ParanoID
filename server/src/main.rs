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
    let alpha = env::var("PARANOID_MODE").as_deref() == Ok("closed-alpha-v0");
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
            Ok(config) => Some(config),
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
    if (!alpha && !address.ip().is_loopback()) || (alpha && address.port() != 38443) {
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
    let pool = PgPoolOptions::new()
        .max_connections(4)
        .acquire_timeout(Duration::from_secs(5))
        .connect_with(options)
        .await?;
    let app = paranoid_server::stored_app(pool, tokens, quota).await?;
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
