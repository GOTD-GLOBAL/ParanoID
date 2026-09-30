//! RFC-0027 identity-login-v3 server tests (AUTH-01..05 subset) against real PostgreSQL.
//! Registry RPC is a programmable fake here; live Devnet readback is tested separately.
use paranoid_key_protocol::identity_v3::{
    base58_encode, derive_registry, ChallengeRequestV3, IdentityChallengeV3, ProofRole, Purpose,
    GENESIS, PROGRAM,
};
use paranoid_key_protocol::Identity;
use paranoid_server::identity_v3::{RegistryFailure, RegistryVerifier};
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, PgPool};
use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc, Mutex,
};
use vodozemac::Ed25519SecretKey;

const REALM: &str = "https://127.0.0.3:38444";

#[derive(Default)]
struct FakeRegistry {
    calls: AtomicUsize,
    names: Mutex<HashMap<[u8; 32], String>>,
    outage: Mutex<bool>,
}
impl FakeRegistry {
    fn register(&self, u: &User) {
        self.names
            .lock()
            .unwrap()
            .insert(*u.owner.public_key().as_bytes(), u.name.clone());
    }
}
impl RegistryVerifier for FakeRegistry {
    fn verify<'a>(
        &'a self,
        owner: [u8; 32],
        name: &'a str,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), RegistryFailure>> + Send + 'a>>
    {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if *self.outage.lock().unwrap() {
                return Err(RegistryFailure::Unavailable);
            }
            match self.names.lock().unwrap().get(&owner) {
                Some(n) if n == name => Ok(()),
                _ => Err(RegistryFailure::Invalid),
            }
        })
    }
}

struct User {
    owner: Ed25519SecretKey,
    name: String,
}
fn user(name: &str) -> User {
    User {
        owner: Ed25519SecretKey::new(),
        name: name.into(),
    }
}
fn device() -> Identity {
    Identity::create(
        REALM,
        &"a".repeat(64),
        "curve",
        &uuid::Uuid::new_v4().to_string(),
    )
    .unwrap()
}
fn request(
    u: &User,
    d: &Identity,
    purpose: Purpose,
    generation: &str,
    op: &str,
) -> ChallengeRequestV3 {
    let owner = u.owner.public_key();
    ChallengeRequestV3 {
        purpose,
        operation: op.into(),
        genesis: GENESIS.into(),
        program: PROGRAM.into(),
        identity: base58_encode(&derive_registry(owner.as_bytes(), &u.name).unwrap().identity),
        owner: base58_encode(owner.as_bytes()),
        name: u.name.clone(),
        credential_object: d.credential.clone(),
        expected_generation: generation.into(),
    }
}
fn op() -> String {
    uuid::Uuid::new_v4().to_string()
}

