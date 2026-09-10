//! REQ-CALL-006: actual HTTP/PG/session TURN authority, pre-design test draft.
//! Test transcripts deliberately do not call the implementation SessionV2 helper.
use base64::{engine::general_purpose::STANDARD, Engine};
use paranoid_key_protocol::{digest, transcript, Identity};
use paranoid_server::self_service::{app_with_turn, TurnConfig};
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, PgPool};
use std::{
    fs,
    io::Write,
    net::Ipv4Addr,
    os::unix::fs::{symlink, OpenOptionsExt, PermissionsExt},
    path::PathBuf,
    process::{Command, Stdio},
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
    let name = format!("voice_turn_{}", uuid::Uuid::new_v4().simple());
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
async fn turn_disabled_endpoint_authenticates_before_returning_404() {
    let db = database().await;
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = register(&http, &url).await;
    let s = session(&http, &url, &i).await;
    assert_eq!(
        operation(
            &http,
            &url,
            &i,
            &s,
            "GET",
            "/v2/messages?after=0&limit=20",
            ""
        )
        .await
        .status(),
        200
    );
    let unauthorized = http
        .get(format!("{url}/v2/voice/turn"))
        .send()
        .await
        .unwrap();
    assert_eq!(
        unauthorized.status(),
        401,
        "missing TURN authority must not be indistinguishable from a supported disabled endpoint"
    );
    let disabled = operation(&http, &url, &i, &s, "GET", "/v2/voice/turn", "").await;
    assert_eq!(disabled.status(), 404);
    assert_eq!(disabled.headers().get("cache-control").unwrap(), "no-store");
    assert_eq!(
        disabled.json::<Value>().await.unwrap(),
        json!({"error":"turn_disabled"})
    );
    task.abort();
    db.close().await;
}

const TURN_PATH: &str = "/v2/voice/turn";

#[test]
fn turn_binary_explicit_capability_cannot_be_claimed_by_old_v2_binary() {
    let output = Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
        .env_clear()
        .arg("voice-turn-capabilities")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "issuer binary must explicitly attest its fixed capability"
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap(),
        json!({"api":1,"issuer":"signed-session-turn-v1"})
    );
}

struct PrivateSecret {
    directory: PathBuf,
    path: PathBuf,
}
impl PrivateSecret {
    fn new() -> Self {
        let directory =
            std::env::temp_dir().join(format!("paranoid-turn-secret-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&directory).unwrap();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.join("secret");
        let mut file = fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        write!(
            file,
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        )
        .unwrap();
        Self { directory, path }
    }
    fn load(&self) -> TurnConfig {
        TurnConfig::load(&self.path, Ipv4Addr::new(127, 0, 0, 2), true).unwrap()
    }
}
impl Drop for PrivateSecret {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.directory).unwrap();
    }
}

async fn configured(db: &PgPool, secret: &PrivateSecret) -> (String, tokio::task::JoinHandle<()>) {
    let router = app_with_turn(db.clone(), Some(secret.load()))
        .await
        .unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    (
        url,
        tokio::spawn(async move { axum::serve(listener, router).await.unwrap() }),
    )
}

