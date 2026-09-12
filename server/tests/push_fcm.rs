//! RFC-0020: FCM wake gateway — token registration over the signed session and
//! content-free wakes against a local fake OAuth/FCM endpoint. No Google traffic.
use base64::Engine;
use paranoid_key_protocol::{digest, transcript, Identity};
use paranoid_server::self_service::{app_with_services, PushConfig};
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, PgPool};
use std::{
    process::Command,
    sync::{Arc, Mutex},
    time::Duration,
};

const REALM: &str = "https://127.0.0.2:38443";

async fn database() -> PgPool {
    let base = std::env::var("PARANOID_TEST_DATABASE_URL").unwrap();
    let admin = PgPoolOptions::new()
        .max_connections(1)
        .connect(&base)
        .await
        .unwrap();
    let name = format!("push_fcm_{}", uuid::Uuid::new_v4().simple());
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
        "{}",
        String::from_utf8_lossy(&init.stderr)
    );
    PgPoolOptions::new()
        .max_connections(4)
        .connect(&url)
        .await
        .unwrap()
}

/// Fake Google: /token issues a bearer, /send records wakes and answers per token.
#[derive(Default)]
struct Fake {
    token_requests: usize,
    sends: Vec<(String, Value)>,
    assertions: Vec<String>,
}