struct Server {
    url: String,
    http: reqwest::Client,
    db: PgPool,
    registry: Arc<FakeRegistry>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn database() -> (PgPool, String) {
    let base = std::env::var("PARANOID_TEST_DATABASE_URL").unwrap();
    let admin = PgPoolOptions::new()
        .max_connections(1)
        .connect(&base)
        .await
        .unwrap();
    let name = format!("idv3_{}", uuid::Uuid::new_v4().simple());
    sqlx::QueryBuilder::<sqlx::Postgres>::new("CREATE DATABASE ")
        .push(&name)
        .build()
        .execute(&admin)
        .await
        .unwrap();
    admin.close().await;
    let url = base.replace("/postgres?", &format!("/{name}?"));
    (
        PgPoolOptions::new()
            .max_connections(4)
            .connect(&url)
            .await
            .unwrap(),
        url,
    )
}

async fn server() -> Server {
    let (db, _) = database().await;
    paranoid_server::identity_v3::initialize(&db, REALM, &"a".repeat(64))
        .await
        .unwrap();
    serve(db).await
}
async fn serve(db: PgPool) -> Server {
    let registry = Arc::new(FakeRegistry::default());
    let router = paranoid_server::identity_v3::app(db.clone(), None, None, registry.clone())
        .await
        .unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    Server {
        url,
        http: reqwest::Client::new(),
        db,
        registry,
        task,
    }
}

async fn post(s: &Server, path: &str, body: &Value) -> (u16, Value) {
    // Stay under the shared 8 auth-requests/second ingress window.
    tokio::time::sleep(std::time::Duration::from_millis(140)).await;
    let r = s
        .http
        .post(format!("{}{path}", s.url))
        .json(body)
        .send()
        .await
        .unwrap();
    let status = r.status().as_u16();
    (status, r.json().await.unwrap_or(Value::Null))
}

async fn challenge(s: &Server, r: &ChallengeRequestV3) -> (u16, Value) {
    post(
        s,
        "/v3/identity/challenge",
        &serde_json::to_value(r).unwrap(),
    )
    .await
}

fn proofs(u: &User, d: &Identity, ch: &Value) -> Value {
    let c: IdentityChallengeV3 = serde_json::from_value(ch.clone()).unwrap();
    let auth = Ed25519SecretKey::from_base64(&d.auth_secret).unwrap();
    let device_signature = auth
        .sign(&c.transcript(ProofRole::Device).unwrap())
        .to_base64();
    if c.purpose == Purpose::Status {
        json!({"id": c.id, "device_signature": device_signature})
    } else {
        let owner_signature = u
            .owner
            .sign(&c.transcript(ProofRole::Owner).unwrap())
            .to_base64();
        json!({"id": c.id, "owner_signature": owner_signature, "device_signature": device_signature})
    }
}

async fn call(
    s: &Server,
    u: &User,
    d: &Identity,
    purpose: Purpose,
    generation: &str,
    op: &str,
) -> (u16, Value) {
    let (status, ch) = challenge(s, &request(u, d, purpose, generation, op)).await;
    assert_eq!(status, 200, "challenge rejected: {ch}");
    post(s, purpose.path(), &proofs(u, d, &ch)).await
}

/// Existing v2 device proof on /v2/auth/verify with the transport credential.
async fn v2_status(s: &Server, d: &Identity) -> u16 {
    let body = "{}";
    let (status, ch) = post(
        s,
        "/v2/auth/challenge",
        &json!({"account": d.credential.account, "device": d.credential.device,
            "credential": d.credential.fingerprint(), "purpose": "status", "method": "POST",
            "path": "/v2/auth/verify", "body": paranoid_key_protocol::digest(body.as_bytes())}),
    )
    .await;
    if status != 200 {
        return status;
    }
    let c: paranoid_key_protocol::ChallengeV2 = serde_json::from_value(ch).unwrap();
    let sig = Ed25519SecretKey::from_base64(&d.auth_secret)
        .unwrap()
        .sign(&c.bytes())
        .to_base64();
    tokio::time::sleep(std::time::Duration::from_millis(140)).await;
    s.http
        .post(format!("{}/v2/auth/verify", s.url))
        .header("authorization", format!("ParanoidV2 {}.{sig}", c.id))
        .body(body)
        .send()
        .await
        .unwrap()
        .status()
        .as_u16()
}

async fn send_message(s: &Server, from: &Identity, to: &str) -> (u16, Value) {
    let body =
        json!({"id": uuid::Uuid::new_v4().to_string(), "recipient": to, "ciphertext": "AQID"})
            .to_string();
    let (status, ch) = post(
        s,
        "/v2/auth/challenge",
        &json!({"account": from.credential.account, "device": from.credential.device,
            "credential": from.credential.fingerprint(), "purpose": "message", "method": "POST",
            "path": "/v2/messages", "body": paranoid_key_protocol::digest(body.as_bytes())}),
    )
    .await;
    assert_eq!(status, 200, "{ch}");
    let c: paranoid_key_protocol::ChallengeV2 = serde_json::from_value(ch).unwrap();
    let sig = Ed25519SecretKey::from_base64(&from.auth_secret)
        .unwrap()
        .sign(&c.bytes())
        .to_base64();
    tokio::time::sleep(std::time::Duration::from_millis(140)).await;
    let r = s
        .http
        .post(format!("{}/v2/messages", s.url))
        .header("authorization", format!("ParanoidV2 {}.{sig}", c.id))
        .header("content-type", "application/json")
        .body(body)
        .send()
        .await
        .unwrap();
    let status = r.status().as_u16();
    (status, r.json().await.unwrap_or(Value::Null))
}

async fn open_session(s: &Server, d: &Identity) -> paranoid_key_protocol::SessionV2 {
    let (status, ch) = post(
        s,
        "/v2/auth/challenge",
        &json!({"account": d.credential.account, "device": d.credential.device,
            "credential": d.credential.fingerprint(), "purpose": "session", "method": "POST",
            "path": "/v2/session", "body": paranoid_key_protocol::digest(b"{}")}),
    )
    .await;
    assert_eq!(status, 200, "{ch}");
    let c: paranoid_key_protocol::ChallengeV2 = serde_json::from_value(ch).unwrap();
    let sig = Ed25519SecretKey::from_base64(&d.auth_secret)
        .unwrap()
        .sign(&c.bytes())
        .to_base64();
    tokio::time::sleep(std::time::Duration::from_millis(140)).await;
    s.http
        .post(format!("{}/v2/session", s.url))
        .header("authorization", format!("ParanoidV2 {}.{sig}", c.id))
        .body("{}")
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap()
}

async fn session_call(
    s: &Server,
    d: &Identity,
    session: &paranoid_key_protocol::SessionV2,
    method: &str,
    path: &str,
    body: &str,
) -> u16 {
    let nonce = uuid::Uuid::new_v4().to_string();
    let bytes = session.bytes(
        &nonce,
        method,
        path,
        &paranoid_key_protocol::digest(body.as_bytes()),
    );
    let sig = Ed25519SecretKey::from_base64(&d.auth_secret)
        .unwrap()
        .sign(&bytes)
        .to_base64();
    tokio::time::sleep(std::time::Duration::from_millis(60)).await;
    let request = if method == "GET" {
        s.http.get(format!("{}{path}", s.url))
    } else {
        s.http
            .post(format!("{}{path}", s.url))
            .body(body.to_owned())
    };
    request
        .header(
            "authorization",
            format!("ParanoidSessionV2 {}.{nonce}.{sig}", session.id),
        )
        .send()
        .await
        .unwrap()
        .status()
        .as_u16()
}

#[tokio::test]
async fn v2_auth_routes_cannot_register_accounts_in_v3_mode() {
    let s = server().await;
    let d = device();
    for (path, body) in [
        (
            "/v2/auth/challenge",
            json!({"credential": d.credential, "purpose": "register",
            "method": "POST", "path": "/v2/registration/commit",
            "body": paranoid_key_protocol::digest(b"{}")}),
        ),
        (
            "/v2/auth/challenge",
            json!({"account": d.credential.account, "device": d.credential.device,
            "credential": d.credential.fingerprint(), "purpose": "register", "method": "POST",
            "path": "/v2/registration/commit", "body": paranoid_key_protocol::digest(b"{}")}),
        ),
        (
            "/v2/auth/challenge",
            json!({"account": d.credential.account, "device": d.credential.device,
            "credential": d.credential.fingerprint(), "purpose": "status", "method": "POST",
            "path": "/v2/auth/verify", "body": paranoid_key_protocol::digest(b"{}")}),
        ),
    ] {
        let (status, _) = post(&s, path, &body).await;
        assert_eq!(status, 401, "{path} {body}");
    }
    for path in ["/v2/auth/verify", "/v2/session"] {
        assert_eq!(post(&s, path, &json!({})).await.0, 401);
    }
    let accounts: i64 = sqlx::query_scalar("SELECT (SELECT count(*) FROM ss_accounts)+(SELECT count(*) FROM ss_devices)+(SELECT count(*) FROM id_memberships)+(SELECT count(*) FROM id_bindings)")
        .fetch_one(&s.db)
        .await
        .unwrap();
    assert_eq!(accounts, 0, "no rows created without a v3 commit");
}

#[tokio::test]
async fn replacement_revokes_every_session_operation_of_the_old_device() {
    let s = server().await;
    let alice = user("alice_sess");
    s.registry.register(&alice);
    let (old, new) = (device(), device());
    call(&s, &alice, &old, Purpose::Enroll, "0", &op()).await;
    let session = open_session(&s, &old).await;
    let push = r#"{"platform":"fcm","token":"t"}"#;
    assert_eq!(
        session_call(
            &s,
            &old,
            &session,
            "GET",
            "/v2/messages?after=0&limit=20",
            ""
        )
        .await,
        200,
        "session works before replacement"
    );
    call(&s, &alice, &new, Purpose::Replace, "1", &op()).await;
    for (method, path, body) in [
        ("GET", "/v2/messages?after=0&limit=20", ""),
        ("GET", "/v2/events?after=0&limit=20", ""),
        ("POST", "/v2/push", push),
        ("GET", "/v2/voice/turn", ""),
        (
            "POST",
            "/v2/messages",
            r#"{"id":"11111111-1111-4111-8111-111111111111","recipient":"00","ciphertext":"AQ=="}"#,
        ),
    ] {
        assert_eq!(
            session_call(&s, &old, &session, method, path, body).await,
            401,
            "{method} {path} after replacement"
        );
    }
    // A proof for a session obtained BEFORE replacement but redeemed after it must fail:
    // the session is inserted only after the binding is rechecked under the lock.
    let body = "{}";
    let (status, ch) = post(
        &s,
        "/v2/auth/challenge",
        &json!({"account": new.credential.account, "device": new.credential.device,
            "credential": new.credential.fingerprint(), "purpose": "session", "method": "POST",
            "path": "/v2/session", "body": paranoid_key_protocol::digest(body.as_bytes())}),
    )
    .await;
    assert_eq!(status, 200);
    let pending: paranoid_key_protocol::ChallengeV2 = serde_json::from_value(ch).unwrap();
    let newer = device();
    let mut tx = s.db.begin().await.unwrap();
    sqlx::query("UPDATE id_memberships SET last_replace=NULL")
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    call(&s, &alice, &newer, Purpose::Replace, "2", &op()).await;
    let sig = Ed25519SecretKey::from_base64(&new.auth_secret)
        .unwrap()
        .sign(&pending.bytes())
        .to_base64();
    let late = s
        .http
        .post(format!("{}/v2/session", s.url))
        .header("authorization", format!("ParanoidV2 {}.{sig}", pending.id))
        .body(body)
        .send()
        .await
        .unwrap();
    // Existing v2 contract: a revoked binding is a 409 conflict. No session is issued.
    assert_eq!(
        late.status().as_u16(),
        409,
        "stale proof redeemed after replacement"
    );
    let late: Value = late.json().await.unwrap();
    assert_eq!(late["error"], "binding_conflict");
    assert!(late.get("id").is_none());
    // The old device cannot open a new session either.
    let (status, _) = post(
        &s,
        "/v2/auth/challenge",
        &json!({"account": old.credential.account, "device": old.credential.device,
            "credential": old.credential.fingerprint(), "purpose": "session", "method": "POST",
            "path": "/v2/session", "body": paranoid_key_protocol::digest(b"{}")}),
    )
    .await;
    assert_eq!(status, 401);
    let fresh = open_session(&s, &newer).await;
    assert_eq!(
        session_call(
            &s,
            &newer,
            &fresh,
            "GET",
            "/v2/messages?after=0&limit=20",
            ""
        )
        .await,
        200
    );
}

#[tokio::test]
async fn ban_trigger_cannot_be_bypassed_by_application_sql() {
    let s = server().await;
    let alice = user("alice_trig");
    s.registry.register(&alice);
    let (d1, d2) = (device(), device());
    call(&s, &alice, &d1, Purpose::Enroll, "0", &op()).await;
    // Pre-create a second active transport account to try swapping in during a ban.
    let spare = device();
    sqlx::query("INSERT INTO ss_accounts VALUES($1,$2,'active')")
        .bind(&spare.credential.account)
        .bind(&spare.credential.root)
        .execute(&s.db)
        .await
        .unwrap();
    sqlx::query("UPDATE id_memberships SET state='banned', account=$1")
        .bind(&spare.credential.account)
        .execute(&s.db)
        .await
        .unwrap();
    let modes: Vec<String> =
        sqlx::query_scalar("SELECT mode FROM ss_accounts WHERE account IN ($1,$2)")
            .bind(&d1.credential.account)
            .bind(&spare.credential.account)
            .fetch_all(&s.db)
            .await
            .unwrap();
    assert_eq!(
        modes,
        ["revoked", "revoked"],
        "both old and new account revoked"
    );
    for sql in [
        "UPDATE id_memberships SET state='active'",
        "UPDATE id_memberships SET account=(SELECT account FROM ss_accounts LIMIT 1)",
    ] {
        assert!(sqlx::query(sql).execute(&s.db).await.is_err(), "{sql}");
    }
    assert!(
        sqlx::query("UPDATE ss_accounts SET mode='active' WHERE account=$1")
            .bind(&d1.credential.account)
            .execute(&s.db)
            .await
            .is_err(),
        "no reactivation of a revoked transport account"
    );
    assert!(
        sqlx::query(
            "INSERT INTO id_memberships(membership,identity,owner,name,state,generation,account,operation,intent,result,last_replace,proof) VALUES('m','i','o','n','banned',1,$1,'op','x','{}',NULL,'{}')"
        )
        .bind(&d2.credential.account)
        .execute(&s.db)
        .await
        .is_err(),
        "memberships start active"
    );
}

#[tokio::test]
async fn challenge_accepts_bodies_up_to_16_kib() {
    let s = server().await;
    let r = serde_json::to_string(&request(
        &user("pad_user"),
        &device(),
        Purpose::Enroll,
        "0",
        &op(),
    ))
    .unwrap();
    let padded = |size: usize| format!("{r}{}", " ".repeat(size - r.len()));
    for (size, expected) in [(12_000, 200), (16_384, 200), (16_385, 413)] {
        tokio::time::sleep(std::time::Duration::from_millis(140)).await;
        let status = s
            .http
            .post(format!("{}/v3/identity/challenge", s.url))
            .header("content-type", "application/json")
            .body(padded(size))
            .send()
            .await
            .unwrap()
            .status()
            .as_u16();
        assert_eq!(status, expected, "{size} bytes");
    }
}

#[tokio::test]
async fn initialization_ignores_a_hostile_search_path() {
    let (db, url) = database().await;
    sqlx::query("CREATE SCHEMA shadow")
        .execute(&db)
        .await
        .unwrap();
    let name = url
        .split('/')
        .nth(3)
        .unwrap()
        .split('?')
        .next()
        .unwrap()
        .to_owned();
    sqlx::QueryBuilder::<sqlx::Postgres>::new(format!(
        "ALTER DATABASE {name} SET search_path = shadow"
    ))
    .build()
    .execute(&db)
    .await
    .unwrap();
    db.close().await;
    let db = PgPoolOptions::new()
        .max_connections(2)
        .connect(&url)
        .await
        .unwrap();
    paranoid_server::identity_v3::initialize(&db, REALM, &"a".repeat(64))
        .await
        .unwrap();
    let placed: bool = sqlx::query_scalar("SELECT to_regclass('public.id_meta') IS NOT NULL AND to_regclass('shadow.id_meta') IS NULL")
        .fetch_one(&db)
        .await
        .unwrap();
    assert!(placed, "schema must be created in public");
}

#[tokio::test]
async fn initialization_requires_empty_database_and_v2_runtime_refuses_v3() {
    let (db, _) = database().await;
    paranoid_server::identity_v3::initialize(&db, REALM, &"a".repeat(64))
        .await
        .unwrap();
    assert!(
        paranoid_server::identity_v3::initialize(&db, REALM, &"a".repeat(64))
            .await
            .is_err(),
        "never reinitialize a populated database"
    );
    assert!(
        paranoid_server::self_service::app(db.clone())
            .await
            .is_err(),
        "a v2 runtime must refuse a v3 database"
    );
    let (legacy, url) = database().await;
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
        .arg("self-service-init")
        .env_remove("PARANOID_MODE")
        .env("PARANOID_DATABASE_URL", &url)
        .env("PARANOID_KEY_REALM", REALM)
        .env("PARANOID_KEY_PIN", "a".repeat(64))
        .output()
        .unwrap();
    assert!(out.status.success());
    assert!(
        paranoid_server::identity_v3::initialize(&legacy, REALM, &"a".repeat(64))
            .await
            .is_err(),
        "never convert an existing v2 database"
    );
    let registry = Arc::new(FakeRegistry::default());
    assert!(
        paranoid_server::identity_v3::app(legacy.clone(), None, None, registry)
            .await
            .is_err(),
        "a v3 runtime must refuse a v2 database"
    );
}

#[tokio::test]
async fn legacy_registration_and_unknown_routes_are_absent() {
    let s = server().await;
    for path in [
        "/v2/registration/challenge",
        "/v2/registration/commit",
        "/v1/enrollment/challenge",
        "/v1/auth/challenge",
        "/v0/messages",
        "/v3/identity/lookup",
    ] {
        let (status, _) = post(&s, path, &json!({})).await;
        assert_eq!(status, 404, "{path} must not be routed");
    }
    let health: Value = s
        .http
        .get(format!("{}/health", s.url))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(health["protocol"], "paranoid-identity-v3");
    assert!(health.as_object().unwrap().len() <= 3);
}

#[tokio::test]
async fn enroll_then_existing_transport_works_without_separate_registration() {
    let s = server().await;
    let (alice, bob) = (user("alice_one"), user("bob_one"));
    s.registry.register(&alice);
    s.registry.register(&bob);
    let (da, db_) = (device(), device());
    assert_eq!(v2_status(&s, &da).await, 401, "no account before login");
    let (status, a) = call(&s, &alice, &da, Purpose::Enroll, "0", &op()).await;
    assert_eq!(status, 200, "{a}");
    assert_eq!(a["mode"], "active");
    assert_eq!(a["generation"], "1");
    assert_eq!(a["account"], da.credential.account);
    assert_eq!(a["credential_fingerprint"], da.credential.fingerprint());
    let keys: Vec<&str> = a.as_object().unwrap().keys().map(String::as_str).collect();
    let mut sorted = keys.clone();
    sorted.sort();
    assert_eq!(
        sorted,
        [
            "account",
            "credential_fingerprint",
            "device",
            "generation",
            "membership",
            "mode",
            "operation"
        ]
    );
    assert_eq!(
        call(&s, &bob, &db_, Purpose::Enroll, "0", &op()).await.0,
        200
    );
    assert_eq!(v2_status(&s, &da).await, 200);
    let (status, sent) = send_message(&s, &da, &db_.credential.account).await;
    assert_eq!(status, 200, "{sent}");
}

#[tokio::test]
async fn challenge_is_membership_independent_and_performs_no_rpc() {
    let s = server().await;
    let alice = user("alice_two");
    s.registry.register(&alice);
    let da = device();
    call(&s, &alice, &da, Purpose::Enroll, "0", &op()).await;
    let calls = s.registry.calls.load(Ordering::SeqCst);
    let stranger = user("stranger_x");
    let shape = |v: &Value| {
        let mut k: Vec<String> = v.as_object().unwrap().keys().cloned().collect();
        k.sort();
        k
    };
    let (s1, known) = challenge(
        &s,
        &request(&alice, &device(), Purpose::Replace, "1", &op()),
    )
    .await;
    let (s2, unknown) = challenge(
        &s,
        &request(&stranger, &device(), Purpose::Replace, "1", &op()),
    )
    .await;
    let (s3, stale) = challenge(
        &s,
        &request(&alice, &device(), Purpose::Replace, "5", &op()),
    )
    .await;
    assert_eq!((s1, s2, s3), (200, 200, 200));
    assert_eq!(shape(&known), shape(&unknown));
    assert_eq!(shape(&known), shape(&stale));
    assert_eq!(known.as_object().unwrap().len(), 17);
    assert_eq!(
        s.registry.calls.load(Ordering::SeqCst),
        calls,
        "no RPC before proof"
    );
    // Invalid syntax and a wrong-server credential are rejected before issuance.
    let mut wrong = request(&stranger, &device(), Purpose::Enroll, "0", &op());
    wrong.credential_object.pin = "b".repeat(64);
    assert_eq!(challenge(&s, &wrong).await.0, 400);
    let mut extra =
        serde_json::to_value(request(&stranger, &device(), Purpose::Enroll, "0", &op())).unwrap();
    extra["surprise"] = json!(1);
    assert_eq!(post(&s, "/v3/identity/challenge", &extra).await.0, 400);
}

#[tokio::test]
async fn proofs_are_route_bound_single_use_and_invalid_proof_does_not_consume() {
    let s = server().await;
    let alice = user("alice_three");
    s.registry.register(&alice);
    let da = device();
    let (_, ch) = challenge(&s, &request(&alice, &da, Purpose::Enroll, "0", &op())).await;
    let good = proofs(&alice, &da, &ch);
    let mut bad = good.clone();
    bad["owner_signature"] = good["device_signature"].clone();
    assert_eq!(post(&s, "/v3/identity/commit", &bad).await.0, 401);
    assert_eq!(
        post(&s, "/v3/identity/inspect", &good).await.0,
        401,
        "route/purpose bound"
    );
    let mut stripped = good.clone();
    stripped.as_object_mut().unwrap().remove("owner_signature");
    assert_eq!(post(&s, "/v3/identity/commit", &stripped).await.0, 401);
    assert_eq!(
        post(&s, "/v3/identity/commit", &good).await.0,
        200,
        "legitimate proof survived"
    );
    assert_eq!(
        post(&s, "/v3/identity/commit", &good).await.0,
        401,
        "replay"
    );
}

#[tokio::test]
async fn inspect_reveals_only_the_proven_identity() {
    let s = server().await;
    let alice = user("alice_four");
    s.registry.register(&alice);
    let (status, v) = call(&s, &alice, &device(), Purpose::Inspect, "0", &op()).await;
    assert_eq!(
        (status, v.clone()),
        (200, json!({"mode": "absent", "generation": "0"}))
    );
    call(&s, &alice, &device(), Purpose::Enroll, "0", &op()).await;
    let (_, v) = call(&s, &alice, &device(), Purpose::Inspect, "0", &op()).await;
    assert_eq!(v, json!({"mode": "active", "generation": "1"}));
    // An attacker controlling their own owner key but claiming alice's NAME learns nothing.
    let mallory = user("alice_four");
    let (status, v) = call(&s, &mallory, &device(), Purpose::Inspect, "0", &op()).await;
    let random = user("nobody_here");
    let (status2, v2) = call(&s, &random, &device(), Purpose::Inspect, "0", &op()).await;
    assert_eq!((status, v), (status2, v2));
}

#[tokio::test]
async fn replacement_retires_old_device_everywhere_and_status_reports_it() {
    let s = server().await;
    let (alice, bob) = (user("alice_five"), user("bob_five"));
    s.registry.register(&alice);
    s.registry.register(&bob);
    let (old, new, peer) = (device(), device(), device());
    let first = op();
    call(&s, &alice, &old, Purpose::Enroll, "0", &first).await;
    call(&s, &bob, &peer, Purpose::Enroll, "0", &op()).await;
    sqlx::query("CREATE TABLE IF NOT EXISTS ss_push_tokens(account TEXT PRIMARY KEY REFERENCES ss_accounts(account),device TEXT NOT NULL REFERENCES ss_devices(device),platform TEXT NOT NULL CHECK(platform='fcm'),token TEXT NOT NULL CHECK(octet_length(token) BETWEEN 1 AND 4096),updated BIGINT NOT NULL CHECK(updated>0))")
        .execute(&s.db).await.unwrap();
    sqlx::query("INSERT INTO ss_push_tokens VALUES($1,$2,'fcm','token',1)")
        .bind(&old.credential.account)
        .bind(&old.credential.device)
        .execute(&s.db)
        .await
        .unwrap();
    let second = op();
    let (status, r) = call(&s, &alice, &new, Purpose::Replace, "1", &second).await;
    assert_eq!(status, 200, "{r}");
    assert_eq!(r["generation"], "2");
    assert_eq!(
        v2_status(&s, &old).await,
        401,
        "old device lost transport access"
    );
    assert_eq!(v2_status(&s, &new).await, 200);
    let tokens: i64 = sqlx::query_scalar("SELECT count(*) FROM ss_push_tokens")
        .fetch_one(&s.db)
        .await
        .unwrap();
    assert_eq!(tokens, 0, "push token of retired device deleted");
    let (_, st) = call(&s, &alice, &old, Purpose::Status, "0", &op()).await;
    assert_eq!(
        st,
        json!({"mode": "revoked", "generation": "1", "operation": first})
    );
    let (_, st) = call(&s, &alice, &new, Purpose::Status, "0", &op()).await;
    assert_eq!(
        st,
        json!({"mode": "active", "generation": "2", "operation": second})
    );
    let (_, st) = call(&s, &alice, &device(), Purpose::Status, "0", &op()).await;
    assert_eq!(
        st,
        json!({"mode": "absent", "generation": "0", "operation": ""})
    );
    // Retired recipients are rejected explicitly, not falsely accepted.
    let (status, e) = send_message(&s, &peer, &old.credential.account).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (409, Some("recipient_retired"))
    );
    assert_eq!(
        send_message(&s, &peer, &new.credential.account).await.0,
        200
    );
}

