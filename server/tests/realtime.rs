//! REQ-MSG-002/004, REQ-ID-004/005/008, REQ-SEC-001: actual HTTP/PG boundaries.
//! Test transcripts deliberately do not call the implementation SessionV2 helper.
use paranoid_key_protocol::{digest, transcript, Identity};
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, PgPool};
use std::{
    process::Command,
    time::{Duration, Instant},
};

const REALM: &str = "https://127.0.0.2:38443";

async fn database() -> PgPool {
    let base = std::env::var("PARANOID_TEST_DATABASE_URL").unwrap();
    let admin = PgPoolOptions::new()
        .max_connections(1)
        .connect(&base)
        .await
        .unwrap();
    let name = format!("realtime_{}", uuid::Uuid::new_v4().simple());
    sqlx::QueryBuilder::<sqlx::Postgres>::new("CREATE DATABASE ")
        .push(&name)
        .build()
        .execute(&admin)
        .await
        .unwrap();
    admin.close().await;
    let url = base.replace("/postgres?", &format!("/{name}?"));
    let init = Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
        .arg("self-service-init")
        .env_remove("PARANOID_MODE")
        .env("PARANOID_DATABASE_URL", &url)
        .env("PARANOID_KEY_REALM", REALM)
        .env("PARANOID_KEY_PIN", "a".repeat(64))
        .output()
        .unwrap();
    assert!(
        init.status.success(),
        "isolated init: {}",
        String::from_utf8_lossy(&init.stderr)
    );
    PgPoolOptions::new()
        .max_connections(4)
        .connect(&url)
        .await
        .unwrap()
}

async fn serve(db: &PgPool) -> (String, tokio::task::JoinHandle<()>) {
    let router = paranoid_server::self_service::app(db.clone())
        .await
        .unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    (
        url,
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() }),
    )
}

fn identity() -> Identity {
    Identity::create(REALM, &"a".repeat(64), "curve", "prekey").unwrap()
}

fn sign(i: &Identity, domain: &str, value: &Value, names: &[&str], suffix: &[&str]) -> String {
    let values: Vec<String> = names
        .iter()
        .map(|n| {
            value[n]
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| value[n].to_string())
        })
        .collect();
    let mut fields = vec![domain];
    fields.extend(values.iter().map(String::as_str));
    fields.extend_from_slice(suffix);
    vodozemac::Ed25519SecretKey::from_base64(&i.auth_secret)
        .unwrap()
        .sign(&transcript(&fields))
        .to_base64()
}

async fn old_signed(
    http: &reqwest::Client,
    url: &str,
    i: &Identity,
    purpose: &str,
    method: &str,
    path: &str,
    body: &str,
) -> reqwest::Response {
    // Existing proof endpoint is intentionally limited to two per account/sec.
    tokio::time::sleep(Duration::from_millis(550)).await;
    let mut request = json!({"credential":i.credential.fingerprint(),"account":i.credential.account,
        "device":i.credential.device,"purpose":purpose,"method":method,"path":path,"body":digest(body.as_bytes())});
    let route = if purpose == "register" {
        request.as_object_mut().unwrap().remove("account");
        request.as_object_mut().unwrap().remove("device");
        request["credential"] = serde_json::to_value(&i.credential).unwrap();
        "registration"
    } else {
        "auth"
    };
    let response = http
        .post(format!("{url}/v2/{route}/challenge"))
        .json(&request)
        .send()
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        200,
        "exact {purpose} challenge must be supported"
    );
    let ch: Value = response.json().await.unwrap();
    let signature = sign(
        i,
        "paranoid-proof-v2",
        &ch,
        &[
            "id",
            "nonce",
            "epoch",
            "expires",
            "realm",
            "pin",
            "account",
            "device",
            "credential",
            "purpose",
            "method",
            "path",
            "body",
        ],
        &[],
    );
    http.request(method.parse().unwrap(), format!("{url}{path}"))
        .header(
            "Authorization",
            format!("ParanoidV2 {}.{signature}", ch["id"].as_str().unwrap()),
        )
        .body(body.to_owned())
        .send()
        .await
        .unwrap()
}

