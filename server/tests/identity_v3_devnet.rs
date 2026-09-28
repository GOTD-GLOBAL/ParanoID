//! Live read-only Devnet check of the real registry verifier (no wallet, no signing,
//! no transaction). Ignored by default because it needs public network access:
//! `cargo test --test identity_v3_devnet -- --ignored`.
use paranoid_key_protocol::identity_v3::base58_decode32;
use paranoid_server::identity_v3::{DevnetRegistry, RegistryFailure, RegistryVerifier, DEVNET_RPC};

const OWNER: &str = "n2NGZdM6KZFJE1bBghSapYaMqZM1sb6J1x7CLYei5QJ";

#[tokio::test]
#[ignore = "public Devnet network access"]
async fn live_devnet_registry_accepts_real_name_and_rejects_others() {
    let registry = DevnetRegistry::new(DEVNET_RPC).unwrap();
    let owner = base58_decode32(OWNER).unwrap();
    assert_eq!(registry.verify(owner, "p28_accept_0922").await, Ok(()));
    assert_eq!(
        registry.verify(owner, "p28_accept_0923").await,
        Err(RegistryFailure::Invalid),
        "a name this owner does not hold"
    );
    let mut stranger = owner;
    stranger[0] ^= 1;
    assert_eq!(
        registry.verify(stranger, "p28_accept_0922").await,
        Err(RegistryFailure::Invalid),
        "the real name under a different owner"
    );
}

#[test]
fn registry_rpc_must_be_https() {
    assert!(DevnetRegistry::new("http://api.devnet.solana.com").is_err());
}
