use std::process::Command;

#[test]
fn alpha_without_tls_fails_before_database() {
    let output = Command::new(env!("CARGO_BIN_EXE_paranoid-server"))
        .env_clear()
        .env("PARANOID_MODE", "closed-alpha-v0")
        .env("PARANOID_BIND", "0.0.0.0:38443")
        .output()
        .unwrap();
    assert!(!output.status.success());
    // A static stage code distinguishes an intentional deployment gate, no secrets.
    assert!(String::from_utf8_lossy(&output.stderr).contains("invalid TLS configuration"));
}