async fn register(http: &reqwest::Client, url: &str) -> Identity {
    let i = identity();
    assert_eq!(
        old_signed(
            http,
            url,
            &i,
            "register",
            "POST",
            "/v2/registration/commit",
            "{}"
        )
        .await
        .status(),
        200
    );
    i
}

async fn session(http: &reqwest::Client, url: &str, i: &Identity) -> Value {
    let r = old_signed(http, url, i, "session", "POST", "/v2/session", "{}").await;
    assert_eq!(r.status(), 200, "signed session creation must exist");
    let s: Value = r.json().await.unwrap();
    assert_eq!(s.as_object().unwrap().len(), 8);
    assert_eq!(s["realm"], i.credential.realm);
    assert_eq!(s["account"], i.credential.account);
    assert_eq!(s["device"], i.credential.device);
    assert_eq!(s["credential"], i.credential.fingerprint());
    assert_eq!(s["pin"], i.credential.pin);
    s
}

fn proof(i: &Identity, s: &Value, nonce: &str, method: &str, path: &str, body: &str) -> String {
    let d = digest(body.as_bytes());
    let signature = sign(
        i,
        "paranoid-session-request-v1",
        s,
        &[
            "id",
            "epoch",
            "expires",
            "realm",
            "pin",
            "account",
            "device",
            "credential",
        ],
        &[nonce, method, path, &d],
    );
    format!(
        "ParanoidSessionV2 {}.{nonce}.{signature}",
        s["id"].as_str().unwrap()
    )
}

async fn operation(
    http: &reqwest::Client,
    url: &str,
    i: &Identity,
    s: &Value,
    method: &str,
    path: &str,
    body: &str,
) -> reqwest::Response {
    http.request(method.parse().unwrap(), format!("{url}{path}"))
        .header(
            "Authorization",
            proof(i, s, &uuid::Uuid::new_v4().to_string(), method, path, body),
        )
        .body(body.to_owned())
        .send()
        .await
        .unwrap()
}

fn message(peer: &Identity) -> String {
    json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":peer.credential.account,"ciphertext":"AQID"}).to_string()
}

