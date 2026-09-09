use super::*;
use paranoid_key_protocol::{digest, olm_digest, transcript, verify, Credential};
#[derive(Serialize, Deserialize, Clone, PartialEq)]
#[serde(deny_unknown_fields)]
pub(super) struct ContactV2 {
    #[serde(rename = "type")]
    kind: String,
    pub credential: Credential,
    pub bundle: Bundle,
    pub fallback_key: String,
    signature: String,
}
impl ContactV2 {
    fn bytes(&self) -> Vec<u8> {
        transcript(&[
            "paranoid-contact-v2",
            &self.credential.fingerprint(),
            &self.bundle.device,
            &self.bundle.realm,
            &self.bundle.curve,
            &self.bundle.one_time_key,
            &self.fallback_key,
        ])
    }
    pub fn fingerprint(&self) -> String {
        digest(&self.bytes())
    }
    pub fn create(s: &Client, fallback: &str) -> Result<Self> {
        let i = s.identity.as_ref().ok_or("invalid_state")?;
        let mut c = Self {
            kind: "paranoid-contact-v2".into(),
            credential: i.credential.clone(),
            bundle: s.public.clone(),
            fallback_key: fallback.into(),
            signature: String::new(),
        };
        c.signature = vodozemac::Ed25519SecretKey::from_base64(&i.auth_secret)
            .map_err(|_| "invalid_state")?
            .sign(&c.bytes())
            .to_base64();
        Ok(c)
    }
    pub fn verify(&self, s: &Client) -> Result<()> {
        self.credential.verify()?;
        let own = &s
            .identity
            .as_ref()
            .ok_or("create_identity_first")?
            .credential;
        if self.kind != "paranoid-contact-v2"
            || self.credential.realm != own.realm
            || self.credential.pin != own.pin
            || self.bundle.realm != own.realm
            || self.credential.account == own.account
            || self.bundle.curve == s.public.curve
            || self.credential.olm != olm_digest(&self.bundle.curve, &self.bundle.one_time_key)
            || !["unassigned", "alice", "bob"].contains(&self.bundle.device.as_str())
        {
            return Err("contact_binding_mismatch");
        }
        for raw in [
            &self.bundle.curve,
            &self.bundle.one_time_key,
            &self.fallback_key,
        ] {
            if key(raw)?.to_base64() != *raw {
                return Err("invalid_peer_key");
            }
        }
        verify(&self.credential.auth, &self.bytes(), &self.signature)
    }
}