#[tokio::test]
async fn lost_reply_retry_is_exact_and_retired_retry_is_revoked() {
    let s = server().await;
    let alice = user("alice_six");
    s.registry.register(&alice);
    let (d1, d2) = (device(), device());
    let first = op();
    let (_, original) = call(&s, &alice, &d1, Purpose::Enroll, "0", &first).await;
    let calls = s.registry.calls.load(Ordering::SeqCst);
    let (status, again) = call(&s, &alice, &d1, Purpose::Enroll, "0", &first).await;
    assert_eq!((status, &again), (200, &original));
    assert_eq!(
        s.registry.calls.load(Ordering::SeqCst),
        calls,
        "exact retry needs no RPC"
    );
    // Same operation, different intent.
    let (status, e) = call(&s, &alice, &d2, Purpose::Enroll, "0", &first).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (409, Some("operation_conflict"))
    );
    let second = op();
    let (_, replaced) = call(&s, &alice, &d2, Purpose::Replace, "1", &second).await;
    let (status, again) = call(&s, &alice, &d2, Purpose::Replace, "1", &second).await;
    assert_eq!(
        (status, &again),
        (200, &replaced),
        "retry after generation advanced"
    );
    let (status, e) = call(&s, &alice, &d1, Purpose::Enroll, "0", &first).await;
    assert_eq!((status, e["error"].as_str()), (409, Some("device_revoked")));
}

