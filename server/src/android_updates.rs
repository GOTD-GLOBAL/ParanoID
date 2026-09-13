//! Optional read-only RFC-0013 distribution; no database or registration authority.
#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture(std::path::PathBuf);
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn fixture() -> (Fixture, String) {
        use std::os::unix::fs::PermissionsExt;
        let root = std::path::PathBuf::from(std::env::var_os("HOME").unwrap())
            .join(format!(".apk-stream-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let bytes = b"immutable synthetic transport fixture";
        let hash = paranoid_key_protocol::digest(bytes);
        std::fs::write(root.join(format!("{hash}.apk")), bytes).unwrap();
        std::fs::write(
            root.join("android.json"),
            serde_json::json!({
                "schema":1,"package":"global.paranoid.messenger","version_code":26,
                "version_name":"size-test","min_sdk":26,"abi":"arm64-v8a",
                "apk_sha256":hash,"apk_size":bytes.len()
            })
            .to_string(),
        )
        .unwrap();
        (Fixture(root), hash)
    }
    #[tokio::test]
    async fn verified_snapshot_survives_source_mutation_and_holds_budget_until_body_drop() {
        let (root, hash) = fixture();
        let reads = std::sync::Arc::new(tokio::sync::Semaphore::new(2));
        let state = Publication {
            root: Some(root.0.clone()),
            reads: reads.clone(),
        };
        let uri: Uri = format!("/v2/updates/android/apk/{hash}").parse().unwrap();
        let a = download(State(state.clone()), uri.clone())
            .await
            .ok()
            .unwrap();
        let b = download(State(state.clone()), uri.clone())
            .await
            .ok()
            .unwrap();
        assert_eq!(reads.available_permits(), 0);
        assert!(download(State(state.clone()), uri.clone()).await.is_err());
        std::fs::write(root.0.join(format!("{hash}.apk")), b"corrupt after headers").unwrap();
        let bytes = axum::body::to_bytes(a.into_body(), 1024).await.unwrap();
        assert_eq!(paranoid_key_protocol::digest(&bytes), hash);
        drop(b); // cancellation releases snapshot + permit once blocking I/O ends
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while reads.available_permits() != 2 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert!(download(State(state), uri).await.is_err());
        assert_eq!(reads.available_permits(), 2);
        assert_eq!(std::fs::read_dir(&root.0).unwrap().count(), 2);
    }
    #[tokio::test]
    async fn dropping_unconsumed_large_body_releases_backpressured_worker() {
        let (root, _) = fixture();
        let dir = open_root(&root.0).unwrap();
        let raw = read_publication(&dir, "android.json", MAX_METADATA).unwrap();
        let manifest = parse(&raw).ok().unwrap();
        let snapshot = snapshot_apk(&dir, &manifest).unwrap();
        // Synthetic sparse transport bytes: more chunks than the bounded channel.
        snapshot.set_len((COPY_BUFFER * 8) as u64).unwrap();
        let reads = std::sync::Arc::new(tokio::sync::Semaphore::new(1));
        let body = snapshot_body(snapshot, reads.clone().try_acquire_owned().unwrap());
        assert_eq!(reads.available_permits(), 0);
        drop(body);
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while reads.available_permits() != 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert_eq!(std::fs::read_dir(&root.0).unwrap().count(), 2);
    }

    #[test]
    fn anonymous_snapshot_and_positive_signed_64_bit_size_contract() {
        let (root, _) = fixture();
        let dir = open_root(&root.0).unwrap();
        let raw = read_publication(&dir, "android.json", MAX_METADATA).unwrap();
        let manifest = parse(&raw).ok().unwrap();
        let snapshot = snapshot_apk(&dir, &manifest).unwrap();
        assert_eq!(snapshot.metadata().unwrap().nlink(), 0);
        assert_eq!(snapshot.metadata().unwrap().mode() & 0o777, 0o600);
        let mut value: serde_json::Value = serde_json::from_slice(&raw).unwrap();
        for size in [16777217_i64, 2147483648, i64::MAX] {
            value["apk_size"] = serde_json::json!(size);
            assert_eq!(
                parse(value.to_string().as_bytes()).ok().unwrap().apk_size,
                size
            );
        }
        for size in [
            serde_json::json!(0),
            serde_json::json!(-1),
            serde_json::json!(9223372036854775808_u64),
        ] {
            value["apk_size"] = size;
            assert!(parse(value.to_string().as_bytes()).is_err());
        }
    }

    #[tokio::test]
    async fn occupied_reader_budget_fails_closed_without_queueing() {
        let reads = std::sync::Arc::new(tokio::sync::Semaphore::new(2));
        let _a = reads.clone().try_acquire_owned().unwrap();
        let _b = reads.clone().try_acquire_owned().unwrap();
        let result = download(
            State(Publication { root: None, reads }),
            "/v2/updates/android".parse().unwrap(),
        )
        .await;
        assert!(matches!(
            result,
            Err(crate::Failure(
                StatusCode::SERVICE_UNAVAILABLE,
                "update_unavailable"
            ))
        ));
    }
    #[test]
    fn kernel_mount_guard_rejects_existing_proc_mount_without_mounting() {
        let root = File::open("/").unwrap();
        assert_eq!(
            open_child(&root, b"proc", true, true)
                .unwrap_err()
                .raw_os_error(),
            Some(18)
        );
        assert!(open_child(&root, b"proc", true, false).is_ok());
    }
}
use axum::{
    extract::State,
    http::{StatusCode, Uri},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};
use std::{
    ffi::CString,
    fs::File,
    io::{self, Read, Seek, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{ffi::OsStrExt, fs::MetadataExt},
    },
    path::{Path, PathBuf},
};

// Linux openat2 ABI (x86_64/aarch64 deployment targets). No fallback to a
// check-then-open pathname: unsupported kernels fail closed.
#[repr(C)]
struct OpenHow {
    flags: u64,
    mode: u64,
    resolve: u64,
}
unsafe extern "C" {
    fn syscall(number: std::ffi::c_long, ...) -> std::ffi::c_long;
    fn geteuid() -> u32;
}
fn open_child(parent: &File, name: &[u8], directory: bool, no_mount: bool) -> io::Result<File> {
    let name = CString::new(name).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    let how = OpenHow {
        // O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK; O_DIRECTORY for dirs.
        flags: 0x80000 | 0x20000 | 0x800 | if directory { 0x10000 } else { 0 },
        mode: 0,
        // RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS (includes magic links) | NO_XDEV.
        resolve: 8 | 4 | u64::from(no_mount),
    };
    // SAFETY: NUL-terminated name and initialized ABI struct live through call;
    // parent is a borrowed live fd. Only a successful owned fd becomes File.
    let fd = unsafe {
        syscall(
            437,
            parent.as_raw_fd(),
            name.as_ptr(),
            &how as *const OpenHow,
            std::mem::size_of::<OpenHow>(),
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_fd(fd as i32) })
}
fn open_root(path: &Path) -> io::Result<File> {
    let bad = || io::Error::from(io::ErrorKind::PermissionDenied);
    let bytes = path.as_os_str().as_bytes();
    if !path.is_absolute() {
        return Err(bad());
    }
    let parts: Vec<_> = bytes[1..].split(|b| *b == b'/').collect();
    if parts
        .iter()
        .any(|p| p.is_empty() || *p == b"." || *p == b".." || *p == b"data")
    {
        return Err(bad());
    }
    let uid = unsafe { geteuid() };
    let mut dir = File::open("/")?;
    for (i, part) in parts.iter().enumerate() {
        let last = i == parts.len() - 1;
        dir = open_child(&dir, part, true, last)?;
        let m = dir.metadata()?;
        if !m.is_dir()
            || (m.uid() != uid && m.uid() != 0)
            || m.mode() & 0o022 != 0
            || (last && (m.uid() != uid || m.mode() & 0o777 != 0o700))
        {
            return Err(bad());
        }
    }
    Ok(dir)
}
fn read_publication(dir: &File, name: &str, max: usize) -> io::Result<Vec<u8>> {
    let f = open_child(dir, name.as_bytes(), false, true)?;
    let m = f.metadata()?;
    if !m.is_file()
        || m.uid() != dir.metadata()?.uid()
        || m.nlink() != 1
        || m.mode() & 0o022 != 0
        || m.len() > max as u64
    {
        return Err(io::Error::from(io::ErrorKind::PermissionDenied));
    }
    let mut bytes = Vec::new();
    (&f).take(max as u64 + 1).read_to_end(&mut bytes)?;
    let after = f.metadata()?;
    if bytes.len() > max
        || bytes.len() as u64 != m.len()
        || after.len() != m.len()
        || after.nlink() != 1
        || after.uid() != m.uid()
        || after.mode() != m.mode()
        || after.mtime() != m.mtime()
        || after.mtime_nsec() != m.mtime_nsec()
        || after.ctime() != m.ctime()
        || after.ctime_nsec() != m.ctime_nsec()
    {
        return Err(io::Error::from(io::ErrorKind::InvalidData));
    }
    Ok(bytes)
}
// APK length has only the shared signed-64-bit representation bound, no size budget.
const COPY_BUFFER: usize = 64 * 1024;

fn snapshot_apk(dir: &File, manifest: &Manifest) -> io::Result<File> {
    use sha2::{Digest, Sha256};
    let bad = || io::Error::from(io::ErrorKind::InvalidData);
    let mut source = open_child(
        dir,
        format!("{}.apk", manifest.apk_sha256).as_bytes(),
        false,
        true,
    )?;
    let before = source.metadata()?;
    let size = manifest.apk_size as u64;
    if !before.is_file()
        || before.uid() != dir.metadata()?.uid()
        || before.nlink() != 1
        || before.mode() & 0o022 != 0
        || before.len() != size
    {
        return Err(bad());
    }
    // SAFETY: live directory fd and initialized writable statvfs ABI storage.
    let mut space = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    if unsafe { libc::fstatvfs(dir.as_raw_fd(), space.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let space = unsafe { space.assume_init() };
    if u128::from(space.f_bavail) * u128::from(space.f_frsize) < u128::from(size) {
        return Err(io::Error::from(io::ErrorKind::StorageFull));
    }
    // Anonymous inode on the held publication directory's filesystem. Never a
    // pathname in /tmp, never linked/published; closing the last fd reclaims it.
    // SAFETY: fixed NUL-terminated name, live directory fd, explicit mode.
    let fd = unsafe {
        libc::openat(
            dir.as_raw_fd(),
            c".".as_ptr(),
            libc::O_TMPFILE | libc::O_RDWR | libc::O_CLOEXEC,
            0o600,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut snapshot = unsafe { File::from_raw_fd(fd) };
    let mut hash = Sha256::new();
    let mut buffer = [0u8; COPY_BUFFER];
    let mut remaining = size;
    let started = std::time::Instant::now();
    while remaining != 0 {
        if started.elapsed() > std::time::Duration::from_secs(10) {
            return Err(io::Error::from(io::ErrorKind::TimedOut));
        }
        let want = remaining.min(COPY_BUFFER as u64) as usize;
        let n = source.read(&mut buffer[..want])?;
        if n == 0 {
            return Err(bad());
        }
        snapshot.write_all(&buffer[..n])?;
        hash.update(&buffer[..n]);
        remaining -= n as u64;
    }
    if source.read(&mut buffer[..1])? != 0 {
        return Err(bad());
    }
    let after = source.metadata()?;
    if after.len() != before.len()
        || after.nlink() != 1
        || after.uid() != before.uid()
        || after.mode() != before.mode()
        || after.mtime() != before.mtime()
        || after.mtime_nsec() != before.mtime_nsec()
        || after.ctime() != before.ctime()
        || after.ctime_nsec() != before.ctime_nsec()
        || format!("{:x}", hash.finalize()) != manifest.apk_sha256
    {
        return Err(bad());
    }
    snapshot.rewind()?;
    Ok(snapshot)
}

struct SnapshotBody {
    receiver: tokio::sync::mpsc::Receiver<io::Result<axum::body::Bytes>>,
    _permit: std::sync::Arc<tokio::sync::OwnedSemaphorePermit>,
}
impl futures_core::Stream for SnapshotBody {
    type Item = io::Result<axum::body::Bytes>;
    fn poll_next(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        self.receiver.poll_recv(cx)
    }
}
fn snapshot_body(mut file: File, permit: tokio::sync::OwnedSemaphorePermit) -> axum::body::Body {
    let permit = std::sync::Arc::new(permit);
    let worker_permit = permit.clone();
    let (sender, receiver) = tokio::sync::mpsc::channel(1);
    tokio::task::spawn_blocking(move || {
        // Keep the permit coupled to actual blocking I/O, even after the response
        // is cancelled. The receiver also holds it through response lifetime.
        let mut buffer = [0u8; COPY_BUFFER];
        while !sender.is_closed() {
            match file.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => {
                    if sender
                        .blocking_send(Ok(axum::body::Bytes::copy_from_slice(&buffer[..n])))
                        .is_err()
                    {
                        break;
                    }
                }
                Err(e) => {
                    let _ = sender.blocking_send(Err(e));
                    break;
                }
            }
        }
        drop(file); // close anonymous snapshot BEFORE releasing worker's permit
        drop(worker_permit);
    });
    axum::body::Body::from_stream(SnapshotBody {
        receiver,
        _permit: permit,
    })
}
const MAX_METADATA: usize = 8192;
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema: u32,
    package: String,
    version_code: i64,
    version_name: String,
    min_sdk: i32,
    abi: String,
    apk_sha256: String,
    apk_size: i64,
}
fn hex(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn parse(bytes: &[u8]) -> Result<Manifest, crate::Failure> {
    if bytes.len() > MAX_METADATA {
        return Err(invalid());
    }
    let m: Manifest = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    if m.schema != 1
        || m.package != "global.paranoid.messenger"
        || m.version_code <= 0
        || m.min_sdk <= 0
        || m.version_name.is_empty()
        || m.version_name.len() > 128
        || m.version_name.chars().any(char::is_control)
        || m.abi != "arm64-v8a"
        || !hex(&m.apk_sha256)
        || m.apk_size <= 0
    {
        return Err(invalid());
    }
    Ok(m)
}
fn invalid() -> crate::Failure {
    crate::Failure(StatusCode::SERVICE_UNAVAILABLE, "update_unavailable")
}
#[derive(Clone)]
struct Publication {
    root: Option<PathBuf>,
    reads: std::sync::Arc<tokio::sync::Semaphore>,
}
pub fn router(root: Option<PathBuf>) -> Router {
    Router::new()
        .route(
            "/v2/updates/android",
            get(download).head(|| async { StatusCode::METHOD_NOT_ALLOWED }),
        )
        .route(
            "/v2/updates/android/apk/{sha256}",
            get(download).head(|| async { StatusCode::METHOD_NOT_ALLOWED }),
        )
        .with_state(Publication {
            root,
            reads: std::sync::Arc::new(tokio::sync::Semaphore::new(2)),
        })
}
async fn download(State(s): State<Publication>, uri: Uri) -> Result<Response, crate::Failure> {
    let permit = s.reads.try_acquire_owned().map_err(|_| invalid())?;

    tokio::task::spawn_blocking(move || {
        // Keep the bound even if the outer global handler timeout cancels its wait.
        publication(s.root, uri, permit)
    })
    .await
    .map_err(|_| invalid())?
}
fn publication(
    root: Option<PathBuf>,
    uri: Uri,
    permit: tokio::sync::OwnedSemaphorePermit,
) -> Result<Response, crate::Failure> {
    if uri.query().is_some() {
        return Ok(StatusCode::NOT_FOUND.into_response());
    }
    let requested = uri.path().strip_prefix("/v2/updates/android/apk/");
    if requested.is_some_and(|s| !hex(s)) {
        return Ok(StatusCode::NOT_FOUND.into_response());
    }
    let Some(root) = root else {
        return Ok(StatusCode::NOT_FOUND.into_response());
    };
    let dir = match open_root(&root) {
        Ok(dir) => dir,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Ok(StatusCode::NOT_FOUND.into_response())
        }
        Err(_) => return Err(invalid()),
    };
    let metadata = match read_publication(&dir, "android.json", MAX_METADATA) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Ok(StatusCode::NOT_FOUND.into_response())
        }
        Err(_) => return Err(invalid()),
    };
    let manifest = parse(&metadata)?;
    if requested.is_some_and(|s| s != manifest.apk_sha256) {
        return Ok(StatusCode::NOT_FOUND.into_response());
    }
    let apk = snapshot_apk(&dir, &manifest).map_err(|_| invalid())?;
    if uri.path() == "/v2/updates/android" {
        Ok(([("content-type", "application/json")], metadata).into_response())
    } else {
        let body = snapshot_body(apk, permit);
        Response::builder()
            .header("content-type", "application/vnd.android.package-archive")
            .header("content-length", manifest.apk_size.to_string())
            .body(body)
            .map_err(|_| invalid())
    }
}
