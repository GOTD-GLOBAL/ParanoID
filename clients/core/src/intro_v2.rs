//! Mandatory signed clean-install channel. Historical intro-v1 is not reinterpreted.
use super::contact_v2::ContactV2;
use super::*;
use paranoid_key_protocol::{digest, transcript, verify};
pub(super) const PROFILE: &str = "account-id-intro-v1";
const DOMAIN: &str = "paranoid-sender-intro-v2";
pub(super) fn canonical_id(id: &str) -> bool {
    uuid::Uuid::parse_str(id).is_ok_and(|u| u.to_string() == id && u.get_version_num() == 4)
}
pub(super) fn frame(text: &str) -> Result<Vec<u8>> {
    if text.len() > 4 * 16384_usize.div_ceil(3) {
        return Err("introduction_limit");
    }
    let bytes = STANDARD.decode(text).map_err(|_| "invalid_introduction")?;
    if !(2..=16384).contains(&bytes.len()) || STANDARD.encode(&bytes) != text {
        return Err("invalid_introduction");
    }
    Ok(bytes)
}
pub(super) fn channel(a: &ContactV2, b: &ContactV2) -> Result<String> {
    if a.credential.account == b.credential.account
        || a.credential.realm != b.credential.realm
        || a.credential.pin != b.credential.pin
    {
        return Err("introduction_context_mismatch");
    }
    let (low, high) = if a.credential.account < b.credential.account {
        (a, b)
    } else {
        (b, a)
    };
    Ok(digest(&transcript(&[
        "paranoid-first-contact-channel-v1",
        &low.credential.account,
        &low.credential.device,
        &low.credential.fingerprint(),
        &low.fingerprint(),
        &high.credential.account,
        &high.credential.device,
        &high.credential.fingerprint(),
        &high.fingerprint(),
        &a.credential.realm,
        &a.credential.pin,
        PROFILE,
    ])))
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Introduction {
    #[serde(rename = "type")]
    kind: String,
    pub contact: ContactV2,
    recipient_account: String,
    recipient_device: String,
    recipient_credential: String,
    recipient_contact: String,
    id: String,
    profile: String,
    pub channel: String,
    ciphertext: String,
    signature: String,
}
impl Introduction {
    pub fn inner(&self) -> Result<Vec<u8>> {
        let inner = frame(&self.ciphertext)?;
        if inner[0] > 1 {
            return Err("invalid_introduction");
        }
        OlmMessage::from_parts(inner[0] as usize, &inner[1..])
            .map_err(|_| "invalid_introduction")?;
        Ok(inner)
    }
    fn bytes(&self) -> Result<Vec<u8>> {
        Ok(transcript(&[
            DOMAIN,
            &self.contact.fingerprint(),
            &self.recipient_account,
            &self.recipient_device,
            &self.recipient_credential,
            &self.recipient_contact,
            &self.id,
            &self.profile,
            &self.channel,
            &digest(&self.inner()?),
        ]))
    }
    pub fn create(
        own: &Client,
        fallback: &str,
        recipient: &ContactV2,
        pending: &Outgoing,
        selected: &str,
    ) -> Result<Outgoing> {
        recipient.verify(own)?;
        let local = ContactV2::create(own, fallback)?;
        if pending.recipient != recipient.credential.account
            || !canonical_id(&pending.id)
            || selected != channel(&local, recipient)?
        {
            return Err("introduction_context_mismatch");
        }
        let mut intro = Self {
            kind: DOMAIN.into(),
            contact: local,
            recipient_account: recipient.credential.account.clone(),
            recipient_device: recipient.credential.device.clone(),
            recipient_credential: recipient.credential.fingerprint(),
            recipient_contact: recipient.fingerprint(),
            id: pending.id.clone(),
            profile: PROFILE.into(),
            channel: selected.into(),
            ciphertext: pending.ciphertext.clone(),
            signature: String::new(),
        };
        let identity = own.identity.as_ref().ok_or("invalid_state")?;
        intro.signature = vodozemac::Ed25519SecretKey::from_base64(&identity.auth_secret)
            .map_err(|_| "invalid_state")?
            .sign(&intro.bytes()?)
            .to_base64();
        let mut bytes = vec![2];
        bytes.extend(serde_json::to_vec(&intro).map_err(|_| "state_error")?);
        if bytes.len() > 16384 {
            return Err("introduction_limit");
        }
        Ok(Outgoing {
            id: pending.id.clone(),
            recipient: pending.recipient.clone(),
            ciphertext: STANDARD.encode(bytes),
        })
    }
    pub fn inspect(own: &Client, fallback: &str, message: &Incoming) -> Result<Self> {
        let bytes = frame(&message.ciphertext)?;
        if bytes[0] != 2 {
            return Err("invalid_introduction");
        }
        let intro: Self =
            serde_json::from_slice(&bytes[1..]).map_err(|_| "invalid_introduction")?;
        intro.contact.verify(own)?;
        let local = ContactV2::create(own, fallback)?;
        if intro.kind != DOMAIN
            || intro.profile != PROFILE
            || intro.contact.credential.account != message.sender
            || intro.recipient_account != local.credential.account
            || intro.recipient_device != local.credential.device
            || intro.recipient_credential != local.credential.fingerprint()
            || intro.recipient_contact != local.fingerprint()
            || intro.id != message.id
            || !canonical_id(&intro.id)
            || intro.channel != channel(&local, &intro.contact)?
        {
            return Err("introduction_context_mismatch");
        }
        verify(
            &intro.contact.credential.auth,
            &intro.bytes()?,
            &intro.signature,
        )?;
        Ok(intro)
    }
}