#[tokio::test]
async fn stale_generation_and_duplicate_enrollment_conflict() {
    let s = server().await;
    let alice = user("alice_seven");
    s.registry.register(&alice);
    call(&s, &alice, &device(), Purpose::Enroll, "0", &op()).await;
    let (status, e) = call(&s, &alice, &device(), Purpose::Enroll, "0", &op()).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (409, Some("generation_conflict"))
    );
    let (status, e) = call(&s, &alice, &device(), Purpose::Replace, "2", &op()).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (409, Some("generation_conflict"))
    );
    let ghost = user("ghost_one");
    s.registry.register(&ghost);
    let (status, e) = call(&s, &ghost, &device(), Purpose::Replace, "1", &op()).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (409, Some("generation_conflict"))
    );
}

#[tokio::test]
async fn retired_or_foreign_transport_keys_cannot_be_rebound() {
    let s = server().await;
    let (alice, eve) = (user("alice_eight"), user("eve_eight"));
    s.registry.register(&alice);
    s.registry.register(&eve);
    let (old, new) = (device(), device());
    call(&s, &alice, &old, Purpose::Enroll, "0", &op()).await;
    call(&s, &alice, &new, Purpose::Replace, "1", &op()).await;
    // Retired device credential re-enrolled under a second identity.
    let (status, e) = call(&s, &eve, &old, Purpose::Enroll, "0", &op()).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (403, Some("identity_invalid"))
    );
    // A live foreign binding is equally indistinguishable.
    let (status, e) = call(&s, &eve, &new, Purpose::Enroll, "0", &op()).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (403, Some("identity_invalid"))
    );
    let memberships: i64 = sqlx::query_scalar("SELECT count(*) FROM id_memberships")
        .fetch_one(&s.db)
        .await
        .unwrap();
    assert_eq!(memberships, 1);
    assert_eq!(v2_status(&s, &old).await, 401);
}

