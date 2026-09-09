//! Public, non-bearer session context for draft realtime-v1. Signing callers must
//! independently bind method/path/body to their durable native request intent.
use crate::{Credential, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionV2 {
    pub id: String,
    pub epoch: String,
    pub expires: i64,
    pub realm: String,
    pub pin: String,
    pub account: String,
    pub device: String,
    pub credential: String,
}

/// A nonce is a canonical UUIDv4, not an attacker-sized arbitrary string.
pub fn session_nonce_valid(nonce: &str) -> bool {
    uuid::Uuid::parse_str(nonce)
        .map(|n| n.get_version_num() == 4 && n.to_string() == nonce)
        .unwrap_or(false)
}

impl SessionV2 {
    /// Validate retained identity/trust, without trusting client wall-clock time.
    /// Server expiry enforcement and client monotonic renewal are separate.
    pub fn validate_binding(&self, credential: &Credential) -> Result<()> {
        if !session_nonce_valid(&self.id)
            || !session_nonce_valid(&self.epoch)
            || self.expires <= 0
            || self.realm != credential.realm
            || self.pin != credential.pin
            || self.account != credential.account
            || self.device != credential.device
            || self.credential != credential.fingerprint()
        {
            return Err("session_binding");
        }
        Ok(())
    }

    /// Canonical signing bytes only; this does not authorize arbitrary intents.
    pub fn bytes(&self, nonce: &str, method: &str, path: &str, body_digest: &str) -> Vec<u8> {
        crate::transcript(&[
            "paranoid-session-request-v1",
            &self.id,
            &self.epoch,
            &self.expires.to_string(),
            &self.realm,
            &self.pin,
            &self.account,
            &self.device,
            &self.credential,
            nonce,
            method,
            path,
            body_digest,
        ])
    }
}
