use paranoid_key_protocol::digest;
use paranoid_server::android_updates;
use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf};
struct Feed {
    root: PathBuf,
    bytes: Vec<u8>,
}
impl Feed {
    fn new() -> Self {
        let root = PathBuf::from(std::env::var_os("HOME").unwrap())
            .join(format!(".update-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let f = Self {
            root,
            bytes: b"synthetic APK transport fixture\0\xff".to_vec(),
        };
        f.publish();
        f
    }
    fn manifest(&self) -> serde_json::Value {
        serde_json::json!({"schema":1,"package":"org.paranoid.devtext","version_code":6,"version_name":"0.0.6","min_sdk":28,"abi":"arm64-v8a","apk_sha256":digest(&self.bytes),"apk_size":self.bytes.len()})
    }
    fn publish(&self) {
        fs::write(
            self.root.join(format!("{}.apk", digest(&self.bytes))),
            &self.bytes,
        )
        .unwrap();
        fs::write(self.root.join("android.json"), self.manifest().to_string()).unwrap();
    }
    async fn serve(&self) -> (String, tokio::task::JoinHandle<()>) {
        serve(android_updates::router(Some(self.root.clone()))).await
    }
}
impl Drop for Feed {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
async fn serve(router: axum::Router) -> (String, tokio::task::JoinHandle<()>) {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", l.local_addr().unwrap());
    (
        url,
        tokio::spawn(async move {
            axum::serve(l, router).await.unwrap();
        }),
    )
}
async fn status(root: Option<PathBuf>, route: &str) -> (u16, Vec<u8>) {
    let (url, task) = serve(android_updates::router(root)).await;
    let r = reqwest::get(format!("{url}{route}")).await.unwrap();
    assert!(r.headers().get("location").is_none());
    assert!(r.headers().get("set-cookie").is_none());
    let code = r.status().as_u16();
    let bytes = r.bytes().await.unwrap().to_vec();
    task.abort();
    (code, bytes)
}
#[tokio::test]
async fn rejects_invalid_metadata_with_static_error() {
    let f = Feed::new();
    let mut cases = Vec::new();
    for (key, value) in [
        ("schema", serde_json::json!(2)),
        ("package", serde_json::json!("evil")),
        ("version_code", serde_json::json!(0)),
        ("min_sdk", serde_json::json!(-1)),
        ("abi", serde_json::json!("x86")),
        ("apk_sha256", serde_json::json!("../secret")),
        ("apk_size", serde_json::json!(16777217)),
        ("version_name", serde_json::json!("")),
        ("version_name", serde_json::json!("bad\nname")),
        ("version_name", serde_json::json!("bad\u{0085}name")),
        ("version_name", serde_json::json!("x".repeat(129))),
        ("url", serde_json::json!("https://secret.invalid")),
        ("apk_size", serde_json::json!(0)),
        ("version_code", serde_json::json!(1.5)),
    ] {
        let mut m = f.manifest();
        m[key] = value;
        cases.push(m.to_string().into_bytes());
    }
    cases.extend([
        b"{}".to_vec(),
        b"[1]".to_vec(),
        b"\xff".to_vec(),
        vec![b' '; 8193],
        f.manifest()
            .to_string()
            .replacen("{", "{\"schema\":1,", 1)
            .into_bytes(),
    ]);
    for input in cases {
        fs::write(f.root.join("android.json"), &input).unwrap();
        let (code, bytes) = status(Some(f.root.clone()), "/v2/updates/android").await;
        assert_eq!(code, 503, "input {:?}", input);
        assert_eq!(bytes, b"{\"error\":\"update_unavailable\"}");
    }
}
#[tokio::test]
async fn absent_feed_unknown_paths_queries_and_wrong_digest_never_select_files() {
    let f = Feed::new();
    assert_eq!(status(None, "/v2/updates/android").await.0, 404);
    for path in [
        "/v2/updates/android?file=secret",
        "/v2/updates/android/apk/android.json",
        "/v2/updates/android/apk/%2e%2e%2fsecret",
        "/v1/updates/android",
        "/v2/updates/android/apk/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "/v2/updates/android/apk/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ] {
        assert_eq!(status(Some(f.root.clone()), path).await.0, 404, "{path}");
    }
    fs::remove_file(f.root.join("android.json")).unwrap();
    assert_eq!(
        status(Some(f.root.clone()), "/v2/updates/android").await.0,
        404
    );
    assert_eq!(
        status(
            Some(f.root.clone()),
            &format!("/v2/updates/android/apk/{}", digest(&f.bytes))
        )
        .await
        .0,
        404
    );
}
#[tokio::test]
async fn actual_apk_hash_size_and_limits_are_checked_before_metadata_or_apk() {
    let f = Feed::new();
    let apk = f.root.join(format!("{}.apk", digest(&f.bytes)));
    for bytes in [
        vec![],
        vec![b'x'; f.bytes.len()],
        vec![b'x'; f.bytes.len() + 1],
        vec![0; 16777217],
    ] {
        fs::write(&apk, bytes).unwrap();
        for route in [
            "/v2/updates/android".to_owned(),
            format!("/v2/updates/android/apk/{}", digest(&f.bytes)),
        ] {
            assert_eq!(
                status(Some(f.root.clone()), &route).await,
                (503, b"{\"error\":\"update_unavailable\"}".to_vec())
            );
        }
    }
    fs::remove_file(apk).unwrap();
    assert_eq!(
        status(Some(f.root.clone()), "/v2/updates/android").await.0,
        503
    );
}
#[tokio::test]
async fn rejects_symlink_hardlink_directory_fifo_and_unsafe_root_substitution() {
    use std::os::unix::fs::symlink;
    let f = Feed::new();
    let other = Feed::new();
    for name in [
        "android.json".to_owned(),
        format!("{}.apk", digest(&f.bytes)),
    ] {
        let p = f.root.join(&name);
        for kind in ["symlink", "hardlink", "directory", "fifo"] {
            fs::remove_file(&p).unwrap();
            match kind {
                "symlink" => symlink(other.root.join(&name), &p).unwrap(),
                "hardlink" => fs::hard_link(other.root.join(&name), &p).unwrap(),
                "directory" => fs::create_dir(&p).unwrap(),
                _ => {
                    assert!(std::process::Command::new("mkfifo")
                        .arg(&p)
                        .status()
                        .unwrap()
                        .success());
                }
            }
            let check = tokio::time::timeout(
                std::time::Duration::from_secs(2),
                status(Some(f.root.clone()), "/v2/updates/android"),
            )
            .await;
            assert_eq!(check.unwrap().0, 503, "{name} {kind}");
            if kind == "directory" {
                fs::remove_dir(&p).unwrap();
            } else {
                fs::remove_file(&p).unwrap();
            }
            f.publish();
        }
    }
    fs::set_permissions(&f.root, fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(
        status(Some(f.root.clone()), "/v2/updates/android").await.0,
        503
    );
    fs::set_permissions(&f.root, fs::Permissions::from_mode(0o700)).unwrap();
    let (url, task) = f.serve().await;
    let moved = f.root.with_extension("moved");
    fs::rename(&f.root, &moved).unwrap();
    symlink(&other.root, &f.root).unwrap();
    assert_eq!(
        reqwest::get(format!("{url}/v2/updates/android"))
            .await
            .unwrap()
            .status(),
        503
    );
    fs::remove_file(&f.root).unwrap();
    fs::rename(&moved, &f.root).unwrap();
    task.abort();
    let data = f.root.join("data");
    fs::create_dir(&data).unwrap();
    fs::set_permissions(&data, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(data.join("android.json"), f.manifest().to_string()).unwrap();
    fs::write(data.join(format!("{}.apk", digest(&f.bytes))), &f.bytes).unwrap();
    assert_eq!(status(Some(data), "/v2/updates/android").await.0, 503);
}
#[tokio::test]
async fn exact_size_boundaries_are_served_and_mutation_after_check_is_rejected() {
    let mut f = Feed::new();
    f.bytes = vec![0xa5; 16777216];
    f.publish();
    let mut metadata = f.manifest().to_string();
    metadata.extend(std::iter::repeat_n(' ', 8192 - metadata.len()));
    fs::write(f.root.join("android.json"), metadata.as_bytes()).unwrap();
    let (code, raw) = status(Some(f.root.clone()), "/v2/updates/android").await;
    assert_eq!(code, 200);
    assert_eq!(raw.len(), 8192);
    let route = format!("/v2/updates/android/apk/{}", digest(&f.bytes));
    let (code, raw) = status(Some(f.root.clone()), &route).await;
    assert_eq!(code, 200);
    assert_eq!(raw, f.bytes);
    fs::write(
        f.root.join(format!("{}.apk", digest(&f.bytes))),
        b"substitution",
    )
    .unwrap();
    assert_eq!(status(Some(f.root.clone()), &route).await.0, 503);
}
#[tokio::test]
#[ignore = "explicit build-host APK snapshot only; set PARANOID_TEST_APK"]
async fn actual_build_apk_snapshot_roundtrips_exact_bytes_and_digest() {
    let mut f = Feed::new();
    // Read the moving build output ONCE; all subsequent checks use this snapshot.
    f.bytes = fs::read(std::env::var_os("PARANOID_TEST_APK").expect("APK path required")).unwrap();
    assert!(!f.bytes.is_empty() && f.bytes.len() <= 16777216);
    f.publish();
    let route = format!("/v2/updates/android/apk/{}", digest(&f.bytes));
    let (code, raw) = status(Some(f.root.clone()), &route).await;
    assert_eq!(code, 200);
    assert_eq!(raw, f.bytes);
    assert_eq!(digest(&raw), digest(&f.bytes));
    println!(
        "actual APK snapshot: bytes={} sha256={}",
        raw.len(),
        digest(&raw)
    );
}
#[tokio::test]
async fn only_get_is_supported_and_legacy_router_has_no_update_routes() {
    let f = Feed::new();
    let (url, task) = f.serve().await;
    let c = reqwest::Client::new();
    for method in [
        reqwest::Method::POST,
        reqwest::Method::HEAD,
        reqwest::Method::PUT,
        reqwest::Method::DELETE,
    ] {
        assert_eq!(
            c.request(method, format!("{url}/v2/updates/android"))
                .send()
                .await
                .unwrap()
                .status(),
            405
        );
    }
    task.abort();
    let (url, task) = serve(paranoid_server::app()).await;
    assert_eq!(
        reqwest::get(format!("{url}/v2/updates/android"))
            .await
            .unwrap()
            .status(),
        404
    );
    task.abort();
}
#[tokio::test]
async fn android_long_version_code_is_supported() {
    let f = Feed::new();
    let mut m = f.manifest();
    m["version_code"] = serde_json::json!(2147483648_i64);
    fs::write(f.root.join("android.json"), m.to_string()).unwrap();
    assert_eq!(
        status(Some(f.root.clone()), "/v2/updates/android").await.0,
        200
    );
}
#[tokio::test]
async fn valid_feed_returns_exact_metadata_and_hash_checked_apk() {
    let f = Feed::new();
    let (url, task) = f.serve().await;
    let c = reqwest::Client::new();
    let r = c
        .get(format!("{url}/v2/updates/android"))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 200);
    assert_eq!(r.json::<serde_json::Value>().await.unwrap(), f.manifest());
    let r = c
        .get(format!("{url}/v2/updates/android/apk/{}", digest(&f.bytes)))
        .send()
        .await
        .unwrap();
    assert_eq!(r.status(), 200);
    assert_eq!(
        r.headers()["content-type"],
        "application/vnd.android.package-archive"
    );
    assert_eq!(r.content_length(), Some(f.bytes.len() as u64));
    let bytes = r.bytes().await.unwrap();
    assert_eq!(bytes.as_ref(), f.bytes);
    assert_eq!(digest(&bytes), digest(&f.bytes));
    task.abort();
}