#[tokio::test]
async fn registry_failures_fail_closed_and_consume_the_challenge() {
    let s = server().await;
    let alice = user("alice_nine");
    let da = device();
    let (status, e) = call(&s, &alice, &da, Purpose::Enroll, "0", &op()).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (403, Some("identity_invalid")),
        "unregistered"
    );
    s.registry.register(&alice);
    *s.registry.outage.lock().unwrap() = true;
    let o = op();
    let (_, ch) = challenge(&s, &request(&alice, &da, Purpose::Enroll, "0", &o)).await;
    let p = proofs(&alice, &da, &ch);
    let (status, e) = post(&s, "/v3/identity/commit", &p).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (503, Some("registry_unavailable"))
    );
    assert_eq!(post(&s, "/v3/identity/commit", &p).await.0, 401, "consumed");
    *s.registry.outage.lock().unwrap() = false;
    assert_eq!(
        call(&s, &alice, &da, Purpose::Enroll, "0", &o).await.0,
        200,
        "same intent retries"
    );
}

#[tokio::test]
async fn verification_start_budget_is_global_and_counts_failures() {
    let s = server().await;
    for i in 0..8 {
        let u = user(&format!("unreg_{i}"));
        let (status, _) = call(&s, &u, &device(), Purpose::Enroll, "0", &op()).await;
        assert_eq!(status, 403);
    }
    let alice = user("alice_ten");
    s.registry.register(&alice);
    let calls = s.registry.calls.load(Ordering::SeqCst);
    let (status, e) = call(&s, &alice, &device(), Purpose::Enroll, "0", &op()).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (429, Some("verification_budget"))
    );
    assert_eq!(
        s.registry.calls.load(Ordering::SeqCst),
        calls,
        "no RPC after budget"
    );
}

#[tokio::test]
async fn replacement_cooldown_and_banned_membership() {
    let s = server().await;
    let alice = user("alice_eleven");
    s.registry.register(&alice);
    let (d1, d2, d3) = (device(), device(), device());
    call(&s, &alice, &d1, Purpose::Enroll, "0", &op()).await;
    call(&s, &alice, &d2, Purpose::Replace, "1", &op()).await;
    let (status, e) = call(&s, &alice, &d3, Purpose::Replace, "2", &op()).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (409, Some("replacement_limit")),
        "24h cooldown"
    );
    // Fixture-only ban (no operator API): ONLY the membership state changes. The
    // database itself must revoke the current transport account (RFC-0027 review B5).
    let mut tx = s.db.begin().await.unwrap();
    sqlx::query("SELECT id FROM ss_meta WHERE id=1 FOR UPDATE")
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("UPDATE id_memberships SET state='banned'")
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert_eq!(v2_status(&s, &d2).await, 401);
    let (_, st) = call(&s, &alice, &d2, Purpose::Status, "0", &op()).await;
    assert_eq!(st["mode"], "banned");
    let (_, v) = call(&s, &alice, &device(), Purpose::Inspect, "0", &op()).await;
    assert_eq!(v["mode"], "banned");
    let (status, e) = call(&s, &alice, &d3, Purpose::Replace, "2", &op()).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (403, Some("membership_banned"))
    );
    // A banned member is NOT "retired": senders get the generic recipient error.
    let bob = user("bob_eleven");
    s.registry.register(&bob);
    let peer = device();
    call(&s, &bob, &peer, Purpose::Enroll, "0", &op()).await;
    let (status, e) = send_message(&s, &peer, &d2.credential.account).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (400, Some("invalid_envelope"))
    );
    // The genuinely retired generation-1 device is still reported as retired.
    let (status, e) = send_message(&s, &peer, &d1.credential.account).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (409, Some("recipient_retired"))
    );
}