async fn fake_google(state: Arc<Mutex<Fake>>) -> String {
    use axum::{extract::State, routing::post, Json, Router};
    let router = Router::new()
        .route(
            "/token",
            post(|State(s): State<Arc<Mutex<Fake>>>, body: String| async move {
                let mut f = s.lock().unwrap();
                f.token_requests += 1;
                let assertion = body
                    .split('&')
                    .find_map(|kv| kv.strip_prefix("assertion="))
                    .unwrap()
                    .to_owned();
                f.assertions.push(assertion);
                Json(json!({"access_token":"fake-access","expires_in":3600,"token_type":"Bearer"}))
            }),
        )
        .route(
            "/v1/projects/{project}/messages:send",
            post(
                |State(s): State<Arc<Mutex<Fake>>>,
                 axum::extract::Path(project): axum::extract::Path<String>,
                 headers: axum::http::HeaderMap,
                 Json(body): Json<Value>| async move {
                    assert_eq!(project, "test-project");
                    assert_eq!(headers["authorization"], "Bearer fake-access");
                    let token = body["message"]["token"].as_str().unwrap().to_owned();
                    s.lock().unwrap().sends.push((token.clone(), body));
                    if token == "dead-token" {
                        (
                            axum::http::StatusCode::NOT_FOUND,
                            Json(json!({"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}})),
                        )
                    } else {
                        (axum::http::StatusCode::OK, Json(json!({"name":"projects/x/messages/1"})))
                    }
                },
            ),
        )
        .with_state(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    url
}

fn credential_file(google: &str) -> tempfile_path::Temp {
    let key = Command::new("openssl")
        .args([
            "genpkey",
            "-algorithm",
            "RSA",
            "-pkeyopt",
            "rsa_keygen_bits:2048",
        ])
        .output()
        .unwrap();
    assert!(key.status.success());
    let pem = String::from_utf8(key.stdout).unwrap();
    let file = tempfile_path::Temp::new("push-credential.json");
    std::fs::write(
        &file.path,
        json!({"type":"service_account","project_id":"test-project","private_key":pem,
            "client_email":"gw@test-project.iam.gserviceaccount.com","token_uri":format!("{google}/token")})
        .to_string(),
    )
    .unwrap();
    file
}

mod tempfile_path {
    pub struct Temp {
        pub path: std::path::PathBuf,
    }
    impl Temp {
        pub fn new(name: &str) -> Self {
            let dir = std::env::temp_dir()
                .join(format!("paranoid-push-{}", uuid::Uuid::new_v4().simple()));
            std::fs::create_dir_all(&dir).unwrap();
            Self {
                path: dir.join(name),
            }
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(self.path.parent().unwrap());
        }
    }
}

async fn serve(db: &PgPool, push: Option<PushConfig>) -> String {
    let router = app_with_services(db.clone(), None, push).await.unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    url
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

async fn seed(db: &PgPool) -> Identity {
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

async fn session(http: &reqwest::Client, url: &str, i: &Identity) -> Value {
    tokio::time::sleep(Duration::from_millis(550)).await;
    let request = json!({"credential":i.credential.fingerprint(),"account":i.credential.account,
        "device":i.credential.device,"purpose":"session","method":"POST","path":"/v2/session","body":digest(b"{}")});
    let ch: Value = http
        .post(format!("{url}/v2/auth/challenge"))
        .json(&request)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
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
    let r = http
        .post(format!("{url}/v2/session"))
        .header(
            "Authorization",
            format!("ParanoidV2 {}.{signature}", ch["id"].as_str().unwrap()),
        )
        .body("{}")
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 200);
    r.json().await.unwrap()
}

async fn call(
    http: &reqwest::Client,
    url: &str,
    i: &Identity,
    s: &Value,
    method: &str,
    path: &str,
    body: &str,
) -> reqwest::Response {
    let nonce = uuid::Uuid::new_v4().to_string();
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
        &[&nonce, method, path, &digest(body.as_bytes())],
    );
    http.request(method.parse().unwrap(), format!("{url}{path}"))
        .header(
            "Authorization",
            format!(
                "ParanoidSessionV2 {}.{nonce}.{signature}",
                s["id"].as_str().unwrap()
            ),
        )
        .body(body.to_owned())
        .send()
        .await
        .unwrap()
}

async fn sends(fake: &Arc<Mutex<Fake>>, expected: usize) -> Vec<(String, Value)> {
    for _ in 0..50 {
        if fake.lock().unwrap().sends.len() >= expected {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    fake.lock().unwrap().sends.clone()
}

#[tokio::test]
async fn push_register_wake_content_free_rate_limited_and_dead_token_removed() {
    let db = database().await;
    let fake = Arc::new(Mutex::new(Fake::default()));
    let google = fake_google(fake.clone()).await;
    let credential = credential_file(&google);
    let push = PushConfig::from_options(
        Some(&credential.path),
        Some(&format!("{google}/v1/projects/{{project}}/messages:send")),
    )
    .unwrap()
    .unwrap();
    let url = serve(&db, Some(push)).await;
    let http = reqwest::Client::new();
    let (alice, bob) = (seed(&db).await, seed(&db).await);
    let sa = session(&http, &url, &alice).await;
    let sb = session(&http, &url, &bob).await;

    // Registration binds to the authenticated account/device; bad shapes rejected.
    for bad in [
        json!({"platform":"apns","token":"x"}).to_string(),
        json!({"platform":"fcm","token":"bad token"}).to_string(),
        json!({"platform":"fcm","token":"x".repeat(4097)}).to_string(),
        json!({"platform":"fcm","token":"x","extra":1}).to_string(),
        "{".to_owned(),
    ] {
        assert_eq!(
            call(&http, &url, &bob, &sb, "POST", "/v2/push", &bad)
                .await
                .status(),
            400
        );
    }
    assert_eq!(
        call(&http, &url, &bob, &sb, "GET", "/v2/push", "")
            .await
            .status(),
        405,
        "GET is not a push route"
    );
    let ok = call(
        &http,
        &url,
        &bob,
        &sb,
        "POST",
        "/v2/push",
        &json!({"platform":"fcm","token":"bob-token"}).to_string(),
    )
    .await;
    assert_eq!(ok.status(), 200);
    assert_eq!(
        ok.json::<Value>().await.unwrap(),
        json!({"registered":true})
    );
    let row: (String, String, String) =
        sqlx::query_as("SELECT device,platform,token FROM ss_push_tokens WHERE account=$1")
            .bind(&bob.credential.account)
            .fetch_one(&db)
            .await
            .unwrap();
    assert_eq!(
        row,
        (
            bob.credential.device.clone(),
            "fcm".into(),
            "bob-token".into()
        )
    );

    // A message to bob (not long-polling) produces exactly one content-free wake.
    let text = |peer: &Identity| {
        json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":peer.credential.account,"ciphertext":"AQID"}).to_string()
    };
    assert_eq!(
        call(
            &http,
            &url,
            &alice,
            &sa,
            "POST",
            "/v2/messages",
            &text(&bob)
        )
        .await
        .status(),
        200
    );
    let sent = sends(&fake, 1).await;
    assert_eq!(sent.len(), 1);
    let (token, body) = &sent[0];
    assert_eq!(token, "bob-token");
    assert_eq!(body["message"]["data"], json!({"t":"wake"}));
    assert_eq!(body["message"]["android"]["priority"], "high");
    assert!(body["message"].get("notification").is_none());
    let raw = body.to_string();
    for secret in [
        alice.credential.account.as_str(),
        bob.credential.account.as_str(),
        "AQID",
        alice.credential.device.as_str(),
    ] {
        assert!(!raw.contains(secret), "wake must not carry {secret}");
    }
    // OAuth JWT: RS256 assertion, single token request cached afterwards.
    {
        let f = fake.lock().unwrap();
        assert_eq!(f.token_requests, 1);
        let parts: Vec<&str> = f.assertions[0].split('.').collect();
        assert_eq!(parts.len(), 3);
        let claims: Value = serde_json::from_slice(
            &base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(parts[1])
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            claims["scope"],
            "https://www.googleapis.com/auth/firebase.messaging"
        );
        assert_eq!(claims["iss"], "gw@test-project.iam.gserviceaccount.com");
    }
    // Second message within 10 s: rate-limited, no second wake.
    assert_eq!(
        call(
            &http,
            &url,
            &alice,
            &sa,
            "POST",
            "/v2/messages",
            &text(&bob)
        )
        .await
        .status(),
        200
    );
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(fake.lock().unwrap().sends.len(), 1);
    // Message to alice (no token): nothing sent.
    assert_eq!(
        call(
            &http,
            &url,
            &bob,
            &sb,
            "POST",
            "/v2/messages",
            &text(&alice)
        )
        .await
        .status(),
        200
    );
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(fake.lock().unwrap().sends.len(), 1);
    assert_eq!(
        fake.lock().unwrap().token_requests,
        1,
        "access token is cached"
    );

    // Dead token: FCM says UNREGISTERED -> row removed.
    let carol = seed(&db).await;
    let sc = session(&http, &url, &carol).await;
    assert_eq!(
        call(
            &http,
            &url,
            &carol,
            &sc,
            "POST",
            "/v2/push",
            &json!({"platform":"fcm","token":"dead-token"}).to_string()
        )
        .await
        .status(),
        200
    );
    assert_eq!(
        call(
            &http,
            &url,
            &alice,
            &sa,
            "POST",
            "/v2/messages",
            &text(&carol)
        )
        .await
        .status(),
        200
    );
    let sent = sends(&fake, 2).await;
    assert_eq!(sent[1].0, "dead-token");
    for _ in 0..50 {
        let n: i64 = sqlx::query_scalar("SELECT count(*) FROM ss_push_tokens WHERE account=$1")
            .bind(&carol.credential.account)
            .fetch_one(&db)
            .await
            .unwrap();
        if n == 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM ss_push_tokens WHERE account=$1")
        .bind(&carol.credential.account)
        .fetch_one(&db)
        .await
        .unwrap();
    assert_eq!(n, 0, "unregistered token deleted");

    // Explicit unregister with empty token.
    assert_eq!(
        call(
            &http,
            &url,
            &bob,
            &sb,
            "POST",
            "/v2/push",
            &json!({"platform":"fcm","token":""}).to_string()
        )
        .await
        .status(),
        200
    );
    let n: i64 = sqlx::query_scalar("SELECT count(*) FROM ss_push_tokens WHERE account=$1")
        .bind(&bob.credential.account)
        .fetch_one(&db)
        .await
        .unwrap();
    assert_eq!(n, 0);
    // Messages schema untouched: bob's inbox still has both messages.
    let inbox = call(
        &http,
        &url,
        &bob,
        &sb,
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
        2
    );
}

#[tokio::test]
async fn push_disabled_server_authenticates_then_404_and_never_contacts_anyone() {
    let db = database().await;
    let url = serve(&db, None).await;
    let http = reqwest::Client::new();
    let bob = seed(&db).await;
    let sb = session(&http, &url, &bob).await;
    let unsigned = http
        .post(format!("{url}/v2/push"))
        .body(json!({"platform":"fcm","token":"x"}).to_string())
        .send()
        .await
        .unwrap();
    assert_eq!(unsigned.status(), 401);
    let r = call(
        &http,
        &url,
        &bob,
        &sb,
        "POST",
        "/v2/push",
        &json!({"platform":"fcm","token":"x"}).to_string(),
    )
    .await;
    assert_eq!(r.status(), 404);
    assert_eq!(r.json::<Value>().await.unwrap()["error"], "push_disabled");
    let exists: bool =
        sqlx::query_scalar("SELECT to_regclass('public.ss_push_tokens') IS NOT NULL")
            .fetch_one(&db)
            .await
            .unwrap();
    assert!(
        !exists,
        "base v2 schema is untouched; the token table exists only with a configured gateway"
    );
}

#[test]
fn push_config_rejects_bad_credential_and_endpoint() {
    let dir = tempfile_path::Temp::new("c.json");
    std::fs::write(&dir.path, "{}").unwrap();
    assert!(PushConfig::from_options(Some(&dir.path), None).is_err());
    std::fs::write(&dir.path, json!({"project_id":"p","client_email":"e","token_uri":"http://evil/x","private_key":"nope"}).to_string()).unwrap();
    assert!(PushConfig::from_options(Some(&dir.path), None).is_err());
    assert!(PushConfig::from_options(None, None).unwrap().is_none());
    let key = Command::new("openssl")
        .args([
            "genpkey",
            "-algorithm",
            "RSA",
            "-pkeyopt",
            "rsa_keygen_bits:2048",
        ])
        .output()
        .unwrap();
    std::fs::write(&dir.path, json!({"project_id":"p","client_email":"e","token_uri":"https://oauth2.googleapis.com/token","private_key":String::from_utf8(key.stdout).unwrap()}).to_string()).unwrap();
    assert!(PushConfig::from_options(Some(&dir.path), None)
        .unwrap()
        .is_some());
    assert!(
        PushConfig::from_options(Some(&dir.path), Some("http://10.0.0.1/x")).is_err(),
        "override only loopback or https"
    );
}
