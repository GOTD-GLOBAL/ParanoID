use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha512;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::IdentityError;

const ED25519_MASTER_KEY: &[u8] = b"ed25519 seed";
const HARDENED_OFFSET: u32 = 1 << 31;

pub(crate) const EXPERIMENTAL_ACCOUNT_ROOT_PATH: &[u32] = &[0];
pub(crate) const SOLANA_REGISTRY_PATH: &[u32] = &[44, 501, 0, 0];

type HmacSha512 = Hmac<Sha512>;

#[derive(Zeroize, ZeroizeOnDrop)]
struct ExtendedPrivateKey {
    secret_key: [u8; 32],
    chain_code: [u8; 32],
}

pub(crate) fn derive_ed25519_seed(
    seed: &[u8],
    path: &[u32],
) -> Result<Zeroizing<[u8; 32]>, IdentityError> {
    let node = derive_extended_private_key(seed, path)?;
    Ok(Zeroizing::new(node.secret_key))
}

fn derive_extended_private_key(
    seed: &[u8],
    path: &[u32],
) -> Result<ExtendedPrivateKey, IdentityError> {
    let master = hmac_sha512(ED25519_MASTER_KEY, seed)?;
    let mut node = split_extended_key(&master);

    for index in path {
        node = derive_hardened_child(&node, *index)?;
    }

    Ok(node)
}

fn derive_hardened_child(
    parent: &ExtendedPrivateKey,
    index: u32,
) -> Result<ExtendedPrivateKey, IdentityError> {
    let hardened_index = index
        .checked_add(HARDENED_OFFSET)
        .ok_or(IdentityError::InvalidSlip10Index)?;
    let mut data = Zeroizing::new([0_u8; 37]);
    data[1..33].copy_from_slice(&parent.secret_key);
    data[33..].copy_from_slice(&hardened_index.to_be_bytes());

    let child = hmac_sha512(&parent.chain_code, data.as_ref())?;
    Ok(split_extended_key(&child))
}

fn hmac_sha512(key: &[u8], data: &[u8]) -> Result<Zeroizing<[u8; 64]>, IdentityError> {
    let mut mac =
        HmacSha512::new_from_slice(key).map_err(|_| IdentityError::KeyDerivationFailed)?;
    mac.update(data);
    let bytes = mac.finalize().into_bytes();
    let mut result = Zeroizing::new([0_u8; 64]);
    result.copy_from_slice(&bytes);
    Ok(result)
}

fn split_extended_key(bytes: &[u8; 64]) -> ExtendedPrivateKey {
    let mut secret_key = [0_u8; 32];
    secret_key.copy_from_slice(&bytes[..32]);
    let mut chain_code = [0_u8; 32];
    chain_code.copy_from_slice(&bytes[32..]);

    ExtendedPrivateKey {
        secret_key,
        chain_code,
    }
}

#[cfg(test)]
mod tests {
    use super::{HARDENED_OFFSET, derive_extended_private_key};

    #[test]
    fn matches_slip_0010_ed25519_master_and_first_hardened_vector() {
        let seed = hex::decode("000102030405060708090a0b0c0d0e0f")
            .unwrap_or_else(|error| unreachable!("static fixture is valid hex: {error}"));

        let master = derive_extended_private_key(&seed, &[])
            .unwrap_or_else(|error| unreachable!("SLIP-0010 master derivation succeeds: {error}"));
        assert_eq!(
            hex::encode(master.secret_key),
            "2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7"
        );
        assert_eq!(
            hex::encode(master.chain_code),
            "90046a93de5380a72b5e45010748567d5ea02bbf6522f979e05c0d8d8ca9fffb"
        );

        let first_child = derive_extended_private_key(&seed, &[0])
            .unwrap_or_else(|error| unreachable!("SLIP-0010 child derivation succeeds: {error}"));
        assert_eq!(
            hex::encode(first_child.secret_key),
            "68e0fe46dfb67e368c75379acec591dad19df3cde26e63b93a8e704f1dade7a3"
        );
        assert_eq!(
            hex::encode(first_child.chain_code),
            "8b59aa11380b624e81507a27fedda59fea6d0b779a778918a2fd3590e16e9c69"
        );
    }

    #[test]
    fn rejects_an_already_hardened_input_index() {
        let result = derive_extended_private_key(&[0_u8; 16], &[HARDENED_OFFSET]);
        assert!(result.is_err());
    }
}
