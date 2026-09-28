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
    // Fixture-only ban (no operator API): state + revoked transport under ss_meta.
    let mut tx = s.db.begin().await.unwrap();
    sqlx::query("SELECT id FROM ss_meta WHERE id=1 FOR UPDATE")
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("UPDATE id_memberships SET state='banned'")
        .execute(&mut *tx)
        .await
        .unwrap();
    sqlx::query("UPDATE ss_accounts SET mode='revoked' WHERE account=$1")
        .bind(&d2.credential.account)
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
