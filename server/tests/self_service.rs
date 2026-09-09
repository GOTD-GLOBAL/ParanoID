use paranoid_key_protocol::Identity;
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, PgPool};
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
fn sign(i: &Identity, ch: &Value) -> String {
    let names = [
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
    ];
    let fields: Vec<String> = names
        .iter()
        .map(|n| {
            ch[n]
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| ch[n].to_string())
        })
        .collect();
    let mut parts = vec!["paranoid-proof-v2"];
    parts.extend(fields.iter().map(String::as_str));
    let sig = vodozemac::Ed25519SecretKey::from_base64(&i.auth_secret)
        .unwrap()
        .sign(&paranoid_key_protocol::transcript(&parts))
        .to_base64();
    format!("ParanoidV2 {}.{sig}", ch["id"].as_str().unwrap())
}
async fn challenge(
    http: &reqwest::Client,
    url: &str,
    i: &Identity,
    purpose: &str,
    method: &str,
    path: &str,
    body: &str,
) -> reqwest::Response {
    tokio::time::sleep(std::time::Duration::from_millis(550)).await;
    let mut request = json!({"credential":i.credential.fingerprint(),"account":i.credential.account,"device":i.credential.device,"purpose":purpose,"method":method,"path":path,"body":paranoid_key_protocol::digest(body.as_bytes())});
    let route = if purpose == "register" {
        request.as_object_mut().unwrap().remove("account");
        request.as_object_mut().unwrap().remove("device");
        request["credential"] = serde_json::to_value(&i.credential).unwrap();
        "registration"
    } else {
        "auth"
    };
    http.post(format!("{url}/v2/{route}/challenge"))
        .json(&request)
        .send()
        .await
        .unwrap()
}
async fn signed(
    http: &reqwest::Client,
    url: &str,
    i: &Identity,
    purpose: &str,
    method: &str,
    path: &str,
    body: &str,
) -> reqwest::Response {
    let response = challenge(http, url, i, purpose, method, path, body).await;
    assert_eq!(response.status(), 200, "challenge should succeed");
    let ch: Value = response.json().await.unwrap();
    http.request(method.parse().unwrap(), format!("{url}{path}"))
        .header("Authorization", sign(i, &ch))
        .body(body.to_owned())
        .send()
        .await
        .unwrap()
}
#[tokio::test]
async fn three_accounts_self_register_only_after_device_pop_and_retry_same_identity() {
    let (db, url) = database().await;
    assert!(initialize(&url).status.success());
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    for _ in 0..3 {
        let i = identity();
        let response = challenge(
            &http,
            &url,
            &i,
            "register",
            "POST",
            "/v2/registration/commit",
            "{}",
        )
        .await;
        assert_eq!(
            response.status(),
            200,
            "self-service challenge route must exist without operator grants"
        );
        let ch: Value = response.json().await.unwrap();
        let before: i64 = sqlx::query_scalar("SELECT count(*) FROM ss_accounts WHERE account=$1")
            .bind(&i.credential.account)
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(before, 0);
        let proof = sign(&i, &ch);
        let response = http
            .post(format!("{url}/v2/registration/commit"))
            .header("Authorization", &proof)
            .body("{}")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        let status: Value = response.json().await.unwrap();
        assert_eq!(
            status,
            json!({"mode":"active","account":i.credential.account,"device":i.credential.device,"credential":i.credential.fingerprint()})
        );
        assert_eq!(
            http.post(format!("{url}/v2/registration/commit"))
                .header("Authorization", &proof)
                .body("{}")
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
        assert_eq!(
            signed(
                &http,
                &url,
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
    }
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_accounts")
            .fetch_one(&db)
            .await
            .unwrap(),
        3
    );
    task.abort();
    db.close().await;
}
use std::process::Command;
#[tokio::test]
async fn auth_status_is_bound_to_known_device_and_restart_invalidates_proofs() {
    let (db, database_url) = database().await;
    assert!(initialize(&database_url).status.success());
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = identity();
    assert_eq!(
        challenge(&http, &url, &i, "status", "POST", "/v2/auth/verify", "{}")
            .await
            .status(),
        401
    );
    assert_eq!(
        signed(
            &http,
            &url,
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
    assert_eq!(
        signed(&http, &url, &i, "status", "POST", "/v2/auth/verify", "{}")
            .await
            .status(),
        200
    );
    let ch: Value = challenge(&http, &url, &i, "status", "POST", "/v2/auth/verify", "{}")
        .await
        .json()
        .await
        .unwrap();
    let mut other = identity();
    other.credential.account = i.credential.account.clone();
    assert_eq!(
        challenge(
            &http,
            &url,
            &other,
            "status",
            "POST",
            "/v2/auth/verify",
            "{}"
        )
        .await
        .status(),
        401
    );
    let proof = sign(&i, &ch);
    task.abort();
    let (url, task) = serve(&db).await;
    assert_eq!(
        http.post(format!("{url}/v2/auth/verify"))
            .header("Authorization", proof)
            .body("{}")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        signed(&http, &url, &i, "status", "POST", "/v2/auth/verify", "{}")
            .await
            .status(),
        200
    );
    task.abort();
    db.close().await;
}
#[tokio::test]
async fn registration_capacity_rejects_new_accounts_but_allows_fresh_identical_retry() {
    let (db, u) = database().await;
    assert!(initialize(&u).status.success());
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = identity();
    assert_eq!(
        signed(
            &http,
            &url,
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
    sqlx::query("INSERT INTO ss_accounts SELECT 'fixture-'||n,'root-'||n,'active' FROM generate_series(1,1023) n").execute(&db).await.unwrap();
    assert_eq!(
        signed(
            &http,
            &url,
            &identity(),
            "register",
            "POST",
            "/v2/registration/commit",
            "{}"
        )
        .await
        .status(),
        429
    );
    assert_eq!(
        signed(
            &http,
            &url,
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
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_accounts")
            .fetch_one(&db)
            .await
            .unwrap(),
        1024
    );
    task.abort();
    db.close().await;
}
#[tokio::test]
async fn new_account_rate_is_durable_across_router_restart() {
    let (db, u) = database().await;
    assert!(initialize(&u).status.success());
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    for _ in 0..8 {
        assert_eq!(
            signed(
                &http,
                &url,
                &identity(),
                "register",
                "POST",
                "/v2/registration/commit",
                "{}"
            )
            .await
            .status(),
            200
        );
    }
    task.abort();
    let (url, task) = serve(&db).await;
    assert_eq!(
        signed(
            &http,
            &url,
            &identity(),
            "register",
            "POST",
            "/v2/registration/commit",
            "{}"
        )
        .await
        .status(),
        429
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_accounts")
            .fetch_one(&db)
            .await
            .unwrap(),
        8
    );
    task.abort();
    db.close().await;
}
#[tokio::test]
async fn unauthenticated_ingress_and_challenge_memory_are_bounded_without_rows() {
    let (db, u) = database().await;
    assert!(initialize(&u).status.success());
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let mut throttled = false;
    for _ in 0..12 {
        throttled |= http
            .post(format!("{url}/v2/auth/challenge"))
            .body("{}")
            .send()
            .await
            .unwrap()
            .status()
            == 429;
    }
    assert!(throttled, "auth requests must be bounded before DB lookup");
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    let i = identity();
    for _ in 0..4 {
        assert_eq!(
            challenge(
                &http,
                &url,
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
    }
    assert_eq!(
        challenge(
            &http,
            &url,
            &i,
            "register",
            "POST",
            "/v2/registration/commit",
            "{}"
        )
        .await
        .status(),
        429
    );
    for _ in 0..12 {
        assert_eq!(
            challenge(
                &http,
                &url,
                &identity(),
                "register",
                "POST",
                "/v2/registration/commit",
                "{}"
            )
            .await
            .status(),
            200
        );
    }
    assert_eq!(
        challenge(
            &http,
            &url,
            &identity(),
            "register",
            "POST",
            "/v2/registration/commit",
            "{}"
        )
        .await
        .status(),
        429
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_accounts")
            .fetch_one(&db)
            .await
            .unwrap(),
        0
    );
    task.abort();
    db.close().await;
}
#[tokio::test]
async fn general_messaging_preserves_ciphertext_ids_and_inbox_history_across_restart() {
    let (db, u) = database().await;
    assert!(initialize(&u).status.success());
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let users = [identity(), identity(), identity()];
    for i in &users {
        assert_eq!(
            signed(
                &http,
                &url,
                i,
                "register",
                "POST",
                "/v2/registration/commit",
                "{}"
            )
            .await
            .status(),
            200
        );
    }
    let mut saved = Vec::new();
    for (sender, recipient) in [(0, 1), (0, 2), (2, 1)] {
        let body=json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":users[recipient].credential.account,"ciphertext":"AAECAw=="}).to_string();
        let response = signed(
            &http,
            &url,
            &users[sender],
            "message",
            "POST",
            "/v2/messages",
            &body,
        )
        .await;
        assert_eq!(
            response.status(),
            200,
            "general message append must be available"
        );
        let accepted: Value = response.json().await.unwrap();
        saved.push((sender, body, accepted));
    }
    task.abort();
    let (url, task) = serve(&db).await;
    for (sender, body, accepted) in &saved {
        assert_eq!(
            signed(
                &http,
                &url,
                &users[*sender],
                "message",
                "POST",
                "/v2/messages",
                body
            )
            .await
            .json::<Value>()
            .await
            .unwrap(),
            *accepted
        );
        let mut altered: Value = serde_json::from_str(body).unwrap();
        altered["ciphertext"] = json!("BA==");
        assert_eq!(
            signed(
                &http,
                &url,
                &users[*sender],
                "message",
                "POST",
                "/v2/messages",
                &altered.to_string()
            )
            .await
            .status(),
            409
        );
    }
    let inbox: Value = signed(
        &http,
        &url,
        &users[1],
        "message",
        "GET",
        "/v2/messages?after=0&limit=1",
        "",
    )
    .await
    .json()
    .await
    .unwrap();
    assert_eq!(inbox["messages"][0]["sender"], users[0].credential.account);
    assert_eq!(inbox["messages"][0]["ciphertext"], "AAECAw==");
    let next: Value = signed(
        &http,
        &url,
        &users[1],
        "message",
        "GET",
        &format!("/v2/messages?after={}&limit=100", inbox["cursor"]),
        "",
    )
    .await
    .json()
    .await
    .unwrap();
    assert_eq!(next["messages"][0]["sender"], users[2].credential.account);
    let own: Value = signed(&http, &url, &users[0], "message", "GET", "/v2/messages", "")
        .await
        .json()
        .await
        .unwrap();
    assert_eq!(own["messages"], json!([]));
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_messages")
            .fetch_one(&db)
            .await
            .unwrap(),
        3
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_conversations")
            .fetch_one(&db)
            .await
            .unwrap(),
        3
    );
    task.abort();
    db.close().await;
}
#[tokio::test]
async fn ciphertext_storage_quotas_reject_without_eviction_and_retry_still_works() {
    for (rows, size, global) in [
        (1024i64, 16384i32, false),
        (10000, 1, false),
        (16384, 16384, true),
        (100000, 1, true),
    ] {
        let (db, u) = database().await;
        assert!(initialize(&u).status.success());
        let (url, task) = serve(&db).await;
        let http = reqwest::Client::new();
        let a = identity();
        let b = identity();
        for i in [&a, &b] {
            assert_eq!(
                signed(
                    &http,
                    &url,
                    i,
                    "register",
                    "POST",
                    "/v2/registration/commit",
                    "{}"
                )
                .await
                .status(),
                200
            );
        }
        let seed = if global {
            &b.credential.account
        } else {
            &a.credential.account
        };
        let recipient = if global {
            &a.credential.account
        } else {
            &b.credential.account
        };
        let (first, second) = if seed < recipient {
            (seed, recipient)
        } else {
            (recipient, seed)
        };
        sqlx::query("INSERT INTO ss_conversations VALUES($1,$2)")
            .bind(first)
            .bind(second)
            .execute(&db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO ss_messages SELECT n,$1,$2,('00000000-0000-4000-8000-'||lpad(n::text,12,'0')),decode(repeat('ab',$3),'hex'),$4,$5 FROM generate_series(1,$6) n").bind(seed).bind(recipient).bind(size).bind(first).bind(second).bind(rows).execute(&db).await.unwrap();
        sqlx::query("UPDATE ss_meta SET sequence=$1")
            .bind(rows)
            .execute(&db)
            .await
            .unwrap();
        let body=json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":b.credential.account,"ciphertext":"AA=="}).to_string();
        assert_eq!(
            signed(&http, &url, &a, "message", "POST", "/v2/messages", &body)
                .await
                .status(),
            507,
            "quota rows={rows} size={size} global={global}"
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_messages")
                .fetch_one(&db)
                .await
                .unwrap(),
            rows
        );
        if !global {
            use base64::Engine;
            let retry=json!({"id":"00000000-0000-4000-8000-000000000001","recipient":b.credential.account,"ciphertext":base64::engine::general_purpose::STANDARD.encode(vec![0xab;size as usize])}).to_string();
            assert_eq!(
                signed(&http, &url, &a, "message", "POST", "/v2/messages", &retry)
                    .await
                    .status(),
                200
            );
        }
        task.abort();
        db.close().await;
    }
}
async fn legacy(db: &PgPool, mode: &str) -> [Identity; 2] {
    sqlx::raw_sql(include_str!("../schema.sql"))
        .execute(db)
        .await
        .unwrap();
    sqlx::raw_sql(include_str!("../key-schema.sql"))
        .execute(db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO key_meta VALUES(1,1,$1,$2)")
        .bind(REALM)
        .bind("a".repeat(64))
        .execute(db)
        .await
        .unwrap();
    let users = [identity(), identity()];
    for (slot, i) in users.iter().enumerate() {
        let c = &i.credential;
        sqlx::query("INSERT INTO key_grants VALUES($1,$2,$3,$4,$5,$6,$7,1,$8)")
            .bind(slot as i16)
            .bind(uuid::Uuid::new_v4().to_string())
            .bind(serde_json::to_string(c).unwrap())
            .bind(c.fingerprint())
            .bind(&c.account)
            .bind(&c.device)
            .bind(&c.auth)
            .bind(if slot == 0 { mode } else { "active" })
            .execute(db)
            .await
            .unwrap();
    }
    sqlx::query("INSERT INTO envelopes VALUES(1,0,1,'00000000-0000-4000-8000-000000000001',decode('ab','hex')),(3,1,0,'00000000-0000-4000-8000-000000000003',decode('cdef','hex'))").execute(db).await.unwrap();
    sqlx::query("UPDATE room_state SET sequence=3,used_bytes=3")
        .execute(db)
        .await
        .unwrap();
    users
}
#[tokio::test]
async fn offline_migration_preserves_history_and_requires_pending_device_proof() {
    for mode in ["approved", "pending", "active", "revoked"] {
        let (db, u) = database().await;
        let users = legacy(&db, mode).await;
        assert!(
            initialize(&u).status.success(),
            "verified legacy migration must work: {mode}"
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT count(*) FROM envelopes")
                .fetch_one(&db)
                .await
                .unwrap(),
            2
        );
        assert_eq!(
            sqlx::query_scalar::<_, String>("SELECT mode FROM key_grants WHERE slot=0")
                .fetch_one(&db)
                .await
                .unwrap(),
            mode
        );
        let persisted: String = sqlx::query_scalar("SELECT mode FROM ss_accounts WHERE account=$1")
            .bind(&users[0].credential.account)
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(persisted, if mode == "approved" { "pending" } else { mode });
        let (url, task) = serve(&db).await;
        let http = reqwest::Client::new();
        if mode != "active" {
            assert_eq!(
                challenge(
                    &http,
                    &url,
                    &users[0],
                    "status",
                    "POST",
                    "/v2/auth/verify",
                    "{}"
                )
                .await
                .status(),
                401
            );
        }
        let response = signed(
            &http,
            &url,
            &users[0],
            "register",
            "POST",
            "/v2/registration/commit",
            "{}",
        )
        .await;
        assert_eq!(response.status(), if mode == "revoked" { 409 } else { 200 });
        if mode != "revoked" {
            let inbox: Value = signed(&http, &url, &users[0], "message", "GET", "/v2/messages", "")
                .await
                .json()
                .await
                .unwrap();
            assert_eq!(
                inbox["messages"],
                json!([{"id":"00000000-0000-4000-8000-000000000003","sender":users[1].credential.account,"sequence":3,"ciphertext":"ze8="}])
            );
        }
        let unknown = identity();
        assert_eq!(
            signed(
                &http,
                &url,
                &unknown,
                "register",
                "POST",
                "/v2/registration/commit",
                "{}"
            )
            .await
            .status(),
            200
        );
        let inbox: Value = signed(&http, &url, &unknown, "message", "GET", "/v2/messages", "")
            .await
            .json()
            .await
            .unwrap();
        assert_eq!(inbox["messages"], json!([]));
        assert!(
            paranoid_server::registration::key_app(
                db.clone(),
                ["a".repeat(64), "b".repeat(64)],
                1024
            )
            .await
            .is_err(),
            "historical key startup must reject cutover"
        );
        assert!(
            paranoid_server::stored_app(db.clone(), ["a".repeat(64), "b".repeat(64)], 1024)
                .await
                .is_err()
        );
        task.abort();
        db.close().await;
    }
}
#[tokio::test]
async fn migration_rejects_ambiguous_schema_and_unbound_state_transactionally() {
    for mutation in [
        "CREATE TYPE unexpected AS ENUM ('state')",
        "ALTER TABLE key_grants ADD COLUMN surprise TEXT",
        "ALTER TABLE envelopes DROP CONSTRAINT envelopes_sender_check",
        "CREATE TABLE mystery(n INT)",
        "UPDATE key_grants SET fingerprint=repeat('0',64) WHERE slot=0",
        "UPDATE key_grants SET credential=replace(credential,'https://','http://') WHERE slot=0",
        "DELETE FROM key_grants WHERE slot=0",
        "UPDATE room_state SET used_bytes=99",
        "DROP TABLE key_grants; DROP TABLE key_meta",
    ] {
        let (db, u) = database().await;
        let _ = legacy(&db, "active").await;
        sqlx::raw_sql(mutation).execute(&db).await.unwrap();
        assert!(!initialize(&u).status.success(), "must reject {mutation}");
        assert!(
            !sqlx::query_scalar::<_, bool>("SELECT to_regclass('ss_meta') IS NOT NULL")
                .fetch_one(&db)
                .await
                .unwrap(),
            "failed migration must rollback all new tables"
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT count(*) FROM envelopes")
                .fetch_one(&db)
                .await
                .unwrap(),
            2
        );
        db.close().await;
    }
}
fn tls_json(
    cert: &std::path::Path,
    address: &str,
    method: &str,
    path: &str,
    body: &str,
    auth: Option<&str>,
) -> Value {
    let mut command = Command::new("curl");
    command
        .args([
            "--silent",
            "--show-error",
            "--fail",
            "--max-time",
            "3",
            "--cacert",
        ])
        .arg(cert)
        .args(["-X", method, "-H", "Content-Type: application/json"]);
    if !body.is_empty() {
        command.args(["--data-binary", body]);
    }
    if let Some(proof) = auth {
        command.args(["-H", &format!("Authorization: {proof}")]);
    }
    let out = command
        .arg(format!("https://{address}{path}"))
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "TLS request failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).unwrap()
}
fn tls_inbox(cert: &std::path::Path, address: &str, i: &Identity) -> Value {
    let request=json!({"account":i.credential.account,"device":i.credential.device,"credential":i.credential.fingerprint(),"purpose":"message","method":"GET","path":"/v2/messages","body":paranoid_key_protocol::digest(b"")}).to_string();
    let ch = tls_json(cert, address, "POST", "/v2/auth/challenge", &request, None);
    tls_json(
        cert,
        address,
        "GET",
        "/v2/messages",
        "",
        Some(&sign(i, &ch)),
    )
}
struct ChildGuard(std::process::Child);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
#[tokio::test]
async fn local_tls_mode_requires_single_worker_and_offline_schema_lock() {
    let (db, u) = database().await;
    assert!(initialize(&u).status.success());
    let (http_url, http_task) = serve(&db).await;
    let http = reqwest::Client::new();
    let a = identity();
    let b = identity();
    for i in [&a, &b] {
        assert_eq!(
            signed(
                &http,
                &http_url,
                i,
                "register",
                "POST",
                "/v2/registration/commit",
                "{}"
            )
            .await
            .status(),
            200
        );
    }
    let body=json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":b.credential.account,"ciphertext":"AAECAw=="}).to_string();
    assert_eq!(
        signed(
            &http,
            &http_url,
            &a,
            "message",
            "POST",
            "/v2/messages",
            &body
        )
        .await
        .status(),
        200
    );
    http_task.abort();
    let dir = std::env::temp_dir().join(format!("paranoid-ss-tls-{}", uuid::Uuid::new_v4()));
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
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let command = |bind: String| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_paranoid-server"));
        c.env_clear()
            .env("PARANOID_MODE", "self-service-v2-local")
            .env("PARANOID_BIND", bind)
            .env("PARANOID_DATABASE_URL", &u)
            .env("PARANOID_TLS_CERT", &cert)
            .env("PARANOID_TLS_KEY", &key)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        c
    };
    let mut child = ChildGuard(command(address.to_string()).spawn().unwrap());
    let mut ready = false;
    for _ in 0..50 {
        assert!(
            child.0.try_wait().unwrap().is_none(),
            "explicit self-service TLS mode must start without legacy bearer env"
        );
        let out = Command::new("curl")
            .args(["--silent", "--fail", "--max-time", "1", "--cacert"])
            .arg(&cert)
            .arg(format!("https://{address}/health"))
            .output()
            .unwrap();
        if out.status.success() {
            let v: Value = serde_json::from_slice(&out.stdout).unwrap();
            assert_eq!(v["protocol"], "paranoid-self-service-v2");
            ready = true;
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    assert!(ready, "verified local TLS health must be ready");
    let inbox = tls_inbox(&cert, &address.to_string(), &b);
    assert_eq!(inbox["messages"][0]["sender"], a.credential.account);
    let free = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let other = free.local_addr().unwrap();
    drop(free);
    let mut second = ChildGuard(command(other.to_string()).spawn().unwrap());
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert!(second.0.try_wait().unwrap().is_some());
    let (other_db, other_url) = database().await;
    assert!(
        !initialize(&other_url).status.success(),
        "offline helper cannot share running worker lock, even for a fresh DB"
    );
    other_db.close().await;
    drop(child);
    let mut restarted = ChildGuard(command(address.to_string()).spawn().unwrap());
    for _ in 0..50 {
        assert!(restarted.0.try_wait().unwrap().is_none());
        if Command::new("curl")
            .args(["--silent", "--fail", "--max-time", "1", "--cacert"])
            .arg(&cert)
            .arg(format!("https://{address}/health"))
            .output()
            .unwrap()
            .status
            .success()
        {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    assert_eq!(
        tls_inbox(&cert, &address.to_string(), &b),
        inbox,
        "process SIGKILL/restart preserves exact inbox"
    );
    drop(restarted);
    let mut external = ChildGuard(
        command(format!("0.0.0.0:{}", address.port()))
            .spawn()
            .unwrap(),
    );
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert!(
        external.0.try_wait().unwrap().is_some(),
        "self-service mode must not bind publicly"
    );
    std::fs::remove_dir_all(dir).unwrap();
    db.close().await;
}
#[tokio::test]
async fn conflicting_device_binding_is_rejected_without_creating_an_account() {
    let (db, u) = database().await;
    assert!(initialize(&u).status.success());
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let a = identity();
    assert_eq!(
        signed(
            &http,
            &url,
            &a,
            "register",
            "POST",
            "/v2/registration/commit",
            "{}"
        )
        .await
        .status(),
        200
    );
    let mut b = identity();
    b.credential.device = a.credential.device.clone();
    b.credential.signature = vodozemac::Ed25519SecretKey::from_base64(&b.root_secret)
        .unwrap()
        .sign(&b.credential.bytes())
        .to_base64();
    assert_eq!(
        signed(
            &http,
            &url,
            &b,
            "register",
            "POST",
            "/v2/registration/commit",
            "{}"
        )
        .await
        .status(),
        409
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_accounts")
            .fetch_one(&db)
            .await
            .unwrap(),
        1
    );
    task.abort();
    db.close().await;
}
// Expanded adversarial verification of the earlier HTTP proof tracer.
#[tokio::test]
async fn every_proof_field_wrong_signer_and_cross_request_are_rejected_without_consuming() {
    let (db, u) = database().await;
    assert!(initialize(&u).status.success());
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = identity();
    let ch: Value = challenge(
        &http,
        &url,
        &i,
        "register",
        "POST",
        "/v2/registration/commit",
        "{}",
    )
    .await
    .json()
    .await
    .unwrap();
    use base64::Engine;
    assert_eq!(
        base64::engine::general_purpose::STANDARD
            .decode(ch["nonce"].as_str().unwrap())
            .unwrap()
            .len(),
        32
    );
    for field in [
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
    ] {
        tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        let mut wrong = ch.clone();
        wrong[field] = if field == "expires" {
            json!(1)
        } else {
            json!(format!("{}x", wrong[field].as_str().unwrap()))
        };
        let proof = sign(&i, &wrong);
        assert_eq!(
            http.post(format!("{url}/v2/registration/commit"))
                .header("Authorization", proof)
                .body("{}")
                .send()
                .await
                .unwrap()
                .status(),
            401,
            "bound field {field}"
        );
    }
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    assert_eq!(
        http.post(format!("{url}/v2/registration/commit"))
            .header("Authorization", sign(&identity(), &ch))
            .body("{}")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        http.post(format!("{url}/v2/registration/commit"))
            .header("Authorization", sign(&i, &ch))
            .body("{ }")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        http.post(format!("{url}/v2/auth/verify"))
            .header("Authorization", sign(&i, &ch))
            .body("{}")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    let proof = sign(&i, &ch);
    let send = || {
        http.post(format!("{url}/v2/registration/commit"))
            .header("Authorization", &proof)
            .body("{}")
            .send()
    };
    let (a, b) = tokio::join!(send(), send());
    let mut codes = [a.unwrap().status().as_u16(), b.unwrap().status().as_u16()];
    codes.sort();
    assert_eq!(codes, [200, 401]);
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    for field in ["account", "device", "credential"] {
        let mut request = json!({"account":i.credential.account,"device":i.credential.device,"credential":i.credential.fingerprint(),"purpose":"status","method":"POST","path":"/v2/auth/verify","body":paranoid_key_protocol::digest(b"{}")});
        request[field] = json!("wrong");
        assert_eq!(
            http.post(format!("{url}/v2/auth/challenge"))
                .json(&request)
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
    }
    let raw = format!(
        r#"{{"credential":{},"purpose":"register","purpose":"register","method":"POST","path":"/v2/registration/commit","body":"{}"}}"#,
        serde_json::to_string(&i.credential).unwrap(),
        paranoid_key_protocol::digest(b"{}")
    );
    assert_eq!(
        http.post(format!("{url}/v2/registration/challenge"))
            .body(raw)
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
async fn historical_admin_cannot_initialize_legacy_tables_in_v2_database() {
    let (db, u) = database().await;
    assert!(initialize(&u).status.success());
    let out = Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
        .arg("key-admin-init")
        .env("PARANOID_DATABASE_URL", &u)
        .env("PARANOID_KEY_REALM", REALM)
        .env("PARANOID_KEY_PIN", "a".repeat(64))
        .output()
        .unwrap();
    assert!(
        !out.status.success(),
        "key admin must refuse v2 before touching old schema"
    );
    assert!(
        !sqlx::query_scalar::<_, bool>("SELECT to_regclass('envelopes') IS NOT NULL")
            .fetch_one(&db)
            .await
            .unwrap()
    );
    db.close().await;
}
#[tokio::test]
async fn pre_marker_binary_startup_sql_is_blocked_on_fresh_and_migrated_storage() {
    for migrated in [false, true] {
        let (db, u) = database().await;
        if migrated {
            let _ = legacy(&db, "active").await;
        }
        assert!(initialize(&u).status.success());
        if migrated {
            assert!(
                sqlx::query_as::<_, (String, String)>(
                    "SELECT realm,pin FROM key_meta WHERE id=1 AND version=1"
                )
                .fetch_optional(&db)
                .await
                .unwrap()
                .is_none(),
                "old key binary version lookup must fail"
            );
            assert_eq!(
                sqlx::query_scalar::<_, i16>("SELECT version FROM ss_legacy_key_meta WHERE id=1")
                    .fetch_one(&db)
                    .await
                    .unwrap(),
                1
            );
        }
        assert!(
            sqlx::raw_sql(include_str!("../schema.sql"))
                .execute(&db)
                .await
                .is_err(),
            "old v0 initialization SQL must fail even without marker-aware code"
        );
        db.close().await;
    }
}
#[tokio::test]
async fn nominally_empty_database_with_unknown_function_is_not_initialized() {
    let (db, u) = database().await;
    sqlx::raw_sql("CREATE FUNCTION unknown_state() RETURNS integer LANGUAGE sql AS 'SELECT 1'")
        .execute(&db)
        .await
        .unwrap();
    assert!(
        !initialize(&u).status.success(),
        "unknown existing schema is not fresh"
    );
    assert!(
        !sqlx::query_scalar::<_, bool>("SELECT to_regclass('ss_meta') IS NOT NULL")
            .fetch_one(&db)
            .await
            .unwrap()
    );
    db.close().await;
}
#[tokio::test]
async fn durable_device_binding_changes_between_issue_and_use_fail_closed() {
    let (db, u) = database().await;
    assert!(initialize(&u).status.success());
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = identity();
    assert_eq!(
        signed(
            &http,
            &url,
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
    let ch: Value = challenge(&http, &url, &i, "status", "POST", "/v2/auth/verify", "{}")
        .await
        .json()
        .await
        .unwrap();
    sqlx::query("UPDATE ss_devices SET auth=$1")
        .bind(identity().credential.auth)
        .execute(&db)
        .await
        .unwrap();
    assert_eq!(
        http.post(format!("{url}/v2/auth/verify"))
            .header("Authorization", sign(&i, &ch))
            .body("{}")
            .send()
            .await
            .unwrap()
            .status(),
        409
    );
    task.abort();
    db.close().await;
}
#[tokio::test]
async fn expired_v2_challenge_never_creates_an_account() {
    let (db, u) = database().await;
    assert!(initialize(&u).status.success());
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let i = identity();
    let ch: Value = challenge(
        &http,
        &url,
        &i,
        "register",
        "POST",
        "/v2/registration/commit",
        "{}",
    )
    .await
    .json()
    .await
    .unwrap();
    tokio::time::sleep(std::time::Duration::from_secs(61)).await;
    assert_eq!(
        http.post(format!("{url}/v2/registration/commit"))
            .header("Authorization", sign(&i, &ch))
            .body("{}")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_accounts")
            .fetch_one(&db)
            .await
            .unwrap(),
        0
    );
    assert_eq!(
        signed(
            &http,
            &url,
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
    task.abort();
    db.close().await;
}
#[tokio::test]
async fn migrated_history_and_post_cutover_message_survive_database_dump_restore() {
    let (db, u) = database().await;
    let users = legacy(&db, "active").await;
    assert!(initialize(&u).status.success());
    let (url, task) = serve(&db).await;
    let http = reqwest::Client::new();
    let retry=json!({"id":"00000000-0000-4000-8000-000000000001","recipient":users[1].credential.account,"ciphertext":"qw=="}).to_string();
    assert_eq!(
        signed(
            &http,
            &url,
            &users[0],
            "message",
            "POST",
            "/v2/messages",
            &retry
        )
        .await
        .json::<Value>()
        .await
        .unwrap()["sequence"],
        1
    );
    let body=json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":users[1].credential.account,"ciphertext":"AAECAw=="}).to_string();
    let accepted: Value = signed(
        &http,
        &url,
        &users[0],
        "message",
        "POST",
        "/v2/messages",
        &body,
    )
    .await
    .json()
    .await
    .unwrap();
    assert_eq!(accepted["sequence"], 4);
    let before: Value = signed(&http, &url, &users[1], "message", "GET", "/v2/messages", "")
        .await
        .json()
        .await
        .unwrap();
    task.abort();
    let file = std::env::temp_dir().join(format!("paranoid-ss-dump-{}.sql", uuid::Uuid::new_v4()));
    let bin = std::path::PathBuf::from(
        std::env::var("PG_BIN").unwrap_or_else(|_| "/usr/lib/postgresql/16/bin".into()),
    );
    let dump = Command::new(bin.join("pg_dump"))
        .args(["--no-owner", "--no-privileges", "--dbname", &u, "--file"])
        .arg(&file)
        .output()
        .unwrap();
    assert!(dump.status.success(), "fixture pg_dump failed");
    let (restored, restore_url) = database().await;
    let restore = Command::new(bin.join("psql"))
        .args([
            "-X",
            "--set",
            "ON_ERROR_STOP=1",
            "--dbname",
            &restore_url,
            "--file",
        ])
        .arg(&file)
        .output()
        .unwrap();
    std::fs::remove_file(file).unwrap();
    assert!(
        restore.status.success(),
        "fixture restore failed: {}",
        String::from_utf8_lossy(&restore.stderr)
    );
    let (url, task) = serve(&restored).await;
    assert_eq!(
        signed(&http, &url, &users[1], "message", "GET", "/v2/messages", "")
            .await
            .json::<Value>()
            .await
            .unwrap(),
        before
    );
    assert_eq!(
        signed(
            &http,
            &url,
            &users[0],
            "message",
            "POST",
            "/v2/messages",
            &body
        )
        .await
        .json::<Value>()
        .await
        .unwrap(),
        accepted
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM envelopes")
            .fetch_one(&restored)
            .await
            .unwrap(),
        2
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_messages")
            .fetch_one(&restored)
            .await
            .unwrap(),
        3
    );
    assert!(paranoid_server::registration::key_app(
        restored.clone(),
        ["a".repeat(64), "b".repeat(64)],
        1024
    )
    .await
    .is_err());
    task.abort();
    db.close().await;
    restored.close().await;
}
const REALM: &str = "https://127.0.0.2:38443";
async fn database() -> (PgPool, String) {
    let base = std::env::var("PARANOID_TEST_DATABASE_URL").unwrap();
    let admin = PgPoolOptions::new()
        .max_connections(1)
        .connect(&base)
        .await
        .unwrap();
    let name = format!("self_{}", uuid::Uuid::new_v4().simple());
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
fn initialize(url: &str) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
        .arg("self-service-init")
        .env_remove("PARANOID_MODE")
        .env("PARANOID_DATABASE_URL", url)
        .env("PARANOID_KEY_REALM", REALM)
        .env("PARANOID_KEY_PIN", "a".repeat(64))
        .output()
        .unwrap()
}
#[tokio::test]
async fn fresh_offline_schema_has_no_operator_or_accounts() {
    let (db, url) = database().await;
    let result = initialize(&url);
    assert!(
        result.status.success(),
        "explicit offline self-service initialization is missing: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM ss_accounts")
        .fetch_one(&db)
        .await
        .unwrap();
    assert_eq!(count, 0);
    assert!(
        !initialize(&url).status.success(),
        "never silently reinitialize"
    );
    db.close().await;
}
