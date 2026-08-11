use core::fmt;

/// Errors returned by the experimental identity key-hierarchy implementation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdentityError {
    /// The supplied BIP-39 mnemonic is invalid or is not an English mnemonic.
    InvalidMnemonic,
    /// A standard key-derivation operation failed.
    KeyDerivationFailed,
    /// SLIP-0010 received an index outside its non-hardened input range.
    InvalidSlip10Index,
}

impl fmt::Display for IdentityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidMnemonic => "invalid English BIP-39 mnemonic",
            Self::KeyDerivationFailed => "identity key derivation failed",
            Self::InvalidSlip10Index => "invalid SLIP-0010 child index",
        };

        formatter.write_str(message)
    }
}

impl std::error::Error for IdentityError {}
