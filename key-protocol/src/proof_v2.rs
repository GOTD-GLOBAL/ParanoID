use serde::{Deserialize, Serialize};
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ChallengeV2 {
    pub id: String,
    pub nonce: String,
    pub epoch: String,
    pub expires: i64,
    pub realm: String,
    pub pin: String,
    pub account: String,
    pub device: String,
    pub credential: String,
    pub purpose: String,
    pub method: String,
    pub path: String,
    pub body: String,
}
impl ChallengeV2 {
    pub fn bytes(&self) -> Vec<u8> {
        crate::transcript(&[
            "paranoid-proof-v2",
            &self.id,
            &self.nonce,
            &self.epoch,
            &self.expires.to_string(),
            &self.realm,
            &self.pin,
            &self.account,
            &self.device,
            &self.credential,
            &self.purpose,
            &self.method,
            &self.path,
            &self.body,
        ])
    }
}