#[tokio::test]
async fn generation_cap_blocks_ninth_generation_but_keeps_traffic() {
    let s = server().await;
    let alice = user("alice_twelve");
    s.registry.register(&alice);
    let current = device();
    call(&s, &alice, &device(), Purpose::Enroll, "0", &op()).await;
    // Fixture: skip seven real 24h cooldowns by aging the membership to generation 8.
    let mut tx = s.db.begin().await.unwrap();
    sqlx::query("SELECT id FROM ss_meta WHERE id=1 FOR UPDATE")
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("UPDATE id_memberships SET last_replace=NULL")
        .execute(&mut *tx)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let mut generation = 1;
    let mut last = current;
    while generation < 8 {
        let d = device();
        let (status, r) = call(
            &s,
            &alice,
            &d,
            Purpose::Replace,
            &generation.to_string(),
            &op(),
        )
        .await;
        assert_eq!(status, 200, "{r}");
        sqlx::query("UPDATE id_memberships SET last_replace=NULL")
            .execute(&s.db)
            .await
            .unwrap();
        generation += 1;
        last = d;
        if generation % 4 == 0 {
            sqlx::query(
                "UPDATE id_meta SET success_window=0, successes=0, start_window=0, starts=0",
            )
            .execute(&s.db)
            .await
            .unwrap();
        }
    }
    let (status, e) = call(&s, &alice, &device(), Purpose::Replace, "8", &op()).await;
    assert_eq!(
        (status, e["error"].as_str()),
        (409, Some("replacement_limit"))
    );
    assert_eq!(
        v2_status(&s, &last).await,
        200,
        "current generation keeps working"
    );
}

// ---------------------------------------------------------------------------------------
// RFC-0028 server member directory.

/// Device whose credential commits to a known (curve, one-time key) pair, so a test can
/// publish a matching contact card. The server checks binding and signature only.
fn card_device() -> (Identity, String) {
    let prekey = uuid::Uuid::new_v4().to_string();
    let d = Identity::create(REALM, &"a".repeat(64), "curve", &prekey).unwrap();
    (d, prekey)
}

fn card(d: &Identity, prekey: &str) -> Value {
    let c = &d.credential;
    let bytes = paranoid_key_protocol::transcript(&[
        "paranoid-contact-v2",
        &c.fingerprint(),
        "unassigned",
        REALM,
        "curve",
        prekey,
        "fallback",
    ]);
    let signature = Ed25519SecretKey::from_base64(&d.auth_secret)
        .unwrap()
        .sign(&bytes)
        .to_base64();
    json!({"type":"paranoid-contact-v2","credential":c,
        "bundle":{"device":"unassigned","realm":REALM,"curve":"curve","one_time_key":prekey},
        "fallback_key":"fallback","signature":signature})
}

async fn session_json(
    s: &Server,
    d: &Identity,
    session: &paranoid_key_protocol::SessionV2,
    path: &str,
    body: &Value,
) -> (u16, Value) {
    let body = body.to_string();
    let nonce = uuid::Uuid::new_v4().to_string();
    let bytes = session.bytes(
        &nonce,
        "POST",
        path,
        &paranoid_key_protocol::digest(body.as_bytes()),
    );
    let sig = Ed25519SecretKey::from_base64(&d.auth_secret)
        .unwrap()
        .sign(&bytes)
        .to_base64();
    tokio::time::sleep(std::time::Duration::from_millis(60)).await;
    let r = s
        .http
        .post(format!("{}{path}", s.url))
        .header(
            "authorization",
            format!("ParanoidSessionV2 {}.{nonce}.{sig}", session.id),
        )
        .body(body)
        .send()
        .await
        .unwrap();
    let status = r.status().as_u16();
    (status, r.json().await.unwrap_or(Value::Null))
}

async fn search(
    s: &Server,
    d: &Identity,
    session: &paranoid_key_protocol::SessionV2,
    query: &str,
    after: Option<&str>,
) -> (u16, Value) {
    session_json(
        s,
        d,
        session,
        "/v3/directory/search",
        &json!({"query": query, "after": after}),
    )
    .await
}

fn names(v: &Value) -> Vec<String> {
    v["members"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["name"].as_str().unwrap().to_owned())
        .collect()
}

/// A logged-in member with a published card and an open session.
struct Member {
    user: User,
    device: Identity,
    session: paranoid_key_protocol::SessionV2,
}

async fn member(s: &Server, name: &str) -> Member {
    let user = user(name);
    s.registry.register(&user);
    let (device, prekey) = card_device();
    let (status, v) = call(s, &user, &device, Purpose::Enroll, "0", &op()).await;
    assert_eq!(status, 200, "{v}");
    let session = open_session(s, &device).await;
    let (status, v) = session_json(
        s,
        &device,
        &session,
        "/v3/directory/card",
        &card(&device, &prekey),
    )
    .await;
    assert_eq!(status, 200, "{v}");
    Member {
        user,
        device,
        session,
    }
}

