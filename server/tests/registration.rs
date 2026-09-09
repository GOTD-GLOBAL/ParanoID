use serde_json::{json, Value};
use sqlx::postgres::PgPoolOptions;
use std::process::Command;

async fn approve_fixture(
    db: &sqlx::PgPool,
    slot: i16,
) -> (paranoid_key_protocol::Identity, String) {
    let identity = paranoid_key_protocol::Identity::create(
        "https://127.0.0.2:38443",
        &"a".repeat(64),
        "curve",
        "prekey",
    )
    .unwrap();
    let c = &identity.credential;
    let grant = uuid::Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO key_grants VALUES($1,$2,$3,$4,$5,$6,$7, floor(extract(epoch FROM clock_timestamp()))::bigint+900,'approved')")
        .bind(slot).bind(&grant).bind(serde_json::to_string(c).unwrap()).bind(c.fingerprint()).bind(&c.account).bind(&c.device).bind(&c.auth).execute(db).await.unwrap();
    (identity, grant)
}
fn sign_challenge(identity: &paranoid_key_protocol::Identity, ch: &Value) -> String {
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
        "grant",
        "slot",
        "purpose",
        "method",
        "path",
        "body",
    ];
    let fields: Vec<String> = names
        .iter()
        .map(|n| {
            if ch[n].is_string() {
                ch[n].as_str().unwrap().into()
            } else {
                ch[n].to_string()
            }
        })
        .collect();
    let mut parts = vec!["paranoid-proof-v1"];
    parts.extend(fields.iter().map(String::as_str));
    let signature = vodozemac::Ed25519SecretKey::from_base64(&identity.auth_secret)
        .unwrap()
        .sign(&paranoid_key_protocol::transcript(&parts))
        .to_base64();
    format!("Paranoid {}.{signature}", ch["id"].as_str().unwrap())
}

