use serde_json::json;
use sqlx::postgres::PgPoolOptions;

async fn pool() -> sqlx::PgPool {
    let url =
        std::env::var("PARANOID_TEST_DATABASE_URL").expect("explicit isolated test DB required");
    let admin = PgPoolOptions::new()
        .max_connections(1)
        .connect(&url)
        .await
        .unwrap();
    let schema = format!("test_{}", uuid::Uuid::new_v4().simple());
    // Only a locally generated UUID identifier is interpolated, never external input.
    sqlx::QueryBuilder::<sqlx::Postgres>::new("CREATE SCHEMA ")
        .push(&schema)
        .build()
        .execute(&admin)
        .await
        .unwrap();
    admin.close().await;
    PgPoolOptions::new()
        .max_connections(4)
        .after_connect(move |c, _| {
            let schema = schema.clone();
            Box::pin(async move {
                sqlx::query("SELECT set_config('search_path', $1, false)")
                    .bind(schema)
                    .execute(c)
                    .await?;
                Ok(())
            })
        })
        .connect(&url)
        .await
        .unwrap()
}

async fn start(pool: sqlx::PgPool) -> (String, tokio::task::JoinHandle<()>) {
    let router = paranoid_server::stored_app(pool, ["a".repeat(64), "b".repeat(64)], 1048576)
        .await
        .unwrap();
    let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", socket.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(socket, router).await.unwrap() });
    (url, task)
}

#[tokio::test]
async fn accepted_envelope_is_committed_in_postgres() {
    let db = pool().await;
    let (url, server) = start(db.clone()).await;
    let id = uuid::Uuid::new_v4().to_string();
    let r = reqwest::Client::new()
        .post(format!("{url}/v0/messages"))
        .bearer_auth("a".repeat(64))
        .json(&json!({"id":id,"recipient":"bob","ciphertext":"AQID"}))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 200);
    let ack: serde_json::Value = r.json().await.unwrap();
    assert_eq!(ack["sequence"], 1);
    let row: (String, Vec<u8>) = sqlx::query_as("SELECT message_id, ciphertext FROM envelopes")
        .fetch_one(&db)
        .await
        .unwrap();
    assert_eq!(row, (id, vec![1, 2, 3]));
    server.abort();
    db.close().await;
}

#[tokio::test]
async fn lost_response_retry_keeps_one_row_and_rejects_changed_body() {
    let db = pool().await;
    let (url, server) = start(db.clone()).await;
    let http = reqwest::Client::new();
    let mut payload =
        json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":"bob","ciphertext":"AQID"});
    let first = http
        .post(format!("{url}/v0/messages"))
        .bearer_auth("a".repeat(64))
        .json(&payload)
        .send()
        .await
        .unwrap();
    assert_eq!(first.status(), 200);
    let original = first.json::<serde_json::Value>().await.unwrap();
    let retry = http
        .post(format!("{url}/v0/messages"))
        .bearer_auth("a".repeat(64))
        .json(&payload)
        .send()
        .await
        .unwrap();
    assert_eq!(retry.status(), 200);
    assert_eq!(retry.json::<serde_json::Value>().await.unwrap(), original);
    payload["ciphertext"] = json!("BAUG");
    let conflict = http
        .post(format!("{url}/v0/messages"))
        .bearer_auth("a".repeat(64))
        .json(&payload)
        .send()
        .await
        .unwrap();
    assert_eq!(conflict.status(), 409);
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM envelopes")
        .fetch_one(&db)
        .await
        .unwrap();
    assert_eq!(count, 1);
    server.abort();
    db.close().await;
}