async fn seed_registered(db: &PgPool) -> Identity {
    // This capacity fixture seeds valid synthetic existing accounts, avoiding the
    // unrelated durable eight-new-accounts/minute registration gate. Every session
    // still goes through real challenge, device proof and binding authorization.
    let i = identity();
    sqlx::query("INSERT INTO ss_accounts VALUES($1,$2,'active')")
        .bind(&i.credential.account)
        .bind(&i.credential.root)
        .execute(db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO ss_devices VALUES($1,$2,$3,$4,$5)")
        .bind(&i.credential.account)
        .bind(&i.credential.device)
        .bind(&i.credential.auth)
        .bind(i.credential.fingerprint())
        .bind(serde_json::to_string(&i.credential).unwrap())
        .execute(db)
        .await
        .unwrap();
    i
}

#[tokio::test]
async fn realtime_session_auth_binds_every_context_and_nonce_replay_has_one_winner() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = register(&http, &url).await;
    let s = session(&http, &url, &i).await;
    let health: Value = http
        .get(format!("{url}/health"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(health["realtime"], "signed-long-poll-v1");
    let path = "/v2/messages?after=0&limit=20";
    let nonce = uuid::Uuid::new_v4().to_string();
    let good = proof(&i, &s, &nonce, "GET", path, "");
    let bad = proof(&identity(), &s, &nonce, "GET", path, "");
    assert_eq!(
        http.get(format!("{url}{path}"))
            .header("Authorization", bad)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    let a = http
        .get(format!("{url}{path}"))
        .header("Authorization", &good)
        .send();
    let b = http
        .get(format!("{url}{path}"))
        .header("Authorization", &good)
        .send();
    let (a, b) = tokio::join!(a, b);
    let mut statuses = [a.unwrap().status().as_u16(), b.unwrap().status().as_u16()];
    statuses.sort();
    assert_eq!(statuses, [200, 401]);
    let nonce = uuid::Uuid::new_v4().to_string();
    let good = proof(&i, &s, &nonce, "GET", path, "");
    assert_eq!(
        http.get(format!("{url}{path}"))
            .header("Authorization", &good)
            .header("Authorization", &good)
            .send()
            .await
            .unwrap()
            .status(),
        401,
        "duplicate authorization is ambiguous"
    );
    assert_eq!(
        http.get(format!("{url}{path}"))
            .header("Authorization", &good)
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    for field in [
        "id",
        "epoch",
        "expires",
        "realm",
        "pin",
        "account",
        "device",
        "credential",
    ] {
        tokio::time::sleep(Duration::from_millis(70)).await;
        let mut changed = s.clone();
        changed[field] = if field == "expires" {
            json!(s[field].as_i64().unwrap() + 1)
        } else {
            json!("changed")
        };
        assert_eq!(
            operation(&http, &url, &i, &changed, "GET", path, "")
                .await
                .status(),
            401,
            "field {field}"
        );
    }
    tokio::time::sleep(Duration::from_secs(1)).await;
    for (method, route, body) in [
        ("POST", path, ""),
        ("GET", "/v2/messages?after=1&limit=20", ""),
        ("GET", path, "{}"),
        ("POST", "/v2/auth/verify", "{}"),
    ] {
        let nonce = uuid::Uuid::new_v4().to_string();
        let h = proof(&i, &s, &nonce, "GET", path, "");
        assert!(!http
            .request(method.parse().unwrap(), format!("{url}{route}"))
            .header("Authorization", &h)
            .body(body)
            .send()
            .await
            .unwrap()
            .status()
            .is_success());
        assert_eq!(
            http.get(format!("{url}{path}"))
                .header("Authorization", h)
                .send()
                .await
                .unwrap()
                .status(),
            200,
            "bad context must not burn valid nonce"
        );
    }
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn realtime_wait_wakes_on_legacy_commit_and_paginates_without_losing_rows() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let a = register(&http, &url).await;
    let b = register(&http, &url).await;
    let sa = session(&http, &url, &a).await;
    let sb = session(&http, &url, &b).await;
    let path = "/v2/events?after=0&limit=1";
    let waiting = http
        .get(format!("{url}{path}"))
        .header(
            "Authorization",
            proof(&b, &sb, &uuid::Uuid::new_v4().to_string(), "GET", path, ""),
        )
        .send();
    let waiter = tokio::spawn(waiting);
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(!waiter.is_finished(), "empty inbox should hold request");
    let body = message(&b);
    let r = old_signed(&http, &url, &a, "message", "POST", "/v2/messages", &body).await;
    assert_eq!(r.status(), 200);
    let accepted: Value = r.json().await.unwrap();
    let page: Value = tokio::time::timeout(Duration::from_millis(900), waiter)
        .await
        .unwrap()
        .unwrap()
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(page["messages"][0]["id"], accepted["id"]);
    assert_eq!(page["cursor"], accepted["sequence"]);
    let retry: Value = operation(&http, &url, &a, &sa, "POST", "/v2/messages", &body)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(
        retry, accepted,
        "fresh proof retry preserves original durable sequence"
    );
    let body2 = message(&b);
    assert_eq!(
        operation(&http, &url, &a, &sa, "POST", "/v2/messages", &body2)
            .await
            .status(),
        200
    );
    let after = format!("/v2/events?after={}&limit=1", page["cursor"]);
    let next: Value = operation(&http, &url, &b, &sb, "GET", &after, "")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(next["messages"].as_array().unwrap().len(), 1);
    assert!(next["cursor"].as_i64().unwrap() > page["cursor"].as_i64().unwrap());
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_messages")
            .fetch_one(&db)
            .await
            .unwrap(),
        2
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn realtime_wait_rechecks_revocation_without_holding_database_lock() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = register(&http, &url).await;
    let s = session(&http, &url, &i).await;
    let path = "/v2/events?after=0&limit=20";
    let waiter = tokio::spawn(
        http.get(format!("{url}{path}"))
            .header(
                "Authorization",
                proof(&i, &s, &uuid::Uuid::new_v4().to_string(), "GET", path, ""),
            )
            .send(),
    );
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(!waiter.is_finished());
    let start = Instant::now();
    let revoke = async {
        let mut tx = db.begin().await.unwrap();
        sqlx::query("SELECT id FROM ss_meta WHERE id=1 FOR UPDATE")
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("UPDATE ss_accounts SET mode='revoked' WHERE account=$1")
            .bind(&i.credential.account)
            .execute(&mut *tx)
            .await
            .unwrap();
        tx.commit().await.unwrap();
    };
    tokio::time::timeout(Duration::from_millis(700), revoke)
        .await
        .expect("wait cannot hold global DB lock");
    assert_eq!(
        tokio::time::timeout(Duration::from_millis(1500), waiter)
            .await
            .unwrap()
            .unwrap()
            .unwrap()
            .status(),
        401
    );
    println!("revocation completion ms={}", start.elapsed().as_millis());
    assert_eq!(
        operation(&http, &url, &i, &s, "GET", "/v2/messages", "")
            .await
            .status(),
        401
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn realtime_session_capacity_and_wait_capacity_do_not_evict_authority() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = register(&http, &url).await;
    let a = session(&http, &url, &i).await;
    let b = session(&http, &url, &i).await;
    assert_eq!(
        old_signed(&http, &url, &i, "session", "POST", "/v2/session", "{}")
            .await
            .status(),
        429
    );
    assert_eq!(
        operation(&http, &url, &i, &a, "GET", "/v2/messages", "")
            .await
            .status(),
        200
    );
    let path = "/v2/events?after=0&limit=20";
    let waiter = tokio::spawn(
        http.get(format!("{url}{path}"))
            .header(
                "Authorization",
                proof(&i, &a, &uuid::Uuid::new_v4().to_string(), "GET", path, ""),
            )
            .send(),
    );
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(!waiter.is_finished());
    assert_eq!(
        operation(&http, &url, &i, &b, "GET", path, "")
            .await
            .status(),
        429,
        "one waiter per account across sessions"
    );
    assert_eq!(
        operation(&http, &url, &i, &b, "GET", "/v2/messages", "")
            .await
            .status(),
        200
    );
    sqlx::query("UPDATE ss_accounts SET mode='revoked' WHERE account=$1")
        .bind(&i.credential.account)
        .execute(&db)
        .await
        .unwrap();
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(2), waiter)
            .await
            .unwrap()
            .unwrap()
            .unwrap()
            .status(),
        401
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn realtime_changed_binding_and_server_restart_invalidate_existing_sessions() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = register(&http, &url).await;
    let s = session(&http, &url, &i).await;
    sqlx::query("UPDATE ss_devices SET auth=$1 WHERE account=$2")
        .bind(identity().credential.auth)
        .bind(&i.credential.account)
        .execute(&db)
        .await
        .unwrap();
    assert_eq!(
        operation(&http, &url, &i, &s, "GET", "/v2/messages", "")
            .await
            .status(),
        401
    );
    sqlx::query("UPDATE ss_devices SET auth=$1 WHERE account=$2")
        .bind(&i.credential.auth)
        .bind(&i.credential.account)
        .execute(&db)
        .await
        .unwrap();
    assert_eq!(
        operation(&http, &url, &i, &s, "GET", "/v2/messages", "")
            .await
            .status(),
        401,
        "observed invalid binding permanently invalidates that session"
    );
    let s = session(&http, &url, &i).await;
    task.abort();
    let (url, task) = serve(&db).await;
    assert_eq!(
        operation(&http, &url, &i, &s, "GET", "/v2/messages", "")
            .await
            .status(),
        401
    );
    let fresh = session(&http, &url, &i).await;
    assert_ne!(fresh["epoch"], s["epoch"]);
    assert_eq!(
        operation(&http, &url, &i, &fresh, "GET", "/v2/messages", "")
            .await
            .status(),
        200
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn realtime_empty_wait_returns_after_bounded_timeout_without_advancing_cursor() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = register(&http, &url).await;
    let s = session(&http, &url, &i).await;
    let start = Instant::now();
    let response = operation(
        &http,
        &url,
        &i,
        &s,
        "GET",
        "/v2/events?after=0&limit=20",
        "",
    )
    .await;
    assert_eq!(
        response.status(),
        200,
        "long wait must survive the historical 10s middleware timeout"
    );
    let page: Value = response.json().await.unwrap();
    assert_eq!(page, json!({"messages":[],"cursor":0}));
    assert!(start.elapsed() >= Duration::from_secs(19));
    assert!(start.elapsed() < Duration::from_secs(24));
    for path in [
        "/v2/events?after=-1",
        "/v2/events?after=0&limit=101",
        "/v2/events?after=0&after=1",
        "/v2/events?after=0&extra=1",
    ] {
        assert_eq!(
            operation(&http, &url, &i, &s, "GET", path, "")
                .await
                .status(),
            400,
            "strict cursor {path}"
        );
    }
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn realtime_nonce_ledger_is_bounded_without_evicting_replay_history() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = register(&http, &url).await;
    let s = session(&http, &url, &i).await;
    let first = proof(
        &i,
        &s,
        &uuid::Uuid::new_v4().to_string(),
        "GET",
        "/v2/messages",
        "",
    );
    assert_eq!(
        http.get(format!("{url}/v2/messages"))
            .header("Authorization", &first)
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    for n in 1..2048 {
        // Pace security capacity probe beneath retained global20/s; not a latency benchmark.
        tokio::time::sleep(Duration::from_millis(65)).await;
        assert_eq!(
            operation(&http, &url, &i, &s, "GET", "/v2/messages", "")
                .await
                .status(),
            200,
            "operation {n}"
        );
    }
    assert_eq!(
        operation(&http, &url, &i, &s, "GET", "/v2/messages", "")
            .await
            .status(),
        429
    );
    assert_eq!(
        http.get(format!("{url}/v2/messages"))
            .header("Authorization", first)
            .send()
            .await
            .unwrap()
            .status(),
        401,
        "earliest nonce remains consumed"
    );
    let fresh = session(&http, &url, &i).await;
    assert_eq!(
        operation(&http, &url, &i, &fresh, "GET", "/v2/messages", "")
            .await
            .status(),
        200
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn realtime_real_five_minute_expiry_rejects_old_authority_and_allows_new_session() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = register(&http, &url).await;
    let s = session(&http, &url, &i).await;
    assert_eq!(
        operation(&http, &url, &i, &s, "GET", "/v2/messages", "")
            .await
            .status(),
        200
    );
    // Actual lifetime, without a production timeout override or test-only authority bypass.
    tokio::time::sleep(Duration::from_secs(301)).await;
    assert_eq!(
        operation(&http, &url, &i, &s, "GET", "/v2/messages", "")
            .await
            .status(),
        401
    );
    let fresh = session(&http, &url, &i).await;
    assert_ne!(fresh["id"], s["id"]);
    assert_eq!(
        operation(&http, &url, &i, &fresh, "GET", "/v2/messages", "")
            .await
            .status(),
        200
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn realtime_global_session_and_wait_caps_are_shared_and_release_after_revocation() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let mut users = Vec::new();
    let mut sessions = Vec::new();
    for _ in 0..32 {
        let i = seed_registered(&db).await;
        let a = session(&http, &url, &i).await;
        let b = session(&http, &url, &i).await;
        users.push(i);
        sessions.push((a, b));
    }
    let last = seed_registered(&db).await;
    assert_eq!(
        old_signed(&http, &url, &last, "session", "POST", "/v2/session", "{}")
            .await
            .status(),
        429,
        "64 global sessions, no eviction"
    );
    assert_eq!(
        operation(
            &http,
            &url,
            &users[0],
            &sessions[0].0,
            "GET",
            "/v2/messages",
            ""
        )
        .await
        .status(),
        200
    );
    let path = "/v2/events?after=0&limit=20";
    let mut waiters = Vec::new();
    for n in 0..8 {
        waiters.push(tokio::spawn(
            http.get(format!("{url}{path}"))
                .header(
                    "Authorization",
                    proof(
                        &users[n],
                        &sessions[n].0,
                        &uuid::Uuid::new_v4().to_string(),
                        "GET",
                        path,
                        "",
                    ),
                )
                .send(),
        ));
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(waiters.iter().all(|w| !w.is_finished()));
    assert_eq!(
        operation(&http, &url, &users[8], &sessions[8].0, "GET", path, "")
            .await
            .status(),
        429,
        "eight global waits, no permit queue"
    );
    sqlx::query("UPDATE ss_accounts SET mode='revoked'")
        .execute(&db)
        .await
        .unwrap();
    for w in waiters {
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(2), w)
                .await
                .unwrap()
                .unwrap()
                .unwrap()
                .status(),
            401
        );
    }
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn realtime_actual_tls_pool_nested_deadlines_and_absolute_socket_lifetime() {
    let db = database().await;
    let name: String = sqlx::query_scalar("SELECT current_database()")
        .fetch_one(&db)
        .await
        .unwrap();
    let database_url = std::env::var("PARANOID_TEST_DATABASE_URL")
        .unwrap()
        .replace("/postgres?", &format!("/{name}?"));
    let dir = std::env::temp_dir().join(format!("paranoid-realtime-tls-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&dir).unwrap();
    let cert = dir.join("cert.pem");
    let key = dir.join("key.pem");
    assert!(Command::new("openssl")
        .args([
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-subj",
            "/CN=localhost",
            "-addext",
            "subjectAltName=IP:127.0.0.1",
            "-keyout"
        ])
        .arg(&key)
        .arg("-out")
        .arg(&cert)
        .output()
        .unwrap()
        .status
        .success());
    let pin_output=Command::new("python3").args(["-c","import sys,hashlib;from cryptography import x509;from cryptography.hazmat.primitives import serialization;p=x509.load_pem_x509_certificate(open(sys.argv[1],'rb').read()).public_key();print(hashlib.sha256(p.public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo)).hexdigest())"])
        .arg(&cert).output().unwrap();
    assert!(pin_output.status.success());
    let pin = String::from_utf8(pin_output.stdout)
        .unwrap()
        .trim()
        .to_owned();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    sqlx::query("UPDATE ss_meta SET realm=$1,pin=$2")
        .bind(format!("https://{address}"))
        .bind(&pin)
        .execute(&db)
        .await
        .unwrap();
    struct Child(std::process::Child);
    impl Drop for Child {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let mut child = Child(
        Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
            .env_clear()
            .env("PARANOID_MODE", "self-service-v2-local")
            .env("PARANOID_BIND", address.to_string())
            .env("PARANOID_DATABASE_URL", &database_url)
            .env("PARANOID_TLS_CERT", &cert)
            .env("PARANOID_TLS_KEY", &key)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap(),
    );
    let mut ready = false;
    for _ in 0..50 {
        assert!(child.0.try_wait().unwrap().is_none());
        if Command::new("curl")
            .args(["--silent", "--fail", "--max-time", "1", "--cacert"])
            .arg(&cert)
            .arg(format!("https://{address}/health"))
            .output()
            .unwrap()
            .status
            .success()
        {
            ready = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(ready);
    let output = Command::new("python3")
        .arg(format!(
            "{}/realtime-tls-probe.py",
            env!("CARGO_MANIFEST_DIR")
        ))
        .arg("--port")
        .arg(address.port().to_string())
        .arg("--certificate")
        .arg(&cert)
        .arg("--pin")
        .arg(&pin)
        .output()
        .unwrap();
    print!("{}", String::from_utf8_lossy(&output.stdout));
    assert!(
        output.status.success(),
        "actual TLS probe failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    drop(child);
    db.close().await;
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn realtime_session_open_counts_auth_ingress_while_events_do_not() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    for _ in 0..8 {
        assert_eq!(
            http.post(format!("{url}/v2/session"))
                .body("{}")
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
    }
    let response = http
        .post(format!("{url}/v2/session"))
        .body("{}")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 429);
    assert_eq!(
        response.json::<Value>().await.unwrap()["error"],
        "ingress_limit"
    );
    task.abort();
    let (url, task) = serve(&db).await;
    for _ in 0..8 {
        assert_eq!(
            http.get(format!("{url}/v2/events?after=0"))
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
    }
    assert_eq!(
        http.post(format!("{url}/v2/session"))
            .body("{}")
            .send()
            .await
            .unwrap()
            .status(),
        401,
        "events cannot consume auth budget"
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn realtime_session_messages_preserve_non_evicting_quotas_and_exact_retries() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let a = register(&http, &url).await;
    let b = register(&http, &url).await;
    let session = session(&http, &url, &a).await;
    let body = message(&b);
    let accepted = operation(&http, &url, &a, &session, "POST", "/v2/messages", &body).await;
    assert_eq!(accepted.status(), 200);
    let accepted: Value = accepted.json().await.unwrap();
    let (low, high) = if a.credential.account < b.credential.account {
        (&a.credential.account, &b.credential.account)
    } else {
        (&b.credential.account, &a.credential.account)
    };
    sqlx::query("INSERT INTO ss_messages SELECT n,$1,$2,(md5(n::text)::uuid)::text,decode('01','hex'),$3,$4 FROM generate_series(2,10000) n")
        .bind(&a.credential.account).bind(&b.credential.account).bind(low).bind(high).execute(&db).await.unwrap();
    sqlx::query("UPDATE ss_meta SET sequence=10000")
        .execute(&db)
        .await
        .unwrap();
    assert_eq!(
        operation(
            &http,
            &url,
            &a,
            &session,
            "POST",
            "/v2/messages",
            &message(&b)
        )
        .await
        .status(),
        507
    );
    let retry: Value = operation(&http, &url, &a, &session, "POST", "/v2/messages", &body)
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(retry, accepted);
    let changed = body.replace("AQID", "AQIE");
    assert_eq!(
        operation(&http, &url, &a, &session, "POST", "/v2/messages", &changed)
            .await
            .status(),
        409
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_messages")
            .fetch_one(&db)
            .await
            .unwrap(),
        10000
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn realtime_committed_inbox_without_notify_is_recovered_by_lockless_tick() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let a = register(&http, &url).await;
    let b = register(&http, &url).await;
    let session = session(&http, &url, &b).await;
    let path = "/v2/events?after=0&limit=20";
    let waiter = tokio::spawn(
        http.get(format!("{url}{path}"))
            .header(
                "Authorization",
                proof(
                    &b,
                    &session,
                    &uuid::Uuid::new_v4().to_string(),
                    "GET",
                    path,
                    "",
                ),
            )
            .send(),
    );
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(!waiter.is_finished());
    // Preserve the exact committed-without-process-notification condition that
    // occurs if cancellation wins while awaiting a physically completed COMMIT.
    // This controls durable DB state, not an invented HTTP cancellation timing.
    let id = uuid::Uuid::new_v4().to_string();
    let (low, high) = if a.credential.account < b.credential.account {
        (&a.credential.account, &b.credential.account)
    } else {
        (&b.credential.account, &a.credential.account)
    };
    let mut tx = db.begin().await.unwrap();
    sqlx::query("SELECT id FROM ss_meta WHERE id=1 FOR UPDATE")
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("INSERT INTO ss_conversations VALUES($1,$2)")
        .bind(low)
        .bind(high)
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("UPDATE ss_meta SET sequence=1")
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("INSERT INTO ss_messages VALUES(1,$1,$2,$3,decode('010203','hex'),$4,$5)")
        .bind(&a.credential.account)
        .bind(&b.credential.account)
        .bind(&id)
        .bind(low)
        .bind(high)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let start = Instant::now();
    let page: Value = tokio::time::timeout(Duration::from_millis(1500), waiter)
        .await
        .unwrap()
        .unwrap()
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(page["messages"][0]["id"], id);
    println!(
        "committed-without-notify recovery ms={}",
        start.elapsed().as_millis()
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn realtime_eight_idle_waiters_do_not_starve_continuous_sends() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    // Match the actual TLS binary: one of its four PG connections is retained
    // for the process advisory lock, leaving three for operational work.
    let reserved_process_connection = db.acquire().await.unwrap();
    let http = reqwest::Client::new();
    let sender = seed_registered(&db).await;
    let receiver = seed_registered(&db).await;
    let sender_session = session(&http, &url, &sender).await;
    async fn measured_sends(
        http: &reqwest::Client,
        url: &str,
        sender: &Identity,
        session: &Value,
        receiver: &Identity,
    ) -> Vec<f64> {
        let mut timings = Vec::new();
        for _ in 0..30 {
            tokio::time::sleep(Duration::from_millis(65)).await;
            let body = message(receiver);
            let start = Instant::now();
            let response =
                operation(http, url, sender, session, "POST", "/v2/messages", &body).await;
            assert_eq!(
                response.status(),
                200,
                "continuous send cannot acquire-timeout or ingress-starve"
            );
            let value: Value = response.json().await.unwrap();
            assert!(value["sequence"].as_i64().unwrap() > 0);
            timings.push(start.elapsed().as_secs_f64() * 1000.0);
        }
        timings.sort_by(f64::total_cmp);
        timings
    }
    let baseline = measured_sends(&http, &url, &sender, &sender_session, &receiver).await;
    let mut users = Vec::new();
    for _ in 0..8 {
        let user = seed_registered(&db).await;
        let session = session(&http, &url, &user).await;
        users.push((user, session));
    }
    let path = "/v2/events?after=0&limit=20";
    let mut waiters = Vec::new();
    for (user, session) in &users {
        waiters.push(tokio::spawn(
            http.get(format!("{url}{path}"))
                .header(
                    "Authorization",
                    proof(
                        user,
                        session,
                        &uuid::Uuid::new_v4().to_string(),
                        "GET",
                        path,
                        "",
                    ),
                )
                .send(),
        ));
    }
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert!(waiters.iter().all(|w| !w.is_finished()));
    let loaded = measured_sends(&http, &url, &sender, &sender_session, &receiver).await;
    println!(
        "server HTTP/PG accept timings ms {}",
        json!({"baseline":baseline,"eight_idle_waiters":loaded,"baseline_p95":baseline[28],"eight_waiters_p95":loaded[28]})
    );
    assert!(
        loaded[28] < 1500.0,
        "local server accept P95 bounded under eight idle waits"
    );
    sqlx::query("UPDATE ss_accounts SET mode='revoked' WHERE account<>$1 AND account<>$2")
        .bind(&sender.credential.account)
        .bind(&receiver.credential.account)
        .execute(&db)
        .await
        .unwrap();
    for waiter in waiters {
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(2), waiter)
                .await
                .unwrap()
                .unwrap()
                .unwrap()
                .status(),
            401
        );
    }
    task.abort();
    drop(reserved_process_connection);
    db.close().await;
}
