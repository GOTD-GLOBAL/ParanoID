use paranoid_key_protocol::{digest, verify, Challenge, Credential};
use serde_json::Value;
#[test]
fn independent_python_vectors_match_rust_canonical_bytes_and_strict_ed25519() {
    let v: Value = serde_json::from_str(include_str!(
        "../../../docs/protocol/key-enrollment-v1-vectors.json"
    ))
    .unwrap();
    let c: Credential = serde_json::from_value(v["credential"].clone()).unwrap();
    let hex = |bytes: &[u8]| bytes.iter().map(|b| format!("{b:02x}")).collect::<String>();
    assert_eq!(hex(&c.bytes()), v["credential_bytes_hex"]);
    assert_eq!(c.fingerprint(), v["credential_fingerprint"]);
    c.verify().unwrap();
    let p: Challenge = serde_json::from_value(v["proof"].clone()).unwrap();
    assert_eq!(hex(&p.bytes()), v["proof_bytes_hex"]);
    verify(&c.auth, &p.bytes(), v["proof_signature"].as_str().unwrap()).unwrap();
    assert_ne!(digest(&c.bytes()), digest(&p.bytes()));
    assert!(verify(&c.root, &p.bytes(), v["proof_signature"].as_str().unwrap()).is_err());
    for n in 0..p.bytes().len() {
        let mut bytes = p.bytes();
        bytes[n] ^= 1;
        assert!(verify(&c.auth, &bytes, v["proof_signature"].as_str().unwrap()).is_err());
    }
}