fn independent_password(secret: &PrivateSecret, username: &str) -> String {
    // Independent standard-library HMAC; secret never enters argv or test output.
    let mut child = Command::new("python3").arg("-c")
        .arg("import base64,hashlib,hmac,pathlib,sys; print(base64.b64encode(hmac.new(pathlib.Path(sys.argv[1]).read_bytes(),sys.stdin.buffer.read(),hashlib.sha1).digest()).decode())")
        .arg(&secret.path).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(username.as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

#[tokio::test]
async fn turn_real_session_issues_strict_random_hmac_and_preserves_messages_schema() {
    let db = database().await;
    let secret = PrivateSecret::new();
    let (url, task) = configured(&db, &secret).await;
    let http = reqwest::Client::new();
    let i = register(&http, &url).await;
    let s = session(&http, &url, &i).await;
    let mut usernames = std::collections::HashSet::new();
    let before = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    for _ in 0..2 {
        let response = operation(&http, &url, &i, &s, "GET", TURN_PATH, "").await;
        assert_eq!(response.status(), 200);
        assert_eq!(response.headers().get("cache-control").unwrap(), "no-store");
        let bytes = response.bytes().await.unwrap();
        assert!(bytes.len() <= 2048);
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value.as_object().unwrap().len(), 6);
        assert_eq!(value["v"], 1);
        assert_eq!(value["ttl"], 1200);
        assert_eq!(
            value["urls"],
            json!([
                "turn:127.0.0.2:34781?transport=udp",
                "turn:127.0.0.2:34781?transport=tcp"
            ])
        );
        let expires = value["expires"].as_u64().unwrap();
        assert!((before + 1200..=before + 1205).contains(&expires));
        let username = value["username"].as_str().unwrap();
        let (prefix, suffix) = username.split_once(':').unwrap();
        assert_eq!(prefix, expires.to_string());
        assert_eq!(suffix.len(), 32);
        assert!(suffix
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)));
        assert!(usernames.insert(username.to_owned()));
        assert!(!username.contains(&i.credential.account));
        let credential = value["credential"].as_str().unwrap();
        let decoded = STANDARD.decode(credential).unwrap();
        assert_eq!(decoded.len(), 20);
        assert!(STANDARD.encode(decoded) == credential);
        assert!(
            independent_password(&secret, username) == credential,
            "independent HMAC must match without logging credentials"
        );
    }
    let counts: (i64, i64, i64) = sqlx::query_as("SELECT (SELECT count(*) FROM ss_conversations),(SELECT count(*) FROM ss_messages),(SELECT sequence FROM ss_meta WHERE id=1)").fetch_one(&db).await.unwrap();
    assert_eq!(counts, (0, 0, 0));
    let peer = register(&http, &url).await;
    assert_eq!(
        operation(&http, &url, &i, &s, "POST", "/v2/messages", &message(&peer))
            .await
            .status(),
        200
    );
    let peer_session = session(&http, &url, &peer).await;
    let inbox = operation(
        &http,
        &url,
        &peer,
        &peer_session,
        "GET",
        "/v2/messages?after=0&limit=20",
        "",
    )
    .await;
    assert_eq!(inbox.status(), 200);
    assert_eq!(
        inbox.json::<Value>().await.unwrap()["messages"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn turn_fixed_route_body_auth_context_replay_and_concurrent_winner() {
    let db = database().await;
    let secret = PrivateSecret::new();
    let (url, task) = configured(&db, &secret).await;
    let http = reqwest::Client::new();
    let i = register(&http, &url).await;
    let s = session(&http, &url, &i).await;
    let nonce = uuid::Uuid::new_v4().to_string();
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
        let mut changed = s.clone();
        changed[field] = if field == "expires" {
            json!(s[field].as_i64().unwrap() + 1)
        } else {
            json!("changed")
        };
        let h = proof(&i, &changed, &nonce, "GET", TURN_PATH, "");
        assert_eq!(
            http.get(format!("{url}{TURN_PATH}"))
                .header("Authorization", h)
                .send()
                .await
                .unwrap()
                .status(),
            401,
            "all signed context fields remain bound"
        );
    }
    for (path, body) in [
        ("/v2/voice/turn?x=1", ""),
        (TURN_PATH, "{}"),
        (TURN_PATH, " "),
    ] {
        assert_eq!(
            operation(&http, &url, &i, &s, "GET", path, body)
                .await
                .status(),
            401
        );
    }
    let good = proof(&i, &s, &nonce, "GET", TURN_PATH, "");
    assert_eq!(
        http.get(format!("{url}{TURN_PATH}"))
            .header("Authorization", &good)
            .header("Authorization", &good)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    // Invalid proofs must not spend the one valid nonce or issuance budget.
    let request = || {
        http.get(format!("{url}{TURN_PATH}"))
            .header("Authorization", &good)
            .send()
    };
    let (a, b) = tokio::join!(request(), request());
    let mut statuses = vec![a.unwrap().status().as_u16(), b.unwrap().status().as_u16()];
    statuses.sort_unstable();
    assert_eq!(statuses, vec![200, 401]);
    assert_eq!(
        http.get(format!("{url}{TURN_PATH}"))
            .header("Authorization", good)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn turn_locked_revocation_denies_waiting_issuance_and_restart_invalidates_session() {
    let db = database().await;
    let secret = PrivateSecret::new();
    let (url, task) = configured(&db, &secret).await;
    let http = reqwest::Client::new();
    let i = register(&http, &url).await;
    let s = session(&http, &url, &i).await;
    let mut tx = db.begin().await.unwrap();
    sqlx::query("SELECT id FROM ss_meta WHERE id=1 FOR UPDATE")
        .execute(&mut *tx)
        .await
        .unwrap();
    let h = proof(
        &i,
        &s,
        &uuid::Uuid::new_v4().to_string(),
        "GET",
        TURN_PATH,
        "",
    );
    let request = http
        .get(format!("{url}{TURN_PATH}"))
        .header("Authorization", h)
        .send();
    let waiter = tokio::spawn(request);
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(
        !waiter.is_finished(),
        "issuer must serialize with retained DB authorization lock"
    );
    sqlx::query("UPDATE ss_accounts SET mode='revoked' WHERE account=$1")
        .bind(&i.credential.account)
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert_eq!(waiter.await.unwrap().unwrap().status(), 401);
    task.abort();
    let (url, task) = configured(&db, &secret).await;
    assert_eq!(
        operation(&http, &url, &i, &s, "GET", TURN_PATH, "")
            .await
            .status(),
        401
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn turn_changed_immutable_bindings_and_meta_trust_fail_closed() {
    for mutation in [
        "UPDATE ss_accounts SET root='changed'",
        "UPDATE ss_accounts SET mode='pending'",
        "UPDATE ss_devices SET device='changed'",
        "UPDATE ss_devices SET auth='changed'",
        "UPDATE ss_devices SET fingerprint='changed'",
        "UPDATE ss_devices SET credential='{}'",
        "UPDATE ss_meta SET realm='https://127.0.0.3:38443'",
        "UPDATE ss_meta SET pin='changed'",
        "DELETE FROM ss_meta",
        "ALTER TABLE ss_meta DROP CONSTRAINT ss_meta_version_check; UPDATE ss_meta SET version=3",
    ] {
        let db = database().await;
        let secret = PrivateSecret::new();
        let (url, task) = configured(&db, &secret).await;
        let http = reqwest::Client::new();
        let i = register(&http, &url).await;
        let s = session(&http, &url, &i).await;
        sqlx::raw_sql(mutation).execute(&db).await.unwrap();
        assert_eq!(
            operation(&http, &url, &i, &s, "GET", TURN_PATH, "")
                .await
                .status(),
            401,
            "mutated immutable context cannot issue relay credentials"
        );
        task.abort();
        db.close().await;
    }
}

#[tokio::test]
async fn turn_account_quota_survives_fresh_session_without_starving_text() {
    let db = database().await;
    let secret = PrivateSecret::new();
    let (url, task) = configured(&db, &secret).await;
    let http = reqwest::Client::new();
    let i = register(&http, &url).await;
    let s = session(&http, &url, &i).await;
    for _ in 0..4 {
        assert_eq!(
            operation(&http, &url, &i, &s, "GET", TURN_PATH, "")
                .await
                .status(),
            200
        );
    }
    assert_eq!(
        operation(&http, &url, &i, &s, "GET", TURN_PATH, "")
            .await
            .status(),
        429
    );
    let replacement = session(&http, &url, &i).await;
    assert_eq!(
        operation(&http, &url, &i, &replacement, "GET", TURN_PATH, "")
            .await
            .status(),
        429
    );
    assert_eq!(
        operation(
            &http,
            &url,
            &i,
            &replacement,
            "GET",
            "/v2/messages?after=0&limit=20",
            ""
        )
        .await
        .status(),
        200
    );
    task.abort();
    let (url, task) = configured(&db, &secret).await;
    assert_eq!(
        operation(&http, &url, &i, &replacement, "GET", TURN_PATH, "")
            .await
            .status(),
        401
    );
    let restarted = session(&http, &url, &i).await;
    assert_ne!(restarted["epoch"], replacement["epoch"]);
    assert_eq!(
        operation(&http, &url, &i, &restarted, "GET", TURN_PATH, "")
            .await
            .status(),
        200
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn turn_global_quota_limits_distinct_real_device_authorities() {
    let db = database().await;
    let secret = PrivateSecret::new();
    let (url, task) = configured(&db, &secret).await;
    let http = reqwest::Client::new();
    for _ in 0..8 {
        let i = seed_registered(&db).await;
        let s = session(&http, &url, &i).await;
        for _ in 0..4 {
            assert_eq!(
                operation(&http, &url, &i, &s, "GET", TURN_PATH, "")
                    .await
                    .status(),
                200
            );
            tokio::time::sleep(Duration::from_millis(60)).await;
        }
    }
    let i = seed_registered(&db).await;
    let s = session(&http, &url, &i).await;
    assert_eq!(
        operation(&http, &url, &i, &s, "GET", TURN_PATH, "")
            .await
            .status(),
        429
    );
    assert_eq!(
        operation(
            &http,
            &url,
            &i,
            &s,
            "GET",
            "/v2/messages?after=0&limit=20",
            ""
        )
        .await
        .status(),
        200
    );
    task.abort();
    db.close().await;
}

#[test]
fn turn_secret_loader_rejects_unsafe_shape_permissions_links_and_fifo_without_hang() {
    let secret = PrivateSecret::new();
    let load = |path: &std::path::Path| TurnConfig::load(path, Ipv4Addr::new(127, 0, 0, 2), true);
    assert!(load(&secret.path).is_ok());
    fs::set_permissions(&secret.path, fs::Permissions::from_mode(0o400)).unwrap();
    assert!(load(&secret.path).is_ok());
    for mode in [0o000, 0o644, 0o660, 0o640, 0o700, 0o4600] {
        fs::set_permissions(&secret.path, fs::Permissions::from_mode(mode)).unwrap();
        assert!(load(&secret.path).is_err());
    }
    fs::set_permissions(&secret.path, fs::Permissions::from_mode(0o600)).unwrap();
    let link = secret.directory.join("link");
    symlink(&secret.path, &link).unwrap();
    assert!(load(&link).is_err());
    fs::remove_file(&link).unwrap();
    fs::hard_link(&secret.path, &link).unwrap();
    assert!(load(&secret.path).is_err());
    fs::remove_file(&link).unwrap();
    assert!(load(&secret.directory).is_err());
    assert!(load(std::path::Path::new("relative-secret")).is_err());
    for value in [
        "".to_owned(),
        "a".repeat(63),
        "a".repeat(65),
        "A".repeat(64),
        format!("{}\n", "a".repeat(64)),
        "x".repeat(64),
    ] {
        fs::write(&secret.path, value).unwrap();
        assert!(load(&secret.path).is_err());
    }
    let fifo = secret.directory.join("fifo");
    assert!(Command::new("mkfifo")
        .arg(&fifo)
        .status()
        .unwrap()
        .success());
    let start = Instant::now();
    assert!(load(&fifo).is_err());
    assert!(
        start.elapsed() < Duration::from_millis(500),
        "nonregular secret must never block opening"
    );
}

#[tokio::test]
async fn turn_configuration_rejects_host_mismatch_and_public_private_relay() {
    let secret = PrivateSecret::new();
    for ip in [
        Ipv4Addr::LOCALHOST,
        Ipv4Addr::new(10, 0, 0, 1),
        Ipv4Addr::new(169, 254, 1, 1),
        Ipv4Addr::new(224, 0, 0, 1),
        Ipv4Addr::new(100, 64, 0, 1),
        Ipv4Addr::new(192, 0, 2, 1),
        Ipv4Addr::new(198, 51, 100, 1),
        Ipv4Addr::new(203, 0, 113, 1),
        Ipv4Addr::new(198, 18, 0, 1),
        Ipv4Addr::new(240, 0, 0, 1),
        Ipv4Addr::UNSPECIFIED,
    ] {
        assert!(TurnConfig::load(&secret.path, ip, false).is_err());
    }
    assert!(TurnConfig::load(&secret.path, Ipv4Addr::new(157, 180, 49, 125), false).is_ok());
    let db = database().await;
    let wrong = TurnConfig::load(&secret.path, Ipv4Addr::LOCALHOST, true).unwrap();
    assert!(app_with_turn(db.clone(), Some(wrong)).await.is_err());
    db.close().await;
}

#[test]
fn turn_startup_options_require_both_values_and_reject_invalid_partial_configuration() {
    let secret = PrivateSecret::new();
    assert!(TurnConfig::from_options(None, None, true)
        .unwrap()
        .is_none());
    assert!(TurnConfig::from_options(Some(&secret.path), None, true).is_err());
    assert!(TurnConfig::from_options(None, Some("127.0.0.2"), true).is_err());
    assert!(TurnConfig::from_options(Some(&secret.path), Some(""), true).is_err());
    assert!(TurnConfig::from_options(Some(&secret.path), Some("127.0.0.2:34781"), true).is_err());
    assert!(TurnConfig::from_options(Some(&secret.path), Some("relay.invalid"), true).is_err());
    assert!(
        TurnConfig::from_options(Some(&secret.path), Some("127.0.0.2"), true)
            .unwrap()
            .is_some()
    );
    assert!(TurnConfig::from_options(Some(&secret.path), Some("127.0.0.2"), false).is_err());
}

#[test]
fn turn_startup_rejects_noncanonical_host_syntax() {
    let secret = PrivateSecret::new();
    for host in [
        "127.00.0.2",
        "127.0.0.2 ",
        "::1",
        "::ffff:127.0.0.2",
        "https://127.0.0.2",
        "127.0.0.2?x=1",
    ] {
        assert!(TurnConfig::from_options(Some(&secret.path), Some(host), true).is_err());
    }
}

#[test]
fn turn_actual_native_startup_rejects_partial_config_before_listener_or_tls() {
    let secret = PrivateSecret::new();
    for (file, ip) in [
        (Some(secret.path.as_path()), None),
        (None, Some("127.0.0.2")),
        (Some(secret.path.as_path()), Some("relay.invalid")),
    ] {
        let mut command = Command::new(env!("CARGO_BIN_EXE_paranoid-server"));
        command
            .env_clear()
            .env("PARANOID_MODE", "self-service-v2-local");
        if let Some(path) = file {
            command.env("PARANOID_TURN_SECRET_FILE", path);
        }
        if let Some(ip) = ip {
            command.env("PARANOID_TURN_RELAY_IP", ip);
        }
        let output = command.output().unwrap();
        assert!(!output.status.success());
        assert!(
            String::from_utf8_lossy(&output.stderr) == "ParanoID development server could not start or stopped with an error\n",
            "native startup must fail before TLS validation and preserve the generic sanitized error"
        );
    }
}

#[tokio::test]
async fn turn_actual_native_binary_pinned_tls_and_same_data_disabled_reopen() {
    let db = database().await;
    let secret = PrivateSecret::new();
    let name: String = sqlx::query_scalar("SELECT current_database()")
        .fetch_one(&db)
        .await
        .unwrap();
    let database_url = std::env::var("PARANOID_TEST_DATABASE_URL")
        .unwrap()
        .replace("/postgres?", &format!("/{name}?"));
    let cert = secret.directory.join("cert.pem");
    let key = secret.directory.join("key.pem");
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
    let output = Command::new("python3").args(["-c", "import sys,hashlib;from cryptography import x509;from cryptography.hazmat.primitives import serialization;p=x509.load_pem_x509_certificate(open(sys.argv[1],'rb').read()).public_key();print(hashlib.sha256(p.public_bytes(serialization.Encoding.DER,serialization.PublicFormat.SubjectPublicKeyInfo)).hexdigest())"]).arg(&cert).output().unwrap();
    assert!(output.status.success());
    let pin = String::from_utf8(output.stdout).unwrap().trim().to_owned();
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
            .env("PARANOID_TURN_SECRET_FILE", &secret.path)
            .env("PARANOID_TURN_RELAY_IP", "127.0.0.1")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
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
            "{}/voice-turn-tls-probe.py",
            env!("CARGO_MANIFEST_DIR")
        ))
        .arg("--port")
        .arg(address.port().to_string())
        .arg("--certificate")
        .arg(&cert)
        .arg("--pin")
        .arg(&pin)
        .arg("--secret-file")
        .arg(&secret.path)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "pinned issuer TLS probe failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    print!("{}", String::from_utf8_lossy(&output.stdout));
    drop(child);
    // Same schema/data can reopen through the retained default-disabled wrapper.
    let before: i64 = sqlx::query_scalar("SELECT count(*) FROM ss_accounts")
        .fetch_one(&db)
        .await
        .unwrap();
    let app = paranoid_server::self_service::app(db.clone())
        .await
        .unwrap();
    drop(app);
    let after: i64 = sqlx::query_scalar("SELECT count(*) FROM ss_accounts")
        .fetch_one(&db)
        .await
        .unwrap();
    assert_eq!(before, 1);
    assert_eq!(after, before);
    db.close().await;
}
