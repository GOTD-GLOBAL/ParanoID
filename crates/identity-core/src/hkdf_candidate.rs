use hkdf::Hkdf;
use sha2::Sha512;
use zeroize::Zeroizing;

use crate::IdentityError;

const EXPERIMENT_SALT: &[u8] = b"ParanoID identity-core key hierarchy experiment v1";
pub(crate) const ACCOUNT_ROOT_INFO: &[u8] =
    b"paranoid.identity.experiment.v1/account-root/ed25519-seed";
pub(crate) const REGISTRY_AUTHORITY_INFO: &[u8] =
    b"paranoid.identity.experiment.v1/solana-registry-authority/ed25519-seed";

pub(crate) fn derive_ed25519_seed(
    bip39_seed: &[u8],
    purpose: &[u8],
) -> Result<Zeroizing<[u8; 32]>, IdentityError> {
    let hkdf = Hkdf::<Sha512>::new(Some(EXPERIMENT_SALT), bip39_seed);
    let mut derived = Zeroizing::new([0_u8; 32]);
    hkdf.expand(purpose, derived.as_mut())
        .map_err(|_| IdentityError::KeyDerivationFailed)?;

    Ok(derived)
}