#[tokio::test]
async fn offline_recipient_catches_up_after_server_restart_without_cross_device_leak() {
    let db = pool().await;
    let (url, server) = start(db.clone()).await;
    let http = reqwest::Client::new();
    for _ in 0..3 {
        let r=http.post(format!("{url}/v0/messages")).bearer_auth("a".repeat(64))
          .json(&json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":"bob","ciphertext":"AQID"})).send().await.unwrap();
        assert_eq!(r.status(), 200);
    }
    server.abort();
    let (url, server) = start(db.clone()).await;
    let r = http
        .get(format!("{url}/v0/messages?after=0&limit=2"))
        .bearer_auth("b".repeat(64))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 200);
    let page = r.json::<serde_json::Value>().await.unwrap();
    assert_eq!(page["messages"].as_array().unwrap().len(), 2);
    assert_eq!(page["cursor"], 2);
    assert_eq!(page["messages"][0]["sender"], "alice");
    let r = http
        .get(format!("{url}/v0/messages?after=2"))
        .bearer_auth("b".repeat(64))
        .send()
        .await
        .unwrap();
    let page = r.json::<serde_json::Value>().await.unwrap();
    assert_eq!(page["messages"].as_array().unwrap().len(), 1);
    assert_eq!(page["cursor"], 3);
    let r = http
        .get(format!("{url}/v0/messages?after=3"))
        .bearer_auth("b".repeat(64))
        .send()
        .await
        .unwrap();
    let page = r.json::<serde_json::Value>().await.unwrap();
    assert!(page["messages"].as_array().unwrap().is_empty());
    assert_eq!(page["cursor"], 3);
    let own = http
        .get(format!("{url}/v0/messages"))
        .bearer_auth("a".repeat(64))
        .send()
        .await
        .unwrap()
        .json::<serde_json::Value>()
        .await
        .unwrap();
    assert!(own["messages"].as_array().unwrap().is_empty());
    assert_eq!(
        http.get(format!("{url}/v0/messages"))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    server.abort();
    db.close().await;
}

#[tokio::test]
async fn quota_rejects_new_data_without_eviction_and_still_accepts_retry() {
    let db = pool().await;
    let router = paranoid_server::stored_app(db.clone(), ["a".repeat(64), "b".repeat(64)], 3)
        .await
        .unwrap();
    let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", socket.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(socket, router).await.unwrap() });
    let http = reqwest::Client::new();
    let original =
        json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":"bob","ciphertext":"AQID"});
    assert_eq!(
        http.post(format!("{url}/v0/messages"))
            .bearer_auth("a".repeat(64))
            .json(&original)
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    let other =
        json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":"bob","ciphertext":"AQID"});
    assert_eq!(
        http.post(format!("{url}/v0/messages"))
            .bearer_auth("a".repeat(64))
            .json(&other)
            .send()
            .await
            .unwrap()
            .status(),
        507
    );
    assert_eq!(
        http.post(format!("{url}/v0/messages"))
            .bearer_auth("a".repeat(64))
            .json(&original)
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM envelopes")
        .fetch_one(&db)
        .await
        .unwrap();
    assert_eq!(count, 1);
    server.abort();
    db.close().await;
}

#[tokio::test]
async fn concurrent_duplicate_requests_share_one_commit_and_sequence() {
    let db = pool().await;
    let (url, server) = start(db.clone()).await;
    let payload =
        json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":"bob","ciphertext":"AQID"});
    let mut workers = tokio::task::JoinSet::new();
    for _ in 0..16 {
        let url = url.clone();
        let payload = payload.clone();
        workers.spawn(async move {
            let response = reqwest::Client::new()
                .post(format!("{url}/v0/messages"))
                .bearer_auth("a".repeat(64))
                .json(&payload)
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), 200);
            response.json::<serde_json::Value>().await.unwrap()["sequence"]
                .as_i64()
                .unwrap()
        });
    }
    while let Some(result) = workers.join_next().await {
        assert_eq!(result.unwrap(), 1);
    }
    let state: (i64, i64) = sqlx::query_as("SELECT sequence,used_bytes FROM room_state")
        .fetch_one(&db)
        .await
        .unwrap();
    assert_eq!(state, (1, 3));
    server.abort();
    db.close().await;
}

#[tokio::test]
async fn invalid_input_and_credentials_never_create_rows() {
    let db = pool().await;
    let (url, server) = start(db.clone()).await;
    let http = reqwest::Client::new();
    let valid =
        json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":"bob","ciphertext":"AQID"});
    for token in ["", "c", &"c".repeat(64)] {
        assert_eq!(
            http.post(format!("{url}/v0/messages"))
                .bearer_auth(token)
                .json(&valid)
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
    }
    for (field, value) in [
        ("id", json!("not-uuid")),
        ("recipient", json!("alice")),
        ("recipient", json!("mallory")),
        ("ciphertext", json!("!")),
        ("ciphertext", json!("")),
        ("sender", json!("bob")),
        ("version", json!(999)),
    ] {
        let mut p = valid.clone();
        p[field] = value;
        let status = http
            .post(format!("{url}/v0/messages"))
            .bearer_auth("a".repeat(64))
            .json(&p)
            .send()
            .await
            .unwrap()
            .status();
        assert!(status.is_client_error(), "{field}: {status}");
    }
    let large = json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":"bob","ciphertext":"A".repeat(25000)});
    assert_eq!(
        http.post(format!("{url}/v0/messages"))
            .bearer_auth("a".repeat(64))
            .json(&large)
            .send()
            .await
            .unwrap()
            .status(),
        413
    );
    for query in [
        "after=-1",
        "limit=0",
        "limit=101",
        "after=9223372036854775808",
        "unknown=yes",
    ] {
        assert!(http
            .get(format!("{url}/v0/messages?{query}"))
            .bearer_auth("b".repeat(64))
            .send()
            .await
            .unwrap()
            .status()
            .is_client_error());
    }
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM envelopes")
        .fetch_one(&db)
        .await
        .unwrap();
    assert_eq!(count, 0);
    server.abort();
    db.close().await;
}

#[test]
fn server_binary_responds_over_http_and_preserves_accepted_data_on_restart() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    let db = rt.block_on(pool());
    let schema: String = rt
        .block_on(sqlx::query_scalar("SELECT current_schema()").fetch_one(&db))
        .unwrap();
    let mut database =
        reqwest::Url::parse(&std::env::var("PARANOID_TEST_DATABASE_URL").unwrap()).unwrap();
    let pairs: Vec<(String, String)> = database
        .query_pairs()
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    let mut options = pairs
        .iter()
        .filter(|(k, _)| k == "options")
        .map(|(_, v)| v.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    options.push_str(&format!(" -csearch_path={schema}"));
    database
        .query_pairs_mut()
        .clear()
        .extend_pairs(pairs.iter().filter(|(k, _)| k != "options"))
        .append_pair("options", &options);
    let database = database.to_string();
    let socket = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = socket.local_addr().unwrap();
    drop(socket);
    let launch = || {
        std::process::Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
            .env("PARANOID_DEVELOPMENT_ONLY", "1")
            .env("PARANOID_BIND", addr.to_string())
            .env("PARANOID_DATABASE_URL", &database)
            .env("PARANOID_ALICE_TOKEN", "a".repeat(64))
            .env("PARANOID_BOB_TOKEN", "b".repeat(64))
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap()
    };
    struct Child(std::process::Child);
    impl Drop for Child {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let url = format!("http://{addr}");
    let mut process = Child(launch());
    let wait = |p: &mut Child| {
        for _ in 0..100 {
            if let Some(code) = p.0.try_wait().unwrap() {
                panic!("server exited before ready: {code}");
            }
            let ready = rt.block_on(async {
                reqwest::get(format!("{url}/health"))
                    .await
                    .map(|r| r.status() == 200)
                    .unwrap_or(false)
            });
            if ready {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        panic!("server not ready");
    };
    wait(&mut process);
    rt.block_on(async { let r=reqwest::Client::new().post(format!("{url}/v0/messages")).bearer_auth("a".repeat(64))
        .json(&json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":"bob","ciphertext":"AQID"})).send().await.unwrap();assert_eq!(r.status(),200); });
    drop(process);
    let mut process = Child(launch());
    wait(&mut process);
    rt.block_on(async {
        let r = reqwest::Client::new()
            .get(format!("{url}/v0/messages"))
            .bearer_auth("b".repeat(64))
            .send()
            .await
            .unwrap();
        assert_eq!(r.status(), 200);
        assert_eq!(
            r.json::<serde_json::Value>().await.unwrap()["messages"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    });
    drop(process);
    rt.block_on(db.close());
}

#[tokio::test]
async fn record_limit_bounds_metadata_without_eviction() {
    let db = pool().await;
    let (url, server) = start(db.clone()).await;
    sqlx::query("UPDATE room_state SET sequence=100000 WHERE id=1")
        .execute(&db)
        .await
        .unwrap();
    let r = reqwest::Client::new()
        .post(format!("{url}/v0/messages"))
        .bearer_auth("a".repeat(64))
        .json(&json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":"bob","ciphertext":"AQID"}))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 507);
    server.abort();
    db.close().await;
}

#[test]
fn binary_refuses_external_bind_and_redacts_configuration_errors() {
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
        .env("PARANOID_DEVELOPMENT_ONLY", "1")
        .env("PARANOID_BIND", "0.0.0.0:0")
        .env(
            "PARANOID_DATABASE_URL",
            "postgresql://secret-marker@127.0.0.1/fake",
        )
        .output()
        .unwrap();
    assert!(!output.status.success());
    let text = String::from_utf8_lossy(&output.stderr);
    assert!(!text.contains("secret-marker"));
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
        .env_remove("PARANOID_DEVELOPMENT_ONLY")
        .output()
        .unwrap();
    assert!(!output.status.success());
}

#[tokio::test]
async fn two_olm_fixture_clients_exchange_real_ciphertext_over_http() {
    use base64::{engine::general_purpose::STANDARD, Engine};
    use vodozemac::olm::{Account, OlmMessage, SessionConfig};
    // Fixture trust is established in this test, not by an implemented contact protocol.
    let alice = Account::new();
    let mut bob = Account::new();
    bob.generate_one_time_keys(1);
    let prekey = *bob.one_time_keys().values().next().unwrap();
    let mut a = alice
        .create_outbound_session(
            SessionConfig::version_1(),
            bob.identity_keys().curve25519,
            prekey,
        )
        .unwrap();
    let marker = b"[SYNTHETIC] private hello from alice";
    let encrypted = a.encrypt(marker).unwrap();
    let frame = |m: OlmMessage| {
        let (kind, body) = m.to_parts();
        let mut data = vec![kind as u8];
        data.extend(body);
        STANDARD.encode(data)
    };
    let unframe = |s: &str| {
        let data = STANDARD.decode(s).unwrap();
        OlmMessage::from_parts(data[0] as usize, &data[1..]).unwrap()
    };
    let db = pool().await;
    let (url, server) = start(db.clone()).await;
    let a_http = reqwest::Client::new();
    let b_http = reqwest::Client::new();
    let r=a_http.post(format!("{url}/v0/messages")).bearer_auth("a".repeat(64))
        .json(&json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":"bob","ciphertext":frame(encrypted)})).send().await.unwrap();
    assert_eq!(r.status(), 200);
    let page = b_http
        .get(format!("{url}/v0/messages"))
        .bearer_auth("b".repeat(64))
        .send()
        .await
        .unwrap()
        .json::<serde_json::Value>()
        .await
        .unwrap();
    let received = unframe(page["messages"][0]["ciphertext"].as_str().unwrap());
    let OlmMessage::PreKey(first) = received else {
        panic!("expected initial prekey message")
    };
    let inbound = bob
        .create_inbound_session(
            SessionConfig::version_1(),
            alice.identity_keys().curve25519,
            &first,
        )
        .unwrap();
    assert_eq!(inbound.plaintext, marker);
    let mut b = inbound.session;
    let reply = b.encrypt(b"[SYNTHETIC] bob received the message").unwrap();
    assert_eq!(b_http.post(format!("{url}/v0/messages")).bearer_auth("b".repeat(64))
        .json(&json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":"alice","ciphertext":frame(reply)})).send().await.unwrap().status(),200);
    let page = a_http
        .get(format!("{url}/v0/messages"))
        .bearer_auth("a".repeat(64))
        .send()
        .await
        .unwrap()
        .json::<serde_json::Value>()
        .await
        .unwrap();
    assert_eq!(
        a.decrypt(&unframe(
            page["messages"][0]["ciphertext"].as_str().unwrap()
        ))
        .unwrap(),
        b"[SYNTHETIC] bob received the message"
    );
    let rows: Vec<(Vec<u8>,)> = sqlx::query_as("SELECT ciphertext FROM envelopes")
        .fetch_all(&db)
        .await
        .unwrap();
    assert_eq!(rows.len(), 2);
    assert!(rows
        .iter()
        .all(|(c,)| !c.windows(marker.len()).any(|part| part == marker)));
    server.abort();
    db.close().await;
}

#[tokio::test]
async fn malformed_extractors_return_static_errors_without_reflecting_markers() {
    let db = pool().await;
    let (url, server) = start(db.clone()).await;
    let http = reqwest::Client::new();
    let marker = "private-test-marker-do-not-reflect";
    let r = http
        .post(format!("{url}/v0/messages"))
        .bearer_auth("a".repeat(64))
        .json(&json!({marker:"data"}))
        .send()
        .await
        .unwrap();
    assert!(r.status().is_client_error());
    assert!(!r.text().await.unwrap().contains(marker));
    let r = http
        .get(format!("{url}/v0/messages?{marker}=1"))
        .bearer_auth("b".repeat(64))
        .send()
        .await
        .unwrap();
    assert!(r.status().is_client_error());
    assert!(!r.text().await.unwrap().contains(marker));
    server.abort();
    db.close().await;
}

#[test]
fn database_gate_rejects_remote_and_existing_system_sockets() {
    use std::str::FromStr;
    let options = |s| sqlx::postgres::PgConnectOptions::from_str(s).unwrap();
    assert!(!paranoid_server::development_database_allowed(
        &options("postgres://u@192.0.2.1/live"),
        false
    ));
    assert!(!paranoid_server::development_database_allowed(
        &options("postgres://u@localhost/postgres?host=/var/run/postgresql"),
        false
    ));
    assert!(!paranoid_server::development_database_allowed(
        &options("postgres://paranoid_test@127.0.0.1/paranoid_test"),
        false
    ));
    assert!(paranoid_server::development_database_allowed(
        &options("postgres://paranoid_test@127.0.0.1/paranoid_test"),
        true
    ));
    assert!(!paranoid_server::development_database_allowed(
        &options("postgres://paranoid_test@192.0.2.1/paranoid_test"),
        true
    ));
}

#[tokio::test]
async fn health_is_a_real_http_response() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server =
        tokio::spawn(async move { axum::serve(listener, paranoid_server::app()).await.unwrap() });
    let response = reqwest::get(format!("http://{address}/health"))
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(
        response.json::<serde_json::Value>().await.unwrap()["protocol"],
        "paranoid-dev-v0"
    );
    server.abort();
}
