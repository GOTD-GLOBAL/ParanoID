//! Candidate identity-v3 primitives; not a server admission or registry verifier.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy)]
pub enum ProofRole {
    Owner,
    Device,
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Purpose {
    Inspect,
    Status,
    Enroll,
    Replace,
}

impl Purpose {
    fn name(self) -> &'static str {
        match self {
            Self::Inspect => "inspect",
            Self::Status => "status",
            Self::Enroll => "enroll",
            Self::Replace => "replace",
        }
    }
    fn path(self) -> &'static str {
        match self {
            Self::Inspect => "/v3/identity/inspect",
            Self::Status => "/v3/identity/status",
            Self::Enroll | Self::Replace => "/v3/identity/commit",
        }
    }
}

/// Wire representation only. Decoding/encoding is NOT semantic acceptance.
/// Callers must separately verify canonical keys, pins, PDA, saved intent and expiry.
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct IdentityChallengeV3 {
    pub id: String,
    pub nonce: String,
    pub epoch: String,
    pub expires: i64,
    pub realm: String,
    pub pin: String,
    pub purpose: Purpose,
    pub operation: String,
    pub genesis: String,
    pub program: String,
    pub identity: String,
    pub owner: String,
    pub name: String,
    pub account: String,
    pub device: String,
    pub credential_fingerprint: String,
    pub expected_generation: String,
}

impl IdentityChallengeV3 {
    /// Encoding primitive, not a signer. Do not sign without full context validation.
    pub fn transcript(&self, role: ProofRole) -> crate::Result<Vec<u8>> {
        let generation = parse_generation(&self.expected_generation)?;
        if self.expires < 0
            || (self.purpose == Purpose::Replace && (generation == 0 || generation == i64::MAX))
            || (self.purpose != Purpose::Replace && generation != 0)
            || (self.purpose == Purpose::Status && matches!(role, ProofRole::Owner))
        {
            return Err("invalid_challenge");
        }
        let domain = match role {
            ProofRole::Owner => "paranoid-identity-v3-owner",
            ProofRole::Device => "paranoid-identity-v3-device",
        };
        Ok(crate::transcript(&[
            domain,
            &self.id,
            &self.nonce,
            &self.epoch,
            &self.expires.to_string(),
            &self.realm,
            &self.pin,
            self.purpose.name(),
            &self.operation,
            &self.genesis,
            &self.program,
            &self.identity,
            &self.owner,
            &self.name,
            &self.account,
            &self.device,
            &self.credential_fingerprint,
            &self.expected_generation,
            "POST",
            self.purpose.path(),
        ]))
    }
}

/// Canonical decimal generation, bounded by PostgreSQL/Java signed 64-bit integers.
pub fn parse_generation(value: &str) -> crate::Result<i64> {
    if value.is_empty()
        || value.len() > 19
        || !value.bytes().all(|b| b.is_ascii_digit())
        || (value.len() > 1 && value.starts_with('0'))
    {
        return Err("invalid_generation");
    }
    value.parse().map_err(|_| "invalid_generation")
}