#[tokio::test]
async fn exact_key_enrollment_commit_is_one_use_and_status_survives_router_restart() {
    let (db, _) = fixture().await;
    let (identity, grant) = approve_fixture(&db, 0).await;
    let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", socket.local_addr().unwrap());
    let router = paranoid_server::registration::key_app(
        db.clone(),
        ["a".repeat(64), "b".repeat(64)],
        1048576,
    )
    .await
    .unwrap();
    let task = tokio::spawn(async move { axum::serve(socket, router).await.unwrap() });
    let http = reqwest::Client::new();
    let request = json!({"grant":grant,"credential":identity.credential.fingerprint(),"purpose":"enroll","method":"POST","path":"/v1/enrollment/commit","body":paranoid_key_protocol::digest(b"{}")});
    let response = http
        .post(format!("{url}/v1/enrollment/challenge"))
        .json(&request)
        .send()
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        200,
        "approved exact-key challenge must be available"
    );
    let ch: Value = response.json().await.unwrap();
    let proof = sign_challenge(&identity, &ch);
    let send = || {
        http.post(format!("{url}/v1/enrollment/commit"))
            .header("Authorization", &proof)
            .header("Content-Type", "application/json")
            .body("{}")
            .send()
    };
    let (a, b) = tokio::join!(send(), send());
    let mut codes = [a.unwrap().status().as_u16(), b.unwrap().status().as_u16()];
    codes.sort();
    assert_eq!(codes, [200, 401]);
    assert_eq!(
        sqlx::query_scalar::<_, String>("SELECT mode FROM key_grants WHERE slot=0")
            .fetch_one(&db)
            .await
            .unwrap(),
        "pending"
    );
    task.abort();
    let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", socket.local_addr().unwrap());
    let router = paranoid_server::registration::key_app(
        db.clone(),
        ["a".repeat(64), "b".repeat(64)],
        1048576,
    )
    .await
    .unwrap();
    let task = tokio::spawn(async move { axum::serve(socket, router).await.unwrap() });

    let mut request = request;
    request["purpose"] = json!("status");
    request["path"] = json!("/v1/auth/verify");
    let ch: Value = http
        .post(format!("{url}/v1/auth/challenge"))
        .json(&request)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let response = http
        .post(format!("{url}/v1/auth/verify"))
        .header("Authorization", sign_challenge(&identity, &ch))
        .body("{}")
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.json::<Value>().await.unwrap()["mode"], "pending");
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn unknown_auth_ingress_is_bounded_before_lookup_without_allocating_rows() {
    let (db, _) = fixture().await;
    let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", socket.local_addr().unwrap());
    let router = paranoid_server::registration::key_app(
        db.clone(),
        ["a".repeat(64), "b".repeat(64)],
        1048576,
    )
    .await
    .unwrap();
    let task = tokio::spawn(async move { axum::serve(socket, router).await.unwrap() });
    let http = reqwest::Client::new();
    let mut throttled = false;
    for _ in 0..12 {
        let result = http
            .post(format!("{url}/v1/auth/challenge"))
            .body("{}")
            .send()
            .await
            .unwrap();
        throttled |= result.status() == 429;
    }
    assert!(
        throttled,
        "unknown public ingress must be throttled before database lookup"
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM key_grants")
            .fetch_one(&db)
            .await
            .unwrap(),
        0
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn local_operator_can_abort_pending_but_cannot_revive_bearer_after_activation() {
    let (db, url) = fixture().await;
    let (i, _) = approve_fixture(&db, 0).await;
    sqlx::query("UPDATE key_grants SET mode='pending'")
        .execute(&db)
        .await
        .unwrap();
    let revoke = || {
        Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
            .args(["key-admin-revoke", "0", &i.credential.fingerprint()])
            .env("PARANOID_DATABASE_URL", &url)
            .output()
            .unwrap()
    };
    assert!(
        revoke().status.success(),
        "explicit exact-key pending abort must work"
    );
    assert_eq!(
        sqlx::query_scalar::<_, String>("SELECT mode FROM key_grants")
            .fetch_one(&db)
            .await
            .unwrap(),
        "revoked"
    );
    sqlx::query("UPDATE key_grants SET mode='active'")
        .execute(&db)
        .await
        .unwrap();
    assert!(!revoke().status.success());
    assert_eq!(
        sqlx::query_scalar::<_, String>("SELECT mode FROM key_grants")
            .fetch_one(&db)
            .await
            .unwrap(),
        "active"
    );
    db.close().await;
}

#[tokio::test]
async fn control_challenges_reject_nonempty_semantic_payloads() {
    let (db, _) = fixture().await;
    let (i, g) = approve_fixture(&db, 0).await;
    let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", socket.local_addr().unwrap());
    let router = paranoid_server::registration::key_app(
        db.clone(),
        ["a".repeat(64), "b".repeat(64)],
        1048576,
    )
    .await
    .unwrap();
    let task = tokio::spawn(async move { axum::serve(socket, router).await.unwrap() });
    let intent = json!({"grant":g,"credential":i.credential.fingerprint(),"purpose":"enroll","method":"POST","path":"/v1/enrollment/commit","body":paranoid_key_protocol::digest(b"{\"unexpected\":true}")});
    let response = reqwest::Client::new()
        .post(format!("{url}/v1/enrollment/challenge"))
        .json(&intent)
        .send()
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        401,
        "control body must be exactly empty object, not an extensible unsigned contract"
    );
    task.abort();
    db.close().await;
}

// Expanded verification of the implemented proof tracer, not fabricated network responses.
#[tokio::test]
async fn proof_tampering_expiry_revocation_capacity_and_old_boot_fail_closed() {
    use std::time::Duration;
    let (db, _) = fixture().await;
    let (i, g) = approve_fixture(&db, 0).await;
    let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", socket.local_addr().unwrap());
    let router = paranoid_server::registration::key_app(
        db.clone(),
        ["a".repeat(64), "b".repeat(64)],
        1048576,
    )
    .await
    .unwrap();
    let task = tokio::spawn(async move { axum::serve(socket, router).await.unwrap() });
    let http = reqwest::Client::new();
    let intent = json!({"grant":g,"credential":i.credential.fingerprint(),"purpose":"enroll","method":"POST","path":"/v1/enrollment/commit","body":paranoid_key_protocol::digest(b"{}")});
    let issue = || {
        http.post(format!("{url}/v1/enrollment/challenge"))
            .json(&intent)
            .send()
    };
    let mut wrong = intent.clone();
    wrong["credential"] = json!("0".repeat(64));
    assert_eq!(
        http.post(format!("{url}/v1/enrollment/challenge"))
            .json(&wrong)
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    sqlx::query("UPDATE key_grants SET expires=1")
        .execute(&db)
        .await
        .unwrap();
    assert_eq!(issue().await.unwrap().status(), 401);
    sqlx::query(
        "UPDATE key_grants SET expires=floor(extract(epoch FROM clock_timestamp()))::bigint+900",
    )
    .execute(&db)
    .await
    .unwrap();
    let response = issue().await.unwrap();
    assert_eq!(response.status(), 200);
    let ch: Value = response.json().await.unwrap();
    tokio::time::sleep(Duration::from_secs(1)).await;
    for field in [
        "nonce",
        "epoch",
        "expires",
        "realm",
        "pin",
        "account",
        "device",
        "credential",
        "grant",
        "slot",
        "purpose",
        "method",
        "path",
        "body",
    ] {
        let mut bad = ch.clone();
        bad[field] = if bad[field].is_number() {
            json!(42)
        } else {
            json!("different")
        };
        let response = http
            .post(format!("{url}/v1/enrollment/commit"))
            .header("Authorization", sign_challenge(&i, &bad))
            .body("{}")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 401, "altered signed transcript accepted");
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    let proof = sign_challenge(&i, &ch);
    for (path, body) in [
        ("/v1/enrollment/commit", " { }"),
        ("/v1/enrollment/commit?other=1", "{}"),
        ("/v1/enrollment/activate", "{}"),
    ] {
        assert_eq!(
            http.post(format!("{url}{path}"))
                .header("Authorization", &proof)
                .body(body)
                .send()
                .await
                .unwrap()
                .status(),
            401
        );
    }
    // Wrong signatures/context never consume the legitimate proof.
    assert_eq!(
        http.post(format!("{url}/v1/enrollment/commit"))
            .header("Authorization", proof)
            .body("{}")
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    // A new fixture approval state lets us exercise expiration without waiting 15 minutes.
    sqlx::query("UPDATE key_grants SET mode='approved'")
        .execute(&db)
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_secs(1)).await;
    let ch: Value = issue().await.unwrap().json().await.unwrap();
    sqlx::query("UPDATE key_grants SET mode='revoked'")
        .execute(&db)
        .await
        .unwrap();
    assert_eq!(
        http.post(format!("{url}/v1/enrollment/commit"))
            .header("Authorization", sign_challenge(&i, &ch))
            .body("{}")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    sqlx::query("UPDATE key_grants SET mode='approved'")
        .execute(&db)
        .await
        .unwrap();
    // Actual elapsed-time expiry, not a fake server response or adjusted client clock.
    tokio::time::sleep(Duration::from_secs(61)).await;
    assert_eq!(
        http.post(format!("{url}/v1/enrollment/commit"))
            .header("Authorization", sign_challenge(&i, &ch))
            .body("{}")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    let mut last = Value::Null;
    for _ in 0..4 {
        tokio::time::sleep(Duration::from_millis(550)).await;
        let r = issue().await.unwrap();
        assert_eq!(r.status(), 200);
        last = r.json().await.unwrap();
    }
    tokio::time::sleep(Duration::from_millis(550)).await;
    assert_eq!(issue().await.unwrap().status(), 429);
    let old = sign_challenge(&i, &last);
    task.abort();
    let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", socket.local_addr().unwrap());
    let router = paranoid_server::registration::key_app(
        db.clone(),
        ["a".repeat(64), "b".repeat(64)],
        1048576,
    )
    .await
    .unwrap();
    let task = tokio::spawn(async move { axum::serve(socket, router).await.unwrap() });
    assert_eq!(
        http.post(format!("{url}/v1/enrollment/commit"))
            .header("Authorization", old)
            .body("{}")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM envelopes")
            .fetch_one(&db)
            .await
            .unwrap(),
        0
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn expired_unconsumed_grant_can_be_explicitly_renewed_without_rebinding_a_slot() {
    let (db, url) = fixture().await;
    let (i, old) = approve_fixture(&db, 0).await;
    sqlx::query("UPDATE key_grants SET expires=1")
        .execute(&db)
        .await
        .unwrap();
    let out = std::env::temp_dir().join(format!("paranoid-renew-{}.json", uuid::Uuid::new_v4()));
    let result = Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
        .args(["key-admin-renew", "0", &i.credential.fingerprint()])
        .arg(&out)
        .env("PARANOID_DATABASE_URL", &url)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "operator must be able to renew an expired unconsumed exact-key approval"
    );
    let g: Value = serde_json::from_slice(&std::fs::read(&out).unwrap()).unwrap();
    assert_ne!(g["id"], old);
    assert_eq!(g["credential"], i.credential.fingerprint());
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM key_grants")
            .fetch_one(&db)
            .await
            .unwrap(),
        1
    );
    std::fs::remove_file(out).unwrap();
    db.close().await;
}

async fn fixture() -> (sqlx::PgPool, String) {
    let base = std::env::var("PARANOID_TEST_DATABASE_URL").unwrap();
    let admin = PgPoolOptions::new()
        .max_connections(1)
        .connect(&base)
        .await
        .unwrap();
    let name = format!("reg_{}", uuid::Uuid::new_v4().simple());
    sqlx::QueryBuilder::<sqlx::Postgres>::new("CREATE DATABASE ")
        .push(&name)
        .build()
        .execute(&admin)
        .await
        .unwrap();
    let url = base.replace("/postgres?", &format!("/{name}?"));
    admin.close().await;
    let db = PgPoolOptions::new()
        .max_connections(4)
        .connect(&url)
        .await
        .unwrap();
    assert!(Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
        .arg("key-admin-init")
        .env("PARANOID_DATABASE_URL", &url)
        .env("PARANOID_KEY_REALM", "https://127.0.0.2:38443")
        .env("PARANOID_KEY_PIN", "a".repeat(64))
        .output()
        .unwrap()
        .status
        .success());
    (db, url)
}

// Keep each independently signed field explicit in this contract-test helper.
#[allow(clippy::too_many_arguments)]
async fn signed(
    http: &reqwest::Client,
    url: &str,
    identity: &paranoid_key_protocol::Identity,
    grant: &str,
    purpose: &str,
    method: &str,
    path: &str,
    body: &str,
) -> reqwest::Response {
    tokio::time::sleep(std::time::Duration::from_millis(550)).await;
    let route = if purpose == "enroll" {
        "/v1/enrollment/challenge"
    } else {
        "/v1/auth/challenge"
    };
    let request = json!({"grant":grant,"credential":identity.credential.fingerprint(),"purpose":purpose,"method":method,"path":path,"body":paranoid_key_protocol::digest(body.as_bytes())});
    let response = http
        .post(format!("{url}{route}"))
        .json(&request)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200, "challenge rejected");
    let ch: Value = response.json().await.unwrap();
    http.request(method.parse().unwrap(), format!("{url}{path}"))
        .header("Authorization", sign_challenge(identity, &ch))
        .header("Content-Type", "application/json")
        .body(body.to_string())
        .send()
        .await
        .unwrap()
}

#[tokio::test]
async fn activation_disables_only_assigned_bearer_and_key_messages_reuse_durable_dedup() {
    let (db, _) = fixture().await;
    let (identity, grant) = approve_fixture(&db, 0).await;
    let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", socket.local_addr().unwrap());
    let router = paranoid_server::registration::key_app(
        db.clone(),
        ["a".repeat(64), "b".repeat(64)],
        1048576,
    )
    .await
    .unwrap();
    let task = tokio::spawn(async move { axum::serve(socket, router).await.unwrap() });
    let http = reqwest::Client::new();
    assert_eq!(
        signed(
            &http,
            &url,
            &identity,
            &grant,
            "enroll",
            "POST",
            "/v1/enrollment/commit",
            "{}"
        )
        .await
        .status(),
        200
    );
    assert_eq!(
        http.get(format!("{url}/v0/messages"))
            .bearer_auth("a".repeat(64))
            .send()
            .await
            .unwrap()
            .status(),
        200,
        "pending migration preserves old access"
    );
    assert_eq!(
        signed(
            &http,
            &url,
            &identity,
            &grant,
            "activate",
            "POST",
            "/v1/enrollment/activate",
            "{}"
        )
        .await
        .status(),
        200
    );
    assert_eq!(
        http.get(format!("{url}/v0/messages"))
            .bearer_auth("a".repeat(64))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        http.get(format!("{url}/v0/messages"))
            .bearer_auth("b".repeat(64))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    let body = json!({"id":uuid::Uuid::new_v4().to_string(),"recipient":"bob","ciphertext":"AQID"})
        .to_string();
    let first = signed(
        &http,
        &url,
        &identity,
        &grant,
        "message",
        "POST",
        "/v1/messages",
        &body,
    )
    .await;
    assert_eq!(first.status(), 200);
    let first: Value = first.json().await.unwrap();
    let retry = signed(
        &http,
        &url,
        &identity,
        &grant,
        "message",
        "POST",
        "/v1/messages",
        &body,
    )
    .await;
    assert_eq!(retry.status(), 200);
    assert_eq!(first, retry.json::<Value>().await.unwrap());
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM envelopes")
            .fetch_one(&db)
            .await
            .unwrap(),
        1
    );
    task.abort();
    db.close().await;
}

#[tokio::test]
async fn operator_approves_only_exact_credential_and_verified_named_slot() {
    use paranoid_key_protocol::Identity;
    let (db, url) = fixture().await;
    let identity = Identity::create(
        "https://127.0.0.2:38443",
        &"a".repeat(64),
        "curve",
        "prekey",
    )
    .unwrap();
    let directory = std::env::temp_dir().join(format!("paranoid-public-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let request = directory.join("request.json");
    let output = directory.join("grant.json");
    std::fs::write(
        &request,
        serde_json::json!({"type":"paranoid-request-v1","credential":identity.credential})
            .to_string(),
    )
    .unwrap();
    let approve = |slot: &str, olm: &str| {
        Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
            .args([
                "key-admin-approve",
                slot,
                &identity.credential.fingerprint(),
                olm,
            ])
            .arg(&request)
            .arg(&output)
            .env("PARANOID_DATABASE_URL", &url)
            .output()
            .unwrap()
            .status
            .success()
    };
    assert!(!approve("0", &"f".repeat(64)));
    assert!(!approve("2", &identity.credential.olm));
    assert!(
        approve("1", &identity.credential.olm),
        "local exact-key approval must work without bearer"
    );
    let grant: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&output).unwrap()).unwrap();
    assert_eq!(grant["slot"], 1);
    assert_eq!(grant["credential"], identity.credential.fingerprint());
    assert_eq!(grant["type"], "paranoid-grant-v1");
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM key_grants")
            .fetch_one(&db)
            .await
            .unwrap(),
        1
    );
    assert!(!approve("0", &identity.credential.olm));
    std::fs::remove_dir_all(directory).unwrap();
    db.close().await;
}

#[tokio::test]
async fn explicit_local_schema_transition_preserves_rows_and_blocks_old_startup() {
    let base = std::env::var("PARANOID_TEST_DATABASE_URL").expect("isolated fixture required");
    let admin = PgPoolOptions::new()
        .max_connections(1)
        .connect(&base)
        .await
        .unwrap();
    let name = format!("reg_{}", uuid::Uuid::new_v4().simple());
    sqlx::QueryBuilder::<sqlx::Postgres>::new("CREATE DATABASE ")
        .push(&name)
        .build()
        .execute(&admin)
        .await
        .unwrap();
    let url = base.replace("/postgres?", &format!("/{name}?"));
    let db = PgPoolOptions::new()
        .max_connections(2)
        .connect(&url)
        .await
        .unwrap();
    let _ = paranoid_server::stored_app(db.clone(), ["a".repeat(64), "b".repeat(64)], 1048576)
        .await
        .unwrap();
    sqlx::query("INSERT INTO envelopes VALUES(1,0,1,'old-message',decode('010203','hex'))")
        .execute(&db)
        .await
        .unwrap();
    sqlx::query("UPDATE room_state SET sequence=1,used_bytes=3")
        .execute(&db)
        .await
        .unwrap();
    let result = Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
        .arg("key-admin-init")
        .env("PARANOID_DATABASE_URL", &url)
        .env("PARANOID_KEY_REALM", "https://127.0.0.2:38443")
        .env("PARANOID_KEY_PIN", "a".repeat(64))
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "explicit offline key-schema initialization must succeed"
    );
    let row: (i64, i64) = sqlx::query_as("SELECT sequence,used_bytes FROM room_state")
        .fetch_one(&db)
        .await
        .unwrap();
    assert_eq!(row, (1, 3));
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM envelopes")
            .fetch_one(&db)
            .await
            .unwrap(),
        1
    );
    assert!(
        paranoid_server::stored_app(db.clone(), ["a".repeat(64), "b".repeat(64)], 1048576)
            .await
            .is_err(),
        "v0 startup must fail, never revive bearer"
    );
    db.close().await;
    admin.close().await;
}
