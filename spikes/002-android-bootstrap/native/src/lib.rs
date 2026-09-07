//! Disposable local-only Android library probe. No network or production identity.
use vodozemac::olm::{Account, OlmMessage, Session, SessionConfig, SessionPickle};

pub fn probe() -> Result<(), String> {
    let alice = Account::new();
    let mut bob = Account::new();
    bob.generate_one_time_keys(1);
    let otk = *bob.one_time_keys().values().next().ok_or("No prekey")?;
    // Both peers are created in this process: there is NO remote trust protocol.
    let mut a = alice
        .create_outbound_session(
            SessionConfig::version_1(),
            bob.identity_keys().curve25519,
            otk,
        )
        .map_err(|e| e.to_string())?;
    let first = a.encrypt(b"[TEST DATA] hello").map_err(|e| e.to_string())?;
    let prekey = match &first {
        OlmMessage::PreKey(p) => p,
        _ => return Err("Expected prekey".into()),
    };
    let inbound = bob
        .create_inbound_session(
            SessionConfig::version_1(),
            alice.identity_keys().curve25519,
            prekey,
        )
        .map_err(|e| e.to_string())?;
    if inbound.plaintext != b"[TEST DATA] hello" {
        return Err("First plaintext mismatch".into());
    }
    let mut b = inbound.session;
    let reply = b.encrypt(b"[TEST DATA] reply").map_err(|e| e.to_string())?;
    if a.decrypt(&reply).map_err(|e| e.to_string())? != b"[TEST DATA] reply" {
        return Err("Reply mismatch".into());
    }
    let message = a
        .encrypt(b"[TEST DATA] integrity")
        .map_err(|e| e.to_string())?;
    if !matches!(message, OlmMessage::Normal(_)) {
        return Err("Expected normal message".into());
    }
    // Public test constant; no real data or persistent storage in this probe.
    let key = [42u8; 32];
    let snapshot = b.pickle().encrypt(&key);
    let (kind, bytes) = message.to_parts();
    for i in 0..bytes.len() {
        let mut altered = bytes.clone();
        altered[i] ^= 1;
        let mut restored = Session::from_pickle(
            SessionPickle::from_encrypted(&snapshot, &key).map_err(|e| e.to_string())?,
        );
        if let Ok(m) = OlmMessage::from_parts(kind, &altered) {
            if restored.decrypt(&m).is_ok() {
                return Err("Tampering accepted".into());
            }
        }
    }
    if b.decrypt(&message).map_err(|e| e.to_string())? != b"[TEST DATA] integrity" {
        return Err("Integrity plaintext mismatch".into());
    }
    if b.decrypt(&message).is_ok() {
        return Err("Duplicate accepted".into());
    }
    Ok(())
}

// Java owns the JNI handles. The probe does not read/write them or return secrets.
#[no_mangle]
pub extern "system" fn Java_org_paranoid_bootstrap_MainActivity_nativeProbe(
    _env: *mut std::ffi::c_void,
    _class: *mut std::ffi::c_void,
) -> i32 {
    match std::panic::catch_unwind(probe) {
        Ok(Ok(())) => 0,
        Ok(Err(_)) => 1,
        Err(_) => 2,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn fresh_accounts_roundtrip_and_reject_tampering() {
        assert_eq!(super::probe(), Ok(()));
    }
}
