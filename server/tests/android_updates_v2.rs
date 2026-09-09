//! Disposable private-DB integration; run through scripts/check-server.py.
use std::{fs, os::unix::fs::PermissionsExt};
#[tokio::test]
async fn optional_environment_feed_is_v2_only_and_shares_ingress_budget() {
    let base = std::env::var("PARANOID_TEST_DATABASE_URL").unwrap();
    let admin = sqlx::postgres::PgPoolOptions::new()
        .max_connections(1)
        .connect(&base)
        .await
        .unwrap();
    let name = format!("update_{}", uuid::Uuid::new_v4().simple());
    sqlx::QueryBuilder::<sqlx::Postgres>::new("CREATE DATABASE ")
        .push(&name)
        .build()
        .execute(&admin)
        .await
        .unwrap();
    admin.close().await;
    let db = sqlx::postgres::PgPoolOptions::new()
        .max_connections(2)
        .connect(&base.replace("/postgres?", &format!("/{name}?")))
        .await
        .unwrap();
    sqlx::raw_sql(include_str!("../self-service-schema.sql"))
        .execute(&db)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO ss_meta(id,version,realm,pin) VALUES(1,2,'https://127.0.0.1:38443',$1)",
    )
    .bind("a".repeat(64))
    .execute(&db)
    .await
    .unwrap();
    let root = std::path::PathBuf::from(std::env::var_os("HOME").unwrap())
        .join(format!(".update-integration-{}", uuid::Uuid::new_v4()));
    fs::create_dir(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    let hash = paranoid_key_protocol::digest(b"APK fixture");
    fs::write(root.join(format!("{hash}.apk")), b"APK fixture").unwrap();
    fs::write(root.join("android.json"), serde_json::json!({"schema":1,"package":"org.paranoid.devtext","version_code":6,"version_name":"0.0.6","min_sdk":26,"abi":"arm64-v8a","apk_sha256":hash,"apk_size":11}).to_string()).unwrap();
    // Only this integration-test binary mutates its process environment.
    std::env::set_var("PARANOID_ANDROID_UPDATE_ROOT", &root);
    let app = paranoid_server::self_service::app(db.clone())
        .await
        .unwrap();
    std::env::remove_var("PARANOID_ANDROID_UPDATE_ROOT");
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", l.local_addr().unwrap());
    let task = tokio::spawn(async move {
        axum::serve(l, app).await.unwrap();
    });
    let c = reqwest::Client::new();
    assert_eq!(
        c.get(format!("{url}/v2/updates/android"))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(
        c.get(format!("{url}/v2/messages"))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        c.post(format!("{url}/v2/registration/challenge"))
            .body("{}")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        c.get(format!("{url}/v1/updates/android"))
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
    let mut limited = false;
    for _ in 0..30 {
        limited |= c
            .get(format!("{url}/v2/updates/android"))
            .send()
            .await
            .unwrap()
            .status()
            == 429;
    }
    assert!(limited, "update routes must share global ingress budget");
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM ss_accounts")
            .fetch_one(&db)
            .await
            .unwrap(),
        0
    );
    task.abort();
    db.close().await;
    fs::remove_dir_all(root).unwrap();
}
