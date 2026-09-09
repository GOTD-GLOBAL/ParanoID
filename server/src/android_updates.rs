//! Optional read-only RFC-0013 distribution; no database or registration authority.
#[cfg(test)]
mod tests {
    use super::*;
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
    io::{self, Read},
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
const MAX_APK: usize = 16 * 1024 * 1024;
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
    apk_size: usize,
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
        || m.package != "org.paranoid.devtext"
        || m.version_code <= 0
        || m.min_sdk <= 0
        || m.version_name.is_empty()
        || m.version_name.len() > 128
        || m.version_name.chars().any(char::is_control)
        || m.abi != "arm64-v8a"
        || !hex(&m.apk_sha256)
        || !(1..=MAX_APK).contains(&m.apk_size)
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
        let _permit = permit;

        publication(s.root, uri)
    })
    .await
    .map_err(|_| invalid())?
}
fn publication(root: Option<PathBuf>, uri: Uri) -> Result<Response, crate::Failure> {
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
    let apk = read_publication(&dir, &format!("{}.apk", manifest.apk_sha256), MAX_APK)
        .map_err(|_| invalid())?;
    if apk.len() != manifest.apk_size || paranoid_key_protocol::digest(&apk) != manifest.apk_sha256
    {
        return Err(invalid());
    }
    if uri.path() == "/v2/updates/android" {
        Ok(([("content-type", "application/json")], metadata).into_response())
    } else {
        Ok((
            [("content-type", "application/vnd.android.package-archive")],
            apk,
        )
            .into_response())
    }
}
