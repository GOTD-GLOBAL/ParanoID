use bip39::Mnemonic;
use paranoid_identity_core::{
    DerivationCandidate, IdentityError, PublicTestVectorDocument, derive_public_vector,
    fixed_public_test_vector_document,
};

const ZERO_ENTROPY_MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art";

#[test]
fn bip39_zero_entropy_fixture_is_stable() {
    let mnemonic = Mnemonic::from_entropy(&[0_u8; 32])
        .unwrap_or_else(|error| unreachable!("fixed entropy is valid: {error}"));
    assert_eq!(mnemonic.to_string(), ZERO_ENTROPY_MNEMONIC);
}

#[test]
fn every_candidate_is_deterministic_and_separates_root_from_registry() {
    for candidate in DerivationCandidate::ALL {
        let first = derive_public_vector(ZERO_ENTROPY_MNEMONIC, "", candidate)
            .unwrap_or_else(|error| unreachable!("fixture derivation succeeds: {error}"));
        let second = derive_public_vector(ZERO_ENTROPY_MNEMONIC, "", candidate)
            .unwrap_or_else(|error| unreachable!("fixture derivation succeeds: {error}"));

        assert_eq!(first, second);
        assert_ne!(
            first.account_root_public_key_hex,
            first.registry_authority_public_key_hex
        );
        assert_eq!(first.account_root_public_key_hex.len(), 64);
        assert_eq!(first.registry_authority_public_key_hex.len(), 64);
    }
}

#[test]
fn hybrid_and_slip10_candidates_use_the_solana_compatibility_path() {
    for candidate in [
        DerivationCandidate::HybridHkdfRootSolanaRegistryV1,
        DerivationCandidate::Slip10Ed25519V1,
    ] {
        let vector = derive_public_vector(ZERO_ENTROPY_MNEMONIC, "", candidate)
            .unwrap_or_else(|error| unreachable!("fixture derivation succeeds: {error}"));
        assert_eq!(
            vector.registry_authority_public_key_hex,
            vector.solana_compatibility_public_key_hex
        );
    }
}

#[test]
fn hkdf_registry_authority_is_not_the_solana_compatibility_path() {
    let vector = derive_public_vector(ZERO_ENTROPY_MNEMONIC, "", DerivationCandidate::HkdfSha512V1)
        .unwrap_or_else(|error| unreachable!("fixture derivation succeeds: {error}"));
    assert_ne!(
        vector.registry_authority_public_key_hex,
        vector.solana_compatibility_public_key_hex
    );
}

#[test]
fn passphrase_changes_every_public_authority() {
    for candidate in DerivationCandidate::ALL {
        let without_passphrase = derive_public_vector(ZERO_ENTROPY_MNEMONIC, "", candidate)
            .unwrap_or_else(|error| unreachable!("fixture derivation succeeds: {error}"));
        let with_passphrase =
            derive_public_vector(ZERO_ENTROPY_MNEMONIC, "PARANOID-EXPERIMENT", candidate)
                .unwrap_or_else(|error| unreachable!("fixture derivation succeeds: {error}"));

        assert_ne!(
            without_passphrase.account_root_public_key_hex,
            with_passphrase.account_root_public_key_hex
        );
        assert_ne!(
            without_passphrase.registry_authority_public_key_hex,
            with_passphrase.registry_authority_public_key_hex
        );
        assert_ne!(
            without_passphrase.solana_compatibility_public_key_hex,
            with_passphrase.solana_compatibility_public_key_hex
        );
    }
}

#[test]
fn invalid_mnemonic_is_rejected_without_fallback() {
    let result = derive_public_vector(
        "this is not a valid recovery mnemonic",
        "",
        DerivationCandidate::HkdfSha512V1,
    );
    assert_eq!(result, Err(IdentityError::InvalidMnemonic));
}

#[test]
fn generated_document_matches_the_committed_public_vector() {
    let committed: PublicTestVectorDocument = serde_json::from_str(include_str!(
        "../../../specs/protocol/identity/key-derivation-experiment-v1.json"
    ))
    .unwrap_or_else(|error| unreachable!("committed vector is valid JSON: {error}"));
    let generated = fixed_public_test_vector_document()
        .unwrap_or_else(|error| unreachable!("fixture derivation succeeds: {error}"));

    assert_eq!(generated, committed);
}
