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
use zeroize::{Zeroize, Zeroizing};

/// Runs the unchanged Devnet JSON command contract.
///
/// # Safety
/// `request` must be NULL or a readable NUL-terminated string valid throughout
/// the call. Release the unmodified returned string with `paranoid_devnet_free`.
#[no_mangle]
pub unsafe extern "C" fn paranoid_devnet_command(request: *const c_char) -> *mut c_char {
    // SAFETY: forwards the caller's pointer contract unchanged.
    unsafe { devnet_command_with(request, paranoid_devnet_client::command) }
}

// Internal injection point only for testing the unwind boundary, not an ABI.
unsafe fn devnet_command_with(
    request: *const c_char,
    command: impl FnOnce(&str) -> String + std::panic::UnwindSafe,
) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if request.is_null() {
            return r#"{"error":"invalid_request"}"#.to_owned();
        }
        // Scan at most limit + 1 bytes; reject before copying oversized input.
        // SAFETY: the caller guarantees a readable, terminated string. Stop at
        // the first NUL, so short buffers are never read beyond their terminator.
        let mut len = 0;
        while len <= DEVNET_REQUEST_LIMIT && unsafe { *request.add(len) } != 0 {
            len += 1;
        }
        if len > DEVNET_REQUEST_LIMIT {
            return r#"{"error":"input_limit"}"#.to_owned();
        }
        let bytes = unsafe { std::slice::from_raw_parts(request.cast::<u8>(), len) };
        match std::str::from_utf8(bytes) {
            Ok(request) => command(&Zeroizing::new(request.to_owned())),
            Err(_) => r#"{"error":"invalid_request"}"#.to_owned(),
        }
    });
    devnet_reply(Zeroizing::new(
        result.unwrap_or_else(|_| NATIVE_FAILURE.to_owned()),
    ))
}

fn devnet_reply(output: Zeroizing<String>) -> *mut c_char {
    let text = if output.as_bytes().contains(&0) {
        NATIVE_FAILURE
    } else {
        &output
    };
    // Allocate the final exact-sized C buffer BEFORE copying secrets. Growing
    // or shrinking a secret-bearing String could free an unwiped old allocation.
    let mut bytes = vec![0; text.len() + 1];
    bytes[..text.len()].copy_from_slice(text.as_bytes());
    // SAFETY: text has no interior NUL; the final byte is the only terminator.
    // len == capacity, so conversion to the boxed C string does not resize.
    unsafe { CString::from_vec_with_nul_unchecked(bytes) }.into_raw()
    // `output` wipes the original Rust-owned response, including spare capacity.
}

/// Overwrites and releases a Devnet reply. NULL is ignored.
///
/// # Safety
/// `text` must be NULL or an unmodified, not-yet-freed return value of
/// `paranoid_devnet_command`.
#[no_mangle]
pub unsafe extern "C" fn paranoid_devnet_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: ownership is returned exactly once by the caller.
        let mut bytes = unsafe { CString::from_raw(text) }.into_bytes_with_nul();
        bytes.zeroize();
    }
}

const DEVNET_REQUEST_LIMIT: usize = 16384;

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

#[cfg(test)]
mod devnet_tests {
    use super::*;

    fn take(output: *mut c_char) -> String {
        // SAFETY: tests pass only newly minted bridge replies.
        unsafe {
            let result = CStr::from_ptr(output).to_str().unwrap().to_owned();
            paranoid_devnet_free(output);
            result
        }
    }

    #[test]
    fn unwind_is_a_fixed_failure_not_a_panic_across_c() {
        let input = CString::new(r#"{"op":"program_info"}"#).unwrap();
        let output = unsafe { devnet_command_with(input.as_ptr(), |_| panic!("synthetic panic")) };
        assert_eq!(take(output), NATIVE_FAILURE);
    }

    #[test]
    fn reply_transfer_rejects_interior_nul_without_leaking_partial_text() {
        let output = devnet_reply(Zeroizing::new("synthetic\0invalid".to_owned()));
        assert_eq!(take(output), NATIVE_FAILURE);
    }
}
