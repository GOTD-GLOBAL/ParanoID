use super::{Bundle, Client, Result};
use paranoid_key_protocol::{digest, olm_digest, transcript, verify, Credential};
use serde::{Deserialize, Serialize};
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Status {
    pub mode: String,
    pub slot: i16,
    pub grant: String,
    pub credential: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Contact {
    #[serde(rename = "type")]
    pub kind: String,
    pub credential: Credential,
    pub bundle: Bundle,
    pub signature: String,
}
impl Contact {
    fn bytes(&self) -> Vec<u8> {
        transcript(&[
            "paranoid-contact-v1",
            &self.credential.fingerprint(),
            &self.bundle.device,
            &self.bundle.realm,
            &self.bundle.curve,
            &self.bundle.one_time_key,
        ])
    }
    pub fn fingerprint(&self) -> String {
        digest(&self.bytes())
    }
    pub fn verify(&self, s: &Client) -> Result<()> {
        self.credential.verify()?;
        let own = s.identity.as_ref().ok_or("create_identity_first")?;
        if self.kind != "paranoid-contact-v1"
            || self.credential.realm != s.public.realm
            || self.bundle.realm != s.public.realm
            || self.credential.pin != own.credential.pin
            || self.credential.account == own.credential.account
            || self.credential.olm != olm_digest(&self.bundle.curve, &self.bundle.one_time_key)
        {
            return Err("contact_binding_mismatch");
        }
        verify(&self.credential.auth, &self.bytes(), &self.signature)?;
        if s.peer_credential
            .as_ref()
            .is_some_and(|old| *old != self.credential)
        {
            return Err("peer_already_pinned");
        }
        super::validate_peer(s, &self.bundle, true)
    }
}
pub(super) fn contact(s: &Client) -> Result<Option<Contact>> {
    if s.enrollment.as_ref().map(|e| e.mode.as_str()) != Some("active") {
        return Ok(None);
    }
    let i = s.identity.as_ref().ok_or("invalid_state")?;
    let mut c = Contact {
        kind: "paranoid-contact-v1".into(),
        credential: i.credential.clone(),
        bundle: s.public.clone(),
        signature: String::new(),
    };
    let key =
        vodozemac::Ed25519SecretKey::from_base64(&i.auth_secret).map_err(|_| "invalid_state")?;
    c.signature = key.sign(&c.bytes()).to_base64();
    Ok(Some(c))
}