/// Synthetic active member rows for paging (no RPC or enrollment budget needed).
async fn synthetic_member(s: &Server, name: &str) {
    let id = uuid::Uuid::new_v4().simple().to_string();
    sqlx::query("INSERT INTO ss_accounts VALUES($1,$2,'active')")
        .bind(&id)
        .bind(format!("root{id}"))
        .execute(&s.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO id_memberships(membership,identity,owner,name,state,generation,account,operation,intent,result,proof,card) VALUES($1,$2,$3,$4,'active',1,$1,$5,'i','{}','{}','{}')")
        .bind(&id).bind(format!("id{id}")).bind(format!("ow{id}")).bind(name).bind(format!("op{id}"))
        .execute(&s.db).await.unwrap();
    sqlx::query("INSERT INTO id_bindings VALUES($1,$1,1,$2,$3,$4,$5,$6,$7,false)")
        .bind(&id)
        .bind(format!("op{id}"))
        .bind(format!("root{id}"))
        .bind(format!("dev{id}"))
        .bind(format!("auth{id}"))
        .bind(format!("fp{id}"))
        .bind(format!("olm{id}"))
        .execute(&s.db)
        .await
        .unwrap();
}

#[tokio::test]
async fn directory_refuses_unauthenticated_and_non_member_callers() {
    let s = server().await;
    let alice = member(&s, "alice_dir").await;
    for path in [
        "/v3/directory/search",
        "/v3/directory/visibility",
        "/v3/directory/card",
    ] {
        let (status, _) = post(&s, path, &json!({"query":"","after":null})).await;
        assert_eq!(status, 401, "{path} without a session");
        let r = s
            .http
            .post(format!("{}{path}", s.url))
            .header("authorization", "ParanoidSessionV2 x.y.z")
            .body("{}")
            .send()
            .await
            .unwrap();
        assert_eq!(r.status().as_u16(), 401, "{path} with a forged session");
    }
    // GET and query strings are not part of the signed allowlist.
    assert_eq!(
        session_call(
            &s,
            &alice.device,
            &alice.session,
            "GET",
            "/v3/directory/search",
            ""
        )
        .await,
        405
    );
    // Signature over a different body is refused.
    let (status, _) = search(&s, &alice.device, &alice.session, "", None).await;
    assert_eq!(status, 200);
    let bad = session_call(
        &s,
        &alice.device,
        &alice.session,
        "POST",
        "/v3/directory/search?x=1",
        r#"{"query":"","after":null}"#,
    )
    .await;
    assert_eq!(bad, 401);
    // Malformed requests are rejected strictly.
    for body in [
        json!({"query":"A","after":null}),
        json!({"query":"%","after":null}),
        json!({"query":"","after":"Bad"}),
        json!({"query":"","after":null,"extra":1}),
        json!({"query":"a".repeat(25),"after":null}),
    ] {
        let (status, _) = session_json(
            &s,
            &alice.device,
            &alice.session,
            "/v3/directory/search",
            &body,
        )
        .await;
        assert_eq!(status, 400, "{body}");
    }
}

#[tokio::test]
async fn directory_lists_prefix_pages_and_hides_hidden_retired_and_banned() {
    let s = server().await;
    let alice = member(&s, "alice_list").await;
    let bob = member(&s, "bob_list").await;
    let carol = member(&s, "carol_list").await;
    // A member without a published card is not listed.
    let dan = user("dan_nocard");
    s.registry.register(&dan);
    call(&s, &dan, &device(), Purpose::Enroll, "0", &op()).await;
    let (status, v) = search(&s, &alice.device, &alice.session, "", None).await;
    assert_eq!(status, 200, "{v}");
    assert_eq!(
        names(&v),
        ["bob_list", "carol_list"],
        "caller itself is not listed"
    );
    assert_eq!(v["next"], Value::Null);
    assert_eq!(v["me"], json!({"visible": true, "card": true}));
    let entry = &v["members"][0];
    assert_eq!(
        entry["owner"],
        base58_encode(bob.user.owner.public_key().as_bytes())
    );
    assert_eq!(entry["contact"]["credential"], json!(bob.device.credential));
    let (_, v) = search(&s, &alice.device, &alice.session, "car", None).await;
    assert_eq!(names(&v), ["carol_list"]);
    let (_, v) = search(&s, &alice.device, &alice.session, "zzz", None).await;
    assert_eq!(names(&v), Vec::<String>::new());
    // Hidden: absent for others, still able to search itself.
    let (status, v) = session_json(
        &s,
        &carol.device,
        &carol.session,
        "/v3/directory/visibility",
        &json!({"visible": false}),
    )
    .await;
    assert_eq!((status, v), (200, json!({"visible": false})));
    let (_, v) = search(&s, &alice.device, &alice.session, "", None).await;
    assert_eq!(names(&v), ["bob_list"]);
    let (status, v) = search(&s, &carol.device, &carol.session, "", None).await;
    assert_eq!(status, 200);
    assert_eq!(v["me"]["visible"], false);
    // Retired: bob replaces his phone; the old phone is refused, bob is absent until the new
    // phone publishes a card for the new credential.
    sqlx::query("UPDATE id_memberships SET last_replace=NULL")
        .execute(&s.db)
        .await
        .unwrap();
    let (new_bob, prekey) = card_device();
    assert_eq!(
        call(&s, &bob.user, &new_bob, Purpose::Replace, "1", &op())
            .await
            .0,
        200
    );
    assert_eq!(
        search(&s, &bob.device, &bob.session, "", None).await.0,
        401,
        "retired caller"
    );
    let (_, v) = search(&s, &alice.device, &alice.session, "", None).await;
    assert_eq!(
        names(&v),
        Vec::<String>::new(),
        "replacement drops the old card"
    );
    let new_session = open_session(&s, &new_bob).await;
    // The old credential's card cannot be published for the new generation.
    let stale = card(&bob.device, "whatever");
    assert_eq!(
        session_json(&s, &new_bob, &new_session, "/v3/directory/card", &stale)
            .await
            .0,
        409
    );
    assert_eq!(
        session_json(
            &s,
            &new_bob,
            &new_session,
            "/v3/directory/card",
            &card(&new_bob, &prekey)
        )
        .await
        .0,
        200
    );
    let (_, v) = search(&s, &alice.device, &alice.session, "", None).await;
    assert_eq!(names(&v), ["bob_list"]);
    assert_eq!(
        v["members"][0]["contact"]["credential"],
        json!(new_bob.credential)
    );
    // Banned: absent and refused.
    sqlx::query("UPDATE id_memberships SET state='banned' WHERE name='bob_list'")
        .execute(&s.db)
        .await
        .unwrap();
    let (_, v) = search(&s, &alice.device, &alice.session, "", None).await;
    assert_eq!(names(&v), Vec::<String>::new());
    assert_eq!(
        search(&s, &new_bob, &new_session, "", None).await.0,
        401,
        "banned caller"
    );
    // Paging: 55 synthetic visible members -> 50 + 5, ordered by name, `next` cursor.
    for n in 0..55 {
        synthetic_member(&s, &format!("page_{n:02}")).await;
    }
    let (_, first) = search(&s, &alice.device, &alice.session, "page_", None).await;
    let first_names = names(&first);
    assert_eq!(first_names.len(), 50);
    assert_eq!(first_names[0], "page_00");
    assert_eq!(first["next"], "page_49");
    let (_, second) = search(&s, &alice.device, &alice.session, "page_", Some("page_49")).await;
    assert_eq!(
        names(&second),
        ["page_50", "page_51", "page_52", "page_53", "page_54"]
    );
    assert_eq!(second["next"], Value::Null);
}

#[tokio::test]
async fn directory_rate_limits_member_and_server_windows() {
    let s = server().await;
    let alice = member(&s, "alice_rate").await;
    let bob = member(&s, "bob_rate").await;
    // `member` published one card (1 request). 59 more succeed, the 61st is refused.
    for n in 0..59 {
        let (status, v) = search(&s, &alice.device, &alice.session, "", None).await;
        assert_eq!(status, 200, "request {n}: {v}");
    }
    let (status, v) = search(&s, &alice.device, &alice.session, "", None).await;
    assert_eq!((status, v["error"].clone()), (429, json!("directory_rate")));
    // Other members are unaffected by alice's window.
    assert_eq!(search(&s, &bob.device, &bob.session, "", None).await.0, 200);
    // Server window: exhaust it directly and every member is refused without charge.
    sqlx::query("UPDATE id_meta SET directory_count=600, directory_window=floor(extract(epoch FROM clock_timestamp()))::bigint")
        .execute(&s.db).await.unwrap();
    let before: i64 =
        sqlx::query_scalar("SELECT directory_count FROM id_memberships WHERE name='bob_rate'")
            .fetch_one(&s.db)
            .await
            .unwrap();
    let (status, v) = search(&s, &bob.device, &bob.session, "", None).await;
    assert_eq!((status, v["error"].clone()), (429, json!("directory_rate")));
    let after: i64 =
        sqlx::query_scalar("SELECT directory_count FROM id_memberships WHERE name='bob_rate'")
            .fetch_one(&s.db)
            .await
            .unwrap();
    assert_eq!(before, after, "refused request consumes nothing");
    // Directory requests never use the tight login ingress bucket (8/s): a concurrent burst
    // of 12 signed searches within one second all succeed (global budget is 20/s).
    sqlx::query("UPDATE id_meta SET directory_count=0")
        .execute(&s.db)
        .await
        .unwrap();
    let carol = member(&s, "carol_rate").await;
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    let burst = (0..12).map(|_| {
        let body = json!({"query":"","after":null}).to_string();
        let nonce = uuid::Uuid::new_v4().to_string();
        let bytes = carol.session.bytes(
            &nonce,
            "POST",
            "/v3/directory/search",
            &paranoid_key_protocol::digest(body.as_bytes()),
        );
        let sig = Ed25519SecretKey::from_base64(&carol.device.auth_secret)
            .unwrap()
            .sign(&bytes)
            .to_base64();
        s.http
            .post(format!("{}/v3/directory/search", s.url))
            .header(
                "authorization",
                format!("ParanoidSessionV2 {}.{nonce}.{sig}", carol.session.id),
            )
            .body(body)
            .send()
    });
    let started = std::time::Instant::now();
    let statuses: Vec<u16> = futures_join(burst).await;
    assert!(
        started.elapsed() < std::time::Duration::from_secs(1),
        "burst must fit one ingress window"
    );
    assert_eq!(statuses, vec![200; 12]);
}

async fn futures_join<F>(requests: impl Iterator<Item = F>) -> Vec<u16>
where
    F: std::future::Future<Output = reqwest::Result<reqwest::Response>> + Send + 'static,
{
    let tasks: Vec<_> = requests.map(tokio::spawn).collect();
    let mut out = Vec::new();
    for t in tasks {
        out.push(t.await.unwrap().unwrap().status().as_u16());
    }
    out
}

#[tokio::test]
async fn directory_owner_proof_is_stored_on_enroll_and_replace_and_verifies() {
    use paranoid_key_protocol::identity_v3::DirectoryProof;
    let s = server().await;
    let alice = member(&s, "alice_proof").await;
    let viewer = member(&s, "viewer_proof").await;
    let pin = "a".repeat(64);
    let owner = base58_encode(alice.user.owner.public_key().as_bytes());
    let identity = base58_encode(
        &derive_registry(alice.user.owner.public_key().as_bytes(), "alice_proof")
            .unwrap()
            .identity,
    );
    let (_, v) = search(&s, &viewer.device, &viewer.session, "alice", None).await;
    let entry = &v["members"][0];
    let proof: DirectoryProof = serde_json::from_value(entry["proof"].clone()).unwrap();
    assert_eq!(proof.challenge.purpose, Purpose::Enroll);
    assert_eq!(entry["owner"], owner);
    assert_eq!(entry["identity"], identity);
    proof
        .verify(
            REALM,
            &pin,
            "alice_proof",
            &owner,
            &identity,
            &alice.device.credential,
        )
        .unwrap();
    // Stored JSON equals the served proof.
    let stored: String =
        sqlx::query_scalar("SELECT proof FROM id_memberships WHERE name='alice_proof'")
            .fetch_one(&s.db)
            .await
            .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&stored).unwrap(),
        entry["proof"]
    );
    // Replace: the stored proof is replaced in the same commit and binds the new credential.
    sqlx::query("UPDATE id_memberships SET last_replace=NULL")
        .execute(&s.db)
        .await
        .unwrap();
    let (next, prekey) = card_device();
    assert_eq!(
        call(&s, &alice.user, &next, Purpose::Replace, "1", &op())
            .await
            .0,
        200
    );
    let stored: String =
        sqlx::query_scalar("SELECT proof FROM id_memberships WHERE name='alice_proof'")
            .fetch_one(&s.db)
            .await
            .unwrap();
    let replaced: DirectoryProof = serde_json::from_str(&stored).unwrap();
    assert_eq!(replaced.challenge.purpose, Purpose::Replace);
    replaced
        .verify(
            REALM,
            &pin,
            "alice_proof",
            &owner,
            &identity,
            &next.credential,
        )
        .unwrap();
    assert!(replaced
        .verify(
            REALM,
            &pin,
            "alice_proof",
            &owner,
            &identity,
            &alice.device.credential
        )
        .is_err());
    let session = open_session(&s, &next).await;
    assert_eq!(
        session_json(
            &s,
            &next,
            &session,
            "/v3/directory/card",
            &card(&next, &prekey)
        )
        .await
        .0,
        200
    );
    let (_, v) = search(&s, &viewer.device, &viewer.session, "alice", None).await;
    assert_eq!(
        v["members"][0]["proof"],
        serde_json::to_value(&replaced).unwrap()
    );
}

