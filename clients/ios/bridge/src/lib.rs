//! C ABI shim over `paranoid-client-core` for the iOS client.
//!
//! Mirrors the Android JNI adapter (`clients/core/src/lib.rs`, the
//! `Java_org_paranoid_text_CoreBridge_command` export): the core keeps its
//! state/network/storage boundaries and its input limits (8 MiB state,
//! 65536-byte request) inside `paranoid_client_core::command`; this crate only
//! converts C strings, catches panics and never lets the JSON contract leak
//! Rust-side failures as a crash. The Swift adapter must encrypt and
//! atomically persist the returned `state` BEFORE any network side effect.
use serde_json::json;
use std::ffi::{c_char, CStr, CString};

const NATIVE_FAILURE: &str = r#"{"error":"native_failure"}"#;

/// Runs one core command.
///
/// `state` and `request` must be NUL-terminated UTF-8 JSON documents (`state`
/// may be the empty string for a fresh identity). Returns a NUL-terminated
/// JSON document that the caller releases with [`paranoid_core_free`]; it is
/// never NULL. A NULL or non-UTF-8 argument yields `{"error":"invalid_request"}`
/// and a core panic yields `{"error":"native_failure"}`.
///
/// # Safety
///
/// Every non-NULL pointer must point to a readable NUL-terminated string that
/// stays valid for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn paranoid_core_command(
    state: *const c_char,
    request: *const c_char,
) -> *mut c_char {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(
        || -> Result<String, &'static str> {
            if state.is_null() || request.is_null() {
                return Err("invalid_request");
            }
            // SAFETY: both pointers are non-NULL and the caller guarantees they
            // address NUL-terminated strings that outlive this call.
            let state = unsafe { CStr::from_ptr(state) }
                .to_str()
                .map_err(|_| "invalid_request")?;
            let request = unsafe { CStr::from_ptr(request) }
                .to_str()
                .map_err(|_| "invalid_request")?;
            paranoid_client_core::command(state, request)
        },
    ));
    let text = match result {
        Ok(Ok(output)) => output,
        Ok(Err(error)) => json!({"error":error}).to_string(),
        Err(_) => NATIVE_FAILURE.to_owned(),
    };
    CString::new(text)
        .map(CString::into_raw)
        .unwrap_or_else(|_| CString::new(NATIVE_FAILURE).unwrap().into_raw())
}

/// Releases a string returned by [`paranoid_core_command`]. NULL is ignored.
///
/// # Safety
///
/// `text` must be NULL or a pointer obtained from [`paranoid_core_command`]
/// that has not been freed yet.
#[no_mangle]
pub unsafe extern "C" fn paranoid_core_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the caller passes a pointer minted by `CString::into_raw` in
        // `paranoid_core_command` exactly once.
        unsafe { drop(CString::from_raw(text)) }
    }
}
