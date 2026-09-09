use serde::{Deserialize, Serialize};
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Challenge {
    pub id: String,
    pub nonce: String,
    pub epoch: String,
    pub expires: i64,
    pub realm: String,
    pub pin: String,
    pub account: String,
    pub device: String,
    pub credential: String,
    pub grant: String,
    pub slot: i16,
    pub purpose: String,
    pub method: String,
    pub path: String,
    pub body: String,
}
impl Challenge {
    pub fn bytes(&self) -> Vec<u8> {
        crate::transcript(&[
            "paranoid-proof-v1",
            &self.id,
            &self.nonce,
            &self.epoch,
            &self.expires.to_string(),
            &self.realm,
            &self.pin,
            &self.account,
            &self.device,
            &self.credential,
            &self.grant,
            &self.slot.to_string(),
            &self.purpose,
            &self.method,
            &self.path,
            &self.body,
        ])
    }
}