#[tokio::test]
async fn directory_card_must_match_the_active_credential() {
    let s = server().await;
    let alice = member(&s, "alice_card").await;
    let (other, other_prekey) = card_device();
    // Somebody else's (validly self-signed) card.
    let (status, v) = session_json(
        &s,
        &alice.device,
        &alice.session,
        "/v3/directory/card",
        &card(&other, &other_prekey),
    )
    .await;
    assert_eq!((status, v["error"].clone()), (409, json!("card_mismatch")));
    // Own credential but a substituted one-time key (Olm digest mismatch).
    let mut swapped = card(&alice.device, "substituted");
    swapped["bundle"]["one_time_key"] = json!("other");
    assert_eq!(
        session_json(
            &s,
            &alice.device,
            &alice.session,
            "/v3/directory/card",
            &swapped
        )
        .await
        .0,
        409
    );
    // Own binding but a forged signature.
    let stored: String =
        sqlx::query_scalar("SELECT card FROM id_memberships WHERE name='alice_card'")
            .fetch_one(&s.db)
            .await
            .unwrap();
    let mut forged: Value = serde_json::from_str(&stored).unwrap();
    forged["fallback_key"] = json!("changed");
    assert_eq!(
        session_json(
            &s,
            &alice.device,
            &alice.session,
            "/v3/directory/card",
            &forged
        )
        .await
        .0,
        400
    );
    let mut extra: Value = serde_json::from_str(&stored).unwrap();
    extra["extra"] = json!(1);
    assert_eq!(
        session_json(
            &s,
            &alice.device,
            &alice.session,
            "/v3/directory/card",
            &extra
        )
        .await
        .0,
        400
    );
    let after: String =
        sqlx::query_scalar("SELECT card FROM id_memberships WHERE name='alice_card'")
            .fetch_one(&s.db)
            .await
            .unwrap();
    assert_eq!(
        after, stored,
        "rejected cards never replace the published one"
    );
}
