use bip39::{Language, Mnemonic};
use ed25519_dalek::SigningKey;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::{
    IdentityError, hkdf_candidate,
    slip10_candidate::{self, EXPERIMENTAL_ACCOUNT_ROOT_PATH, SOLANA_REGISTRY_PATH},
};

/// Version of the public experiment-vector document.
pub const TEST_VECTOR_SCHEMA_VERSION: &str = "paranoid.identity.key-hierarchy.experiment.v1";

/// Candidate deterministic key hierarchies evaluated by the experiment.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DerivationCandidate {
    /// Derive account-root and registry-authority seeds with domain-separated HKDF.
    HkdfSha512V1,
    /// Use HKDF for the account root and a Solana-compatible SLIP-0010 registry path.
    HybridHkdfRootSolanaRegistryV1,
    /// Use separate hardened SLIP-0010 paths for the account root and registry authority.
    Slip10Ed25519V1,
}

impl DerivationCandidate {
    /// Stable candidate order used by the committed experiment vectors.
    pub const ALL: [Self; 3] = [
        Self::HkdfSha512V1,
        Self::HybridHkdfRootSolanaRegistryV1,
        Self::Slip10Ed25519V1,
    ];
}

/// Public-only result for one candidate key hierarchy.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublicIdentityVector {
    /// Schema governing this vector.
    pub schema_version: String,
    /// Candidate used for derivation.
    pub candidate: DerivationCandidate,
    /// Number of words in the input mnemonic.
    pub mnemonic_word_count: usize,
    /// Whether a non-empty BIP-39 passphrase affected the derivation.
    pub passphrase_used: bool,
    /// Hex-encoded Ed25519 account-root public key.
    pub account_root_public_key_hex: String,
    /// Hex-encoded Ed25519 Solana-registry-authority public key.
    pub registry_authority_public_key_hex: String,
    /// Hex-encoded public key at the Solana compatibility probe path.
    pub solana_compatibility_public_key_hex: String,
}

/// Input embedded in the committed public test-vector document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublicTestVectorInput {
    /// Public, fixed test entropy. It must never fund or control a real account.
    pub entropy_hex: String,
    /// Public, fixed test mnemonic generated from the entropy.
    pub mnemonic: String,
    /// Public test passphrase; empty for the baseline fixture.
    pub passphrase: String,
}

/// Reproducible public experiment document. It contains no production secret.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublicTestVectorDocument {
    /// Schema governing this document.
    pub schema_version: String,
    /// Safety warning for anyone opening the fixture.
    pub warning: String,
    /// Public test-only input.
    pub input: PublicTestVectorInput,
    /// Public outputs for every candidate.
    pub candidates: Vec<PublicIdentityVector>,
}

/// Derive public keys for one experimental candidate.
///
/// This API is research code. It is not an accepted ParanoID identity protocol.
pub fn derive_public_vector(
    mnemonic_text: &str,
    passphrase: &str,
    candidate: DerivationCandidate,
) -> Result<PublicIdentityVector, IdentityError> {
    let mnemonic = Mnemonic::parse_in(Language::English, mnemonic_text)
        .map_err(|_| IdentityError::InvalidMnemonic)?;
    let bip39_seed = Zeroizing::new(mnemonic.to_seed(passphrase));

    let solana_compatibility_seed =
        slip10_candidate::derive_ed25519_seed(bip39_seed.as_ref(), SOLANA_REGISTRY_PATH)?;

    let (account_root_seed, registry_authority_seed) = match candidate {
        DerivationCandidate::HkdfSha512V1 => (
            hkdf_candidate::derive_ed25519_seed(
                bip39_seed.as_ref(),
                hkdf_candidate::ACCOUNT_ROOT_INFO,
            )?,
            hkdf_candidate::derive_ed25519_seed(
                bip39_seed.as_ref(),
                hkdf_candidate::REGISTRY_AUTHORITY_INFO,
            )?,
        ),
        DerivationCandidate::HybridHkdfRootSolanaRegistryV1 => (
            hkdf_candidate::derive_ed25519_seed(
                bip39_seed.as_ref(),
                hkdf_candidate::ACCOUNT_ROOT_INFO,
            )?,
            Zeroizing::new(*solana_compatibility_seed),
        ),
        DerivationCandidate::Slip10Ed25519V1 => (
            slip10_candidate::derive_ed25519_seed(
                bip39_seed.as_ref(),
                EXPERIMENTAL_ACCOUNT_ROOT_PATH,
            )?,
            Zeroizing::new(*solana_compatibility_seed),
        ),
    };

    Ok(PublicIdentityVector {
        schema_version: TEST_VECTOR_SCHEMA_VERSION.to_owned(),
        candidate,
        mnemonic_word_count: mnemonic.word_count(),
        passphrase_used: !passphrase.is_empty(),
        account_root_public_key_hex: public_key_hex(&account_root_seed),
        registry_authority_public_key_hex: public_key_hex(&registry_authority_seed),
        solana_compatibility_public_key_hex: public_key_hex(&solana_compatibility_seed),
    })
}

/// Build the fixed, public, all-zero-entropy experiment document.
///
/// The returned mnemonic is a public fixture and must never control a real account.
pub fn fixed_public_test_vector_document() -> Result<PublicTestVectorDocument, IdentityError> {
    let entropy = [0_u8; 32];
    let mnemonic = Mnemonic::from_entropy(&entropy).map_err(|_| IdentityError::InvalidMnemonic)?;
    let mnemonic_text = mnemonic.to_string();
    let passphrase = String::new();
    let candidates = DerivationCandidate::ALL
        .into_iter()
        .map(|candidate| derive_public_vector(&mnemonic_text, &passphrase, candidate))
        .collect::<Result<Vec<_>, _>>()?;

    Ok(PublicTestVectorDocument {
        schema_version: TEST_VECTOR_SCHEMA_VERSION.to_owned(),
        warning: "PUBLIC TEST VECTOR ONLY; NEVER USE THIS MNEMONIC OR ENTROPY FOR AN ACCOUNT."
            .to_owned(),
        input: PublicTestVectorInput {
            entropy_hex: hex::encode(entropy),
            mnemonic: mnemonic_text,
            passphrase,
        },
        candidates,
    })
}

fn public_key_hex(secret_seed: &[u8; 32]) -> String {
    let signing_key = SigningKey::from_bytes(secret_seed);
    hex::encode(signing_key.verifying_key().to_bytes())
}
