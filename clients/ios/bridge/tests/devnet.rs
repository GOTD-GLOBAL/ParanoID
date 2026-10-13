//! Public/synthetic data only; no RPC or server calls.
use paranoid_ios_bridge::{paranoid_devnet_command, paranoid_devnet_free};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::ptr;

fn call(request: &str) -> Value {
    let request = CString::new(request).unwrap();
    raw(request.as_ptr())
}

fn raw(request: *const c_char) -> Value {
    // SAFETY: callers provide NULL or a live terminated input; reply freed once.
    unsafe {
        let output = paranoid_devnet_command(request);
        assert!(!output.is_null());
        let value = serde_json::from_slice(CStr::from_ptr(output).to_bytes()).unwrap();
        paranoid_devnet_free(output);
        value
    }
}

#[test]
fn public_identity_vectors_use_the_existing_rust_crypto() {
    for (entropy, owner) in [
        (
            "AAAAAAAAAAAAAAAAAAAAAA==",
            "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk",
        ),
        (
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "3Cy3YNTFywCmxoxt8n7UH6hg6dLo5uACowX3CFceaSnx",
        ),
    ] {
        let input = json!({"op":"identity", "entropy":entropy}).to_string();
        let identity = call(&input);
        assert_eq!(identity["owner"], owner);
        assert!(identity.get("entropy").is_none());
        assert_eq!(
            identity,
            serde_json::from_str::<Value>(&paranoid_devnet_client::command(&input)).unwrap()
        );
        let words = call(&json!({"op":"export_mnemonic", "entropy":entropy}).to_string());
        let recovered = call(&json!({"op":"recover", "mnemonic":words["mnemonic"]}).to_string());
        assert_eq!(recovered, json!({"entropy":entropy}));
    }
}

#[test]
fn malformed_requests_preserve_the_devnet_error_contract() {
    for input in [
        "",
        "not json",
        "{}",
        r#"{"op":"unknown"}"#,
        r#"{"op":"program_info","extra":true}"#,
        r#"{"op":"identity","op":"recover","entropy":"AAAA"}"#,
    ] {
        assert_eq!(call(input), json!({"error":"invalid_request"}));
    }
    assert_eq!(
        call(r#"{"op":"recover","mnemonic":"abandon abandon"}"#),
        json!({"error":"invalid_mnemonic"})
    );
    assert_eq!(
        call(r#"{"op":"identity","entropy":"AAAA"}"#),
        json!({"error":"invalid_entropy"})
    );
}

#[test]
fn null_and_invalid_utf8_follow_core_abi_errors() {
    assert_eq!(raw(ptr::null()), json!({"error":"invalid_request"}));
    let invalid = [0xffu8, 0xfe, 0];
    assert_eq!(
        raw(invalid.as_ptr().cast()),
        json!({"error":"invalid_request"})
    );
    // SAFETY: NULL is explicitly accepted by the free function.
    unsafe { paranoid_devnet_free(ptr::null_mut()) };
}

#[test]
fn size_boundary_is_bytes_not_characters() {
    let valid = r#"{"op":"program_info"}"#;
    let exact = format!("{valid: <16384}");
    assert_eq!(call(&exact), call(valid));
    assert_eq!(call(&(exact + " ")), json!({"error":"input_limit"}));
    assert_eq!(call(&"é".repeat(8193)), json!({"error":"input_limit"}));
    assert_eq!(call(&"x".repeat(16384)), json!({"error":"invalid_request"}));
}

#[test]
fn allocations_are_independent_and_each_can_be_freed_once() {
    let input = CString::new(r#"{"op":"program_info"}"#).unwrap();
    // SAFETY: input remains live; each distinct, unmodified reply freed once.
    unsafe {
        let a = paranoid_devnet_command(input.as_ptr());
        let b = paranoid_devnet_command(input.as_ptr());
        assert_ne!(a, b);
        let expected = CStr::from_ptr(a).to_bytes().to_vec();
        paranoid_devnet_free(a);
        assert_eq!(CStr::from_ptr(b).to_bytes(), expected);
        paranoid_devnet_free(b);
    }
}

#[test]
fn public_mnemonic_recovery_vector() {
    let mnemonic = format!("{} about", ["abandon"; 11].join(" "));
    assert_eq!(
        call(&json!({"op":"recover", "mnemonic":mnemonic}).to_string()),
        json!({"entropy":"AAAAAAAAAAAAAAAAAAAAAA=="})
    );
}
