//! Host-side checks of the C ABI shim through the `rlib` (the same symbols the
//! staticlib exports to Swift).
use paranoid_ios_bridge::{paranoid_core_command, paranoid_core_free};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::ptr;

const REALM: &str = "https://127.0.0.2:38443";
const REQUEST_LIMIT: usize = 65536;

/// Calls the shim with raw pointers and returns the owned reply text.
fn raw(state: *const c_char, request: *const c_char) -> String {
    // SAFETY: the pointers are NULL or NUL-terminated strings owned by the
    // caller for the duration of the call.
    let output = unsafe { paranoid_core_command(state, request) };
    assert!(!output.is_null(), "reply must never be NULL");
    // SAFETY: `output` was minted by the shim and is released exactly once.
    let text = unsafe { CStr::from_ptr(output) }
        .to_str()
        .expect("reply must be UTF-8")
        .to_owned();
    unsafe { paranoid_core_free(output) };
    text
}

fn call(state: &str, request: &str) -> Value {
    let state = CString::new(state).unwrap();
    let request = CString::new(request).unwrap();
    serde_json::from_str(&raw(state.as_ptr(), request.as_ptr())).expect("reply must be JSON")
}

#[test]
fn create_identity_from_empty_state_then_upgrade_v2() {
    let created = call(
        "",
        &json!({"op":"create_identity","realm":REALM,"pin":"a".repeat(64)}).to_string(),
    );
    assert!(created.get("error").is_none(), "create failed: {created}");
    assert_eq!(created["state"]["version"], 0);
    let upgraded = call(
        &created["state"].to_string(),
        &json!({"op":"upgrade_v2"}).to_string(),
    );
    assert!(
        upgraded.get("error").is_none(),
        "upgrade failed: {upgraded}"
    );
    assert_eq!(upgraded["state"]["version"], 3);
}

#[test]
fn garbage_request_is_invalid_request() {
    assert_eq!(call("", "not json"), json!({"error":"invalid_request"}));
    assert_eq!(
        call("garbage state", &json!({"op":"upgrade_v2"}).to_string()),
        json!({"error":"invalid_state"})
    );
}

#[test]
fn request_over_limit_is_input_limit() {
    let request = "a".repeat(REQUEST_LIMIT + 1);
    assert_eq!(call("", &request), json!({"error":"input_limit"}));
    let exact: Value = call("", &"a".repeat(REQUEST_LIMIT));
    assert_eq!(exact, json!({"error":"invalid_request"}));
}

#[test]
fn null_arguments_are_invalid_request() {
    let empty = CString::new("").unwrap();
    for (state, request) in [
        (ptr::null(), empty.as_ptr()),
        (empty.as_ptr(), ptr::null()),
        (ptr::null(), ptr::null()),
    ] {
        assert_eq!(raw(state, request), r#"{"error":"invalid_request"}"#);
    }
}

#[test]
fn non_utf8_arguments_are_invalid_request() {
    let bad = [0xffu8, 0xfe, 0];
    let empty = CString::new("").unwrap();
    let bad_ptr = bad.as_ptr() as *const c_char;
    assert_eq!(
        raw(bad_ptr, empty.as_ptr()),
        r#"{"error":"invalid_request"}"#
    );
    assert_eq!(
        raw(empty.as_ptr(), bad_ptr),
        r#"{"error":"invalid_request"}"#
    );
}

#[test]
fn free_null_is_a_no_op() {
    // SAFETY: NULL is explicitly accepted by the shim.
    unsafe { paranoid_core_free(ptr::null_mut()) };
}
